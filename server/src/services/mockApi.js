// Local in-memory implementation of the backend API contract for mock mode.
// Simulates the identity service: first-login provisioning, identity collapse,
// role management, and resource/provisioning stubs.

import {
  MOCK_USERS,
  MOCK_AWS_RESOURCES,
  MOCK_NUTANIX_RESOURCES,
  MOCK_PROVISION_RESULT,
  MOCK_DEPROVISION_RESULT,
  MOCK_UPDATE_RESULT,
  MOCK_TUPLES,
} from "./mockData";

// Clone so mock mutations don't leak across HMR reloads.
let users = MOCK_USERS.map((u) => ({ ...u, linkedIdentities: [...u.linkedIdentities] }));
let mockTuples = MOCK_TUPLES.map((t) => ({ ...t }));
// Mutable copy of each cloud's resource list so the Deprovision/Edit buttons
// can mutate rows in mock mode (mirrors the backend: deprovision_<cloud>.sh
// DELETE /v1/compute/nodes/{id}, PATCH /v1/compute/nodes/{id}).
let cloudNodes = {
  aws: MOCK_AWS_RESOURCES.nodes.map((n) => ({ ...n })),
  nutanix: MOCK_NUTANIX_RESOURCES.nodes.map((n) => ({ ...n })),
};
let currentSession = null;

const delay = (ms = 250) => new Promise((r) => setTimeout(r, ms));

// Map of "provider:subject" -> internalUserId, used to detect collapse
// candidates when a new external identity shares an email with an existing user.
function findCollapseCandidates(external) {
  const email = external.email?.toLowerCase();
  if (!email) return [];
  return users.filter((u) => u.email.toLowerCase() === email);
}

// Per-cloud capabilities for a mock user, mirroring the backend's live OpenFGA
// derivation (rbac_design.md: roles are per-tenant). superadmin gets global
// read-only (canView both, canProvision/canUpdate none); a tenant user only
// sees its own cloud; owner/admin get canProvision AND canUpdate on their
// tenant (so the per-row Edit + Deprovision buttons render); a viewer gets
// canView only. A user with no tenant sees nothing.
function mockClouds(user) {
  const all = ["aws", "nutanix"];
  if (!user) return all.map((cloud) => ({ cloud, canView: false, canProvision: false, canUpdate: false }));
  if (user.role === "superadmin") return all.map((cloud) => ({ cloud, canView: true, canProvision: false, canUpdate: false }));
  const t = user.tenant;
  const canWrite = user.role === "owner" || user.role === "admin";
  return all.map((cloud) => ({
    cloud,
    canView: cloud === t,
    canProvision: cloud === t && canWrite,
    canUpdate: cloud === t && canWrite,
  }));
}

