// Local in-memory implementation of the backend API contract for mock mode.
// Simulates the identity service: first-login provisioning, identity collapse,
// role management, and resource/provisioning stubs.

import {
  MOCK_USERS,
  MOCK_AWS_RESOURCES,
  MOCK_NUTANIX_RESOURCES,
  MOCK_PROVISION_RESULT,
} from "./mockData";

// Clone so mock mutations don't leak across HMR reloads.
let users = MOCK_USERS.map((u) => ({ ...u, linkedIdentities: [...u.linkedIdentities] }));
let currentSession = null;

const delay = (ms = 250) => new Promise((r) => setTimeout(r, ms));

// Map of "provider:subject" -> internalUserId, used to detect collapse
// candidates when a new external identity shares an email with an existing user.
function findCollapseCandidates(external) {
  const email = external.email?.toLowerCase();
  if (!email) return [];
  return users.filter((u) => u.email.toLowerCase() === email);
}

export const mockApi = {
  async getSession() {
    await delay();
    if (!currentSession) throw new Error("401 no session");
    return currentSession;
  },

  // payload: { provider, code, state, redirectUri }
  async exchange({ provider }) {
    await delay();
    // Simulate Dex returning a subject for the chosen provider.
    const subjectSeed = Math.floor(Math.random() * 1e9).toString();
    const subject = provider === "google" ? `google:108214000000000${subjectSeed}` : `github:${subjectSeed}`;
    const email =
      provider === "google" ? `newuser+${subjectSeed}@libcloud.local` : `newgh+${subjectSeed}@libcloud.local`;

    // First login: no existing user has this external identity.
    const existing = users.find((u) => u.linkedIdentities.includes(subject));
    if (existing) {
      currentSession = { internalUserId: existing.internalUserId, role: existing.role, linkedIdentities: existing.linkedIdentities, email: existing.email };
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
    currentSession = { internalUserId: newUser.internalUserId, role: newUser.role, linkedIdentities: newUser.linkedIdentities, email: newUser.email };
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
      currentSession = { internalUserId: target.internalUserId, role: target.role, linkedIdentities: target.linkedIdentities, email: target.email };
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
    currentSession = { internalUserId: newUser.internalUserId, role: newUser.role, linkedIdentities: newUser.linkedIdentities, email: newUser.email };
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

  async awsResources() {
    await delay();
    return MOCK_AWS_RESOURCES;
  },

  async nutanixResources() {
    await delay();
    return MOCK_NUTANIX_RESOURCES;
  },

  async provisionAws(payload) {
    await delay(400);
    return MOCK_PROVISION_RESULT("aws", payload?.vmName || `libcloud-demo-${Date.now()}`);
  },

  async provisionNutanix(payload) {
    await delay(400);
    return MOCK_PROVISION_RESULT("nutanix", payload?.vmName || `libcloud-ntnx-${Date.now()}`);
  },
};
