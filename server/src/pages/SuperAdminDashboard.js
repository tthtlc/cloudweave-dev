import React, { useEffect, useMemo, useState } from "react";
import { useAuth } from "../context/AuthContext";
import api from "../services/api";
import IdentityBadges from "../components/IdentityBadges";
import Banner from "../components/Banner";

const ROLES = ["superadmin", "owner", "admin", "viewer", "disabled"];
const TENANTS = ["aws", "nutanix"];

// OAuth2/federated users (provisioned via _provision_pending) have IDs like
// "int-pending-<hex>". LLDAP users have IDs like "int-<uid>" where <uid> is
// their directory uid (superadmin, aws-admin, etc.). Federated users always
// need a tenant assignment; LLDAP users derive theirs from the principal slug.
const isFederatedUser = (u) => u.internalUserId?.startsWith("int-pending-");

// Company admins are stored as OpenFGA principals (raw uid, e.g. "user01"),
// while the user select is keyed by internalUserId ("int-user01"). Normalize
// the admin value to internalUserId form so the select shows the current admin.
const adminInternalId = (admin, users) => {
  if (!admin) return "";
  if (admin.startsWith("int-")) return admin;
  const match = users.find((u) => u.internalUserId === `int-${admin}` || u.internalUserId === admin);
  return match ? match.internalUserId : `int-${admin}`;
};
const adminDisplay = (admin, users) => {
  if (!admin) return "—";
  const match = users.find((u) => u.internalUserId === `int-${admin}` || u.internalUserId === admin);
  return match ? match.email || match.internalUserId : admin;
};

