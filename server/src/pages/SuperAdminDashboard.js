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

export default function SuperAdminDashboard() {
  const { session, updateRole } = useAuth();
  const [users, setUsers] = useState([]);
  const [drafts, setDrafts] = useState({}); // internalUserId -> selected role
  const [loading, setLoading] = useState(true);
  const [query, setQuery] = useState("");
  const [msg, setMsg] = useState(null);
  const [err, setErr] = useState(null);

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
    const federated = isFederatedUser(user);
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
    </div>
  );
}
