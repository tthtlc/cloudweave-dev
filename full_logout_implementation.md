# Full Logout Implementation

## Overview

Proper implementation of the logout feature across the libcloud portal stack — ensuring the portal session cookie, Dex refresh token, and Dex SSO session are all invalidated when a user logs out.

---

## 1. Current Architecture (Pre-Fix)

### HTTP Flow (from `libcloud_internal.md`)

```
Browser (portal SPA, :3000)
  │ POST /api/logout
  ▼
identity_service (:8766)
  │ session.revoke() → delete libcloud_portal_sid cookie
  │ _refresh_store.pop(sid) → drop refresh token from memory
  │ TODO at main.py:198 — Dex refresh token NEVER revoked
  ▼
Dex (:5556)
  ◀── NOT CONTACTED AT ALL
  │ Browser still has Dex SSO session cookie
  │ Refresh token still valid until natural expiry
```

### What `POST /api/logout` did (pre-fix)

From `identity_service/app/session.py:82-91`:

```python
def revoke(self, req: Request, resp: Response) -> None:
    s = self._settings()
    token = req.cookies.get(s.session_cookie_name)
    if token:
        try:
            claims = self._decode(token)
            _refresh_store.pop(claims.get("sid", ""), None)  # drop from memory only
        except APIError:
            pass
    resp.delete_cookie(s.session_cookie_name, path="/")      # delete cookie
```

Two things happened:
1. The portal cookie (`libcloud_portal_sid`) was deleted
2. The Dex refresh token was dropped from in-memory `_refresh_store`

The explicit TODO at `identity_service/app/main.py:198`:
```python
# TODO: revoke the Dex refresh token at Dex's revocation endpoint using
# the server-side refresh token from sessions._refresh_store.
```

### Gap Analysis (from `/tmp/logout_component.md` and `libcloud_internal.md`)

| # | Gap | Severity | Detail |
|---|-----|----------|--------|
| 1 | Dex refresh token not revoked | **High** | TODO at main.py:198 — token remained valid at Dex until natural expiry. If exfiltrated before logout, attacker can use it against Dex. |
| 2 | Dex SSO session not terminated | **High** | Logout never touched Dex. Browser retained Dex's session cookie, so re-login skipped the password prompt entirely (single sign-on without single logout). |
| 3 | No `logoutUrl` returned to frontend | Medium | Frontend couldn't redirect browser to clear IdP session even if it wanted to. |
| 4 | Provisioner token cache survives | By design | `idp_login._token_cache` is keyed by cloud, not by user. Service account credential outlives all user sessions. |
| 5 | libcloud-rest-audience tokens still obtainable | Architectural | Separate OAuth client (`libcloud-rest`); credentials in repo's `.env` files. Requires architectural redesign to fix (see `libcloud_internal.md` §"eliminate identity_service"). |
| 6 | Vault token unaffected | By design | `libcloud.rest/.env` — nothing to do with user sessions. |
| 7 | OpenFGA tuples unchanged | By design | Logout doesn't touch authorization state. |

### Credential State After Logout (Pre-Fix)

```
┌───────────────────────────────────────────────────────────────┬───────────────────────┬────────────────────────────────────────────┐
│ Credential                                                    │ Alive after logout?   │ Why                                        │
├───────────────────────────────────────────────────────────────┼───────────────────────┼────────────────────────────────────────────┤
│ Portal cookie (libcloud_portal_sid)                           │ ❌ deleted            │ Only thing logout touches                  │
├───────────────────────────────────────────────────────────────┼───────────────────────┼────────────────────────────────────────────┤
│ Dex refresh token (held by identity_service)                  │ ✅ still valid at Dex │ TODO at main.py:198 — never revoked        │
├───────────────────────────────────────────────────────────────┼───────────────────────┼────────────────────────────────────────────┤
│ Dex SSO session (browser cookie on Dex domain)                │ ✅ still alive        │ Logout doesn't touch Dex                   │
├───────────────────────────────────────────────────────────────┼───────────────────────┼────────────────────────────────────────────┤
│ libcloud-rest-audience token (obtainable by direct Dex login) │ ✅ obtainable anytime │ Separate OAuth client; credentials in repo │
├───────────────────────────────────────────────────────────────┼───────────────────────┼────────────────────────────────────────────┤
│ Provisioner token cache (idp_login._token_cache)              │ ✅ still cached       │ Decoupled from user sessions by design     │
├───────────────────────────────────────────────────────────────┼───────────────────────┼────────────────────────────────────────────┤
│ Vault token (in libcloud.rest/.env)                           │ ✅ always valid       │ Nothing to do with user sessions           │
├───────────────────────────────────────────────────────────────┼───────────────────────┼────────────────────────────────────────────┤
│ OpenFGA tuples                                                │ ✅ unchanged          │ Logout doesn't touch authz                 │
└───────────────────────────────────────────────────────────────┴───────────────────────┴────────────────────────────────────────────┘
```

