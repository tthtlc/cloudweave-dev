import React from "react";
import { Navigate, useLocation } from "react-router-dom";
import { useAuth } from "../context/AuthContext";

// UX-only role gate. roles: array of allowed role strings. Backend authorization
// (OpenFGA) is the source of truth; this only shapes navigation/rendering.
export default function RequireRole({ roles, children }) {
  const { session } = useAuth();
  const location = useLocation();

  if (!session) {
    return <Navigate to="/login" replace state={{ from: location.pathname }} />;
  }
  if (!roles.includes(session.role)) {
    return <Navigate to="/unauthorized" replace />;
  }
  return children;
}
