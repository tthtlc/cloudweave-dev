import React, { useEffect, useMemo, useState } from "react";
import api from "../services/api";
import Banner from "../components/Banner";

// Superadmin power screen: list every OpenFGA relationship tuple in the store
// and let the superadmin add / delete tuples directly. This is the single
// mechanism behind role grants AND disable (delete a user's role tuple to
// revoke their access for this system only). Backend enforces superadmin via
// OpenFGA on every call.
export default function OpenFgaTuplesPage() {
  const [tuples, setTuples] = useState([]);
  const [loading, setLoading] = useState(true);
  const [query, setQuery] = useState("");
  const [msg, setMsg] = useState(null);
  const [err, setErr] = useState(null);
  const [draft, setDraft] = useState({ user: "", relation: "", object: "" });

  async function refresh() {
    setLoading(true);
    setErr(null);
    try {
      const { tuples: list } = await api.listTuples();
      list.sort((a, b) =>
        a.object === b.object
          ? (a.relation || "").localeCompare(b.relation || "")
          : a.object.localeCompare(b.object)
      );
      setTuples(list);
    } catch (e) {
      setErr(e.message || String(e));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { refresh(); }, []);

  async function addTuple() {
    setMsg(null); setErr(null);
    const t = {
      user: draft.user.trim(),
      relation: draft.relation.trim(),
      object: draft.object.trim(),
    };
    if (!t.user || !t.relation || !t.object) {
      setErr("user, relation, and object are all required");
      return;
    }
    try {
      await api.writeTuples([t]);
      setMsg(`Added ${fmt(t)}`);
      setDraft({ user: "", relation: "", object: "" });
      await refresh();
    } catch (e) {
      setErr(e.message || String(e));
    }
  }

  async function removeTuple(t) {
    setMsg(null); setErr(null);
    try {
      await api.deleteTuples([t]);
      setMsg(`Deleted ${fmt(t)}`);
      await refresh();
    } catch (e) {
      setErr(e.message || String(e));
    }
  }

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return tuples;
    return tuples.filter((t) =>
      t.user.toLowerCase().includes(q) ||
      t.relation.toLowerCase().includes(q) ||
      t.object.toLowerCase().includes(q)
    );
  }, [tuples, query]);

  return (
    <div>
      <h1>Superadmin — OpenFGA Tuples</h1>
      <p className="muted">
        Every relationship tuple in the OpenFGA store. Add or delete tuples
        directly; this is how roles are granted and how a user is disabled for
        this system (delete their <code>user:&lt;uid&gt;</code> role tuple on
        <code> tenant:</code>/<code>platform:</code>). Structural tuples
        (parent/provider/tenant) drive permission propagation — edit with care.
      </p>

      {msg && <Banner kind="success">{msg}</Banner>}
      {err && <Banner kind="error">{err}</Banner>}

      <div className="card" style={{ marginBottom: "1rem" }}>
        <h3 style={{ marginTop: 0 }}>Add a tuple</h3>
        <div className="row" style={{ gap: "0.5rem", flexWrap: "wrap" }}>
          <input placeholder="user (e.g. user:aws-admin)" value={draft.user}
            onChange={(e) => setDraft({ ...draft, user: e.target.value })} style={{ minWidth: 220 }} />
          <input placeholder="relation (e.g. admin)" value={draft.relation}
            onChange={(e) => setDraft({ ...draft, relation: e.target.value })} style={{ minWidth: 160 }} />
          <input placeholder="object (e.g. tenant:aws)" value={draft.object}
            onChange={(e) => setDraft({ ...draft, object: e.target.value })} style={{ minWidth: 200 }} />
          <button className="primary" onClick={addTuple}>Add tuple</button>
        </div>
      </div>

      <div className="card">
        <div className="row" style={{ marginBottom: "0.75rem" }}>
          <input placeholder="Filter by user / relation / object…"
            value={query} onChange={(e) => setQuery(e.target.value)} style={{ minWidth: 320 }} />
          <div className="spacer" />
          <button onClick={refresh} disabled={loading}>{loading ? "Loading…" : "Refresh"}</button>
        </div>

        {loading ? (
          <p className="muted">Loading tuples…</p>
        ) : (
          <table>
            <thead>
              <tr><th>User</th><th>Relation</th><th>Object</th><th></th></tr>
            </thead>
            <tbody>
              {filtered.map((t, i) => (
                <tr key={`${t.user}|${t.relation}|${t.object}|${i}`}>
                  <td><code>{t.user}</code></td>
                  <td>{t.relation}</td>
                  <td><code>{t.object}</code></td>
                  <td><button className="danger" onClick={() => removeTuple(t)}>Delete</button></td>
                </tr>
              ))}
              {filtered.length === 0 && (
                <tr><td colSpan={4} className="muted">No matching tuples.</td></tr>
              )}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}

function fmt(t) {
  return `${t.user} ${t.relation} ${t.object}`;
}
