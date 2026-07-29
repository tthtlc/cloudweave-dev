import React, { useEffect } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../context/AuthContext";

// Clears the local session, calls the backend logout endpoint (which revokes
// the Dex refresh token), then navigates back to /login. Stock Dex has no
// RP-initiated logout endpoint, so there is no IdP-side redirect; the
// logoutUrl branch only fires if a future IdP returns one.
export default function LogoutPage() {
  const { logout } = useAuth();
  const navigate = useNavigate();

  useEffect(() => {
    let active = true;
    (async () => {
      const logoutUrl = await logout();
      if (!active) return;
      if (logoutUrl) {
        // Only used if the backend ever returns an IdP logout URL (stock Dex
        // has none); otherwise fall through to the SPA login page.
        window.location.href = logoutUrl;
      } else {
        navigate("/login", { replace: true });
      }
    })();
    return () => { active = false; };
  }, [logout, navigate]);

  return <div className="content muted">Signing out…</div>;
}
