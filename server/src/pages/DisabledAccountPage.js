import React from "react";
import { useAuth } from "../context/AuthContext";
import IdentityBadges from "../components/IdentityBadges";

export default function DisabledAccountPage() {
  const { session } = useAuth();

  return (
    <div>
      <h1>Account Disabled</h1>
      <p className="muted">
        Your account has been disabled by a SuperAdmin and is no longer
        authorized to access any cloud resources or platform features.
        Contact your system administrator if you believe this is an error.
      </p>

      <div className="card" style={{ marginTop: "1rem" }}>
        <h2>Your account</h2>
        <table>
          <tbody>
            <tr>
              <td>Email</td>
              <td>{session?.email || <span className="muted">not set</span>}</td>
            </tr>
            <tr>
              <td>Internal ID</td>
              <td><code>{session?.internalUserId}</code></td>
            </tr>
            <tr>
              <td>Status</td>
              <td><span className="role-pill disabled">disabled</span></td>
            </tr>
            <tr>
              <td>Linked identities</td>
              <td>
                {session?.linkedIdentities?.length > 0 ? (
                  <IdentityBadges identities={session.linkedIdentities} />
                ) : (
                  <span className="muted">none</span>
                )}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div className="card" style={{ marginTop: "1rem" }}>
        <h2>What does "disabled" mean?</h2>
        <ul style={{ paddingLeft: "1.25rem", lineHeight: "1.8" }}>
          <li>Your account still exists in the identity directory (LLDAP / external IdP).</li>
          <li>All role-based access has been revoked — you cannot view, provision, or manage any cloud resources.</li>
          <li>A <strong>SuperAdmin</strong> can re-enable your account by assigning you a new role
              from the <strong>Superadmin → User Management</strong> screen.</li>
          <li>Your login credentials remain valid, but the platform denies all actions.</li>
        </ul>
      </div>
    </div>
  );
}
