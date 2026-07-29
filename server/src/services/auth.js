// Dex / OIDC redirect helpers.
//
// The frontend NEVER handles provider secrets. It only redirects the browser
// to Dex's authorization endpoint; Dex federates to Google/GitHub and returns
// an authorization code to our /auth/callback, which we then forward to the
// backend /api/auth/exchange. The backend performs the token exchange with
// Dex using the client secret (kept server-side) and mints our session.

import config from "../config";

const SESSION_KEY = "libcloud.portal.session";

export async function redirectToDex(provider) {
  // Ask the identity service to mint a server-issued `state` + PKCE verifier
  // and return the Dex authorize URL. The browser no longer generates state
  // itself; the server is the authoritative validator on callback.
  const base = config.api.baseUrl.replace(/\/$/, "");
  const beginUrl = `${base}/api/auth/begin?provider=${encodeURIComponent(provider)}&redirect_uri=${encodeURIComponent(config.dex.redirectUri)}`;
  let res;
  try {
    res = await fetch(beginUrl, { credentials: "include" });
  } catch (e) {
    throw new Error(`Cannot reach identity service at ${base}: ${e.message}`);
  }
  if (!res.ok) {
    throw new Error(`auth/begin failed (${res.status})`);
  }
  const { authorizeUrl, state } = await res.json();
  sessionStorage.setItem("libcloud.portal.oauth", JSON.stringify({ state, provider }));
  window.location.href = authorizeUrl;
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
    case "pending": return "/pending";
    case "viewer":
    default: return "/viewer";
  }
}
