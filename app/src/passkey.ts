// Passkey-only accounts. Mera creates the passkey and derives the wallet from its PRF output
// (BIP-39 entropy, BIP-44 path), so the passkey is the only credential. The passkey's P-256 public
// key is registered onchain, and sensitive actions (sweep, close, session keys) need a fresh
// assertion that IdentityRegistry verifies with Monad's P-256 precompile.
import { createPasskeyWithPrfOutput } from "@category-labs/mera";
import { HDKey } from "@scure/bip32";
import { entropyToMnemonic, mnemonicToSeedSync } from "@scure/bip39";
import { wordlist } from "@scure/bip39/wordlists/english.js";
import { encodeAbiParameters, keccak256, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { identityRegistryAbi } from "./abi";
import { publicClient, walletFor, wait } from "./chain";

const P256_N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n;

const toHex = (b: ArrayBuffer | Uint8Array): Hex =>
  `0x${[...new Uint8Array(b instanceof Uint8Array ? b : new Uint8Array(b))].map((x) => x.toString(16).padStart(2, "0")).join("")}`;
const fromHex = (h: string) => new Uint8Array(h.slice(2).match(/../g)!.map((x) => parseInt(x, 16)));
const fromB64url = (s: string) =>
  Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));

// Mera does not expose the new credential's public key, so capture it from the creation response.
let lastSpki: ArrayBuffer | null = null;
const create = navigator.credentials.create.bind(navigator.credentials);
navigator.credentials.create = async (options?: CredentialCreationOptions) => {
  const cred = (await create(options)) as PublicKeyCredential;
  lastSpki = (cred.response as AuthenticatorAttestationResponse).getPublicKey();
  return cred;
};

export type Session = { walletKey: Hex; address: Address; credentialId: string; qx: Hex; qy: Hex };

const STORE = "margin-line-session";

/** The session lives only in this tab (sessionStorage). This is a demo convenience on the local
 *  fork; a production app re-derives the key from the passkey's PRF on every visit. */
export function loadSession(): Session | null {
  try {
    const raw = sessionStorage.getItem(STORE);
    return raw ? (JSON.parse(raw) as Session) : null;
  } catch {
    return null;
  }
}

function saveSession(s: Session) {
  try {
    sessionStorage.setItem(STORE, JSON.stringify(s));
  } catch {
    /* private mode: the session simply lasts until reload */
  }
}

export function clearSession() {
  try {
    sessionStorage.removeItem(STORE);
  } catch {
    /* nothing stored */
  }
}

function spkiToXY(spki: Hex): [Hex, Hex] {
  const point = spki.slice(-130);
  if (!point.startsWith("04")) throw new Error("Unexpected passkey public key encoding");
  return [`0x${point.slice(2, 66)}`, `0x${point.slice(66)}`];
}

export async function createAccount(): Promise<Session> {
  const r = await createPasskeyWithPrfOutput({
    rp: { id: location.hostname, name: "Margin Line" },
    user: { name: "margin-line-trader", displayName: "Margin Line trader" },
  });
  const seed = mnemonicToSeedSync(entropyToMnemonic(r.prfOutput, wordlist));
  const key = HDKey.fromMasterSeed(seed).derive("m/44'/60'/0'/0/0").privateKey;
  if (!key || !lastSpki) throw new Error("Passkey creation did not return a key");
  const walletKey = toHex(key);
  const [qx, qy] = spkiToXY(toHex(lastSpki));
  const session = { walletKey, address: privateKeyToAccount(walletKey).address, credentialId: r.credentialId, qx, qy };
  saveSession(session);
  return session;
}

export async function isRegistered(identity: Address, user: Address): Promise<boolean> {
  return publicClient.readContract({ address: identity, abi: identityRegistryAbi, functionName: "hasPasskey", args: [user] });
}

export async function registerOnchain(identity: Address, s: Session) {
  await wait(
    await walletFor(s.walletKey).writeContract({
      address: identity, abi: identityRegistryAbi, functionName: "registerFirstPasskey", args: [s.qx, s.qy],
    }),
  );
}

/** DER ECDSA signature to (r, s), with s in low form as the contract requires. */
function derToRS(der: Hex): [Hex, Hex] {
  const b = fromHex(der);
  let i = 2;
  const read = () => {
    if (b[i++] !== 0x02) throw new Error("Bad signature encoding");
    const len = b[i++];
    const v = b.slice(i, i + len);
    i += len;
    return BigInt(toHex(v));
  };
  const r = read();
  let s = read();
  if (s > P256_N / 2n) s = P256_N - s;
  const pad = (x: bigint): Hex => `0x${x.toString(16).padStart(64, "0")}`;
  return [pad(r), pad(s)];
}

export const actions = {
  sweep: (amount: bigint) => keccak256(encodeAbiParameters([{ type: "string" }, { type: "uint256" }], ["sweep", amount])),
  close: () => keccak256(new TextEncoder().encode("close")),
  grantSession: (key: Address, expiry: number, maxOrder: bigint, total: bigint) =>
    keccak256(
      encodeAbiParameters(
        [{ type: "string" }, { type: "address" }, { type: "uint40" }, { type: "uint96" }, { type: "uint96" }],
        ["grantSession", key, expiry, maxOrder, total],
      ),
    ),
};

/** Ask the passkey to approve `action` on `consumer` and return the onchain proof. */
export async function prove(identity: Address, s: Session, consumer: Address, action: Hex) {
  const challenge = await publicClient.readContract({
    address: identity, abi: identityRegistryAbi, functionName: "challengeFor", args: [s.address, consumer, action],
  });
  const keyId = await publicClient.readContract({
    address: identity, abi: identityRegistryAbi, functionName: "keyIdOf", args: [s.qx, s.qy],
  });
  const cred = (await navigator.credentials.get({
    publicKey: {
      challenge: fromHex(challenge),
      rpId: location.hostname,
      allowCredentials: [{ type: "public-key", id: fromB64url(s.credentialId) }],
      userVerification: "required",
    },
  })) as PublicKeyCredential;
  const res = cred.response as AuthenticatorAssertionResponse;
  const clientDataJSON = new TextDecoder().decode(res.clientDataJSON);
  const [r, sig] = derToRS(toHex(res.signature));
  return {
    keyId,
    auth: {
      r, s: sig,
      challengeIndex: BigInt(clientDataJSON.indexOf('"challenge":"')),
      typeIndex: BigInt(clientDataJSON.indexOf('"type":"webauthn.get"')),
      authenticatorData: toHex(res.authenticatorData),
      clientDataJSON,
    },
  };
}