export default function SuperAdminDashboard() {
  const { session, updateRole } = useAuth();
  const [users, setUsers] = useState([]);
  const [drafts, setDrafts] = useState({}); // internalUserId -> selected role
  const [loading, setLoading] = useState(true);
  const [query, setQuery] = useState("");
  const [msg, setMsg] = useState(null);
  const [err, setErr] = useState(null);
  const [companies, setCompanies] = useState([]);
  const [companyName, setCompanyName] = useState("");
  const [companyAdminId, setCompanyAdminId] = useState("");
  const [editingCompany, setEditingCompany] = useState(null);
  const [companyDraft, setCompanyDraft] = useState({ name: "", adminUserId: "" });

  async function refresh() {
    setLoading(true);
    setErr(null);
    try {
      const { users: list } = await api.listUsers();
      setUsers(list);
      setDrafts({});
    } catch (e) {
      setErr(e.message || String(e));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { refresh(); }, []);

  function draftRole(u) {
    return drafts[u.internalUserId]?.role ?? u.role;
  }

  function draftTenant(u) {
    return drafts[u.internalUserId]?.tenant ?? u.tenant ?? "";
  }

  function setDraftRole(u, role) {
    setDrafts((prev) => ({
      ...prev,
      [u.internalUserId]: { ...prev[u.internalUserId], role },
    }));
  }

  function setDraftTenant(u, tenant) {
    setDrafts((prev) => ({
      ...prev,
      [u.internalUserId]: { ...prev[u.internalUserId], tenant },
    }));
  }

  async function saveRole(user) {
    const draft = drafts[user.internalUserId] || {};
    const role = draft.role ?? user.role;
    const tenant = draft.tenant ?? user.tenant;
    // "disabled" needs no tenant; federated users always require a tenant.
    if (role === user.role && tenant === (user.tenant || undefined)) return;
    if (role === "disabled" && user.role === "disabled") return; // nothing to save
    setMsg(null); setErr(null);
    try {
      const updated = await api.setRole(user.internalUserId, role, role === "disabled" ? undefined : tenant);
      setUsers((prev) => prev.map((u) => (u.internalUserId === updated.internalUserId ? updated : u)));
      setDrafts((prev) => { const n = { ...prev }; delete n[user.internalUserId]; return n; });
      if (session?.internalUserId === updated.internalUserId) updateRole(updated.role);
      setMsg(`Saved ${user.email || user.internalUserId} → ${role}${tenant && role !== "disabled" ? ` on ${tenant}` : ""}`);
    } catch (e) {
      setErr(e.message || String(e));
    }
  }

  async function disableUser(user) {
    if (!window.confirm(`Disable ${user.email || user.internalUserId} for this system?\nThis revokes all their OpenFGA role tuples. They stay valid in LLDAP / the external IdP.`)) return;
    setMsg(null); setErr(null);
    try {
      await api.disableUser(user.internalUserId);
      await refresh();
      setMsg(`Disabled ${user.email || user.internalUserId}`);
    } catch (e) {
      setErr(e.message || String(e));
    }
  }

  async function saveEmail(user) {
    const input = window.prompt(`Set contact email for ${user.internalUserId}`, user.email || "");
    if (input === null) return;
    const email = input.trim();
    if (!email || !email.includes("@")) {
      setErr("A valid email is required.");
      return;
    }
    setMsg(null); setErr(null);
    try {
      const updated = await api.setEmail(user.internalUserId, email);
      setUsers((prev) => prev.map((u) => (u.internalUserId === updated.internalUserId ? updated : u)));
      setMsg(`Email saved for ${user.internalUserId}`);
    } catch (e) {
      setErr(e.message || String(e));
    }
  }

  async function refreshCompanies() {
    try {
      const { companies: list } = await api.listCompanies();
      setCompanies(list);
    } catch (e) {
      setErr(e.message || String(e));
    }
  }

  useEffect(() => { refreshCompanies(); }, []);

  async function createCompany() {
    if (!companyName.trim() || !companyAdminId) {
      setErr("A company name and an admin user are required.");
      return;
    }
    setMsg(null); setErr(null);
    try {
      const r = await api.createCompany({ name: companyName.trim(), adminUserId: companyAdminId });
      setCompanyName(""); setCompanyAdminId("");
      setMsg(`Company "${r.id}" created with admin ${r.adminUserId}`);
      await refreshCompanies();
    } catch (e) {
      setErr(e.message || String(e));
    }
  }

  function startEditCompany(c) {
    setEditingCompany(c.id);
    setCompanyDraft({ name: c.id, adminUserId: adminInternalId(c.admin, users) });
    setMsg(null); setErr(null);
  }

  function cancelEditCompany() {
    setEditingCompany(null);
    setCompanyDraft({ name: "", adminUserId: "" });
  }

  async function saveCompany(c) {
    const name = companyDraft.name.trim();
    const adminUserId = companyDraft.adminUserId;
    if (!name) { setErr("A company name is required."); return; }
    if (!adminUserId) { setErr("A company admin is required."); return; }
    setMsg(null); setErr(null);
    try {
      const r = await api.updateCompany(c.id, { name, adminUserId });
      setMsg(`Company "${c.id}" updated${r.id !== c.id ? ` → renamed to "${r.id}"` : ""}`);
      setEditingCompany(null);
      setCompanyDraft({ name: "", adminUserId: "" });
      await refreshCompanies();
    } catch (e) {
      setErr(e.message || String(e));
    }
  }

  async function deleteCompany(c) {
    const n = (c.departments || []).length;
    const warn = `Delete company "${c.id}"?` + (n ? `\nThis also deletes its ${n} department(s) and all their members.` : "");
    if (!window.confirm(warn)) return;
    setMsg(null); setErr(null);
    try {
      await api.deleteCompany(c.id);
      setMsg(`Company "${c.id}" deleted.`);
      await refreshCompanies();
    } catch (e) {
      setErr(e.message || String(e));
    }
  }

  const missingEmail = useMemo(
    () => users.filter((u) => !u.email || !u.email.includes("@")),
    [users]
  );

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return users;
    return users.filter((u) =>
      u.email.toLowerCase().includes(q) || u.internalUserId.toLowerCase().includes(q)
    );
  }, [users, query]);

  return (
    <div>
      <h1>Superadmin — User Management</h1>
      <p className="muted">
        Manage all internal users and their roles. <code>Save</code> commits the
        selected role via <code>PATCH /api/users/:id/role</code> (the backend
        revokes the old role's OpenFGA tuples before writing the new one).
        <code>Disable</code> revokes all of the user's role tuples for this
        system only — they remain valid in LLDAP / the external IdP. The backend
        enforces authorization (OpenFGA); these controls are UX only.
      </p>

      {msg && <Banner kind="success">{msg}</Banner>}
      {err && <Banner kind="error">{err}</Banner>}
      {missingEmail.length > 0 && (
        <Banner kind="error">
          {missingEmail.length} user(s) have no email on file — email is
          mandatory for platform communication. Use “Set email” in each row.
        </Banner>
      )}

      <div className="card">
        <div className="row" style={{ marginBottom: "0.75rem" }}>
          <input
            placeholder="Search by email or internal user ID…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            style={{ minWidth: 260 }}
          />
          <div className="spacer" />
          <button onClick={refresh} disabled={loading}>{loading ? "Loading…" : "Refresh"}</button>
        </div>

        {loading ? (
          <p className="muted">Loading users…</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Internal ID</th>
                <th>Email</th>
                <th>Role</th>
                <th>Linked identities</th>
                <th>Change role</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((u) => {
                const draft = draftRole(u);
                const draftTnt = draftTenant(u);
                const federated = isFederatedUser(u);
                // Role change, or tenant change for a federated user.
                const dirty = draft !== u.role || (federated && draftTnt !== (u.tenant || ""));
                // LLDAP users: just dirty.  Federated users: also need a tenant
                // (unless moving to "disabled", which clears the tenant).
                const canSave = dirty && (!federated || draft === "disabled" || draftTnt);
                return (
                  <tr key={u.internalUserId}>
                    <td><code>{u.internalUserId}</code></td>
                    <td>
                      {u.email ? (
                        <>
                          {u.email}{" "}
                          <button className="primary" onClick={() => saveEmail(u)}>Edit</button>
                        </>
                      ) : (
                        <>
                          <span className="role-pill" style={{ background: "#c0392b", color: "#fff" }}>no email</span>{" "}
                          <button className="primary" onClick={() => saveEmail(u)}>Set email</button>
                        </>
                      )}
                    </td>
                    <td><span className={`role-pill ${u.role}`}>{u.role}</span></td>
                    <td><IdentityBadges identities={u.linkedIdentities} /></td>
                    <td>
                      <select value={draft} onChange={(e) => setDraftRole(u, e.target.value)}>
                        {ROLES.map((r) => (
                          <option key={r} value={r}>{r}</option>
                        ))}
                      </select>
                      {/* Federated (OAuth2) users always need a tenant.  LLDAP
                          users derive theirs from the uid slug so no selector. */}
                      {federated && draft !== "disabled" && (
                        <>
                          {" "}on{" "}
                          <select value={draftTnt} onChange={(e) => setDraftTenant(u, e.target.value)}>
                            <option value="">-- select tenant --</option>
                            {TENANTS.map((t) => (
                              <option key={t} value={t}>{t}</option>
                            ))}
                          </select>
                        </>
                      )}
                      {" "}
                      <button className="primary" disabled={!canSave} onClick={() => saveRole(u)}>
                        {dirty ? "Save" : "Saved"}
                      </button>
                    </td>
                    <td>
                      <button className="danger" onClick={() => disableUser(u)}>Disable</button>
                    </td>
                  </tr>
                );
              })}
              {filtered.length === 0 && (
                <tr><td colSpan={6} className="muted">No matching users.</td></tr>
              )}
            </tbody>
          </table>
        )}
      </div>

      <div className="card">
        <div className="row" style={{ marginBottom: "0.75rem" }}>
          <h2 style={{ margin: 0 }}>Companies</h2>
          <div className="spacer" />
          <button onClick={refreshCompanies}>Refresh</button>
        </div>
        <form
          className="row"
          style={{ gap: "0.5rem", marginBottom: "0.75rem" }}
          onSubmit={(e) => { e.preventDefault(); createCompany(); }}
        >
          <input
            placeholder="Company name (e.g. Acme)"
            value={companyName}
            onChange={(e) => setCompanyName(e.target.value)}
            style={{ minWidth: 200 }}
          />
          <select value={companyAdminId} onChange={(e) => setCompanyAdminId(e.target.value)}>
            <option value="">-- assign company admin --</option>
            {users.filter((u) => !u.internalUserId?.startsWith("int-pending-")).map((u) => (
              <option key={u.internalUserId} value={u.internalUserId}>
                {u.email || u.internalUserId}
              </option>
            ))}
          </select>
          <button className="primary" type="submit">Create company</button>
        </form>
        <table>
          <thead>
            <tr><th>Company</th><th>Admin</th><th>Departments</th><th>Actions</th></tr>
          </thead>
          <tbody>
            {companies.length === 0 && (
              <tr><td colSpan={4} className="muted">No companies yet.</td></tr>
            )}
            {companies.map((c) => {
              const editing = editingCompany === c.id;
              return (
                <tr key={c.id}>
                  <td>
                    {editing ? (
                      <input
                        value={companyDraft.name}
                        onChange={(e) => setCompanyDraft({ ...companyDraft, name: e.target.value })}
                      />
                    ) : (
                      <code>{c.id}</code>
                    )}
                  </td>
                  <td>
                    {editing ? (
                      <select
                        value={companyDraft.adminUserId}
                        onChange={(e) => setCompanyDraft({ ...companyDraft, adminUserId: e.target.value })}
                      >
                        <option value="">-- assign company admin --</option>
                        {users.filter((u) => !u.internalUserId?.startsWith("int-pending-")).map((u) => (
                          <option key={u.internalUserId} value={u.internalUserId}>
                            {u.email || u.internalUserId}
                          </option>
                        ))}
                      </select>
                    ) : (
                      adminDisplay(c.admin, users)
                    )}
                  </td>
                  <td>
                    {(c.departments || []).map((d) => `${d.id} (${(d.clouds || []).join(", ")})`).join(", ") || "—"}
                  </td>
                  <td>
                    {editing ? (
                      <span className="row-actions">
                        <button className="primary" onClick={() => saveCompany(c)}>Save</button>
                        <button onClick={cancelEditCompany}>Cancel</button>
                      </span>
                    ) : (
                      <span className="row-actions">
                        <button onClick={() => startEditCompany(c)}>Edit</button>
                        <button className="danger" onClick={() => deleteCompany(c)}>Delete</button>
                      </span>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
