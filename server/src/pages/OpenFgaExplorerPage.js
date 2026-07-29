import React, { useEffect, useMemo, useState } from "react";
import api from "../services/api";
import Banner from "../components/Banner";

const TABS = [
  { key: "users", label: "Users & Roles" },
  { key: "routes", label: "REST API Routes" },
  { key: "store", label: "Store & Models" },
  { key: "changes", label: "Changes" },
  { key: "query", label: "Query" },
];

// Mapping of OpenFGA relation to portal role for display purposes.
const RELATION_ROLE_MAP = {
  superadmin: "SuperAdmin",
  owner: "Owner",
  admin: "Admin",
  viewer: "Viewer",
};

export default function OpenFgaExplorerPage() {
  const [tab, setTab] = useState("users");
  const [err, setErr] = useState(null);

  return (
    <div>
      <h1>OpenFGA Explorer</h1>
      <p className="muted">
        Comprehensive view of the OpenFGA authorization store: users, roles,
        REST API policies, authorization models, tuple change log, and
        interactive relationship queries.
      </p>

      <nav className="nav" style={{ marginBottom: "1.25rem" }}>
        {TABS.map((t) => (
          <button
            key={t.key}
            onClick={() => { setTab(t.key); setErr(null); }}
            className={tab === t.key ? "active" : ""}
            style={{
              border: "none",
              background: tab === t.key ? "var(--accent-weak)" : "transparent",
              padding: "0.5rem 1rem",
              cursor: "pointer",
              fontWeight: tab === t.key ? 600 : 400,
              borderRadius: 6,
              marginRight: 4,
            }}
          >
            {t.label}
          </button>
        ))}
      </nav>

      {err && <Banner kind="error">{err}</Banner>}

      {tab === "users" && <UsersRolesTab onError={setErr} />}
      {tab === "routes" && <RestApiRoutesTab onError={setErr} />}
      {tab === "store" && <StoreModelsTab onError={setErr} />}
      {tab === "changes" && <ChangesTab onError={setErr} />}
      {tab === "query" && <QueryTab onError={setErr} />}
    </div>
  );
}

// ─── Tab 1: Users & Roles ──────────────────────────────────────────────────