export const mockApi = {
  // Mock-only: list the pregenerated users so the login page can offer a
  // "sign in as" picker in mock mode (mirrors the LLDAP users Dex federates).
  // Real mode never calls this; the backend authenticates via Dex.
  async listMockUsers() {
    await delay(50);
    return users.map((u) => ({
      internalUserId: u.internalUserId,
      email: u.email,
      displayName: u.displayName,
      role: u.role,
      tenant: u.tenant,
    }));
  },

  // Mock-only: sign in directly as one of the pregenerated users. Lets the
  // portal demonstrate the per-role owner/admin/viewer screens (and the
  // per-tenant AWS vs Nutanix dashboards) without a live Dex/LLDAP.
  async mockLoginAs(internalUserId) {
    await delay(150);
    const target = users.find((u) => u.internalUserId === internalUserId);
    if (!target) throw new Error("404 unknown mock user");
    currentSession = {
      internalUserId: target.internalUserId,
      role: target.role,
      linkedIdentities: [...target.linkedIdentities],
      email: target.email,
      clouds: mockClouds(target),
    };
    return { ...currentSession, needsIdentityCollapse: false, collapseCandidates: [] };
  },

  async getSession() {
    await delay();
    if (!currentSession) throw new Error("401 no session");
    return currentSession;
  },

  // payload: { provider, code, state, redirectUri }
  async exchange({ provider }) {
    await delay();

    // LLDAP login == direct login as that LLDAP user (mirrors the backend:
    // resolve_on_login maps `lldap:<uid>` straight to the internal user, no
    // collapse). In mock mode we sign in as the pregenerated superadmin so the
    // portal's superadmin dashboard is reachable without a live Dex/LLDAP.
    if (provider === "lldap") {
      const target = users.find((u) => u.internalUserId === "int-superadmin-0000");
      currentSession = {
        internalUserId: target.internalUserId,
        role: target.role,
        linkedIdentities: [...target.linkedIdentities, "lldap:superadmin"],
        email: target.email,
        clouds: mockClouds(target),
      };
      return { ...currentSession, needsIdentityCollapse: false, collapseCandidates: [] };
    }

    // Simulate Dex returning a subject for the chosen provider.
    const subjectSeed = Math.floor(Math.random() * 1e9).toString();
    const subject = provider === "google" ? `google:108214000000000${subjectSeed}` : `github:${subjectSeed}`;
    const email =
      provider === "google" ? `newuser+${subjectSeed}@libcloud.local` : `newgh+${subjectSeed}@libcloud.local`;

    // First login: no existing user has this external identity.
    const existing = users.find((u) => u.linkedIdentities.includes(subject));
    if (existing) {
      currentSession = { internalUserId: existing.internalUserId, role: existing.role, linkedIdentities: existing.linkedIdentities, email: existing.email, clouds: mockClouds(existing) };
      return { ...currentSession, needsIdentityCollapse: false, collapseCandidates: [] };
    }

    // Collapse heuristic: same email as an existing internal user.
    const candidates = findCollapseCandidates({ email });
    if (candidates.length > 0) {
      return {
        internalUserId: null,
        role: null,
        linkedIdentities: [subject],
        email,
        needsIdentityCollapse: true,
        collapseCandidates: candidates.map((c) => ({ internalUserId: c.internalUserId, email: c.email, displayName: c.displayName, role: c.role, linkedIdentities: c.linkedIdentities })),
        pendingIdentity: { provider, subject, email },
      };
    }

    // Brand-new internal user -> default role viewer.
    const newUser = {
      internalUserId: `int-viewer-${Date.now().toString().slice(-6)}`,
      email,
      displayName: `${provider} user`,
      role: "viewer",
      linkedIdentities: [subject],
      createdAt: new Date().toISOString(),
    };
    users.push(newUser);
    currentSession = { internalUserId: newUser.internalUserId, role: newUser.role, linkedIdentities: newUser.linkedIdentities, email: newUser.email, clouds: mockClouds(newUser) };
    return { ...currentSession, needsIdentityCollapse: false, collapseCandidates: [] };
  },

  // payload: { targetInternalUserId, pendingIdentity: {provider, subject, email}, decision: "link" | "keep" }
  async collapse({ targetInternalUserId, pendingIdentity, decision }) {
    await delay();
    if (decision === "link") {
      const target = users.find((u) => u.internalUserId === targetInternalUserId);
      if (!target) throw new Error("404 target user not found");
      if (!target.linkedIdentities.includes(pendingIdentity.subject)) {
        target.linkedIdentities.push(pendingIdentity.subject);
      }
      currentSession = { internalUserId: target.internalUserId, role: target.role, linkedIdentities: target.linkedIdentities, email: target.email, clouds: mockClouds(target) };
      return currentSession;
    }
    // "keep" -> create a fresh viewer account for the pending identity.
    const newUser = {
      internalUserId: `int-viewer-${Date.now().toString().slice(-6)}`,
      email: pendingIdentity.email,
      displayName: `${pendingIdentity.provider} user`,
      role: "viewer",
      linkedIdentities: [pendingIdentity.subject],
      createdAt: new Date().toISOString(),
    };
    users.push(newUser);
    currentSession = { internalUserId: newUser.internalUserId, role: newUser.role, linkedIdentities: newUser.linkedIdentities, email: newUser.email, clouds: mockClouds(newUser) };
    return currentSession;
  },

  async logout() {
    await delay(100);
    currentSession = null;
    return null;
  },

  async listUsers() {
    await delay();
    return { users };
  },

  async setRole(id, role) {
    await delay();
    const u = users.find((x) => x.internalUserId === id);
    if (!u) throw new Error("404 user not found");
    u.role = role;
    if (currentSession && currentSession.internalUserId === id) currentSession.role = role;
    return u;
  },

  async setEmail(id, email) {
    await delay();
    const u = users.find((x) => x.internalUserId === id);
    if (!u) throw new Error("404 user not found");
    if (!email || !email.includes("@")) throw new Error("400 a valid email is required");
    u.email = email;
    return u;
  },

  async disableUser(id) {
    await delay();
    const u = users.find((x) => x.internalUserId === id);
    if (!u) throw new Error("404 user not found");
    u.role = "disabled";
    if (currentSession && currentSession.internalUserId === id) currentSession.role = "disabled";
    return { internalUserId: id, disabled: true };
  },

  // --- OpenFGA tuple CRUD (mock) ---
  async listTuples() {
    await delay();
    return { tuples: mockTuples.map((t) => ({ ...t })) };
  },
  async writeTuples(writes) {
    await delay();
    for (const t of writes || []) {
      if (!mockTuples.some((x) => x.user === t.user && x.relation === t.relation && x.object === t.object)) {
        mockTuples.push({ ...t });
      }
    }
    return { written: (writes || []).length };
  },
  async deleteTuples(deletes) {
    await delay();
    for (const t of deletes || []) {
      const i = mockTuples.findIndex((x) => x.user === t.user && x.relation === t.relation && x.object === t.object);
      if (i >= 0) mockTuples.splice(i, 1);
    }
    return { deleted: (deletes || []).length };
  },

  async awsResources() {
    await delay();
    return { region: MOCK_AWS_RESOURCES.region, nodes: cloudNodes.aws.map((n) => ({ ...n })) };
  },

  async nutanixResources() {
    await delay();
    return { cluster: MOCK_NUTANIX_RESOURCES.cluster, nodes: cloudNodes.nutanix.map((n) => ({ ...n })) };
  },

  // Cloud-parametric resource list. `cloud` is "aws" | "nutanix". Mirrors the
  // backend GET /api/resources/<cloud> and the per-cloud region/cluster key.
  async resources(cloud) {
    if (cloud === "aws") return this.awsResources();
    if (cloud === "nutanix") return this.nutanixResources();
    throw new Error(`404 unknown cloud ${cloud}`);
  },

  async provisionAws(payload) {
    await delay(400);
    return MOCK_PROVISION_RESULT("aws", payload?.vmName || `libcloud-demo-${Date.now()}`);
  },

  async provisionNutanix(payload) {
    await delay(400);
    return MOCK_PROVISION_RESULT("nutanix", payload?.vmName || `libcloud-ntnx-${Date.now()}`);
  },

  // Cloud-parametric provision (single code path for both clouds).
  async provision(cloud, payload) {
    if (cloud === "aws") return this.provisionAws(payload);
    if (cloud === "nutanix") return this.provisionNutanix(payload);
    throw new Error(`404 unknown cloud ${cloud}`);
  },

  async deprovisionAws(payload) {
    await delay(400);
    const vmId = payload?.vmId;
    const vmName = payload?.vmName;
    // Remove the matching node from the mock list (by id, falling back to name)
    // so a follow-up "View AWS Resources" reflects the deletion — same effect
    // the real backend's deprovision_aws.sh has via DELETE /v1/compute/nodes/{id}.
    const before = cloudNodes.aws.length;
    cloudNodes.aws = cloudNodes.aws.filter((n) => {
      const matchById = vmId && n.id === vmId;
      const matchByName = !vmId && vmName && n.name === vmName;
      return !(matchById || matchByName);
    });
    if (cloudNodes.aws.length === before) {
      return { ...MOCK_DEPROVISION_RESULT("aws", vmId, vmName), status: "failed", message: `No AWS VM matched id=${vmId || ""} name=${vmName || ""} (mock).`, exitCode: 1 };
    }
    return MOCK_DEPROVISION_RESULT("aws", vmId, vmName);
  },

  async deprovisionNutanix(payload) {
    await delay(400);
    const vmId = payload?.vmId;
    const vmName = payload?.vmName;
    const before = cloudNodes.nutanix.length;
    cloudNodes.nutanix = cloudNodes.nutanix.filter((n) => {
      const matchById = vmId && n.id === vmId;
      const matchByName = !vmId && vmName && n.name === vmName;
      return !(matchById || matchByName);
    });
    if (cloudNodes.nutanix.length === before) {
      return { ...MOCK_DEPROVISION_RESULT("nutanix", vmId, vmName), status: "failed", message: `No Nutanix VM matched id=${vmId || ""} name=${vmName || ""} (mock).`, exitCode: 1 };
    }
    return MOCK_DEPROVISION_RESULT("nutanix", vmId, vmName);
  },

  // Cloud-parametric deprovision (single code path for both clouds).
  async deprovision(cloud, payload) {
    if (cloud === "aws") return this.deprovisionAws(payload);
    if (cloud === "nutanix") return this.deprovisionNutanix(payload);
    throw new Error(`404 unknown cloud ${cloud}`);
  },

  async updateAws(payload) {
    await delay(400);
    return this._updateCloud("aws", payload);
  },

  async updateNutanix(payload) {
    await delay(400);
    return this._updateCloud("nutanix", payload);
  },

  // Cloud-parametric update (single code path for both clouds).
  async update(cloud, payload) {
    if (cloud === "aws") return this.updateAws(payload);
    if (cloud === "nutanix") return this.updateNutanix(payload);
    throw new Error(`404 unknown cloud ${cloud}`);
  },

  // Shared edit implementation for both clouds: apply the supplied editable
  // fields to the in-memory node so a follow-up "View <cloud> Resources"
  // reflects the change — same effect the real backend's PATCH has.
  async _updateCloud(cloud, payload) {
    const vmId = payload?.vmId;
    if (!vmId) throw new Error("400 vmId is required");
    const fields = {};
    if (payload?.name != null) fields.name = payload.name;
    if (payload?.newSizeId != null) fields.size = payload.newSizeId;
    if (payload?.memoryMib != null) fields.memory_mib = payload.memoryMib;
    if (payload?.tagKey != null) { fields.tag_key = payload.tagKey; fields.tag_value = payload.tagValue || ""; }
    for (const n of cloudNodes[cloud]) {
      if (n.id === vmId) Object.assign(n, fields);
    }
    return MOCK_UPDATE_RESULT(cloud, vmId, fields);
  },
};
