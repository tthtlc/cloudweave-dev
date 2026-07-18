import React, { useEffect } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../context/AuthContext";
import { redirectToDex, roleHome } from "../services/auth";
import config from "../config";

export default function LoginPage() {
  const { session } = useAuth();
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
          Sign in through the platform identity provider (Dex). Dex federates to
          Google and GitHub; the portal never sees provider credentials.
        </p>

        {config.mockMode && (
          <p className="banner info" style={{ marginTop: "1rem" }}>
            Mock mode is ON — sign-in buttons simulate the Dex callback locally.
          </p>
        )}

        <div className="providers">
          <button className="primary" onClick={() => handleLogin("google", navigate)}>
            Sign in with Google
          </button>
          <button className="primary" onClick={() => handleLogin("github", navigate)}>
            Sign in with GitHub
          </button>
        </div>
      </div>
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
