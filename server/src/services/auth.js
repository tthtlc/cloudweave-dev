// Dex / OIDC redirect helpers.
//
// The frontend NEVER handles provider secrets. It only redirects the browser
// to Dex's authorization endpoint; Dex federates to Google/GitHub and returns
// an authorization code to our /auth/callback, which we then forward to the
// backend /api/auth/exchange. The backend performs the token exchange with
// Dex using the client secret (kept server-side) and mints our session.

import config from "../config";

const SESSION_KEY = "libcloud.portal.session";

// PKCE-style state: random + stored so the callback can validate it.
// NOTE: full PKCE + nonce + S256 challenge verification belongs in the backend
// exchange step; the browser only needs `state` for CSRF protection of the
// redirect itself.
function randomString(len = 24) {
  const arr = new Uint8Array(len);
  crypto.getRandomValues(arr);
  return Array.from(arr, (b) => b.toString(16).padStart(2, "0")).join("");
}

export function buildAuthUrl(provider) {
  const { baseUrl, clientId, redirectUri } = config.dex;
  const state = randomString();
  const nonce = randomString();
  sessionStorage.setItem("libcloud.portal.oauth", JSON.stringify({ state, nonce, provider }));

  const params = new URLSearchParams({
    client_id: clientId,
    redirect_uri: redirectUri,
    response_type: "code",
    scope: "openid profile email",
    state,
    nonce,
  });
  // Dex selects the upstream connector by id via `connector_id`. The backend
  // Dex config registers connectors with ids "google" and "github".
  if (provider) params.set("connector_id", provider);

  return `${baseUrl}/auth?${params.toString()}`;
}

export function redirectToDex(provider) {
  window.location.href = buildAuthUrl(provider);
}

export function consumeOAuthState() {
  const raw = sessionStorage.getItem("libcloud.portal.oauth");
  sessionStorage.removeItem("libcloud.portal.oauth");
  return raw ? JSON.parse(raw) : null;
}

// Minimal session metadata persisted in sessionStorage. We deliberately do
// NOT store raw provider tokens here; the backend owns the session via an
// httpOnly cookie. This is only for UX (route guards, greeting).
export function saveSessionMeta(meta) {
  sessionStorage.setItem(SESSION_KEY, JSON.stringify(meta));
}

export function loadSessionMeta() {
  const raw = sessionStorage.getItem(SESSION_KEY);
  return raw ? JSON.parse(raw) : null;
}

export function clearSessionMeta() {
  sessionStorage.removeItem(SESSION_KEY);
}

// Role -> default landing route.
export function roleHome(role) {
  switch (role) {
    case "superadmin": return "/superadmin";
    case "admin": return "/admin";
    case "owner": return "/owner";
    case "viewer":
    default: return "/viewer";
  }
}
