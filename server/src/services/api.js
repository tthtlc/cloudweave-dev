// Frontend API client for the backend identity service + portal API.
//
// Contract (see user_role_management.md):
//   GET  /api/session
//   POST /api/auth/exchange
//   POST /api/auth/collapse
//   POST /api/logout
//   GET  /api/users
//   PATCH /api/users/:id/role
//   GET  /api/resources/aws
//   GET  /api/resources/nutanix
//   POST /api/provision/aws
//   POST /api/provision/nutanix
//
// In mock mode these calls are answered locally (see mockData.js + mockApi.js)
// so the UI is fully demonstrable without a live backend.

import config from "../config";
import { mockApi } from "./mockApi";

const BASE = config.api.baseUrl.replace(/\/$/, "");

async function http(path, options = {}) {
  const res = await fetch(`${BASE}${path}`, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    credentials: "include", // backend issues httpOnly session cookie
    ...options,
  });
  if (!res.ok) {
    let detail = res.statusText;
    try {
      detail = (await res.json()).error || detail;
    } catch (_) {}
    throw new Error(`${res.status} ${detail}`);
  }
  return res.status === 204 ? null : res.json();
}

function body(method, payload) {
  return { method, body: payload ? JSON.stringify(payload) : undefined };
}

export const api = config.mockMode
  ? mockApi
  : {
      getSession: () => http("/api/session"),
      exchange: (payload) => http("/api/auth/exchange", body("POST", payload)),
      collapse: (payload) => http("/api/auth/collapse", body("POST", payload)),
      logout: () => http("/api/logout", body("POST", {})),
      listUsers: () => http("/api/users"),
      setRole: (id, role) => http(`/api/users/${encodeURIComponent(id)}/role`, body("PATCH", { role })),
      awsResources: () => http("/api/resources/aws"),
      nutanixResources: () => http("/api/resources/nutanix"),
      provisionAws: (payload) => http("/api/provision/aws", body("POST", payload)),
      provisionNutanix: (payload) => http("/api/provision/nutanix", body("POST", payload)),
    };

export default api;
