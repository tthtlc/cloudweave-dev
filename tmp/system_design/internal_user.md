
                                                                                                                                                                                                                                                                                                                     
  in the portal each LLDAP login is immediately followed by a internal user id created in the system correct? and this is only stored in memory?                                                                                                                                                                     
                                                                                                                                                                                                                                                                                                                     

    Globbed, read 1 glob, 2 files
    Globbed "identity_service/app/*.py" in .
    Read identity_service/app/idp_login.py
    Read identity_service/app/users.py

  Not quite — your premise has two parts that are both slightly off. Let me clarify based on the code.

  LLDAP logins do NOT create a new internal user id. When provider == "lldap", resolve_on_login maps the Dex sub claim back to the existing LLDAP uid and derives the internal id as int-<uid>:

   identity_service/app/users.py lines 103-122

          if provider == "lldap":
              email = external.get("email", "")
              candidates = self.lldap.find_by_email(email) if email else []
              if candidates:
                  internal_user_id = candidates[0]["internalUserId"]  # "int-<uid>"
                  uid = internal_user_id[4:]
              else:
                  # Fallback when the email claim is empty/missing: decode Dex's
                  # sub protobuf to recover the uid directly.
                  uid = _dex_lldap_uid(subject)
                  internal_user_id = f"int-{uid}"
              role = self.fga.role_for(uid) or DEFAULT_ROLE
              return {
                  "internalUserId": internal_user_id,
                  "role": role,
                  "linkedIdentities": [subject],
                  "email": email,
                  "needsIdentityCollapse": False,
                  "collapseCandidates": [],
              }

  The internal id is computed from the LLDAP uid that already exists in the directory — it's not minted on login, and nothing is written to any registry. The role comes from OpenFGA (fga.role_for(uid)).

  The in-memory registry is only for federated (Google/GitHub) identities that aren't in LLDAP yet. That's _pending_users, a module-level dict:

   identity_service/app/users.py lines 41-46

  # In-memory internal-user registry for identities that are NOT in LLDAP
  # (e.g. brand-new Google/GitHub logins that have not been linked yet). In a
  # real deployment, persist these as LLDAP users (or a dedicated table) so the
  # superadmin user-management table reflects them. Kept simple here so the
  # first-login provisioning path works end-to-end without a schema migration.
  _pending_users: dict[str, dict[str, Any]] = {}

  A brand-new Google/GitHub login (no email match in LLDAP, no prior pending entry) goes through _provision_viewer, which mints int-viewer-<hex> and stores it in _pending_users:

   identity_service/app/users.py lines 167-183

      def _provision_viewer(self, external: dict[str, str]) -> dict[str, Any]:
          internal_user_id = f"int-viewer-{uuid.uuid4().hex[:8]}"
          user = {
              "internalUserId": internal_user_id,
              "email": external.get("email", ""),
              "displayName": f"{external.get('provider','unknown')} user",
              "role": DEFAULT_ROLE,
              "linkedIdentities": [external["subject"]],
              "createdAt": _now_iso(),
          }
          _pending_users[internal_user_id] = user
          # Seed the OpenFGA tuple so subsequent authZ checks pass. The OpenFGA
          # model keys roles off the LLDAP uid; for pending users we use the
          # internal id's suffix as the principal until the user is linked into
          # LLDAP. TODO: create the LLDAP user and re-key the tuple on its uid.
          self.fga.assign_role(internal_user_id, DEFAULT_ROLE)
          return user

  So to summarize:

  • LLDAP login → no creation, no in-memory entry. Internal id is int-<lldap-uid>, derived from the directory; role from OpenFGA.
  • Federated login (google/github), first time, no email match → mints int-viewer-<hex>, stored only in memory in _pending_users (plus an OpenFGA tuple is seeded). Lost on service restart.
  • Federated login with email matching an LLDAP user → returns needsIdentityCollapse: true and waits for the user to choose link/keep; nothing is stored until apply_collapse runs.

  The "stored only in memory" property applies to the pending-viewer path, not to LLDAP logins. The code comments explicitly flag this as a simplification with a TODO to persist these as LLDAP users or a dedicated table.

                                                                                                                                                                                                                                                                                                                     
  why is the internal ID needed? does the system uses this field?                                                                                                                                                                                                                                                    
                                                                                                                                                                                                                                                                                                                     

    Grepped, read 3 greps, 4 files
    … 4 earlier items hidden
    Read identity_service/app/session.py
    Grepped "internalUserId" in server/src
    Read server/src/services/mockData.js

  Yes — the system uses internalUserId heavily. Here's why it exists and where it's actually consumed.

  Why it exists

  The internal id is the platform-owned, stable identity for a user, deliberately decoupled from any IdP subject. The design rationale is spelled out in the mock data and the UserService docstring:

   server/src/services/mockData.js lines 3-8

  // Models the "internal user" abstraction the backend identity service owns.
  // Each internal user has:
  //   - internalUserId  : stable platform identity (NOT the provider subject)
  //   - email           : display + collapse heuristic
  //   - role            : superadmin | owner | admin | viewer
  //   - linkedIdentities: array of "provider:subject" strings (google:/github:)

   identity_service/app/users.py lines 52-59

      """Resolves an external (Dex) identity to an internal user, and runs the
      identity-collapse heuristic.
      The internal-user abstraction is the portal's own: `internalUserId` is
      stable and platform-owned, NOT the provider subject. One internal user may
      have multiple `linkedIdentities` (google:…, github:…). See
      server/src/services/mockData.js for the shape the browser expects.
      """

  The point: a provider subject (google:108214…, github:…, or Dex's base64-protobuf LDAP sub) is volatile and provider-specific. The portal needs one stable key it controls so that:

  • One human can have multiple linked identities (Google + GitHub) but one account, one role, one email.
  • Role assignments and disable actions survive re-linking or a provider changing its subject format.
  • Admin actions have a single stable target across the user-management UI and the authZ layer.

  Where the system actually uses it

  1. Session cookie (JWT claims). internalUserId is one of the claims baked into the signed httpOnly session cookie, so every authenticated request carries it.

   identity_service/app/session.py lines 51-62

      def create(self, resp: Response, *, internal_user: dict[str, Any], refresh_token: str | None) -> dict[str, Any]:
          s = self._settings()
          sid = uuid.uuid4().hex
          meta = {
              "internalUserId": internal_user["internalUserId"],
              "role": internal_user["role"],
              "email": internal_user["email"],
              "linkedIdentities": internal_user["linkedIdentities"],
              "sid": sid,
          }
          if refresh_token:
              _refresh_store[sid] = {"refresh_token": refresh_token, "internalUserId": internal_user["internalUserId"]}

  2. Deriving the OpenFGA principal for authZ. The role check (_require_role) reads internalUserId off the session, strips the int- prefix, and uses the remainder as the OpenFGA principal to look up roles:

   identity_service/app/main.py lines 60-64

      def _principal(claims: dict[str, Any]) -> str:
          # OpenFGA tuples are keyed by LLDAP uid; for pending users we use the
          # internal id suffix. The session carries internalUserId ("int-<uid>").
          iid = claims["internalUserId"]
          return iid[4:] if iid.startswith("int-") else iid

  3. /api/session response — returned to the browser so the frontend knows who's logged in (main.py:90).

  4. Admin user-management endpoints. The path parameter is the internal id — role changes, disable, email update all address a user by it:

   identity_service/app/main.py lines 197-212

      @app.patch("/api/users/{internal_id}/role")
      def set_role(internal_id: str, body: RoleUpdateRequest, req: Request):
          _require_role(req, "superadmin")
          updated = users.set_role(internal_id, body.role)
          return updated
      @app.post("/api/users/{internal_id}/disable")
      def disable_user(internal_id: str, req: Request):
          ...
          users.disable_user(internal_id)
          return {"internalUserId": internal_id, "disabled": True}
      @app.patch("/api/users/{internal_id}/email")
      def set_email(internal_id: str, body: EmailUpdateRequest, req: Request):
          ...
          return users.set_email(internal_id, body.email)

  5. Identity collapse flow. apply_collapse is keyed by target_internal_user_id — that's how the system knows which existing account to link a new federated subject into (users.py:186-213), and the pending token binds to it.

  6. OpenFGA principal disambiguation. _fga_principal decides whether to key OpenFGA tuples by the LLDAP uid or by the pending int-viewer-<hex> — and it makes that decision by inspecting whether the internal id is in _pending_users:

   identity_service/app/users.py lines 231-239

      def _fga_principal(self, internal_user_id: str) -> str:
          """The OpenFGA `user:` principal for an internal user.
          ...
          """
          if internal_user_id in _pending_users:
              return internal_user_id
          if internal_user_id.startswith("int-"):
              return internal_user_id[4:]
          return internal_user_id

  7. Frontend. The React app uses it as the React key, the row identity in the superadmin table, the target for setRole/disableUser/setEmail API calls, and to detect "did my own role just change" (SuperAdminDashboard.js:47-50, 152).

  The important nuance

  For LLDAP logins, the internal id is not a separately-stored entity — it's just int-<lldap-uid>, computed on the fly. The "user record" lives in LLDAP; OpenFGA holds the role; the session cookie carries the id. So the id is the join key across those three stores, not a row in a table.

  For pending federated viewers, the id is the key into the in-memory _pending_users dict (and the OpenFGA tuple is seeded with it as principal) — which is the only place where the id is also the storage key, and that's the part that's volatile.

  So: yes, the field is load-bearing across auth (session claims), authZ (OpenFGA principal), admin operations (URL path param), and the UI. Removing it would break the indirection between "who the IdP says you are" and "who the portal treats you as."