function UsersRolesTab({ onError }) {
  const [users, setUsers] = useState([]);
  const [tuples, setTuples] = useState([]);
  const [loading, setLoading] = useState(true);
  const [query, setQuery] = useState("");
  const [expandedUser, setExpandedUser] = useState(null);

  useEffect(() => {
    let active = true;
    (async () => {
      setLoading(true);
      try {
        const [uRes, tRes] = await Promise.all([api.listUsers(), api.listTuples()]);
        if (active) {
          setUsers(uRes.users || []);
          setTuples(tRes.tuples || []);
        }
      } catch (e) {
        if (active) onError(e.message || String(e));
      } finally {
        if (active) setLoading(false);
      }
    })();
    return () => { active = false; };
  }, [onError]);

  // Derive principal from internalUserId: strip "int-" prefix
  const principal = (uid) => (uid || "").startsWith("int-") ? uid.slice(4) : uid;

  // Group tuples by user:<principal>
  const userTupleMap = useMemo(() => {
    const map = {};
    for (const t of tuples) {
      if (!t.user) continue;
      map[t.user] = map[t.user] || [];
      map[t.user].push(t);
    }
    return map;
  }, [tuples]);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return users;
    return users.filter(
      (u) =>
        (u.email || "").toLowerCase().includes(q) ||
        (u.internalUserId || "").toLowerCase().includes(q) ||
        (u.role || "").toLowerCase().includes(q)
    );
  }, [users, query]);

  if (loading) return <p className="muted">Loading users and tuples…</p>;

  return (
    <div>
      <div className="card" style={{ marginBottom: "0.75rem" }}>
        <div className="row">
          <strong>{users.length} users</strong>
          <span className="muted">·</span>
          <strong>{tuples.length} tuples</strong>
          <span className="muted">in store</span>
        </div>
      </div>

      <div className="card">
        <div className="row" style={{ marginBottom: "0.75rem" }}>
          <input
            placeholder="Search by email, ID, or role…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            style={{ minWidth: 260 }}
          />
        </div>

        <table>
          <thead>
            <tr>
              <th>Internal ID</th>
              <th>Email</th>
              <th>Role</th>
              <th>Tenant</th>
              <th>Tuples</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((u) => {
              const p = principal(u.internalUserId);
              const userTuples = userTupleMap[`user:${p}`] || [];
              const isExpanded = expandedUser === u.internalUserId;
              return (
                <React.Fragment key={u.internalUserId}>
                  <tr style={isExpanded ? { borderBottom: "none" } : {}}>
                    <td><code>{u.internalUserId}</code></td>
                    <td>{u.email || <span className="muted">—</span>}</td>
                    <td><span className={`role-pill ${u.role}`}>{u.role}</span></td>
                    <td>{u.tenant || <span className="muted">—</span>}</td>
                    <td>
                      <code>{userTuples.length}</code>{" "}
                      <button
                        className="primary"
                        style={{ fontSize: "0.8rem", padding: "0.15rem 0.5rem" }}
                        onClick={() =>
                          setExpandedUser(isExpanded ? null : u.internalUserId)
                        }
                      >
                        {isExpanded ? "Hide" : "Show"}
                      </button>
                    </td>
                    <td></td>
                  </tr>
                  {isExpanded && (
                    <tr key={`${u.internalUserId}-tuples`}>
                      <td colSpan={6} style={{ paddingTop: 0, paddingBottom: "0.75rem" }}>
                        {userTuples.length === 0 ? (
                          <p className="muted" style={{ margin: 0 }}>No tuples found for this user.</p>
                        ) : (
                          <table style={{ margin: 0 }}>
                            <thead>
                              <tr>
                                <th style={{ fontSize: "0.8rem" }}>User</th>
                                <th style={{ fontSize: "0.8rem" }}>Relation</th>
                                <th style={{ fontSize: "0.8rem" }}>Object</th>
                              </tr>
                            </thead>
                            <tbody>
                              {userTuples.map((t, i) => (
                                <tr key={i}>
                                  <td><code style={{ fontSize: "0.8rem" }}>{t.user}</code></td>
                                  <td>
                                    <span
                                      className="role-pill"
                                      style={{
                                        fontSize: "0.7rem",
                                        padding: "0.1rem 0.4rem",
                                        background:
                                          RELATION_ROLE_MAP[t.relation]
                                            ? undefined
                                            : "var(--muted)",
                                      }}
                                    >
                                      {t.relation}
                                    </span>
                                  </td>
                                  <td><code style={{ fontSize: "0.8rem" }}>{t.object}</code></td>
                                </tr>
                              ))}
                            </tbody>
                          </table>
                        )}
                      </td>
                    </tr>
                  )}
                </React.Fragment>
              );
            })}
            {filtered.length === 0 && (
              <tr><td colSpan={6} className="muted">No matching users.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// ─── Tab 2: REST API Routes ─────────────────────────────────────────────────

// Role → scopes mapping (mirrors the backend RBAC design)
const ROLE_SCOPE_MAP = {
  superadmin: ["* (all scopes)"],
  owner: ["compute:node:create", "compute:node:delete", "compute:node:power",
          "compute:node:update", "compute:volume:manage", "compute:snapshot:manage",
          "compute:network:manage", "compute:keypair:manage", "compute:image:manage",
          "compute:read", "compute:location:read", "compute:image:read",
          "compute:size:read", "compute:network:read"],
  admin: ["compute:node:create", "compute:node:delete", "compute:node:power",
          "compute:node:update", "compute:volume:manage", "compute:snapshot:manage",
          "compute:network:manage", "compute:keypair:manage", "compute:image:manage",
          "compute:read", "compute:location:read", "compute:image:read",
          "compute:size:read", "compute:network:read"],
  viewer: ["compute:read", "compute:location:read", "compute:image:read",
           "compute:size:read", "compute:network:read"],
};

function RestApiRoutesTab({ onError }) {
  const [policies, setPolicies] = useState(null);
  const [loading, setLoading] = useState(true);
  const [query, setQuery] = useState("");

  useEffect(() => {
    let active = true;
    (async () => {
      setLoading(true);
      try {
        const data = await api.getRestApiPolicies();
        if (active) setPolicies(data);
      } catch (e) {
        if (active) onError(e.message || String(e));
      } finally {
        if (active) setLoading(false);
      }
    })();
    return () => { active = false; };
  }, [onError]);

  // Convert policies object to array of entries
  const entries = useMemo(() => {
    if (!policies) return [];
    return Object.entries(policies)
      .filter(([k]) => !k.startsWith("_"))
      .map(([routeKey, entry]) => ({ routeKey, ...entry }));
  }, [policies]);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return entries;
    return entries.filter(
      (e) =>
        e.routeKey.toLowerCase().includes(q) ||
        (e.scopes_any_of || []).some((s) => s.toLowerCase().includes(q)) ||
        (e.authz_scope || "").toLowerCase().includes(q) ||
        (e.capability || "").toLowerCase().includes(q)
    );
  }, [entries, query]);

  // Determine which roles can access a given scope set
  const rolesForScopes = (scopes) => {
    if (!scopes || scopes.length === 0) return [];
    return Object.entries(ROLE_SCOPE_MAP)
      .filter(([, roleScopes]) =>
        scopes.some((s) => roleScopes.includes(s) || roleScopes.includes("* (all scopes)"))
      )
      .map(([role]) => role);
  };

  if (loading) return <p className="muted">Loading REST API policies…</p>;

  return (
    <div>
      <div className="card" style={{ marginBottom: "0.75rem" }}>
        <div className="row">
          <strong>{entries.length} routes</strong>
          <span className="muted">in policy table</span>
        </div>
      </div>

      <div className="card">
        <div className="row" style={{ marginBottom: "0.75rem" }}>
          <input
            placeholder="Search by path, scope, or capability…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            style={{ minWidth: 320 }}
          />
        </div>

        <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Method &amp; Path</th>
              <th>Required Scopes</th>
              <th>AuthZ Scope</th>
              <th>Capability</th>
              <th>Connection</th>
              <th>Accessible By</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((e) => {
              const roles = rolesForScopes(e.scopes_any_of);
              return (
                <tr key={e.routeKey}>
                  <td><code style={{ fontSize: "0.8rem" }}>{e.routeKey}</code></td>
                  <td>
                    {e.scopes_any_of.map((s) => (
                      <code key={s} style={{ fontSize: "0.7rem", display: "inline-block", margin: "1px 2px", padding: "0.1rem 0.3rem", background: "var(--accent-weak)", borderRadius: 4 }}>
                        {s}
                      </code>
                    ))}
                  </td>
                  <td>
                    {e.authz_scope ? (
                      <code style={{ fontSize: "0.75rem" }}>{e.authz_scope}</code>
                    ) : e.authz_scope_by_body_field ? (
                      <span className="muted" style={{ fontSize: "0.75rem" }}>dynamic ({e.authz_scope_by_body_field.field})</span>
                    ) : (
                      <span className="muted">—</span>
                    )}
                  </td>
                  <td>{e.capability || <span className="muted">—</span>}</td>
                  <td>{e.connection_required === false ? "No" : "Yes"}</td>
                  <td>
                    {roles.length > 0
                      ? roles.map((r) => (
                          <span key={r} className={`role-pill ${r}`} style={{ fontSize: "0.7rem", padding: "0.1rem 0.4rem", margin: "1px" }}>
                            {r}
                          </span>
                        ))
                      : <span className="muted">none</span>}
                  </td>
                </tr>
              );
            })}
            {filtered.length === 0 && (
              <tr><td colSpan={6} className="muted">No matching routes.</td></tr>
            )}
          </tbody>
        </table>
        </div>
      </div>
    </div>
  );
}

