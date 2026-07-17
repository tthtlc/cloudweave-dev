import React from "react";
import { NavLink, useNavigate } from "react-router-dom";
import { useAuth } from "../context/AuthContext";

// Shared shell for every authenticated page: top bar with brand, current
// user/role, logout; role-aware nav links.
export default function Layout({ children }) {
  const { session, logout } = useAuth();
  const navigate = useNavigate();
  const role = session?.role;

  const links = [
    { to: "/viewer", label: "Viewer", roles: ["viewer", "admin", "owner", "superadmin"] },
    { to: "/admin", label: "Admin", roles: ["admin", "superadmin"] },
    { to: "/owner", label: "Owner", roles: ["owner", "superadmin"] },
    { to: "/superadmin", label: "Superadmin", roles: ["superadmin"] },
  ].filter((l) => l.roles.includes(role));

  async function onLogout() {
    await logout();
    navigate("/login", { replace: true });
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
