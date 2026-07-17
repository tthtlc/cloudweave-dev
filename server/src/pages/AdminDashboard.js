import React, { useState } from "react";
import api from "../services/api";
import Banner from "../components/Banner";

// Shared dashboard shell for admin + owner. `role` controls which actions
// are surfaced; wiring is identical so permissions can be differentiated
// later purely on the backend (OpenFGA) side.
export function CloudDashboard({ role }) {
  const [busy, setBusy] = useState(null);
  const [msg, setMsg] = useState(null);
  const [err, setErr] = useState(null);
  const [aws, setAws] = useState(null);
  const [ntnx, setNtnx] = useState(null);
  const [provResult, setProvResult] = useState(null);

  async function run(name, fn) {
    setBusy(name); setMsg(null); setErr(null);
    try {
      const r = await fn();
      if (name === "awsView") setAws(r);
      else if (name === "ntnxView") setNtnx(r);
      else { setProvResult(r); setMsg(`${name} provisioning accepted: ${r.vmName}`); }
    } catch (e) {
      setErr(e.message || String(e));
    } finally {
      setBusy(null);
    }
  }

  return (
    <div>
      <h1>{role === "owner" ? "Owner" : "Admin"} Dashboard</h1>
      <p className="muted">
        Provisioning and resource views delegate to backend endpoints that
        replay the exact orchestration order from{" "}
        <code>test_script/scripts/provision_aws.sh</code> and{" "}
        <code>test_script/scripts/provision_nutanix.sh</code>. The frontend
        never invents cloud API sequences.
      </p>

      {msg && <Banner kind="success">{msg}</Banner>}
      {err && <Banner kind="error">{err}</Banner>}

      <div className="card grid">
        <button className="primary" disabled={!!busy} onClick={() => run("aws", () => api.provisionAws({ vmName: `libcloud-demo-${Date.now()}` }))}>
          {busy === "aws" ? "Provisioning…" : "Provision AWS"}
        </button>
        <button className="primary" disabled={!!busy} onClick={() => run("ntnx", () => api.provisionNutanix({ vmName: `libcloud-ntnx-${Date.now()}` }))}>
          {busy === "ntnx" ? "Provisioning…" : "Provision Nutanix"}
        </button>
        <button disabled={!!busy} onClick={() => run("awsView", () => api.awsResources())}>
          {busy === "awsView" ? "Loading…" : "View AWS Resources"}
        </button>
        <button disabled={!!busy} onClick={() => run("ntnxView", () => api.nutanixResources())}>
          {busy === "ntnxView" ? "Loading…" : "View Nutanix Resources"}
        </button>
      </div>

      {provResult && (
        <div className="card">
          <h2>Provisioning request — {provResult.provider}</h2>
          <p><strong>VM:</strong> {provResult.vmName} — <em>{provResult.status}</em></p>
          <p className="muted">{provResult.message}</p>
          <h3>Backend orchestration contract (order preserved from script):</h3>
          <ol>
            {provResult.steps.map((s) => <li key={s}>{s}</li>)}
          </ol>
        </div>
      )}

      {aws && (
        <div className="card">
          <h2>AWS resources ({aws.region})</h2>
          <table>
            <thead><tr><th>ID</th><th>Name</th><th>State</th><th>Size</th></tr></thead>
            <tbody>
              {aws.nodes.map((n) => (
                <tr key={n.id}><td><code>{n.id}</code></td><td>{n.name}</td><td>{n.state}</td><td>{n.size}</td></tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {ntnx && (
        <div className="card">
          <h2>Nutanix resources ({ntnx.cluster})</h2>
          <table>
            <thead><tr><th>ID</th><th>Name</th><th>State</th><th>Size</th></tr></thead>
            <tbody>
              {ntnx.nodes.map((n) => (
                <tr key={n.id}><td><code>{n.id}</code></td><td>{n.name}</td><td>{n.state}</td><td>{n.size}</td></tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

export default function AdminDashboard() {
  return <CloudDashboard role="admin" />;
}
