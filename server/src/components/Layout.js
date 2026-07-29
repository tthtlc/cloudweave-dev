import React from "react";
import { NavLink, useNavigate } from "react-router-dom";
import { useAuth } from "../context/AuthContext";

// Shared shell for every authenticated page: top bar with brand, current
// user/role, logout; role-aware nav links.
export default function Layout({ children }) {
  const { session, logout } = useAuth();
  const navigate = useNavigate();
  const role = session?.role;

  // SuperAdmin has no resource-management functionality (rbac_design.md
  // §SuperAdmin: "None (by default)" for resource mgmt), so the Admin and
  // Owner dashboards — which are provisioning/deprovisioning surfaces — are
  // hidden from SuperAdmin and its routes are blocked. Real admin/owner users
  // still see their own tab.
  const links = [
    { to: "/viewer", label: "Viewer", roles: ["viewer", "admin", "owner", "superadmin"] },
    { to: "/admin", label: "Admin", roles: ["admin"] },
    { to: "/owner", label: "Owner", roles: ["owner"] },
    { to: "/superadmin", label: "Superadmin", roles: ["superadmin"] },
    { to: "/superadmin/tuples", label: "Tuples", roles: ["superadmin"] },
    { to: "/superadmin/explorer", label: "Explorer", roles: ["superadmin"] },
  ].filter((l) => l.roles.includes(role));

  async function onLogout() {
    const logoutUrl = await logout();
    if (logoutUrl) {
      // Only used if the backend ever returns an IdP logout URL (stock Dex
      // has none); otherwise fall through to the SPA login page.
      window.location.href = logoutUrl;
    } else {
      navigate("/login", { replace: true });
    }
  }

  return (
    <div className="app-shell">
      <header className="topbar">
        <span className="brand">libcloud Portal</span>
        <div className="who">
          <span>{session?.email || session?.internalUserId}</span>
          <span className="role">role: <span className={`role-pill ${role}`}>{role}</span></span>
        </div>
        <button className="danger" onClick={onLogout}>Logout</button>
      </header>
      <nav className="nav">
        {links.map((l) => (
          <NavLink key={l.to} to={l.to} className={({ isActive }) => (isActive ? "active" : "")}>
            {l.label}
          </NavLink>
        ))}
      </nav>
      <main className="content">{children}</main>
    </div>
  );
}
