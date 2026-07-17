import React from "react";
import { useAuth } from "../context/AuthContext";
import IdentityBadges from "../components/IdentityBadges";

export default function ViewerDashboard() {
  const { session } = useAuth();
  if (!session) return null;

  const provider = session.linkedIdentities?.[0]?.split(":")[0] || "—";

  return (
    <div>
      <h1>Viewer — Read-only</h1>
      <p className="muted">
        Viewers can see their own profile, role, and linked identities. All
        mutating actions are gated by the backend.
      </p>

      <div className="card">
        <h2>Profile</h2>
        <table>
          <tbody>
            <tr><th>Internal user ID</th><td><code>{session.internalUserId}</code></td></tr>
            <tr><th>Email</th><td>{session.email || "—"}</td></tr>
            <tr><th>Role</th><td><span className={`role-pill ${session.role}`}>{session.role}</span></td></tr>
            <tr><th>Login provider</th><td>{provider}</td></tr>
            <tr><th>Linked identities</th><td><IdentityBadges identities={session.linkedIdentities || []} /></td></tr>
          </tbody>
        </table>
      </div>
    </div>
  );
}
