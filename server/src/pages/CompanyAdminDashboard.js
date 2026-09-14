import React, { useCallback, useEffect, useMemo, useState } from "react";
import { useAuth } from "../context/AuthContext";
import api from "../services/api";
import Banner from "../components/Banner";

const PROVIDERS = [
  { id: "aws", label: "AWS" },
  { id: "nutanix", label: "Nutanix" },
];

const MEMBER_ROLES = ["owner", "admin", "viewer"];

// Department owners and members are stored as OpenFGA principals (raw uid,
// e.g. "user01"); the user selects are keyed by internalUserId ("int-user01").
// Normalize principal -> internalUserId and principal -> display label.
const internalIdFor = (principal, users) => {
  if (!principal) return "";
  if (principal.startsWith("int-")) return principal;
  const match = users.find((u) => u.internalUserId === `int-${principal}` || u.internalUserId === principal);
  return match ? match.internalUserId : `int-${principal}`;
};
const displayFor = (principal, users) => {
  if (!principal) return "—";
  const match = users.find((u) => u.internalUserId === `int-${principal}` || u.internalUserId === principal);
  return match ? match.email || match.internalUserId : principal;
};

// Company administrator: create departments (one or more providers each, via a
// checkbox list), manage departments (edit providers/owner, delete), and manage
// the department users (members) across the company (edit role + department,
// delete). The per-department Vault AppRole is created server-side and is
// invisible here (role_id/secret_id are never returned). Credentials are
// viewable/rotatable per department, gated on can_manage_credentials.
export default function CompanyAdminDashboard() {
  const { session } = useAuth();
  const companyId = session?.company || "";

  const [users, setUsers] = useState([]);
  const [departments, setDepartments] = useState([]);
  const [members, setMembers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [msg, setMsg] = useState(null);
  const [err, setErr] = useState(null);
  const [busy, setBusy] = useState(false);

  // create-department draft form
  const [name, setName] = useState("");
  const [ownerId, setOwnerId] = useState("");
  const [selectedClouds, setSelectedClouds] = useState(["aws"]);
  const [cred, setCred] = useState({
    aws: { key: "", secret: "" },
    nutanix: { host: "", key: "", secret: "" },
  });

  // add-member draft form
  const [addUser, setAddUser] = useState("");
  const [addDept, setAddDept] = useState("");
  const [addRole, setAddRole] = useState("admin");

  // department inline edit state
  const [editingDept, setEditingDept] = useState(null);
  const [deptDraft, setDeptDraft] = useState({
    ownerUserId: "",
    clouds: [],
    credentials: { aws: { key: "", secret: "" }, nutanix: { host: "", key: "", secret: "" } },
  });

  // member inline edit state (key = `${dept}:${user}`)
  const [editingMember, setEditingMember] = useState(null);
  const [memberDraft, setMemberDraft] = useState({ role: "viewer", department: "" });

  // credential reveal state: dept id -> { shown: bool, data: {key,secret} }
  const [revealed, setRevealed] = useState({});

  const refresh = useCallback(async () => {
    setLoading(true);
    setErr(null);
    try {
      const [u, d, m] = await Promise.all([
        api.listAssignableUsers(),
        api.listDepartments(companyId),
        api.listMembers(companyId),
      ]);
      setUsers(u.users || []);
      setDepartments(d.departments || []);
      setMembers(m.members || []);
    } catch (e) {
      setErr(e.message || String(e));
    } finally {
      setLoading(false);
    }
  }, [companyId]);

  useEffect(() => { refresh(); }, [refresh]);

  const ownerOptions = useMemo(
    () => users.filter((u) => !u.internalUserId?.startsWith("int-pending-")),
    [users]
  );

  function toggleCloud(id) {
    setSelectedClouds((prev) =>
      prev.includes(id) ? prev.filter((c) => c !== id) : [...prev, id]
    );
  }

  function setCredField(cloud, field, value) {
    setCred((prev) => ({ ...prev, [cloud]: { ...prev[cloud], [field]: value } }));
  }

  async function createDepartment(e) {
    e.preventDefault();
    if (selectedClouds.length === 0) { setErr("Select at least one provider."); return; }
    setBusy(true); setMsg(null); setErr(null);
    try {
      const payload = { name, clouds: selectedClouds, ownerUserId: ownerId, credentials: {} };
      if (selectedClouds.includes("aws") && (cred.aws.key || cred.aws.secret)) {
        payload.credentials.aws = { key: cred.aws.key, secret: cred.aws.secret };
      }
      if (selectedClouds.includes("nutanix") && (cred.nutanix.key || cred.nutanix.secret || cred.nutanix.host)) {
        payload.credentials.nutanix = {
          key: cred.nutanix.key, secret: cred.nutanix.secret, host: cred.nutanix.host,
        };
      }
      const r = await api.createDepartment(companyId, payload);
      setMsg(`Department "${r.id}" created (providers=${r.clouds.join(", ")}, owner=${r.ownerUserId}). The per-department AppRole is created server-side and is not shown.`);
      setName(""); setOwnerId(""); setSelectedClouds(["aws"]);
      setCred({ aws: { key: "", secret: "" }, nutanix: { host: "", key: "", secret: "" } });
      await refresh();
    } catch (e2) {
      setErr(e2.message || String(e2));
    } finally {
      setBusy(false);
    }
  }

  async function addMember(e) {
    e.preventDefault();
    if (!addUser || !addDept) { setErr("Select a user and a department."); return; }
    setBusy(true); setMsg(null); setErr(null);
    try {
      await api.updateDepartmentUser(addDept, addUser, { role: addRole });
      setMsg(`Assigned ${addUser} as ${addRole} in ${addDept}.`);
      setAddUser(""); setAddDept(""); setAddRole("admin");
      await refresh();
    } catch (e2) {
      setErr(e2.message || String(e2));
    } finally {
      setBusy(false);
    }
  }

  // --- department edit / delete ---
  function emptyDeptCredentials() {
    return { aws: { key: "", secret: "" }, nutanix: { host: "", key: "", secret: "" } };
  }
  function startEditDept(d) {
    setEditingDept(d.id);
    setDeptDraft({
      ownerUserId: internalIdFor(d.owner, users),
      clouds: d.clouds || [],
      credentials: emptyDeptCredentials(),
    });
    setMsg(null); setErr(null);
  }
  function toggleDeptCloud(id) {
    setDeptDraft((prev) => ({
      ...prev,
      clouds: prev.clouds.includes(id)
        ? prev.clouds.filter((c) => c !== id)
        : [...prev.clouds, id],
    }));
  }
  function setDeptCredField(cloud, field, value) {
    setDeptDraft((prev) => ({
      ...prev,
      credentials: {
        ...prev.credentials,
        [cloud]: { ...(prev.credentials?.[cloud] || {}), [field]: value },
      },
    }));
  }
  function cancelEditDept() {
    setEditingDept(null);
    setDeptDraft({ ownerUserId: "", clouds: [], credentials: emptyDeptCredentials() });
  }

  async function saveDept(d) {
    if (deptDraft.clouds.length === 0) { setErr("A department needs at least one provider."); return; }
    if (!deptDraft.ownerUserId) { setErr("A department needs an owner."); return; }
    setMsg(null); setErr(null);
    try {
      // Only forward credentials the admin actually typed; blank fields keep
      // the provider's existing secret in Vault.
      const cred = deptDraft.credentials || {};
      const credentials = {};
      if (deptDraft.clouds.includes("aws") && (cred.aws?.key || cred.aws?.secret)) {
        credentials.aws = { key: cred.aws.key, secret: cred.aws.secret };
      }
      if (
        deptDraft.clouds.includes("nutanix") &&
        (cred.nutanix?.key || cred.nutanix?.secret || cred.nutanix?.host)
      ) {
        credentials.nutanix = {
          key: cred.nutanix.key, secret: cred.nutanix.secret, host: cred.nutanix.host,
        };
      }
      const payload = {
        ownerUserId: deptDraft.ownerUserId,
        clouds: deptDraft.clouds,
      };
      if (Object.keys(credentials).length) payload.credentials = credentials;
      await api.updateDepartment(d.id, payload);
      setMsg(`Department "${d.id}" updated${Object.keys(credentials).length ? " (credentials saved)" : ""}.`);
      cancelEditDept();
      await refresh();
    } catch (e2) {
      setErr(e2.message || String(e2));
    }
  }

  async function deleteDept(d) {
    const n = members.filter((m) => m.department === d.id).length;
    const warn = `Delete department "${d.id}"?` + (n ? `\n${n} member(s) will lose their roles.` : "");
    if (!window.confirm(warn)) return;
    setMsg(null); setErr(null);
    try {
      await api.deleteDepartment(d.id);
      setMsg(`Department "${d.id}" deleted.`);
      await refresh();
    } catch (e2) {
      setErr(e2.message || String(e2));
    }
  }

  // --- member edit / delete ---
  function startEditMember(m) {
    setEditingMember(`${m.department}:${m.user}`);
    setMemberDraft({ role: m.role, department: m.department });
    setMsg(null); setErr(null);
  }
  function cancelEditMember() { setEditingMember(null); setMemberDraft({ role: "viewer", department: "" }); }

  async function saveMember(m) {
    setMsg(null); setErr(null);
    try {
      await api.updateDepartmentUser(m.department, m.user, {
        role: memberDraft.role,
        department: memberDraft.department,
      });
      setMsg(`Updated ${m.user} (role=${memberDraft.role}${memberDraft.department !== m.department ? `, moved to ${memberDraft.department}` : ""}).`);
      cancelEditMember();
      await refresh();
    } catch (e2) {
      setErr(e2.message || String(e2));
    }
  }

  async function deleteMember(m) {
    if (!window.confirm(`Remove ${m.user} from ${m.department}?`)) return;
    setMsg(null); setErr(null);
    try {
      await api.deleteDepartmentUser(m.department, m.user);
      setMsg(`Removed ${m.user} from ${m.department}.`);
      await refresh();
    } catch (e2) {
      setErr(e2.message || String(e2));
    }
  }

  // --- credential reveal / rotate ---
  async function revealCredential(dept) {
    setErr(null);
    try {
      const data = await api.getDepartmentCredential(dept);
      setRevealed((prev) => ({ ...prev, [dept]: { shown: true, data } }));
    } catch (e) {
      setErr(e.message || String(e));
    }
  }
  function hideCredential(dept) {
    setRevealed((prev) => ({ ...prev, [dept]: { ...prev[dept], shown: false } }));
  }
  async function rotateCredential(dept) {
    const cur = revealed[dept]?.data || {};
    const nk = window.prompt("New credential key", cur.key || "");
    if (nk === null) return;
    const ns = window.prompt("New credential secret", "");
    if (ns === null) return;
    setErr(null);
    try {
      await api.rotateDepartmentCredential(dept, { key: nk.trim(), secret: ns });
      setMsg(`Credential rotated for ${dept}.`);
      setRevealed((prev) => ({ ...prev, [dept]: { shown: false, data: null } }));
    } catch (e) {
      setErr(e.message || String(e));
    }
  }

  const providerLabels = (clouds) => (clouds || []).map((c) => PROVIDERS.find((p) => p.id === c)?.label || c);

  return (
    <div>
      <h1>Company Admin — Departments &amp; Users</h1>
      <p className="muted">
        Company <code>{companyId || "—"}</code>. Create departments bound to one
        or more cloud providers, assign an owner, and manage the department
        users across your company. The backend mints a distinct per-department
        Vault AppRole (invisible to you); cloud credentials are viewable/rotatable
        below.
      </p>

      {msg && <Banner kind="success">{msg}</Banner>}
      {err && <Banner kind="error">{err}</Banner>}

      <div className="card">
        <h2>Create department</h2>
        <form onSubmit={createDepartment} className="stack" style={{ gap: "0.9rem" }}>
          <div className="row" style={{ gap: "0.5rem", flexWrap: "wrap" }}>
            <input
              placeholder="Department name (e.g. Engineering)"
              value={name}
              onChange={(e) => setName(e.target.value)}
              required
              style={{ minWidth: 220 }}
            />
            <select value={ownerId} onChange={(e) => setOwnerId(e.target.value)} required>
              <option value="">-- assign owner (LLDAP user) --</option>
              {ownerOptions.map((u) => (
                <option key={u.internalUserId} value={u.internalUserId}>
                  {u.email || u.internalUserId}
                </option>
              ))}
            </select>
          </div>

          <fieldset className="checkbox-group">
            <legend>Providers</legend>
            {PROVIDERS.map((p) => (
              <label key={p.id} className="checkbox">
                <input
                  type="checkbox"
                  checked={selectedClouds.includes(p.id)}
                  onChange={() => toggleCloud(p.id)}
                />
                <span>{p.label}</span>
              </label>
            ))}
          </fieldset>

          {selectedClouds.includes("aws") && (
            <fieldset className="cred-block">
              <legend>AWS credential</legend>
              <div className="row" style={{ gap: "0.5rem", flexWrap: "wrap" }}>
                <input
                  placeholder="AWS access key"
                  value={cred.aws.key}
                  onChange={(e) => setCredField("aws", "key", e.target.value)}
                />
                <input
                  type="password"
                  placeholder="AWS secret access key"
                  value={cred.aws.secret}
                  onChange={(e) => setCredField("aws", "secret", e.target.value)}
                />
              </div>
            </fieldset>
          )}

          {selectedClouds.includes("nutanix") && (
            <fieldset className="cred-block">
              <legend>Nutanix credential</legend>
              <div className="row" style={{ gap: "0.5rem", flexWrap: "wrap" }}>
                <input
                  placeholder="Prism Central URL (e.g. host.docker.internal:9440)"
                  value={cred.nutanix.host}
                  onChange={(e) => setCredField("nutanix", "host", e.target.value)}
                />
                <input
                  placeholder="Admin username"
                  value={cred.nutanix.key}
                  onChange={(e) => setCredField("nutanix", "key", e.target.value)}
                />
                <input
                  type="password"
                  placeholder="Admin password"
                  value={cred.nutanix.secret}
                  onChange={(e) => setCredField("nutanix", "secret", e.target.value)}
                />
              </div>
            </fieldset>
          )}

          <div>
            <button className="primary" type="submit" disabled={busy}>
              {busy ? "Creating…" : "Create department"}
            </button>
          </div>
        </form>
      </div>

      <div className="card">
        <div className="row" style={{ marginBottom: "0.75rem" }}>
          <h2 style={{ margin: 0 }}>Departments</h2>
          <div className="spacer" />
          <button onClick={refresh} disabled={loading}>{loading ? "Loading…" : "Refresh"}</button>
        </div>
        {loading ? (
          <p className="muted">Loading departments…</p>
        ) : departments.length === 0 ? (
          <p className="muted">No departments yet.</p>
        ) : (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Providers</th>
                  <th>Owner</th>
                  <th>Credential</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                {departments.map((d) => {
                  const r = revealed[d.id];
                  const editing = editingDept === d.id;
                  return (
                    <tr key={d.id}>
                      <td><code>{d.id}</code></td>
                      <td>
                        {editing ? (
                          <span className="checkbox-inline">
                            {PROVIDERS.map((p) => (
                              <label key={p.id} className="checkbox">
                                <input
                                  type="checkbox"
                                  checked={deptDraft.clouds.includes(p.id)}
                                  onChange={() => toggleDeptCloud(p.id)}
                                />
                                <span>{p.label}</span>
                              </label>
                            ))}
                          </span>
                        ) : (
                          providerLabels(d.clouds).join(", ") || "—"
                        )}
                      </td>
                      <td>
                        {editing ? (
                          <select
                            value={deptDraft.ownerUserId}
                            onChange={(e) => setDeptDraft({ ...deptDraft, ownerUserId: e.target.value })}
                          >
                            <option value="">-- assign owner --</option>
                            {ownerOptions.map((u) => (
                              <option key={u.internalUserId} value={u.internalUserId}>
                                {u.email || u.internalUserId}
                              </option>
                            ))}
                          </select>
                        ) : (
                          displayFor(d.owner, users)
                        )}
                      </td>
                      <td>
                        {editing ? (
                          <span className="stack" style={{ gap: "0.35rem", minWidth: 230 }}>
                            {deptDraft.clouds.includes("aws") && (
                              <div className="row" style={{ gap: "0.25rem" }}>
                                <input
                                  placeholder="AWS access key"
                                  value={deptDraft.credentials?.aws?.key || ""}
                                  onChange={(e) => setDeptCredField("aws", "key", e.target.value)}
                                />
                                <input
                                  type="password"
                                  placeholder="AWS secret key"
                                  value={deptDraft.credentials?.aws?.secret || ""}
                                  onChange={(e) => setDeptCredField("aws", "secret", e.target.value)}
                                />
                              </div>
                            )}
                            {deptDraft.clouds.includes("nutanix") && (
                              <div className="stack" style={{ gap: "0.25rem" }}>
                                <input
                                  placeholder="Prism Central URL"
                                  value={deptDraft.credentials?.nutanix?.host || ""}
                                  onChange={(e) => setDeptCredField("nutanix", "host", e.target.value)}
                                />
                                <input
                                  placeholder="Admin username"
                                  value={deptDraft.credentials?.nutanix?.key || ""}
                                  onChange={(e) => setDeptCredField("nutanix", "key", e.target.value)}
                                />
                                <input
                                  type="password"
                                  placeholder="Admin password"
                                  value={deptDraft.credentials?.nutanix?.secret || ""}
                                  onChange={(e) => setDeptCredField("nutanix", "secret", e.target.value)}
                                />
                              </div>
                            )}
                            <div className="muted" style={{ fontSize: "0.85em" }}>
                              Leave blank to keep existing credentials.
                            </div>
                          </span>
                        ) : (
                          <span>
                            {r?.shown ? (
                              <span>
                                {r.data?.host ? <><code>host={r.data.host}</code>{" "}</> : null}
                                <code>key={r.data?.key || "—"}</code>{" "}
                                <code>secret={r.data?.secret || "—"}</code>{" "}
                                <button onClick={() => hideCredential(d.id)}>Hide</button>{" "}
                                <button onClick={() => rotateCredential(d.id)}>Rotate</button>
                              </span>
                            ) : (
                              <span>
                                <button onClick={() => revealCredential(d.id)}>Reveal credential</button>{" "}
                                <button onClick={() => rotateCredential(d.id)}>Rotate</button>
                              </span>
                            )}
                          </span>
                        )}
                      </td>
                      <td>
                        {editing ? (
                          <span className="row-actions">
                            <button className="primary" onClick={() => saveDept(d)}>Save</button>
                            <button onClick={cancelEditDept}>Cancel</button>
                          </span>
                        ) : (
                          <span className="row-actions">
                            <button onClick={() => startEditDept(d)}>Edit</button>
                            <button className="danger" onClick={() => deleteDept(d)}>Delete</button>
                          </span>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>

      <div className="card">
        <div className="row" style={{ marginBottom: "0.75rem" }}>
          <h2 style={{ margin: 0 }}>Department users</h2>
          <div className="spacer" />
        </div>

        <form onSubmit={addMember} className="row" style={{ gap: "0.5rem", marginBottom: "0.9rem", flexWrap: "wrap" }}>
          <select value={addUser} onChange={(e) => setAddUser(e.target.value)}>
            <option value="">-- select user --</option>
            {ownerOptions.map((u) => (
              <option key={u.internalUserId} value={u.internalUserId}>
                {u.email || u.internalUserId}
              </option>
            ))}
          </select>
          <select value={addDept} onChange={(e) => setAddDept(e.target.value)}>
            <option value="">-- select department --</option>
            {departments.map((d) => (
              <option key={d.id} value={d.id}>{d.id}</option>
            ))}
          </select>
          <select value={addRole} onChange={(e) => setAddRole(e.target.value)}>
            {MEMBER_ROLES.map((r) => <option key={r} value={r}>{r}</option>)}
          </select>
          <button className="primary" type="submit" disabled={busy || !addUser || !addDept}>Add member</button>
        </form>

        {members.length === 0 ? (
          <p className="muted">No department users yet.</p>
        ) : (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>User</th>
                  <th>Department</th>
                  <th>Role</th>
                  <th>Providers</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                {members.map((m) => {
                  const key = `${m.department}:${m.user}`;
                  const editing = editingMember === key;
                  return (
                    <tr key={key}>
                      <td><code>{displayFor(m.user, users)}</code></td>
                      <td>
                        {editing ? (
                          <select
                            value={memberDraft.department}
                            onChange={(e) => setMemberDraft({ ...memberDraft, department: e.target.value })}
                          >
                            {departments.map((d) => (
                              <option key={d.id} value={d.id}>{d.id}</option>
                            ))}
                          </select>
                        ) : (
                          <code>{m.department}</code>
                        )}
                      </td>
                      <td>
                        {editing ? (
                          <select
                            value={memberDraft.role}
                            onChange={(e) => setMemberDraft({ ...memberDraft, role: e.target.value })}
                          >
                            {MEMBER_ROLES.map((r) => <option key={r} value={r}>{r}</option>)}
                          </select>
                        ) : (
                          <span className={`role-pill ${m.role}`}>{m.role}</span>
                        )}
                      </td>
                      <td>{providerLabels(m.clouds).join(", ") || "—"}</td>
                      <td>
                        {editing ? (
                          <span className="row-actions">
                            <button className="primary" onClick={() => saveMember(m)}>Save</button>
                            <button onClick={cancelEditMember}>Cancel</button>
                          </span>
                        ) : (
                          <span className="row-actions">
                            <button onClick={() => startEditMember(m)}>Edit</button>
                            <button className="danger" onClick={() => deleteMember(m)}>Remove</button>
                          </span>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}
