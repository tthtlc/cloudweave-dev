import React from "react";
import { useAuth } from "../context/AuthContext";
import IdentityBadges from "../components/IdentityBadges";

export default function PendingApprovalPage() {
  const { session } = useAuth();

  return (
    <div>
      <h1>Account Pending Approval</h1>
      <p className="muted">
        Your account has been created but is not yet authorized to access any
        cloud resources. A SuperAdmin must assign you a role and tenant before
        you can view or provision resources.
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
              <td><span className="role-pill pending">pending</span></td>
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
        <h2>What happens next?</h2>
        <ol style={{ paddingLeft: "1.25rem", lineHeight: "1.8" }}>
          <li>A SuperAdmin reviews your account in the <strong>Superadmin → User Management</strong> screen.</li>
          <li>They assign you a <strong>role</strong> (viewer, admin, or owner) and a <strong>tenant</strong> (aws or nutanix).</li>
          <li>Once assigned, log out and log back in — you will be routed to your new dashboard.</li>
        </ol>
      </div>
    </div>
  );
}
