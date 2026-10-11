import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./styles.css";
import { isLocalFork, loadDeployment } from "./chain";
import { Curate } from "./pages/Curate";
import { Explore } from "./pages/Explore";
import { Lend } from "./pages/Lend";
import { Trade } from "./pages/Trade";
import { useLoad } from "./ui";

const routes = { trade: Trade, lend: Lend, curate: Curate, explore: Explore } as const;
type Route = keyof typeof routes;

function currentRoute(): Route {
  const name = window.location.pathname.slice(1).toLowerCase();
  return (name in routes ? name : "trade") as Route;
}

function App() {
  const route = currentRoute();
  const deployment = useLoad(loadDeployment, []);
  const Page = routes[route];
  return (
    <div className="app-shell">
      <header className="topbar">
        <a className="brand" href="/">Margin Line<span className="brand-dot">.</span></a>
        <nav aria-label="Main navigation">
          {(Object.keys(routes) as Route[]).map((r) => (
            <a key={r} className={route === r ? "nav-link active" : "nav-link"} href={`/${r}`}>{r[0].toUpperCase() + r.slice(1)}</a>
          ))}
        </nav>
        <span className="network-badge"><span className="status-dot" />{isLocalFork() ? "Local fork of Monad testnet" : "Monad testnet"}</span>
      </header>
      <main>
        <section className="intro">
          <h1>Credit for traders who have earned it.</h1>
          <p className="lede">
            Lenders fund traders with a proven record on Perpl. The borrowed money stays in a trading account the protocol
            owns, so a trader can trade it but never take it out.
          </p>
        </section>
        {deployment.error && <p className="action-error">{deployment.error}</p>}
        {deployment.data && <Page d={deployment.data} />}
      </main>
      <footer>
        Margin Line on Monad. {isLocalFork() ? "Running against a local fork: test funds and demo approvals are fork-only." : ""}
      </footer>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<StrictMode><App /></StrictMode>);