// ─── Tab 3: Store & Models ──────────────────────────────────────────────────

function StoreModelsTab({ onError }) {
  const [store, setStore] = useState(null);
  const [models, setModels] = useState(null);
  const [modelDetail, setModelDetail] = useState(null);
  const [assertions, setAssertions] = useState(null);
  const [loading, setLoading] = useState(true);
  const [loadingAssertions, setLoadingAssertions] = useState(false);

  useEffect(() => {
    let active = true;
    (async () => {
      setLoading(true);
      try {
        const [s, m] = await Promise.all([api.getOpenFgaStore(), api.getOpenFgaModels()]);
        if (active) { setStore(s); setModels(m); }
      } catch (e) {
        if (active) onError(e.message || String(e));
      } finally {
        if (active) setLoading(false);
      }
    })();
    return () => { active = false; };
  }, [onError]);

  async function loadModelDetail(modelId) {
    setModelDetail(null);
    try {
      const detail = await api.getOpenFgaModel(modelId);
      setModelDetail(detail);
    } catch (e) {
      onError(e.message || String(e));
    }
  }

  async function loadAssertions(modelId) {
    setAssertions(null);
    setLoadingAssertions(true);
    try {
      const a = await api.getOpenFgaAssertions(modelId);
      setAssertions(a);
    } catch (e) {
      onError(e.message || String(e));
    } finally {
      setLoadingAssertions(false);
    }
  }

  const modelList = useMemo(
    () => (models && models.authorization_models) || [],
    [models]
  );

  if (loading) return <p className="muted">Loading store and models…</p>;

  return (
    <div>
      {/* Store card */}
      {store && (
        <div className="card" style={{ marginBottom: "1rem" }}>
          <h3 style={{ marginTop: 0 }}>Store</h3>
          <table>
            <tbody>
              <tr><td style={{ fontWeight: 600, width: 130 }}>ID</td><td><code>{store.id}</code></td></tr>
              <tr><td style={{ fontWeight: 600 }}>Name</td><td>{store.name}</td></tr>
              <tr><td style={{ fontWeight: 600 }}>Created</td><td>{store.created_at}</td></tr>
              <tr><td style={{ fontWeight: 600 }}>Updated</td><td>{store.updated_at}</td></tr>
              {store.deleted_at && (
                <tr><td style={{ fontWeight: 600 }}>Deleted</td><td style={{ color: "var(--danger)" }}>{store.deleted_at}</td></tr>
              )}
            </tbody>
          </table>
        </div>
      )}

      {/* Authorization models */}
      <div className="card" style={{ marginBottom: "1rem" }}>
        <h3 style={{ marginTop: 0 }}>
          Authorization Models ({modelList.length})
        </h3>
        {modelList.length === 0 ? (
          <p className="muted">No models found.</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Model ID</th>
                <th>Schema Version</th>
                <th>Types</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {modelList.map((m) => (
                <React.Fragment key={m.id}>
                  <tr>
                    <td><code style={{ fontSize: "0.8rem" }}>{m.id}</code></td>
                    <td>{m.schema_version}</td>
                    <td>{(m.type_definitions || []).map((td) => td.type).join(", ")}</td>
                    <td>
                      <button className="primary" style={{ fontSize: "0.8rem", padding: "0.15rem 0.5rem", marginRight: 4 }}
                        onClick={() => loadModelDetail(m.id)}>
                        Detail
                      </button>
                      <button className="primary" style={{ fontSize: "0.8rem", padding: "0.15rem 0.5rem" }}
                        onClick={() => loadAssertions(m.id)}>
                        Assertions
                      </button>
                    </td>
                  </tr>
                  {/* Inline model detail */}
                  {modelDetail && modelDetail.authorization_model && modelDetail.authorization_model.id === m.id && (
                    <tr key={`${m.id}-detail`}>
                      <td colSpan={4} style={{ paddingTop: 0 }}>
                        <h4 style={{ marginBottom: "0.25rem" }}>Type Definitions</h4>
                        {(modelDetail.authorization_model.type_definitions || []).map((td) => (
                          <div key={td.type} className="card" style={{ padding: "0.5rem 0.75rem", marginBottom: "0.4rem" }}>
                            <strong style={{ fontFamily: "monospace" }}>{td.type}</strong>
                            {td.relations && Object.keys(td.relations).length > 0 && (
                              <div style={{ marginTop: "0.25rem" }}>
                                {Object.entries(td.relations).map(([rel, def]) => (
                                  <div key={rel} style={{ fontSize: "0.8rem", marginLeft: "1rem" }}>
                                    <code>{rel}</code>:{" "}
                                    {def.directly_related_user_types
                                      ? def.directly_related_user_types.map((ut) =>
                                          ut.relation
                                            ? `${ut.type}#${ut.relation}`
                                            : ut.type
                                        ).join(", ")
                                      : <span className="muted">computed</span>}
                                  </div>
                                ))}
                              </div>
                            )}
                            {(!td.relations || Object.keys(td.relations).length === 0) && (
                              <span className="muted" style={{ fontSize: "0.8rem", marginLeft: "1rem" }}>
                                no relations
                              </span>
                            )}
                          </div>
                        ))}
                      </td>
                    </tr>
                  )}
                </React.Fragment>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {/* Assertions */}
      {assertions && (
        <div className="card">
          <h3 style={{ marginTop: 0 }}>
            Assertions
            {assertions.authorization_model_id && (
              <span className="muted" style={{ fontSize: "0.8rem", marginLeft: "0.5rem" }}>
                model {assertions.authorization_model_id}
              </span>
            )}
          </h3>
          {loadingAssertions ? (
            <p className="muted">Loading assertions…</p>
          ) : (assertions.assertions || []).length === 0 ? (
            <p className="muted">No assertions defined.</p>
          ) : (
            <table>
              <thead>
                <tr>
                  <th>User</th>
                  <th>Relation</th>
                  <th>Object</th>
                  <th>Expected</th>
                </tr>
              </thead>
              <tbody>
                {(assertions.assertions || []).map((a, i) => {
                  const tk = a.tuple_key || {};
                  return (
                    <tr key={i}>
                      <td><code style={{ fontSize: "0.8rem" }}>{tk.user}</code></td>
                      <td>{tk.relation}</td>
                      <td><code style={{ fontSize: "0.8rem" }}>{tk.object}</code></td>
                      <td>
                        <span
                          className="role-pill"
                          style={{
                            background: a.expectation ? "var(--ok)" : "var(--danger)",
                            color: "#fff",
                            fontSize: "0.7rem",
                          }}
                        >
                          {a.expectation ? "ALLOW" : "DENY"}
                        </span>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          )}
        </div>
      )}
    </div>
  );
}

// ─── Tab 4: Changes ─────────────────────────────────────────────────────────

function ChangesTab({ onError }) {
  const [changes, setChanges] = useState(null);
  const [loading, setLoading] = useState(true);
  const [typeFilter, setTypeFilter] = useState("");
  const [token, setToken] = useState("");

  async function fetchChanges(continuationToken, filterType) {
    setLoading(true);
    try {
      const params = { page_size: 50 };
      if (continuationToken) params.continuation_token = continuationToken;
      if (filterType) params.type = filterType;
      const data = await api.getOpenFgaChanges(params);
      setChanges(data);
      setToken(data.continuation_token || "");
    } catch (e) {
      onError(e.message || String(e));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    fetchChanges("", typeFilter);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  function applyFilter() {
    fetchChanges("", typeFilter);
  }

  function nextPage() {
    if (token) {
      fetchChanges(token, typeFilter);
    }
  }

  const changeList = (changes && changes.changes) || [];

  return (
    <div>
      <div className="card" style={{ marginBottom: "1rem" }}>
        <div className="row" style={{ gap: "0.5rem", flexWrap: "wrap" }}>
          <select value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)}>
            <option value="">All operations</option>
            <option value="TUPLE_OPERATION_WRITE">WRITE only</option>
            <option value="TUPLE_OPERATION_DELETE">DELETE only</option>
          </select>
          <button className="primary" onClick={applyFilter}>Apply Filter</button>
          <div className="spacer" />
          <span className="muted">{changeList.length} changes</span>
        </div>
      </div>

      <div className="card">
        {loading ? (
          <p className="muted">Loading changes…</p>
        ) : changeList.length === 0 ? (
          <p className="muted">No changes found.</p>
        ) : (
          <>
            <table>
              <thead>
                <tr>
                  <th>Timestamp</th>
                  <th>Operation</th>
                  <th>User</th>
                  <th>Relation</th>
                  <th>Object</th>
                </tr>
              </thead>
              <tbody>
                {changeList.map((c, i) => {
                  const tk = c.tuple_key || {};
                  return (
                    <tr key={i}>
                      <td style={{ fontSize: "0.8rem" }}>{c.timestamp || "—"}</td>
                      <td>
                        <span
                          className="role-pill"
                          style={{
                            fontSize: "0.7rem",
                            padding: "0.1rem 0.4rem",
                            background: c.operation === "TUPLE_OPERATION_WRITE" ? "var(--ok)" : "var(--danger)",
                            color: "#fff",
                          }}
                        >
                          {c.operation === "TUPLE_OPERATION_WRITE" ? "WRITE" : "DELETE"}
                        </span>
                      </td>
                      <td><code style={{ fontSize: "0.8rem" }}>{tk.user}</code></td>
                      <td>{tk.relation}</td>
                      <td><code style={{ fontSize: "0.8rem" }}>{tk.object}</code></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
            {token && (
              <div style={{ marginTop: "0.75rem" }}>
                <button className="primary" onClick={nextPage}>
                  Next page →
                </button>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}

// ─── Tab 5: Query ───────────────────────────────────────────────────────────

function QueryTab({ onError }) {
  // List Users form
  const [luObject, setLuObject] = useState("tenant:aws");
  const [luRelation, setLuRelation] = useState("viewer");
  const [luTypeFilter, setLuTypeFilter] = useState("user");
  const [luResult, setLuResult] = useState(null);
  const [luLoading, setLuLoading] = useState(false);

  // List Objects form
  const [loType, setLoType] = useState("aws_region");
  const [loRelation, setLoRelation] = useState("can_read");
  const [loUser, setLoUser] = useState("user:aws-viewer");
  const [loResult, setLoResult] = useState(null);
  const [loLoading, setLoLoading] = useState(false);

  // Expand form
  const [exRelation, setExRelation] = useState("viewer");
  const [exObject, setExObject] = useState("tenant:aws");
  const [exResult, setExResult] = useState(null);
  const [exLoading, setExLoading] = useState(false);

  async function doListUsers() {
    setLuResult(null); setLuLoading(true);
    try {
      const payload = { object: luObject, relation: luRelation };
      if (luTypeFilter) payload.user_filters = [{ type: luTypeFilter, relation: luRelation }];
      const r = await api.listOpenFgaUsers(payload);
      setLuResult(r);
    } catch (e) {
      onError(e.message || String(e));
    } finally {
      setLuLoading(false);
    }
  }

  async function doListObjects() {
    setLoResult(null); setLoLoading(true);
    try {
      const r = await api.listOpenFgaObjects({ type: loType, relation: loRelation, user: loUser });
      setLoResult(r);
    } catch (e) {
      onError(e.message || String(e));
    } finally {
      setLoLoading(false);
    }
  }

  async function doExpand() {
    setExResult(null); setExLoading(true);
    try {
      const r = await api.expandOpenFga({ relation: exRelation, object: exObject });
      setExResult(r);
    } catch (e) {
      onError(e.message || String(e));
    } finally {
      setExLoading(false);
    }
  }

  // Recursive expand tree renderer
  function renderTreeNode(node, depth = 0) {
    if (!node) return <span className="muted">empty</span>;
    const indent = { marginLeft: depth * 20 };
    if (node.leaf) {
      const lu = node.leaf.userset || node.leaf.computedUserset || node.leaf.tupleToUserset || {};
      return (
        <div style={indent}>
          🍃 <code>{lu.type || "?"}{lu.id ? `:${lu.id}` : ""}{lu.relation ? `#${lu.relation}` : ""}</code>
        </div>
      );
    }
    if (node.userset) {
      return (
        <div style={indent}>
          👤 <code>{node.userset.type}:{node.userset.id}</code>
          {node.userset.relation && <span style={{ fontSize: "0.8rem" }}>#{node.userset.relation}</span>}
        </div>
      );
    }
    if (node.union || node.nodes) {
      const children = node.union ? (node.union.nodes || node.union.child || []) : (node.nodes || []);
      return (
        <div style={indent}>
          <span style={{ fontWeight: 600 }}>∪ union ({children.length})</span>
          {children.map((c, i) => <div key={i}>{renderTreeNode(c, depth + 1)}</div>)}
        </div>
      );
    }
    if (node.intersection) {
      const children = node.intersection.nodes || node.intersection.child || [];
      return (
        <div style={indent}>
          <span style={{ fontWeight: 600 }}>∩ intersection ({children.length})</span>
          {children.map((c, i) => <div key={i}>{renderTreeNode(c, depth + 1)}</div>)}
        </div>
      );
    }
    if (node.difference) {
      return (
        <div style={indent}>
          <span style={{ fontWeight: 600 }}>− difference</span>
          <div><span className="muted">base:</span> {renderTreeNode(node.difference.base, depth + 1)}</div>
          <div><span className="muted">subtract:</span> {renderTreeNode(node.difference.subtract, depth + 1)}</div>
        </div>
      );
    }
    if (node.tupleToUserset) {
      return (
        <div style={indent}>
          <span style={{ fontWeight: 600 }}>↳ tupleToUserset</span>
          <div><code>{node.tupleToUserset.tupleset}</code> → {(node.tupleToUserset.computed || []).map((c) => c.relation || c).join(", ")}</div>
        </div>
      );
    }
    return (
      <div style={indent}>
        <code>{JSON.stringify(node).slice(0, 80)}</code>
      </div>
    );
  }

  return (
    <div style={{ display: "grid", gap: "1rem" }}>
      {/* List Users */}
      <div className="card">
        <h3 style={{ marginTop: 0 }}>List Users</h3>
        <p className="muted">Find users of a given type that have a relation to an object.</p>
        <div className="row" style={{ gap: "0.5rem", flexWrap: "wrap", marginBottom: "0.5rem" }}>
          <input placeholder="Object" value={luObject} onChange={(e) => setLuObject(e.target.value)} style={{ minWidth: 140 }} />
          <input placeholder="Relation" value={luRelation} onChange={(e) => setLuRelation(e.target.value)} style={{ minWidth: 120 }} />
          <input placeholder="User type filter" value={luTypeFilter} onChange={(e) => setLuTypeFilter(e.target.value)} style={{ minWidth: 120 }} />
          <button className="primary" onClick={doListUsers} disabled={luLoading}>
            {luLoading ? "Querying…" : "Run"}
          </button>
        </div>
        {luResult && (
          <div>
            <strong>{(luResult.users || []).length} users found</strong>
            {luResult.users && luResult.users.length > 0 && (
              <table style={{ marginTop: "0.5rem" }}>
                <thead><tr><th>#</th><th>User</th></tr></thead>
                <tbody>
                  {luResult.users.map((u, i) => (
                    <tr key={i}>
                      <td style={{ color: "var(--muted)", fontSize: "0.8rem" }}>{i + 1}</td>
                      <td>
                        {u.object ? (
                          <code>{u.object.type}:{u.object.id}</code>
                        ) : u.userset ? (
                          <code>{u.userset.type}:{u.userset.id}</code>
                        ) : u.wildcard ? (
                          <code>{u.wildcard.type}:*</code>
                        ) : (
                          <code>{JSON.stringify(u)}</code>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        )}
      </div>

      {/* List Objects */}
      <div className="card">
        <h3 style={{ marginTop: 0 }}>List Objects</h3>
        <p className="muted">Find objects of a given type that a user can access via a relation.</p>
        <div className="row" style={{ gap: "0.5rem", flexWrap: "wrap", marginBottom: "0.5rem" }}>
          <input placeholder="Type" value={loType} onChange={(e) => setLoType(e.target.value)} style={{ minWidth: 120 }} />
          <input placeholder="Relation" value={loRelation} onChange={(e) => setLoRelation(e.target.value)} style={{ minWidth: 120 }} />
          <input placeholder="User" value={loUser} onChange={(e) => setLoUser(e.target.value)} style={{ minWidth: 160 }} />
          <button className="primary" onClick={doListObjects} disabled={loLoading}>
            {loLoading ? "Querying…" : "Run"}
          </button>
        </div>
        {loResult && (
          <div>
            <strong>{(loResult.objects || []).length} objects found</strong>
            {loResult.objects && loResult.objects.length > 0 && (
              <table style={{ marginTop: "0.5rem" }}>
                <thead><tr><th>#</th><th>Type</th><th>ID</th></tr></thead>
                <tbody>
                  {loResult.objects.map((o, i) => (
                    <tr key={i}>
                      <td style={{ color: "var(--muted)", fontSize: "0.8rem" }}>{i + 1}</td>
                      <td><code>{o.type || o.objectType || ""}</code></td>
                      <td><code>{o.id || o.objectId || ""}</code></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        )}
      </div>

      {/* Expand */}
      <div className="card">
        <h3 style={{ marginTop: 0 }}>Expand</h3>
        <p className="muted">Expand a relationship into its full userset tree.</p>
        <div className="row" style={{ gap: "0.5rem", flexWrap: "wrap", marginBottom: "0.5rem" }}>
          <input placeholder="Relation" value={exRelation} onChange={(e) => setExRelation(e.target.value)} style={{ minWidth: 120 }} />
          <input placeholder="Object" value={exObject} onChange={(e) => setExObject(e.target.value)} style={{ minWidth: 180 }} />
          <button className="primary" onClick={doExpand} disabled={exLoading}>
            {exLoading ? "Expanding…" : "Run"}
          </button>
        </div>
        {exResult && (
          <div>
            <strong>Expand result for <code>{exRelation}</code> @ <code>{exObject}</code></strong>
            <div className="card" style={{ marginTop: "0.5rem", background: "var(--bg)", fontFamily: "monospace", fontSize: "0.85rem", maxHeight: 400, overflow: "auto" }}>
              {exResult.tree ? renderTreeNode(exResult.tree.root) : (
                <pre style={{ margin: 0, whiteSpace: "pre-wrap" }}>{JSON.stringify(exResult, null, 2)}</pre>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
