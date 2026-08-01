import React, { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../context/AuthContext";
import { redirectToDex, roleHome } from "../services/auth";
import config from "../config";

export default function LoginPage() {
  const { session, login } = useAuth();
  const navigate = useNavigate();

  // Already authenticated -> go to role home.
  useEffect(() => {
    if (session) navigate(roleHome(session.role), { replace: true });
  }, [session, navigate]);

  return (
    <div className="login-wrap">
      <div className="card login-card">
        <h1>libcloud Portal</h1>
        <p className="muted">
          Sign in through the platform identity provider (Dex). LLDAP users
          (superadmin, aws-admin, …) sign in with their uid + password.
          {!config.disableFederation && " Dex also federates to Google and GitHub."} The portal never sees provider
          credentials.
        </p>

        {config.mockMode && (
          <p className="banner info" style={{ marginTop: "1rem" }}>
            Mock mode is ON — sign-in buttons simulate the Dex callback locally.
          </p>
        )}

        <div className="providers">
          <button className="primary" onClick={() => handleLogin("lldap", navigate)}>
            Sign in with LLDAP
          </button>
          {!config.disableFederation && (
            <>
              <button className="primary" onClick={() => handleLogin("google", navigate)}>
                Sign in with Google
              </button>
              <button className="primary" onClick={() => handleLogin("github", navigate)}>
                Sign in with GitHub
              </button>
            </>
          )}
        </div>

        {config.mockMode && <MockUserPicker login={login} navigate={navigate} />}
      </div>
    </div>
  );
}

// Mock-only: sign in directly as one of the pregenerated LLDAP users so every
// per-role / per-tenant screen (superadmin, aws-owner, ntnx-owner, …) is
// reachable without a live Dex/LLDAP. Real mode authenticates through Dex.
function MockUserPicker({ login, navigate }) {
  const [users, setUsers] = useState([]);
  const [selected, setSelected] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);

  useEffect(() => {
    let active = true;
    (async () => {
      try {
        const r = await import("../services/api").then((m) => m.default.listMockUsers());
        if (!active) return;
        setUsers(r.users || []);
        if (r.users?.length) setSelected(r.users[0].internalUserId);
      } catch (e) {
        if (active) setErr(e.message || String(e));
      }
    })();
    return () => { active = false; };
  }, []);

  async function signInAs() {
    if (!selected) return;
    setBusy(true); setErr(null);
    try {
      const api = (await import("../services/api")).default;
      const result = await api.mockLoginAs(selected);
      login(result);
      navigate(roleHome(result.role), { replace: true });
    } catch (e) {
      setErr(e.message || String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="mock-picker" style={{ marginTop: "1.5rem" }}>
      <h3 style={{ marginBottom: "0.25rem" }}>Mock sign-in (no Dex)</h3>
      <p className="muted" style={{ marginTop: 0 }}>
        Pick a pregenerated LLDAP user to land directly on their dashboard. The
        Nutanix owner/admin users show the Edit + Deprovision buttons on the
        Nutanix resource screen.
      </p>
      <div style={{ display: "flex", gap: "0.5rem", alignItems: "center", flexWrap: "wrap" }}>
        <select
          value={selected}
          onChange={(e) => setSelected(e.target.value)}
          disabled={busy}
          style={{ flex: "1 1 220px" }}
        >
          {users.map((u) => (
            <option key={u.internalUserId} value={u.internalUserId}>
              {u.displayName} — {u.role}@{u.tenant || "platform"}
            </option>
          ))}
        </select>
        <button className="primary" disabled={busy || !selected} onClick={signInAs}>
          {busy ? "Signing in…" : "Sign in (mock)"}
        </button>
      </div>
      {err && <div className="banner error" style={{ marginTop: "0.5rem" }}>{err}</div>}
    </div>
  );
}

async function handleLogin(provider, navigate) {
  if (config.mockMode) {
    // Simulate the full Dex redirect -> callback round trip.
    navigate(`/auth/callback?mock_provider=${provider}`);
    return;
  }
  try {
    await redirectToDex(provider);
  } catch (e) {
    // eslint-disable-next-line no-alert
    alert(`Failed to start sign-in: ${e.message}`);
  }
}
