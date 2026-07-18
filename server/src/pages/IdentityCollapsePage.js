import React, { useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../context/AuthContext";
import api from "../services/api";
import { roleHome } from "../services/auth";
import IdentityBadges from "../components/IdentityBadges";
import Banner from "../components/Banner";

export default function IdentityCollapsePage() {
  const { login } = useAuth();
  const navigate = useNavigate();
  const [result] = useState(() => {
    const raw = sessionStorage.getItem("libcloud.portal.collapse");
    return raw ? JSON.parse(raw) : null;
  });
  const [decision, setDecision] = useState("link");
  const [targetId, setTargetId] = useState(result?.collapseCandidates?.[0]?.internalUserId || "");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState(null);

  if (!result) {
    return (
      <div className="content">
        <Banner kind="error">No pending identity to collapse.</Banner>
        <button className="primary" onClick={() => navigate("/login", { replace: true })}>Back to login</button>
      </div>
    );
  }

  async function submit() {
    setSubmitting(true);
    setError(null);
    try {
      const session = await api.collapse({
        targetInternalUserId: targetId,
        pendingIdentity: result.pendingIdentity,
        pendingToken: result.pendingToken,
        decision,
      });
      sessionStorage.removeItem("libcloud.portal.collapse");
      login(session);
      navigate(roleHome(session.role), { replace: true });
    } catch (e) {
      setError(e.message || String(e));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="content">
      <h1>Link this identity?</h1>
      <p>
        The identity you just signed in with appears to match an existing internal
        user. You can link it into that account (one internal user, multiple
        providers) or keep it as a separate account.
      </p>

      <div className="card">
        <h2>New external identity</h2>
        <p><IdentityBadges identities={result.linkedIdentities} /></p>
        <p className="muted">{result.pendingIdentity?.email}</p>
      </div>

      <div className="card">
        <h2>Candidate internal users</h2>
        <table>
          <thead>
            <tr><th></th><th>Internal ID</th><th>Email</th><th>Role</th><th>Linked</th></tr>
          </thead>
          <tbody>
            {result.collapseCandidates.map((c) => (
              <tr key={c.internalUserId}>
                <td>
                  <input
                    type="radio"
                    name="target"
                    checked={targetId === c.internalUserId}
                    onChange={() => setTargetId(c.internalUserId)}
                    disabled={decision !== "link"}
                  />
                </td>
                <td><code>{c.internalUserId}</code></td>
                <td>{c.email}</td>
                <td><span className={`role-pill ${c.role}`}>{c.role}</span></td>
                <td><IdentityBadges identities={c.linkedIdentities} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="card">
        <label>
          <input type="radio" name="decision" checked={decision === "link"} onChange={() => setDecision("link")} />
          {" "}Link into the selected internal user
        </label>
        <br />
        <label>
          <input type="radio" name="decision" checked={decision === "keep"} onChange={() => setDecision("keep")} />
          {" "}Keep as a separate account (new viewer)
        </label>
        <p className="muted" style={{ marginTop: "0.5rem" }}>
          Backend policy decides whether "keep" is allowed; the backend enforces
          this decision regardless of the choice here.
        </p>
      </div>

      {error && <Banner kind="error">{error}</Banner>}

      <button className="primary" disabled={submitting || (decision === "link" && !targetId)} onClick={submit}>
        {submitting ? "Submitting…" : "Confirm"}
      </button>
    </div>
  );
}
