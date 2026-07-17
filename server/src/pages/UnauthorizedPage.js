import React from "react";
import { Link } from "react-router-dom";

export default function UnauthorizedPage() {
  return (
    <div className="login-wrap">
      <div className="card login-card">
        <h1>Unauthorized</h1>
        <p className="muted">Your role does not permit access to that page.</p>
        <Link to="/viewer" className="row" style={{ marginTop: "1rem" }}>Go to your dashboard</Link>
      </div>
    </div>
  );
}
