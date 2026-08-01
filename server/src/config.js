// Centralized runtime configuration read from CRA environment variables.
// All values are public (bundled into the browser) — never reference secrets here.

const env = (key, fallback = "") => (process.env[key] != null ? process.env[key] : fallback);

const config = {
  dex: {
    baseUrl: env("REACT_APP_DEX_BASE_URL", "http://localhost:5556/dex"),
    clientId: env("REACT_APP_DEX_CLIENT_ID", "libcloud-portal"),
    redirectUri:
      env("REACT_APP_DEX_REDIRECT_URI", `${window.location.origin}/auth/callback`),
  },
  api: {
    baseUrl: env("REACT_APP_API_BASE_URL", "http://localhost:8766"),
  },
  // Mock mode isolates the UI from a live backend. Toggle via env or the
  // runtime override below for quick demos.
  mockMode: env("REACT_APP_MOCK_MODE", "true").toLowerCase() === "true",
  // Air-gapped (offline) deployments: set to "true" to hide Google/GitHub
  // sign-in buttons. Dex is configured without those connectors so they
  // would fail anyway. LLDAP-only login remains available.
  disableFederation:
    env("REACT_APP_DISABLE_FEDERATION", "false").toLowerCase() === "true",
};

export default config;
