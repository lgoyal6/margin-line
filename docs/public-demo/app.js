// Read the saved reports only after their pinned byte hashes match.
// Selectors compare recorded horizons and checkpoints, without rerunning trades.
// The loss panel retains the adverse keeper-outage result.
const byId = (id) => document.getElementById(id);
const percent = (value) => Number.isFinite(value) ? `${(value * 100).toFixed(2)}%` : "Not recorded";
const money = (value) => new Intl.NumberFormat("en-US", {style:"currency",currency:"USD"}).format(Number(value) / 1e6);
const reports = {};

function table(rows) {
  const element = document.createElement("table");
  const head = element.createTHead().insertRow();
  for (const text of ["Recorded group", "Checkpoints", "Liquidation rate"]) {
    const cell = document.createElement("th");cell.scope = "col";cell.textContent = text;head.append(cell);
  }
  const body = element.createTBody();
  for (const cells of rows) {
    const row = body.insertRow();
    for (const value of cells) row.insertCell().textContent = String(value);
  }
  return element;
}

function renderRates() {
  const report = reports[byId("horizon").value];
  const selected = byId("checkpoint").value;
  const row = selected === "all" ? report : report.checkpoints.find((item) => item.checkpoint === selected);
  const total = selected === "all" ? report.trader_checkpoints : row.traders;
  byId("rates").replaceChildren(table([
    ["Approved", row.approved, percent(row.approved_liq_rate)],
    ["Denied", total - row.approved, percent(row.denied_liq_rate)],
  ]));
  byId("population").textContent = selected === "all"
    ? `${total.toLocaleString()} trader checkpoints, ${report.unique_traders.toLocaleString()} distinct traders; ${report.unique_approved_traders} distinct approved traders. Window: ${report.window[0].slice(0,10)} to ${report.window[1].slice(0,10)}.`
    : `${selected}: ${total} trader checkpoints. Small approval groups can produce unstable rates.`;
}

function setHorizon() {
  byId("checkpoint").replaceChildren(new Option("All recorded checkpoints", "all"),
    ...reports[byId("horizon").value].checkpoints.map((row) => new Option(row.checkpoint, row.checkpoint)));
  renderRates();
}

function renderLoss() {
  const scenario = reports["stress.json"].scenarios.find((row) => row.name === byId("scenario").value);
  byId("scenario-description").textContent = scenario.about;
  const loss = BigInt(scenario.end.totalLosses) - BigInt(scenario.start.totalLosses);
  const value = document.createElement("p");value.className = `loss-value${loss === 0n ? " zero" : ""}`;
  value.textContent = `${money(loss)} recorded pool loss`;
  const context = document.createElement("p");
  context.textContent = `Saved replay date: ${reports["stress.json"].day}. ${scenario.lines.length} credit lines. This amount comes directly from the recorded pool accounting.`;
  byId("loss").replaceChildren(value, context);
}

async function start() {
  const response = await fetch("evidence.json");if (!response.ok) throw new Error("Evidence index unavailable. Reload to retry.");
  const manifest = await response.json();
  for (const record of manifest.reports) {
    const response = await fetch(`source/${record.file}`);if (!response.ok) throw new Error(`Saved report unavailable: ${record.file}`);
    const bytes = await response.arrayBuffer();
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    const actual = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2,"0")).join("");
    if (actual !== record.sha256) throw new Error(`Saved report hash mismatch: ${record.file}`);
    reports[record.file] = JSON.parse(new TextDecoder().decode(bytes));
    const item = document.createElement("li");const link = document.createElement("a");
    link.href = `source/${record.file}`;link.textContent = record.path;item.append(link);byId("sources").append(item);
  }
  byId("scenario").replaceChildren(...reports["stress.json"].scenarios.map((row) => new Option(`${row.name}: ${row.keeper === "atClose" ? "Keeper offline until close" : row.terms === "approved" ? "Approved credit" : "Maximum credit"}${row.entry === "worst" ? ", worst entries" : ", held from open"}`,row.name)));
  byId("scenario").value = "D";setHorizon();renderLoss();
  byId("horizon").onchange = setHorizon;byId("checkpoint").onchange = renderRates;byId("scenario").onchange = renderLoss;
  byId("reset").onclick = () => {byId("horizon").value="seven.json";byId("scenario").value="D";setHorizon();renderLoss();};
  for (const id of ["horizon","checkpoint","scenario","reset"]) byId(id).disabled=false;
  byId("status").textContent = "All three reports match their pinned SHA-256 hashes.";
  byId("provenance").textContent = `Evidence source revision ${manifest.source_commit}. Selecting a view changes the saved result shown, not the underlying experiment.`;
}
start().catch((error) => {byId("status").className="error";byId("status").textContent=error.message;});
