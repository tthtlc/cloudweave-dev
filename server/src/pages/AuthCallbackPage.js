import React, { useEffect, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { useAuth } from "../context/AuthContext";
import api from "../services/api";
import { consumeOAuthState, roleHome } from "../services/auth";
import config from "../config";

export default function AuthCallbackPage() {
  const { login } = useAuth();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const [error, setError] = useState(null);

  useEffect(() => {
    let active = true;
    (async () => {
      try {
        const code = params.get("code");
        const state = params.get("state");
        const mockProvider = params.get("mock_provider");

        // Real flow: validate state against what we stored before redirect.
        const stored = consumeOAuthState();
        if (!config.mockMode) {
          if (!code || !stored || stored.state !== state) {
            // NOTE: full CSRF/state + PKCE validation belongs in the backend
            // exchange step; here we only sanity-check the browser-side state.
            throw new Error("Invalid OAuth state — refusing to exchange.");
          }
        }

        const provider = config.mockMode ? mockProvider : stored?.provider;
        const result = await api.exchange({
          provider,
          code,
          state,
          redirectUri: config.dex.redirectUri,
        });

        if (!active) return;

        if (result.needsIdentityCollapse) {
          // Stash the pending identity + candidates for the collapse page.
          sessionStorage.setItem("libcloud.portal.collapse", JSON.stringify(result));
          navigate("/identity/collapse", { replace: true });
          return;
        }

        login(result);
        navigate(roleHome(result.role), { replace: true });
      } catch (e) {
        if (active) setError(e.message || String(e));
      }
    })();
    return () => { active = false; };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  if (error) {
    return (
      <div className="login-wrap">
        <div className="card login-card">
          <h2>Sign-in failed</h2>
          <div className="banner error">{error}</div>
          <button className="primary" onClick={() => navigate("/login", { replace: true })}>Back to login</button>
        </div>
      </div>
    );
  }
  return <div className="content muted">Completing sign-in…</div>;
}
