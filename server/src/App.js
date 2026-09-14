import React from "react";
import { Routes, Route, Navigate } from "react-router-dom";
import RequireAuth from "./components/RequireAuth";
import RequireRole from "./components/RequireRole";
import Layout from "./components/Layout";
import LoginPage from "./pages/LoginPage";
import AuthCallbackPage from "./pages/AuthCallbackPage";
import IdentityCollapsePage from "./pages/IdentityCollapsePage";
import SuperAdminDashboard from "./pages/SuperAdminDashboard";
import OpenFgaTuplesPage from "./pages/OpenFgaTuplesPage";
import OpenFgaExplorerPage from "./pages/OpenFgaExplorerPage";
import AdminDashboard from "./pages/AdminDashboard";
import CompanyAdminDashboard from "./pages/CompanyAdminDashboard";
import OwnerDashboard from "./pages/OwnerDashboard";
import ViewerDashboard from "./pages/ViewerDashboard";
import PendingApprovalPage from "./pages/PendingApprovalPage";
import DisabledAccountPage from "./pages/DisabledAccountPage";
import UnauthorizedPage from "./pages/UnauthorizedPage";
import NotFoundPage from "./pages/NotFoundPage";
import LogoutPage from "./pages/LogoutPage";

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route path="/auth/callback" element={<AuthCallbackPage />} />
      <Route path="/unauthorized" element={<UnauthorizedPage />} />
      <Route path="/logout" element={<LogoutPage />} />

      {/* Identity collapse is part of the auth handshake: must be authenticated
          but no specific role is required. */}
      <Route
        path="/identity/collapse"
        element={
          <RequireAuth>
            <Layout>
              <IdentityCollapsePage />
            </Layout>
          </RequireAuth>
        }
      />

      {/* Pending approval — authenticated but not yet assigned a role/tenant. */}
      <Route
        path="/pending"
        element={
          <RequireAuth>
            <Layout>
              <PendingApprovalPage />
            </Layout>
          </RequireAuth>
        }
      />

      {/* Disabled account — authenticated but excluded from the system. */}
      <Route
        path="/disabled"
        element={
          <RequireAuth>
            <Layout>
              <DisabledAccountPage />
            </Layout>
          </RequireAuth>
        }
      />

      {/* Role-gated dashboards. */}
      <Route
        path="/superadmin"
        element={
          <RequireRole roles={["superadmin"]}>
            <Layout>
              <SuperAdminDashboard />
            </Layout>
          </RequireRole>
        }
      />
      <Route
        path="/superadmin/tuples"
        element={
          <RequireRole roles={["superadmin"]}>
            <Layout>
              <OpenFgaTuplesPage />
            </Layout>
          </RequireRole>
        }
      />
      <Route
        path="/superadmin/explorer"
        element={
          <RequireRole roles={["superadmin"]}>
            <Layout>
              <OpenFgaExplorerPage />
            </Layout>
          </RequireRole>
        }
      />
      <Route
        path="/admin"
        element={
          <RequireRole roles={["admin"]}>
            <Layout>
              <AdminDashboard />
            </Layout>
          </RequireRole>
        }
      />
      <Route
        path="/company"
        element={
          <RequireRole roles={["company_admin"]}>
            <Layout>
              <CompanyAdminDashboard />
            </Layout>
          </RequireRole>
        }
      />
      <Route
        path="/owner"
        element={
          <RequireRole roles={["owner"]}>
            <Layout>
              <OwnerDashboard />
            </Layout>
          </RequireRole>
        }
      />
      <Route
        path="/viewer"
        element={
          <RequireRole roles={["viewer", "admin", "owner", "superadmin"]}>
            <Layout>
              <ViewerDashboard />
            </Layout>
          </RequireRole>
        }
      />

      <Route path="/" element={<Navigate to="/login" replace />} />
      <Route path="*" element={<NotFoundPage />} />
    </Routes>
  );
}
