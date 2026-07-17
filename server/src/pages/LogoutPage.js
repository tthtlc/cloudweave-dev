import React, { useEffect } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../context/AuthContext";

// Clears the local session, calls the backend logout endpoint (which should
// also revoke the Dex session / drop the httpOnly cookie), then returns to /login.
export default function LogoutPage() {
  const { logout } = useAuth();
  const navigate = useNavigate();

  useEffect(() => {
    let active = true;
    (async () => {
      await logout();
      if (active) navigate("/login", { replace: true });
    })();
    return () => { active = false; };
  }, [logout, navigate]);

  return <div className="content muted">Signing out…</div>;
}
