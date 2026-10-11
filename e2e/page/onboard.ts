// Runs inside the browser. Onboards a user with nothing but a passkey: Mera creates the passkey and
// derives the user's wallet from its WebAuthn PRF output (24-word BIP-39 entropy, BIP-44 path, as in
// Monad's Mera guide). The passkey's P-256 public key is captured at creation so it can be registered
// onchain, and `approve` produces real WebAuthn assertions for onchain verification.

import { createPasskeyWithPrfOutput } from "@category-labs/mera";
import { HDKey } from "@scure/bip32";
import { entropyToMnemonic, mnemonicToSeedSync } from "@scure/bip39";
import { wordlist } from "@scure/bip39/wordlists/english.js";

const hex = (b: ArrayBuffer | Uint8Array) =>
  "0x" + [...new Uint8Array(b instanceof Uint8Array ? b : new Uint8Array(b))].map((x) => x.toString(16).padStart(2, "0")).join("");

const fromHex = (h: string) => new Uint8Array(h.slice(2).match(/../g)!.map((x) => parseInt(x, 16)));

const fromB64url = (s: string) => {
  const b = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
};

// Mera does not expose the credential's public key, so capture it from the creation response.
let lastSpki: ArrayBuffer | null = null;
const create = navigator.credentials.create.bind(navigator.credentials);
navigator.credentials.create = async (options?: CredentialCreationOptions) => {
  const cred = (await create(options)) as PublicKeyCredential;
  lastSpki = (cred.response as AuthenticatorAttestationResponse).getPublicKey();
  return cred;
};

declare global {
  interface Window {
    onboard: () => Promise<{ walletKey: string; credentialId: string; spki: string }>;
    approve: (challenge: string, credentialId: string) => Promise<{
      authenticatorData: string;
      clientDataJSON: string;
      signature: string;
    }>;
  }
}

window.onboard = async () => {
  const r = await createPasskeyWithPrfOutput({
    rp: { id: location.hostname, name: "Margin Line" },
    user: { name: "e2e-trader", displayName: "E2E Trader" },
  });
  const seed = mnemonicToSeedSync(entropyToMnemonic(r.prfOutput, wordlist));
  const key = HDKey.fromMasterSeed(seed).derive("m/44'/60'/0'/0/0").privateKey;
  if (!key || !lastSpki) throw new Error("passkey onboarding failed");
  // The wallet key leaves the page only because this is a headless test driver.
  return { walletKey: hex(key), credentialId: r.credentialId, spki: hex(lastSpki) };
};

window.approve = async (challenge: string, credentialId: string) => {
  const cred = (await navigator.credentials.get({
    publicKey: {
      challenge: fromHex(challenge),
      rpId: location.hostname,
      allowCredentials: [{ type: "public-key", id: fromB64url(credentialId) }],
      userVerification: "required",
    },
  })) as PublicKeyCredential;
  const res = cred.response as AuthenticatorAssertionResponse;
  return {
    authenticatorData: hex(res.authenticatorData),
    clientDataJSON: new TextDecoder().decode(res.clientDataJSON),
    signature: hex(res.signature),
  };
};
