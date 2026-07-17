import React, { useEffect, useMemo, useState } from "react";
import { useAuth } from "../context/AuthContext";
import api from "../services/api";
import IdentityBadges from "../components/IdentityBadges";
import Banner from "../components/Banner";

const ROLES = ["superadmin", "owner", "admin", "viewer"];

export default function SuperAdminDashboard() {
  const { session, updateRole } = useAuth();
  const [users, setUsers] = useState([]);
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
    } catch (e) {
      setErr(e.message || String(e));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { refresh(); }, []);

  async function changeRole(user, role) {
    setMsg(null); setErr(null);
    try {
      const updated = await api.setRole(user.internalUserId, role);
      setUsers((prev) => prev.map((u) => (u.internalUserId === updated.internalUserId ? updated : u)));
      if (session?.internalUserId === updated.internalUserId) updateRole(updated.role);
      setMsg(`Updated ${user.email} → ${role}`);
    } catch (e) {
      setErr(e.message || String(e));
    }
  }

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
        Manage all internal users and their roles. Role changes here call
        <code> PATCH /api/users/:id/role </code>; the backend enforces
        authorization (OpenFGA) — these controls are UX only.
      </p>

      {msg && <Banner kind="success">{msg}</Banner>}
      {err && <Banner kind="error">{err}</Banner>}

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
              </tr>
            </thead>
            <tbody>
              {filtered.map((u) => (
                <tr key={u.internalUserId}>
                  <td><code>{u.internalUserId}</code></td>
                  <td>{u.email}</td>
                  <td><span className={`role-pill ${u.role}`}>{u.role}</span></td>
                  <td><IdentityBadges identities={u.linkedIdentities} /></td>
                  <td>
                    <select
                      value={u.role}
                      onChange={(e) => changeRole(u, e.target.value)}
                    >
                      {ROLES.map((r) => (
                        <option key={r} value={r}>{r}</option>
                      ))}
                    </select>
                  </td>
                </tr>
              ))}
              {filtered.length === 0 && (
                <tr><td colSpan={5} className="muted">No matching users.</td></tr>
              )}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
