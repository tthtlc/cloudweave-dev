import React, { useState } from "react";
import api from "../services/api";
import Banner from "../components/Banner";
import { useAuth } from "../context/AuthContext";

// Per-cloud metadata. Both clouds share the SAME columns() factory and the
// SAME provision/deprovision/update wiring so the per-row Action column
// (Edit + Deprovision) renders identically for AWS and Nutanix, gated only by
// the per-cloud OpenFGA capabilities in `cap` (canUpdate / canProvision) that
// the backend already computes symmetrically for both clouds (fga.py
// cloud_capabilities). The only per-cloud differences here are the label, the
// region/cluster key, and the connection/provision script the backend replays.
// Helper to display the first IP from a list, or a dash if empty/absent.
function firstIp(ips) {
  if (!ips || !ips.length) return "—";
  return ips[0];
}

function actionColumns(ctx) {
  const { cap, readOnly, deprov, onDep, editing, saving, onEdit } = ctx;
  const showAction = !readOnly && (cap.canUpdate || cap.canProvision);
  return [
    { header: "ID", render: (n) => <code>{n.id}</code> },
    { header: "Name", render: (n) => n.name },
    { header: "Public IP", render: (n) => firstIp(n.public_ips) },
    { header: "Private IP", render: (n) => firstIp(n.private_ips) },
    { header: "Instance Type", render: (n) => n.size || "—" },
    { header: "State", render: (n) => n.state },
    ...(!showAction ? [] : [{
      header: "Action",
      render: (n) => (
        <span className="row-actions">
          {cap.canUpdate && (
            <button
              disabled={!!saving || editing === n.id}
              onClick={() => onEdit(n)}
            >
              {editing === n.id ? "Editing…" : "Edit"}
            </button>
          )}
          {cap.canProvision && (
            <button
              className="danger"
              disabled={deprov[n.id] === "pending" || !!saving || editing !== null}
              onClick={() => onDep(n)}
            >
              {deprov[n.id] === "pending" ? "Deprovisioning…" : "Deprovision"}
            </button>
          )}
        </span>
      ),
    }]),
  ];
}

