import React from "react";
import { Link } from "react-router-dom";

export default function NotFoundPage() {
  return (
    <div className="login-wrap">
      <div className="card login-card">
        <h1>Not found</h1>
        <p className="muted">That route does not exist.</p>
        <Link to="/login" style={{ marginTop: "1rem", display: "inline-block" }}>Back to login</Link>
      </div>
    </div>
  );
}