This was concretely demonstrated in `demo_curl_flows.sh` sections F, G, H: after portal logout, a fresh `libcloud-rest`-audience token obtained directly from Dex could still call `libcloud.rest` successfully.

---

## 2. Implementation

### Design Decisions

1. **Dex supports OAuth2 token revocation (RFC 7009)** at `POST /dex/token/revoke`. Parameters: `token`, `token_type_hint=refresh_token`, `client_id`, `client_secret`.

2. **Dex supports RP-initiated logout** at `GET /dex/auth/logout`. The browser must visit this URL to clear Dex's session cookie. Parameters: `id_token_hint` (identifies the user), `post_logout_redirect_uri` (where Dex redirects after logout).

3. **The `id_token` must be stored at login time** to be available as `id_token_hint` at logout. Previously only the `refresh_token` was stored in `_refresh_store`.

4. **Both revocation and SSO logout are best-effort.** Failures are logged but never block the user from logging out of the portal.

### Files Modified

#### A. `identity_service/app/dex.py` — New `revoke_token()` method

**Lines added: 85-106**

```python
def revoke_token(self, refresh_token: str) -> None:
    """Revoke a refresh token at Dex's OAuth2 revocation endpoint (RFC 7009).

    Best-effort: failures are logged but never block logout — the session
    cookie and server-side store are already cleared by the caller.
    """
    s = self._settings()
    revoke_url = f"{s.dex_token_url}/revoke"
    data = {
        "token": refresh_token,
        "token_type_hint": "refresh_token",
        "client_id": s.dex_portal_client_id,
        "client_secret": s.dex_portal_client_secret,
    }
    log.info("Revoking refresh token at Dex")
    try:
        resp = httpx.post(revoke_url, data=data, timeout=15)
    except httpx.HTTPError as exc:
        log.warning("Dex revocation endpoint unreachable: %s", exc)
        return
    if resp.status_code not in (200, 204):
        log.warning("Dex token revocation returned %s: %s", resp.status_code, resp.text)
```