// Generic read-only tables for the extra AWS resource categories the identity
// service fans out to (grouped per key_resource.md: where a VM can land,
// networks it can join, images it boots from, storage it consumes, object
// storage, access). The backend declares columns + rows per category, so this
// renderer stays cloud-agnostic and dumb. Absent `categories` (e.g. Nutanix)
// renders nothing.
function CategoryTables({ categories }) {
  const groups = {};
  (categories || []).forEach((cat) => {
    (groups[cat.group] = groups[cat.group] || []).push(cat);
  });
  return Object.entries(groups).map(([group, cats]) => (
    <div key={group} className="resource-group">
      <h3>{group}</h3>
      {cats.map((cat) => (
        <div key={cat.key} className="resource-category">
          <h4>{cat.title} ({typeof cat.total === "number" ? cat.total : cat.rows.length})</h4>
          {cat.error && <p className="muted">Unavailable: {cat.error}</p>}
          {!cat.error && cat.rows.length === 0 && <p className="muted">None</p>}
          {typeof cat.total === "number" && cat.total > cat.rows.length && (
            <p className="muted">Showing first {cat.rows.length} of {cat.total}.</p>
          )}
          {cat.rows.length > 0 && (
            <table>
              <thead>
                <tr>{cat.columns.map((col) => <th key={col.key}>{col.label}</th>)}</tr>
              </thead>
              <tbody>
                {cat.rows.map((row, i) => (
                  <tr key={row.id || row.name || row.address || i}>
                    {cat.columns.map((col) => <td key={col.key}>{row[col.key]}</td>)}
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      ))}
    </div>
  ));
}

const CLOUD_META = {
  aws: {
    label: "AWS",
    regionKey: "region",
    provision: (payload) => api.provision("aws", payload),
    resources: () => api.resources("aws"),
    deprovision: (payload) => api.deprovision("aws", payload),
    update: (payload) => api.update("aws", payload),
    columns: actionColumns,
  },
  nutanix: {
    label: "Nutanix",
    regionKey: "cluster",
    provision: (payload) => api.provision("nutanix", payload),
    resources: () => api.resources("nutanix"),
    deprovision: (payload) => api.deprovision("nutanix", payload),
    update: (payload) => api.update("nutanix", payload),
    columns: actionColumns,
  },
};

// Shared dashboard shell for admin + owner (+ read-only viewer). `role` controls
// the title; the backend (OpenFGA) differentiates permissions. `readOnly`
// (viewer) hides Provision/Edit/Deprovision and leaves only the View controls.
// The dashboard only renders the cloud(s) the logged-in user can access
// (rbac_design.md: roles are per-tenant, so the UI must match the user's tenant
// — an aws-admin / aws-viewer never sees Nutanix controls, and vice versa).
export function CloudDashboard({ role, readOnly = false }) {
  const { session } = useAuth();
  // Only clouds the user can view or provision. Computed live by the backend
  // from OpenFGA, so it stays correct after role/tenant changes.
  const clouds = (session?.clouds || []).filter((c) => c.canView || c.canProvision || c.canUpdate);

  const [busy, setBusy] = useState(null);
  const [msg, setMsg] = useState(null);
  const [err, setErr] = useState(null);
  // Per-cloud resource lists keyed by cloud id: { aws: {...}, nutanix: {...} }.
  const [resources, setResources] = useState({});
  const [provResult, setProvResult] = useState(null);
  // Result of the bastion + internal private VM pair provisioning
  // ("Provision Private VM Machine" button, AWS or Nutanix).
  const [privResult, setPrivResult] = useState(null);
  // Per-VM deprovisioning status: "pending" | "done" | "error" | null.
  const [deprov, setDeprov] = useState({});
  // Inline edit state: which VM id is being edited + the draft form fields.
  const [editing, setEditing] = useState(null);
  const [editDraft, setEditDraft] = useState(null);
  const [saving, setSaving] = useState(false);

  async function provision(cloud) {
    const meta = CLOUD_META[cloud];
    setBusy(cloud); setMsg(null); setErr(null);
    try {
      const r = await meta.provision({ vmName: `libcloud-${cloud}-${Date.now()}` });
      setProvResult(r);
      setMsg(`${meta.label} provisioning accepted: ${r.vmName}`);
    } catch (e) {
      setErr(e.message || String(e));
    } finally {
      setBusy(null);
    }
  }

  // "Provision Private VM Machine": bastion host + internal private server
  // pair (aws_bastion_internal_server.md / nutanix_bastion_internal_server.md).
  // The backend re-checks the OpenFGA can_provision grant and shells out to
  // test_script/scripts/provision_aws_private.sh (AWS) or
  // provision_nutanix_bastion_private.sh (Nutanix), which picks the tenant's
  // credentials from Vault via the server-side auth_binding.
  async function provisionPrivatePair(cloud) {
    setBusy(`${cloud}Private`); setMsg(null); setErr(null); setPrivResult(null);
    try {
      const prefix = cloud === "aws" ? "libcloud-aws-pair" : "libcloud-ntnx-pair";
      const r = await api.provisionPrivate(cloud, { vmName: `${prefix}-${Date.now()}` });
      setPrivResult(r);
      if (r.status === "provisioned") {
        setMsg(`Private VM pair provisioned: ${r.bastionName} (bastion) + ${r.internalName} (internal)`);
      } else {
        setErr(`Private VM pair provisioning failed: ${r.message || "see backend logs"}`);
      }
    } catch (e) {
      setErr(e.message || String(e));
    } finally {
      setBusy(null);
    }
  }

  async function view(cloud) {
    const meta = CLOUD_META[cloud];
    setBusy(`${cloud}View`); setMsg(null); setErr(null);
    try {
      const r = await meta.resources();
      setResources((prev) => ({ ...prev, [cloud]: r }));
    } catch (e) {
      setErr(e.message || String(e));
    } finally {
      setBusy(null);
    }
  }

  async function deprovision(cloud, node) {
    const meta = CLOUD_META[cloud];
    setDeprov((d) => ({ ...d, [node.id]: "pending" }));
    setErr(null);
    try {
      const r = await meta.deprovision({ vmId: node.id, vmName: node.name });
      setDeprov((d) => ({ ...d, [node.id]: r.status === "deprovisioned" ? "done" : "error" }));
      if (r.status !== "deprovisioned") {
        setErr(`Deprovision ${node.id} failed: ${r.message || "see backend logs"}`);
      } else {
        setMsg(`Deprovisioned ${node.id} (${node.name}) via deprovision_${cloud}.sh`);
        const refreshed = await meta.resources();
        setResources((prev) => ({ ...prev, [cloud]: refreshed }));
      }
    } catch (e) {
      setDeprov((d) => ({ ...d, [node.id]: "error" }));
      setErr(e.message || String(e));
    }
  }

  function startEdit(node) {
    setEditing(node.id);
    setEditDraft({
      name: node.name || "",
      newSizeId: node.size || "",
      memoryMib: "",
      tagKey: "",
      tagValue: "",
    });
    setErr(null);
    setMsg(null);
  }

  function cancelEdit() {
    setEditing(null);
    setEditDraft(null);
  }

  async function saveEdit(cloud, node) {
    const meta = CLOUD_META[cloud];
    setSaving(true); setErr(null);
    try {
      const payload = { vmId: node.id };
      if (editDraft.name !== node.name) payload.name = editDraft.name;
      if (editDraft.newSizeId) payload.newSizeId = editDraft.newSizeId;
      if (editDraft.memoryMib) payload.memoryMib = Number(editDraft.memoryMib);
      if (editDraft.tagKey) { payload.tagKey = editDraft.tagKey; payload.tagValue = editDraft.tagValue; }
      const r = await meta.update(payload);
      if (r.status === "failed") {
        setErr(`Edit ${node.id} failed: ${r.message || "see backend logs"}`);
      } else {
        setMsg(`Updated ${node.id} (${node.name}) via PATCH /v1/compute/nodes/{id}`);
        const refreshed = await meta.resources();
        setResources((prev) => ({ ...prev, [cloud]: refreshed }));
        cancelEdit();
      }
    } catch (e) {
      setErr(e.message || String(e));
    } finally {
      setSaving(false);
    }
  }

  const provisionable = !readOnly && clouds.filter((c) => c.canProvision);
  const viewable = clouds.filter((c) => c.canView);

  const title =
    role === "owner" ? "Owner Dashboard"
    : role === "viewer" ? "Viewer Dashboard"
    : "Admin Dashboard";

  return (
    <div>
      {!readOnly && (
        <>
          <h1>{title}</h1>
          <p className="muted">
            Provisioning and resource views delegate to backend endpoints that
            replay the exact orchestration order from{" "}
            <code>test_script/scripts/provision_aws.sh</code> and{" "}
            <code>test_script/scripts/provision_nutanix.sh</code>. The{" "}
            <strong>Provision Private VM Machine</strong> button (the tenant's
            owner/admin only) executes{" "}
            <code>test_script/scripts/provision_aws_private.sh</code> (AWS) or{" "}
            <code>test_script/scripts/provision_nutanix_bastion_private.sh</code>{" "}
            (Nutanix) to create a bastion host plus an internal private server.
            The frontend never invents cloud API sequences.
          </p>
        </>
      )}
      {readOnly && <h2>Resources</h2>}

      {msg && <Banner kind="success">{msg}</Banner>}
      {err && <Banner kind="error">{err}</Banner>}

      {clouds.length === 0 && (
        <div className="card">
          <p className="muted">
            You have no cloud access on this system. A SuperAdmin must assign
            you to a tenant before you can view or provision resources.
          </p>
        </div>
      )}

      {clouds.length > 0 && (
        <div className="card grid">
          {provisionable && provisionable.map((c) => (
            <React.Fragment key={c.cloud}>
              <button className="primary" disabled={!!busy} onClick={() => provision(c.cloud)}>
                {busy === c.cloud ? "Provisioning…" : `Provision ${CLOUD_META[c.cloud].label}`}
              </button>
              {/* Beside "Provision <cloud>": the bastion + internal private VM
                  pair. Rendered only when the session's per-cloud capability has
                  canProvision — i.e. that tenant's owner/admin only (viewers get
                  canView only; the backend re-checks the same OpenFGA grant). */}
              <button
                className="primary"
                disabled={!!busy}
                title={`Bastion host + internal private server on ${CLOUD_META[c.cloud].label}`}
                onClick={() => provisionPrivatePair(c.cloud)}
              >
                {busy === `${c.cloud}Private` ? "Provisioning…" : "Provision Private VM Machine"}
              </button>
            </React.Fragment>
          ))}
          {viewable.map((c) => (
            <button key={c.cloud} disabled={!!busy} onClick={() => view(c.cloud)}>
              {busy === `${c.cloud}View` ? "Loading…" : `View ${CLOUD_META[c.cloud].label} Resources`}
            </button>
          ))}
        </div>
      )}

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

      {privResult && (
        <div className="card">
          <h2>Private VM pair — {privResult.provider}</h2>
          <p>
            <strong>Bastion host:</strong> {privResult.bastionName}{" "}
            <strong>Internal server:</strong> {privResult.internalName} — <em>{privResult.status}</em>
          </p>
          <p className="muted">{privResult.message}</p>
          {privResult.stdout && (
            <>
              <h3>Script output ({privResult.provider === "aws" ? "provision_aws_private.sh" : "provision_nutanix_bastion_private.sh"}):</h3>
              <pre>{privResult.stdout}</pre>
            </>
          )}
        </div>
      )}

      {viewable
        .filter((c) => resources[c.cloud])
        .map((c) => {
          const meta = CLOUD_META[c.cloud];
          const list = resources[c.cloud];
          const ctx = {
            cap: c,
            readOnly,
            deprov,
            onDep: (node) => deprovision(c.cloud, node),
            editing,
            saving,
            onEdit: startEdit,
          };
          const cols = meta.columns(ctx);
          return (
            <div className="card" key={c.cloud}>
              <h2>{meta.label} resources ({list[meta.regionKey]})</h2>
              <table>
                <thead>
                  <tr>{cols.map((col) => <th key={col.header}>{col.header}</th>)}</tr>
                </thead>
                <tbody>
                  {list.nodes.map((n) => (
                    <React.Fragment key={n.id}>
                      <tr>
                        {cols.map((col) => <td key={col.header}>{col.render(n)}</td>)}
                      </tr>
                      {editing === n.id && meta.update && (
                        <tr className="edit-row">
                          <td colSpan={cols.length}>
                            <div className="edit-form">
                              <label>Name<input value={editDraft.name || ""} onChange={(e) => setEditDraft({ ...editDraft, name: e.target.value })} /></label>
                              <label>New size id<input value={editDraft.newSizeId || ""} onChange={(e) => setEditDraft({ ...editDraft, newSizeId: e.target.value })} placeholder="e.g. t3.small" /></label>
                              <label>Memory (MiB)<input type="number" value={editDraft.memoryMib || ""} onChange={(e) => setEditDraft({ ...editDraft, memoryMib: e.target.value })} /></label>
                              <label>Tag key<input value={editDraft.tagKey || ""} onChange={(e) => setEditDraft({ ...editDraft, tagKey: e.target.value })} /></label>
                              <label>Tag value<input value={editDraft.tagValue || ""} onChange={(e) => setEditDraft({ ...editDraft, tagValue: e.target.value })} /></label>
                              <span className="edit-actions">
                                <button className="primary" disabled={!!saving} onClick={() => saveEdit(c.cloud, n)}>
                                  {saving ? "Saving…" : "Save"}
                                </button>
                                <button disabled={!!saving} onClick={cancelEdit}>Cancel</button>
                              </span>
                            </div>
                          </td>
                        </tr>
                      )}
                    </React.Fragment>
                  ))}
                </tbody>
              </table>
              {/* Extra AWS resource categories (VPCs, subnets, SGs, ENIs, route
                  tables, IGWs, EIPs, AMIs, volumes, snapshots, buckets, key
                  pairs) from the identity service fan-out. Empty for Nutanix. */}
              <CategoryTables categories={list.categories || []} />
            </div>
          );
        })}
    </div>
  );
}

export default function AdminDashboard() {
  return <CloudDashboard role="admin" />;
}
