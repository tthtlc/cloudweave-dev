import React, { createContext, useContext, useEffect, useState, useCallback } from "react";
import api from "../services/api";
import { loadSessionMeta, saveSessionMeta, clearSessionMeta } from "../services/auth";

const AuthContext = createContext(null);

export function AuthProvider({ children }) {
  const [session, setSession] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  // On mount, try to restore the session from the backend (or mock).
  useEffect(() => {
    let active = true;
    (async () => {
      const meta = loadSessionMeta();
      if (!meta) {
        setLoading(false);
        return;
      }
      try {
        const s = await api.getSession();
        if (active) setSession(s);
      } catch (e) {
        // Stale/invalid session meta -> drop it.
        clearSessionMeta();
        if (active) setError(null);
      } finally {
        if (active) setLoading(false);
      }
    })();
    return () => { active = false; };
  }, []);

  const login = useCallback((newSession) => {
    setSession(newSession);
    const meta = {
      internalUserId: newSession.internalUserId,
      role: newSession.role,
      email: newSession.email,
      linkedIdentities: newSession.linkedIdentities,
    };
    saveSessionMeta(meta);
  }, []);

  const logout = useCallback(async () => {
    let logoutUrl = null;
    try {
      const res = await api.logout();
      logoutUrl = res?.logoutUrl || null;
    } catch (_) {}
    clearSessionMeta();
    setSession(null);
    return logoutUrl;
  }, []);

  const updateRole = useCallback((role) => {
    setSession((prev) => (prev ? { ...prev, role } : prev));
    const meta = loadSessionMeta();
    if (meta) saveSessionMeta({ ...meta, role });
  }, []);

  const value = { session, loading, error, setError, login, logout, updateRole };
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}

export default AuthContext;