**What it does:**
- Calls `POST http://dex:5556/dex/token/revoke` (in-container URL derived from `dex_token_url`)
- Sends `token`, `token_type_hint=refresh_token`, `client_id=libcloud-portal`, and the portal client secret
- On network error: logs warning, returns (doesn't block logout)
- On non-200/204 response: logs warning with status and body, returns
- Dex marks the token as revoked; subsequent refresh attempts with it will fail

#### B. `identity_service/app/session.py` — Store id_token + return tokens from revoke()

**Change 1: `create()` accepts `id_token` (line 51, 61-66)**

```python
def create(self, resp: Response, *,
           internal_user: dict[str, Any],
           refresh_token: str | None,
           id_token: str | None = None) -> dict[str, Any]:
    ...
    if refresh_token:
        _refresh_store[sid] = {
            "refresh_token": refresh_token,
            "id_token": id_token,          # <-- NEW: stored for logout id_token_hint
            "internalUserId": internal_user["internalUserId"],
        }
```

**Change 2: `revoke()` returns stored tokens (lines 86-103)**

```python
def revoke(self, req: Request, resp: Response) -> dict[str, Any] | None:
    """Clear the session cookie and return the stored refresh/id tokens.

    The caller is responsible for revoking the refresh token at Dex and
    returning a logout URL to the browser so the Dex SSO session is also
    terminated.
    """
    s = self._settings()
    stored = None
    token = req.cookies.get(s.session_cookie_name)
    if token:
        try:
            claims = self._decode(token)
            stored = _refresh_store.pop(claims.get("sid", ""), None)
        except APIError:
            pass
    resp.delete_cookie(s.session_cookie_name, path="/")
    return stored   # <-- NEW: returns {"refresh_token": ..., "id_token": ...} or None
```

#### C. `identity_service/app/main.py` — Revoke at Dex + return logoutUrl

**Change 1: `exchange()` passes `id_token` to session (line 163-168)**

```python
sessions.create(
    resp,
    internal_user=internal_user,
    refresh_token=tokens.get("refresh_token"),
    id_token=tokens.get("id_token"),   # <-- NEW
)
```

**Change 2: `logout()` rewritten (lines 197-227)**

```python
@app.post("/api/logout")
def logout(req: Request, resp: Response):
    # 1. Clear the portal session cookie and retrieve the stored Dex tokens
    #    (refresh_token + id_token) before they are dropped.
    stored = sessions.revoke(req, resp)

    # 2. Revoke the Dex refresh token at Dex's OAuth2 revocation endpoint
    #    (RFC 7009). Best-effort: failures are logged but never block logout.
    refresh_token = (stored or {}).get("refresh_token")
    if refresh_token:
        try:
            dex.revoke_token(refresh_token)
        except Exception as exc:
            log.warning("Failed to revoke Dex refresh token: %s", exc)

    # 3. Build a Dex RP-initiated logout URL so the browser can clear its
    #    Dex SSO session cookie. Without this, the user is still logged in at
    #    Dex and a subsequent login would skip the password prompt.
    from urllib.parse import urlencode

    id_token = (stored or {}).get("id_token")
    logout_params: dict[str, str] = {
        "post_logout_redirect_uri": settings.dex_portal_redirect_uri.replace(
            "/auth/callback", "/login"
        ),
    }
    if id_token:
        logout_params["id_token_hint"] = id_token
    dex_logout_url = f"{settings.dex_issuer.rstrip('/')}/auth/logout?{urlencode(logout_params)}"

    return {"logged_out": True, "logoutUrl": dex_logout_url}
```

**What it returns (example):**

```json
{
  "logged_out": true,
  "logoutUrl": "http://login.quest4science.xyz:5556/dex/auth/logout?id_token_hint=eyJhbG...&post_logout_redirect_uri=http%3A%2F%2Flocalhost%3A3000%2Flogin"
}
```

#### D. `server/src/context/AuthContext.js` — Return logoutUrl from logout()

**Lines 46-55:**

```javascript
const logout = useCallback(async () => {
    let logoutUrl = null;
    try {
      const res = await api.logout();
      logoutUrl = res?.logoutUrl || null;
    } catch (_) {}
    clearSessionMeta();
    setSession(null);
    return logoutUrl;   // <-- NEW: returned to caller
}, []);
```

#### E. `server/src/pages/LogoutPage.js` — Redirect to Dex logout

**Lines 5-24:**

```javascript
// Clears the local session, calls the backend logout endpoint (which revokes
// the Dex refresh token and returns a logoutUrl), then redirects the browser to
// Dex's RP-initiated logout to clear the SSO session cookie before returning to /login.
export default function LogoutPage() {
  const { logout } = useAuth();
  const navigate = useNavigate();

  useEffect(() => {
    let active = true;
    (async () => {
      const logoutUrl = await logout();
      if (!active) return;
      if (logoutUrl) {
        // Redirect the browser to Dex's logout endpoint, which clears the
        // Dex SSO session cookie and then redirects back to the portal /login.
        window.location.href = logoutUrl;
      } else {
        navigate("/login", { replace: true });
      }
    })();
    return () => { active = false; };
  }, [logout, navigate]);

  return <div className="content muted">Signing out…</div>;
}
```

#### F. `server/src/components/Layout.js` — Redirect to Dex logout

**Lines 25-34:**

```javascript
async function onLogout() {
    const logoutUrl = await logout();
    if (logoutUrl) {
      // Redirect browser to Dex's RP-initiated logout endpoint, which clears
      // the SSO session cookie and then redirects back to the portal /login.
      window.location.href = logoutUrl;
    } else {
      navigate("/login", { replace: true });
    }
}
```

---

## 3. JWT Session Token: Invalidation Mechanism

### JWT Structure

The portal session cookie (`libcloud_portal_sid`) carries a self-contained signed JWT (HS256). From `session.py:33-42`:

```python
def _encode(self, claims: dict[str, Any]) -> str:
    s = self._settings()
    now = int(time.time())
    payload = {
        **claims,
        "iat": now,
        "exp": now + s.session_ttl_seconds,
        "jti": uuid.uuid4().hex,
    }
    return jwt.encode(payload, s.session_secret, algorithm="HS256")
```

The JWT payload contains:

| Claim | Source | Purpose |
|-------|--------|---------|
| `internalUserId` | User record | Identifies the portal user |
| `role` | User record | Cached role for fast authorization checks |
| `email` | User record | Display / contact |
| `linkedIdentities` | User record | IdP-linked identities (LLDAP DN, etc.) |
| `sid` | `uuid.uuid4().hex` | Session ID — key into `_refresh_store` for the Dex refresh token |
| `iat` | `int(time.time())` | Issued-at timestamp |
| `exp` | `iat + session_ttl_seconds` | Expiration timestamp |
| `jti` | `uuid.uuid4().hex` | JWT ID — unique per token, **generated but not used for revocation** |

The cookie attributes (from `session.py:68-76`):

```python
resp.set_cookie(
    key=s.session_cookie_name,       # "libcloud_portal_sid"
    value=cookie_value,
    max_age=s.session_ttl_seconds,   # matches JWT exp
    httponly=True,                   # not accessible to JavaScript
    secure=s.session_secure,         # True in production (HTTPS only)
    samesite=s.session_samesite,     # "lax" or "strict"
    path="/",
)
```

### How the JWT is Validated on Each Request

Every authenticated endpoint calls `_require_session(req)` (or `_require_role(req, role)` which internally calls `_require_session`). From `main.py:74-75`:

```python
def _require_session(req: Request) -> dict[str, Any]:
    return sessions.read(req)
```

Which delegates to `session.py:79-84`:

```python
def read(self, req: Request) -> dict[str, Any]:
    s = self._settings()
    token = req.cookies.get(s.session_cookie_name)
    if not token:
        raise APIError("auth_no_session", "No session", 401)
    return self._decode(token)
```

And `_decode` (from `session.py:44-49`):

```python
def _decode(self, token: str) -> dict[str, Any]:
    s = self._settings()
    try:
        return jwt.decode(token, s.session_secret, algorithms=["HS256"])
    except jwt.PyJWTError as exc:
        raise APIError("auth_invalid_session", ...)
```

**The validation is purely cryptographic:**
1. **Signature verification** — The JWT is verified against `session_secret` (HS256). A tampered token fails immediately.
2. **Expiry check** — `jwt.decode` rejects tokens where `exp` is in the past.
3. **No server-side state check** — There is no blocklist, no revocation set, no database lookup. If the signature is valid and the token is not expired, the request is accepted.

### What Happens to the JWT at Logout

From `session.py:86-103`:

```python
def revoke(self, req: Request, resp: Response) -> dict[str, Any] | None:
    s = self._settings()
    stored = None
    token = req.cookies.get(s.session_cookie_name)
    if token:
        try:
            claims = self._decode(token)
            stored = _refresh_store.pop(claims.get("sid", ""), None)
        except APIError:
            pass
    resp.delete_cookie(s.session_cookie_name, path="/")
    return stored
```

Three things happen:

| Step | Action | Effect |
|------|--------|--------|
| 1 | `_refresh_store.pop(sid)` | Dex refresh token + id_token removed from server memory. A subsequent refresh attempt against identity_service will fail because `refresh_token_for(sid)` returns `None`. |
| 2 | `resp.delete_cookie(...)` | `Set-Cookie` header sent to browser with `Max-Age=0`, instructing the browser to delete `libcloud_portal_sid`. |
| 3 | Return `stored` to caller | The `{refresh_token, id_token}` dict is returned so `main.py` can revoke the refresh token at Dex and build the logout URL. |

**Critically, what does NOT happen:**
- The JWT itself is **not added to any server-side blocklist/denylist**.
- There is no check during `_decode()` that consults a revocation set.
- The `jti` claim is generated at token creation but never stored or checked anywhere.
- The `sid` is removed from `_refresh_store`, but that store only gates refresh-token access — it does not gate session-JWT acceptance.

### Security Implication: Replay of an Exfiltrated JWT

The portal session JWT is a **bearer token** — anyone who possesses it can authenticate as that user. Because there is no server-side revocation:

```
Timeline of an exfiltrated JWT:

  T0: User logs in. JWT issued with exp = T0 + session_ttl_seconds.
  T1: Attacker exfiltrates the JWT (e.g., XSS, MITM, log leak).
  T2: User logs out.
      - Cookie deleted from browser ✓
      - _refresh_store[sid] popped ✓
      - Dex refresh token revoked ✓
      - Dex SSO session cleared ✓
      - JWT still cryptographically valid ✗
  T3: Attacker replays the exfiltrated JWT (before exp).
      → identity_service accepts it. No blocklist check exists.
      → The attacker can call /api/session, /api/resources/*, etc.
      → The attacker CANNOT refresh (refresh_token_for returns None)
        but can continue using the stolen JWT until it expires naturally.
```

### Why There Is No Server-Side JWT Blocklist

This is a deliberate trade-off, not an oversight:

| Factor | With blocklist | Without blocklist (current) |
|--------|---------------|---------------------------|
| **State** | Requires a shared store (Redis/DB) for revoked `jti` values across all replicas | Stateless — any replica can validate any token independently |
| **Latency** | Extra network call on every request to check the blocklist | Zero additional latency |
| **Memory** | Blocklist grows unboundedly (must prune expired entries) | No memory cost |
| **Complexity** | Must handle blocklist replication, TTL pruning, race conditions | Trivial implementation |
| **Deployment** | Single-replica deployment is simple; multi-replica needs Redis | Works identically for 1 or N replicas |
| **Revocation window** | Can reject a stolen JWT within seconds | Stolen JWT valid until natural expiry |

**The current deployment is single-replica**, so a simple in-memory blocklist (a `set` of revoked `jti` values, pruned of expired entries on each check) would be straightforward. The trade-off was accepted because:

1. **Short TTL**: `session_ttl_seconds` is configured to a relatively short window (typically 15-60 minutes). The exposure window for a stolen JWT is bounded.
2. **httpOnly + Secure + SameSite cookies**: The JWT is never exposed to JavaScript, is sent only over HTTPS (in production), and is protected by SameSite policy — all of which make exfiltration difficult in the first place.
3. **Refresh-token revocation still works**: Even if an attacker replays the JWT, they cannot obtain a new JWT after the original expires (the refresh token was revoked at Dex). The attack is time-limited to the remaining life of the exfiltrated JWT.
4. **Dex SSO session is terminated**: The attacker cannot establish a fresh session by re-authenticating at Dex (the SSO session cookie is cleared).

### How the JWT Expiry Interacts with Logout

```
                        Login                     Logout                   Natural expiry
                          │                          │                          │
                          │◀──── session_ttl ──────▶│                          │
                          │                          │                          │
  JWT valid?             ✓                          ✓                          ✗
  Cookie present?        ✓                          ✗ (deleted)                ✗
  _refresh_store entry?  ✓                          ✗ (popped)                 ✗
  Dex refresh token?     ✓                          ✗ (revoked)                ✗
  Dex SSO session?       ✓                          ✗ (cleared)                ✗
                          │                          │                          │
                          │                          ├── Exposure window ──────▶│
                          │                          │   (stolen JWT still      │
                          │                          │    valid until exp)      │
```

After logout, a stolen JWT remains valid until `exp`. After `exp`, all credentials are dead regardless of whether logout occurred.

### Potential Future Hardening

If a server-side blocklist is desired, the implementation would be:

```python
# In session.py — add a revocation set (pruned of expired entries on each write)

_revoked_jtis: set[str] = set()

def revoke(self, req: Request, resp: Response) -> dict[str, Any] | None:
    ...
    if token:
        try:
            claims = self._decode(token)
            jti = claims.get("jti", "")
            exp = claims.get("exp", 0)
            if jti and exp > time.time():       # only blocklist if not already expired
                _revoked_jtis.add(jti)
            stored = _refresh_store.pop(claims.get("sid", ""), None)
        except APIError:
            pass
    resp.delete_cookie(s.session_cookie_name, path="/")
    return stored

def _decode(self, token: str) -> dict[str, Any]:
    ...
    claims = jwt.decode(token, s.session_secret, algorithms=["HS256"])
    # Prune expired entries on every decode (amortized cleanup)
    now = int(time.time())
    stale = {j for j in _revoked_jtis if ...}   # would need exp tracking
    _revoked_jtis -= stale
    if claims.get("jti") in _revoked_jtis:
        raise APIError("auth_session_revoked", "Session has been revoked", 401)
    return claims
```

This is **not currently implemented**. The document describes it as a reference for future hardening if the threat model requires it.

---

## 4. Server-Side Token Stores

The identity_service process maintains **two** in-memory token stores. They serve different purposes, have different keys, and have different lifetimes — understanding both is essential to understanding what logout does and does not invalidate.

### 4a. `session._refresh_store` — per user session

**Location:** `identity_service/app/session.py:17`

```python
_refresh_store: dict[str, dict[str, Any]] = {}
```

This store holds the Dex-issued refresh token and ID token obtained during the portal OAuth flow (`client_id=libcloud-portal`). Each entry is keyed by a unique session ID (`sid`).

**When entries are created** (`session.py:51-66`):

```python
def create(self, resp, *, internal_user, refresh_token, id_token=None):
    sid = uuid.uuid4().hex          # fresh random session id
    ...
    if refresh_token:
        _refresh_store[sid] = {
            "refresh_token": refresh_token,   # Dex refresh token (libcloud-portal audience)
            "id_token": id_token,             # Dex ID token (for logout id_token_hint)
            "internalUserId": internal_user["internalUserId"],
        }
```

A new entry is created every time a browser completes the OAuth login flow (`POST /api/auth/exchange` → `sessions.create()`). Dex issues a fresh refresh token for each authorization code exchange, so each browser login produces a distinct entry.

**When entries are removed** (`session.py:86-103`):

```python
def revoke(self, req, resp):
    ...
    stored = _refresh_store.pop(claims.get("sid", ""), None)  # single entry popped
    resp.delete_cookie(s.session_cookie_name, path="/")
    return stored
```

Only the single entry matching the session cookie's `sid` is popped. Other entries (other browser sessions, other users) are unaffected.

**Key characteristics:**

| Property | Detail |
|----------|--------|
| **Key** | `sid` — a random `uuid4().hex` string, embedded in the portal JWT cookie |
| **Scope** | One entry per browser login session, not per user |
| **Client** | `libcloud-portal` OAuth client (portal SPA audience) |
| **Contents** | `{refresh_token, id_token, internalUserId}` |
| **Lifetime** | Created at login, destroyed at logout (or process restart) |
| **Replication** | None — in-memory only. Restarting identity_service wipes it |

**Example — same user, two browsers:**

```
Browser A (Chrome) logs in as alice:
  → Dex issues refresh_token = "rt_A1"
  → sid = "abc123"
  → _refresh_store["abc123"] = {refresh_token: "rt_A1", id_token: "id_A1", internalUserId: "alice"}

Browser B (Firefox) logs in as alice:
  → Dex issues refresh_token = "rt_A2"    ← separate token from Dex
  → sid = "def456"
  → _refresh_store["def456"] = {refresh_token: "rt_A2", id_token: "id_A2", internalUserId: "alice"}

_refresh_store = {
    "abc123": {refresh_token: "rt_A1", ...},   ← alice Chrome session
    "def456": {refresh_token: "rt_A2", ...},   ← alice Firefox session
}
```

At logout from Chrome, only `"abc123"` is popped. The Firefox session remains intact. Each session is independently revocable because each has its own Dex refresh token.

**What the refresh token is used for** — when the portal JWT is nearing expiry and the browser calls `GET /api/session`, the identity_service can use the stored refresh token to obtain a fresh ID token from Dex and mint a new portal JWT. The `sid` in the JWT acts as a pointer into this store.

---

### 4b. `idp_login._token_cache` — per cloud, shared by all users

**Location:** `identity_service/app/idp_login.py:18`

```python
_token_cache: dict[str, dict[str, Any]] = {}
```

This store holds provisioner service-account access tokens obtained via the **`libcloud-rest`** OAuth client (a different client than `libcloud-portal`). These tokens are used when the identity_service needs to call `libcloud.rest:8765` on behalf of a portal user — the REST API only accepts tokens with audience `libcloud-rest`, but portal users authenticate with audience `libcloud-portal`. The provisioner tokens bridge this audience gap.

**When entries are created** (`idp_login.py:57-69`):

```python
def _token_for(self, cloud):
    cached = _token_cache.get(cloud)
    if cached and cached.get("expires_at", 0) > time.time() + 60:
        return cached["access_token"]
    # Cache miss or expired — perform Dex LDAP login as provisioner service account
    tok = self._login(cloud)       # logs in as aws-admin or ntnx-admin LLDAP user
    _token_cache[cloud] = tok
    return tok["access_token"]
```

**Key characteristics:**

| Property | Detail |
|----------|--------|
| **Key** | `cloud` — either `"aws"` or `"nutanix"` |
| **Scope** | Exactly two entries total: one per supported cloud |
| **Client** | `libcloud-rest` OAuth client (REST API audience) |
| **Contents** | `{access_token, expires_at}` — the provisioner's bearer token for `libcloud.rest` |
| **Lifetime** | Created on first provision/deprovision call per cloud; evicted on natural expiry; survives all user logouts |
| **Identity** | Service account (`aws-admin` / `ntnx-admin` LLDAP users), not the portal user |
| **Replication** | None — in-memory only. Restarting identity_service wipes it |

**Why this store survives logout (by design):**

The provisioner tokens are **service account credentials**, not user credentials. They are:
- Keyed by cloud, not by user — the same cached token serves all portal users
- Obtained via a completely separate OAuth client (`libcloud-rest`) with its own client secret
- Never exposed to the browser — they are server-side only, used for identity_service → libcloud.rest calls

When a user logs out, their portal session is terminated, but the provisioner tokens remain cached so that other users (or the same user after re-login) can immediately provision resources without waiting for a fresh Dex login by the service account.

---

### 4c. Comparison: both stores at a glance

```
┌─────────────────────────────────────────────────────────────────────┐
│                      identity_service process                        │
│                                                                      │
│  session._refresh_store              idp_login._token_cache          │
│  ┌──────────────────────┐            ┌──────────────────────────┐   │
│  │ Key: sid (session ID)│            │ Key: cloud ("aws"/"ntnx")│   │
│  │                      │            │                          │   │
│  │ "abc123" → {         │            │ "aws" → {                │   │
│  │   refresh_token,     │            │   access_token,          │   │
│  │   id_token,          │            │   expires_at,            │   │
│  │   internalUserId     │            │ }                        │   │
│  │ }                    │            │                          │   │
│  │ "def456" → {...}     │            │ "nutanix" → {            │   │
│  │ ...                  │            │   access_token,          │   │
│  │                      │            │   expires_at,            │   │
│  │ OAuth client:        │            │ }                        │   │
│  │   libcloud-portal    │            │                          │   │
│  │                      │            │ OAuth client:            │   │
│  │ Per browser session  │            │   libcloud-rest          │   │
│  │ Cleared at logout ✓  │            │                          │   │
│  └──────────────────────┘            │ Per cloud (2 entries)    │   │
│                                      │ Survives logout ✗        │   │
│                                      └──────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### 4d. What this means for logout

At logout, only one entry in `_refresh_store` is touched — the one matching the session cookie's `sid`:

```
POST /api/logout (cookie contains sid="abc123")
  │
  ├─ 1. _refresh_store.pop("abc123")   → removes {refresh_token: "rt_A1", id_token: "id_A1"}
  │      _refresh_store["def456"]      → untouched (alice's Firefox session still valid)
  │
  ├─ 2. dex.revoke_token("rt_A1")      → revokes only "rt_A1" at Dex
  │      "rt_A2" (from Firefox session) → still valid at Dex
  │
  ├─ 3. _token_cache["aws"]            → untouched (service account, shared)
  │      _token_cache["nutanix"]       → untouched
  │
  └─ 4. resp.delete_cookie(...)        → browser deletes libcloud_portal_sid
```

Each browser session is independently revocable. The provisioner token cache is completely unaffected — and intentionally so.

---

## 5. New Logout Flow

### Sequence Diagram

```
Browser                              identity_service                  Dex
  │                                       │                              │
  │  POST /api/logout                     │                              │
  │  (with libcloud_portal_sid cookie)    │                              │
  │ ────────────────────────────────────▶ │                              │
  │                                       │                              │
  │                                       │ 1. sessions.revoke()         │
  │                                       │    - decode cookie           │
  │                                       │    - pop _refresh_store[sid] │
  │                                       │    - returns {refresh_token, │
  │                                       │      id_token}               │
  │                                       │    - delete_cookie()         │
  │                                       │                              │
  │                                       │ 2. POST /dex/token/revoke    │
  │                                       │    token={refresh_token}     │
  │                                       │    token_type_hint=refresh.. │
  │                                       │    client_id=libcloud-portal │
  │                                       │ ───────────────────────────▶ │
  │                                       │                              │ Revoke
  │                                       │ ◀─────────────────────────── │ 200 OK
  │                                       │                              │
  │  {"logged_out":true,                  │                              │
  │   "logoutUrl":"...dex/auth/logout     │                              │
  │    ?id_token_hint=...                 │                              │
  │    &post_logout_redirect_uri=         │                              │
  │    .../login"}                        │                              │
  │ ◀──────────────────────────────────── │                              │
  │                                       │                              │
  │  window.location.href = logoutUrl     │                              │
  │ ───────────────────────────────────────────────────────────────────▶ │
  │  GET /dex/auth/logout                 │                              │
  │    ?id_token_hint=...                 │                              │
  │    &post_logout_redirect_uri=.../login│                              │
  │                                       │                              │ Clear Dex
  │                                       │                              │ session cookie
  │                                       │                              │
  │  302 → .../login                      │                              │
  │ ◀─────────────────────────────────────────────────────────────────── │
  │                                       │                              │
  │  Browser lands at /login              │                              │
  │  (Dex SSO session terminated)         │                              │
```

### Steps

1. **Browser** calls `POST /api/logout` with the `libcloud_portal_sid` cookie
2. **identity_service** calls `sessions.revoke()` which:
   - Decodes the session cookie to get the `sid`
   - Pops the stored `{refresh_token, id_token}` from `_refresh_store`
   - Deletes the `libcloud_portal_sid` cookie via `Set-Cookie` header
   - Returns the stored tokens to the caller
3. **identity_service** calls `dex.revoke_token(refresh_token)` — server-to-server `POST /dex/token/revoke` with portal client credentials. Dex invalidates the refresh token.
4. **identity_service** returns `{"logged_out": true, "logoutUrl": "http://...dex/auth/logout?id_token_hint=...&post_logout_redirect_uri=.../login"}`
5. **Browser** receives the response, clears `sessionStorage`, sets session to `null`
6. **Browser** executes `window.location.href = logoutUrl` — navigates to Dex's RP-initiated logout endpoint
7. **Dex** clears its SSO session cookie and redirects the browser back to `post_logout_redirect_uri` (the portal's `/login` page)
8. **Browser** lands at `/login` — all sessions terminated

### Edge Cases Handled

| Scenario | Behavior |
|----------|----------|
| Session cookie already expired | `sessions.revoke()` returns `None`; Dex revocation and `id_token_hint` are skipped; `logoutUrl` still returned (without `id_token_hint`) |
| Refresh token was already revoked | Dex returns success (idempotent); no error propagated |
| Dex revocation endpoint unreachable | `httpx.HTTPError` caught in `revoke_token()`, logged as warning; logout proceeds |
| Dex revocation returns error | Non-200/204 status logged as warning; logout proceeds |
| `id_token` is expired | Still usable as `id_token_hint` — Dex only needs `sub`/`iss` claims to identify the session, not a valid/current token |
| Collapse login path (no refresh token) | `sessions.create()` called without `refresh_token`/`id_token`; `stored` will be `None`; logout works (cookie cleared, no-op Dex calls) |
| Mock mode (frontend) | `mockApi.logout()` returns `null`; frontend falls back to `navigate("/login")` |

---

## 6. Post-Logout Credential State (After Fix)

```
┌───────────────────────────────────────────────────────────────┬────────────────────────────────┬──────────────────────────────────────────────────────┐
│ Credential                                                    │ Alive after logout?            │ Why                                                  │
├───────────────────────────────────────────────────────────────┼────────────────────────────────┼──────────────────────────────────────────────────────┤
│ Portal cookie (libcloud_portal_sid)                           │ ❌ Deleted                     │ session.revoke() → delete_cookie()                   │
├───────────────────────────────────────────────────────────────┼────────────────────────────────┼──────────────────────────────────────────────────────┤
│ Dex refresh token (held by identity_service)                  │ ❌ Revoked at Dex              │ dex.revoke_token() → POST /dex/token/revoke (RFC     │
│                                                               │                                │ 7009)                                                │
├───────────────────────────────────────────────────────────────┼────────────────────────────────┼──────────────────────────────────────────────────────┤
│ Dex SSO session (browser cookie on Dex domain)                │ ❌ Cleared by browser redirect │ Frontend → window.location.href =                   │
│                                                               │                                │ /dex/auth/logout                                     │
├───────────────────────────────────────────────────────────────┼────────────────────────────────┼──────────────────────────────────────────────────────┤
│ Provisioner token cache (idp_login._token_cache)              │ ✅ Still cached                │ Service account — decoupled from user sessions by    │
│                                                               │                                │ design. Keyed by cloud, not by user.                 │
├───────────────────────────────────────────────────────────────┼────────────────────────────────┼──────────────────────────────────────────────────────┤
│ libcloud-rest-audience token (obtainable by direct Dex login) │ ✅ Still obtainable            │ Separate OAuth client (libcloud-rest); credentials   │
│                                                               │                                │ in repo. Architectural — requires redesign to fix.   │
├───────────────────────────────────────────────────────────────┼────────────────────────────────┼──────────────────────────────────────────────────────┤
│ Vault token (in libcloud.rest/.env)                           │ ✅ Always valid                │ Nothing to do with user sessions                    │
├───────────────────────────────────────────────────────────────┼────────────────────────────────┼──────────────────────────────────────────────────────┤
│ OpenFGA tuples                                                │ ✅ Unchanged                   │ Logout doesn't touch authorization state            │
└───────────────────────────────────────────────────────────────┴────────────────────────────────┴──────────────────────────────────────────────────────┘
```

### Remaining Gaps (Not Fixed — Architectural)

1. **Provisioner token cache** — The `aws-admin`/`ntnx-admin` service account tokens in `idp_login._token_cache` survive logout. This is by design: the provisioner is a standing service credential that all users share for the audience bridge. Fixing this requires the architectural redesign described in `libcloud_internal.md` §"eliminate identity_service" (single audience, no service-account bridge).

2. **Direct libcloud.rest access** — Anyone with LLDAP credentials and the `libcloud-rest` client secret (both in the repo's `.env` files) can obtain a `libcloud-rest`-audience token and call `libcloud.rest:8765` directly, bypassing the portal and identity_service entirely. This path is completely independent of portal logout. The REST API's layered auth (Layer 1 JWKS verify + Layer 2 scope gate + Layer 3 OpenFGA on provisioner principal) still controls what the caller can do, but the caller's identity is the provisioner service account, not the portal user. Fixing this also requires the architectural redesign.

---

## 7. Files Changed Summary

| File | Change | Lines |
|------|--------|-------|
| `identity_service/app/dex.py` | Added `revoke_token()` method | +22 |
| `identity_service/app/session.py` | `create()` accepts `id_token`; `revoke()` returns stored tokens | ~10 modified |
| `identity_service/app/main.py` | `exchange()` passes `id_token`; `logout()` revokes at Dex + returns `logoutUrl` | ~20 modified |
| `server/src/context/AuthContext.js` | `logout()` returns `logoutUrl` from API response | ~5 modified |
| `server/src/pages/LogoutPage.js` | Redirects browser to Dex logout URL when available | ~8 modified |
| `server/src/components/Layout.js` | Top-bar logout button redirects to Dex logout URL | ~6 modified |

---

## 8. Dex Endpoints Used

| Endpoint | Method | Purpose | Auth |
|----------|--------|---------|------|
| `http://dex:5556/dex/token/revoke` | POST | Revoke refresh token (RFC 7009) | `client_id` + `client_secret` (libcloud-portal) |
| `http://login.quest4science.xyz:5556/dex/auth/logout` | GET | RP-initiated logout (clear SSO cookie) | Browser redirect with `id_token_hint` |

### Revocation Request (server-to-server)

```
POST /dex/token/revoke
Content-Type: application/x-www-form-urlencoded

token={refresh_token}&token_type_hint=refresh_token&client_id=libcloud-portal&client_secret=l33WEHol5lO3CkSXZv7Bw14587VgIHWB_YbxO0oll74
```

### Logout URL (browser redirect)

```
GET /dex/auth/logout?id_token_hint={id_token}&post_logout_redirect_uri=http://localhost:3000/login
```

---

## 9. Testing

The existing `demo_curl_flows.sh` script can be used to verify the fix. Key sections:

- **Section E**: `POST /api/logout` — now returns `logoutUrl` in addition to `{"logged_out": true}`
- **Section F**: After logout, portal cookie is rejected (unchanged — still works)
- **Section G**: Direct Dex login via `libcloud-rest` client still works (unchanged — architectural gap)
- **Section H**: `libcloud.rest` still accepts provisioner tokens after logout (unchanged — architectural gap)

To verify the new behavior:
1. Login via portal flow (sections B-C)
2. Call `POST /api/logout` (section E) — verify response includes `logoutUrl`
3. Verify the refresh token is actually revoked by attempting to use it at `POST /dex/token` with `grant_type=refresh_token` — should be rejected
4. Visit the `logoutUrl` in a browser — verify Dex clears its session and redirects to `/login`


Resume this session with:
claude --resume ea161b79-9aef-4e72-aad3-78f5863ec25d
