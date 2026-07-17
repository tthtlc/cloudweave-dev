import React from "react";
import { CloudDashboard } from "./AdminDashboard";

// Owner uses the same shell as admin. The backend (OpenFGA) differentiates
// permissions; the UI keeps the layout identical for future extension.
export default function OwnerDashboard() {
  return (
    <>
      <CloudDashboard role="owner" />
      <div className="card">
        <h2>Owner-specific (placeholder)</h2>
        <p className="muted">
          Permission-aware actions for the owner role will be wired here. The
          shell above is shared with admin so backend policy is the only thing
          that needs to change to differentiate the two roles.
        </p>
      </div>
    </>
  );
}
