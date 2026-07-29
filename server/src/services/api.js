// Frontend API client for the backend identity service + portal API.
//
// Contract (see user_role_management.md):
//   GET  /api/session
//   POST /api/auth/exchange
//   POST /api/auth/collapse
//   POST /api/logout
//   GET  /api/users
//   PATCH /api/users/:id/role
//   GET  /api/resources/{cloud}        (aws | nutanix)
//   POST /api/provision/{cloud}        (aws | nutanix)
//   POST /api/provision-private/{cloud} (aws | nutanix: bastion + internal pair)
//   POST /api/deprovision/{cloud}      (aws | nutanix)
//   POST /api/update/{cloud}           (aws | nutanix)
//
// The resource/provision/deprovision/update endpoints are cloud-parametric so
// AWS and Nutanix share one code path in the client (no per-cloud duplication).
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
      setRole: (id, role, tenant) => {
        const payload = { role };
        if (tenant) payload.tenant = tenant;
        return http(`/api/users/${encodeURIComponent(id)}/role`, body("PATCH", payload));
      },
      setEmail: (id, email) => http(`/api/users/${encodeURIComponent(id)}/email`, body("PATCH", { email })),
      disableUser: (id) => http(`/api/users/${encodeURIComponent(id)}/disable`, body("POST", {})),
      listTuples: () => http("/api/tuples"),
      writeTuples: (writes) => http("/api/tuples", body("POST", { writes })),
      deleteTuples: (deletes) => http("/api/tuples", body("DELETE", { deletes })),
      awsResources: () => http("/api/resources/aws"),
      nutanixResources: () => http("/api/resources/nutanix"),
      // Cloud-parametric resource/provision/deprovision/update. `cloud` is one
      // of "aws" | "nutanix"; the backend route is /api/<verb>/<cloud>. The
      // legacy per-cloud aliases below keep older callers working.
      resources: (cloud) => http(`/api/resources/${encodeURIComponent(cloud)}`),
      provision: (cloud, payload) => http(`/api/provision/${encodeURIComponent(cloud)}`, body("POST", payload)),
      // Bastion + internal private VM pair (gated on can_provision, i.e. the
      // tenant owner/admin only — see /api/provision-private/{cloud}). AWS and
      // Nutanix share the one code path, like the other verbs.
      provisionPrivate: (cloud, payload) => http(`/api/provision-private/${encodeURIComponent(cloud)}`, body("POST", payload)),
      deprovision: (cloud, payload) => http(`/api/deprovision/${encodeURIComponent(cloud)}`, body("POST", payload)),
      update: (cloud, payload) => http(`/api/update/${encodeURIComponent(cloud)}`, body("POST", payload)),
      provisionAws: (payload) => http("/api/provision/aws", body("POST", payload)),
      provisionNutanix: (payload) => http("/api/provision/nutanix", body("POST", payload)),
      deprovisionAws: (payload) => http("/api/deprovision/aws", body("POST", payload)),
      deprovisionNutanix: (payload) => http("/api/deprovision/nutanix", body("POST", payload)),
      updateAws: (payload) => http("/api/update/aws", body("POST", payload)),
      updateNutanix: (payload) => http("/api/update/nutanix", body("POST", payload)),

      // --- OpenFGA explorer (superadmin) ---
      getOpenFgaStore: () => http("/api/openfga/store"),
      getOpenFgaModels: () => http("/api/openfga/models"),
      getOpenFgaModel: (id) => http(`/api/openfga/models/${encodeURIComponent(id)}`),
      getOpenFgaAssertions: (modelId) => http(`/api/openfga/assertions/${encodeURIComponent(modelId)}`),
      getOpenFgaChanges: (params = {}) => {
        const qs = new URLSearchParams();
        Object.entries(params).forEach(([k, v]) => { if (v != null && v !== "") qs.set(k, String(v)); });
        const s = qs.toString();
        return http(`/api/openfga/changes${s ? `?${s}` : ""}`);
      },
      listOpenFgaUsers: (payload) => http("/api/openfga/list-users", body("POST", payload)),
      listOpenFgaObjects: (payload) => http("/api/openfga/list-objects", body("POST", payload)),
      expandOpenFga: (payload) => http("/api/openfga/expand", body("POST", payload)),
      getRestApiPolicies: () => http("/api/openfga/rest-api-policies"),
    };

export default api;
