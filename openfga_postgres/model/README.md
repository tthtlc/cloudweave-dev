# OpenFGA authorization model — DSL source

The authorization model has only ever existed as JSON (pushed by
`openfga_bootstrap.py`, readable via the management API). This directory holds
the equivalent **DSL**, which is what `play.fga.dev`, the VS Code extension and
`fga model test` all consume.

| File | What it is |
| --- | --- |
| `libcloud.fga` | The model in DSL form. 8 types, schema 1.1, no conditions. |
| `store.fga.yaml` | 66 live tuples + 108 assertions **replayed from the live server**. |
| `isolation.fga.yaml` | Cross-tenant isolation properties (derived — see provenance below). |

## Provenance

`libcloud.fga` was not hand-written. It was produced by transforming the live
model with the official CLI, so it cannot drift from what the server runs:

```bash
# extract the active model from the enumeration report
python3 -c "
import json
d=json.load(open('../generated/enumeration_report.json'))
s=list(d['sections']['per_store'].values())[0]
json.dump(s['authorization_models_full'][s['queries_model_id']], open('/tmp/model.json','w'))
"
docker run --rm -v /tmp:/w openfga/cli:latest model transform --file /w/model.json > libcloud.fga
```

Source model: `01KXWWZY8424AMK2B443FH7TQ0` (store `01KXFQ6JWFD2MZKFDFSHYNNNXE`),
which matches the configured `FGA_MODEL_ID` in `../generated/fga.env`.

Fidelity was verified two ways:

1. **Structural** — round-tripping DSL→JSON and diffing against the live model
   gives zero semantic differences. (The CLI emits explicit empty
   `directly_related_user_types: []` for computed relations where the Python SDK
   omits the key; that is serializer noise, not meaning.)
2. **Behavioural** — `store.fga.yaml` replays decisions the live server actually
   returned, and the DSL reproduces all of them.

```
$ fga model test --tests store.fga.yaml
Tests 2/2 passing · Checks 66/66 passing · ListObjects 42/42 passing

$ fga model test --tests isolation.fga.yaml
Tests 7/7 passing · Checks 62/62 passing
```

**Why `isolation.fga.yaml` exists.** All 66 recorded checks in the enumeration
report returned `true` — the enumerator only re-checks tuples that already
exist, so nothing in that dataset demonstrates a boundary *holding*. The store
also carries zero server-side assertions on any of its 4 models. The isolation
file covers the denials: an `ntnx-admin` reaching for `aws_region:aws`, a viewer
attempting to provision, an unassigned principal, and so on. Its assertions are
derived rather than replayed, which is sound because the DSL is already proven
equivalent to the live model.

## Regenerating after a model change

`libcloud.fga` is a derived artifact. After `openfga_bootstrap.py` pushes a new
model, re-run the enumerator and the transform above:

```bash
python3 ../enumerate_openfga.py          # needs an unexpired superadmin.jwt
docker run --rm -v /tmp:/w openfga/cli:latest model transform --file /w/model.json > libcloud.fga
docker run --rm -v "$PWD":/w -w /w openfga/cli:latest model test --tests isolation.fga.yaml
```

If `isolation.fga.yaml` starts failing, a tenant boundary moved — treat that as
a security regression, not a stale test.

## Viewing it

- **play.fga.dev** — open the sandbox and paste `libcloud.fga`. The model uses no
  conditions and no modules, so it loads as-is. Note this uploads the model to a
  third-party service; it is schema rather than secrets, but it does describe the
  internal tenant and role layout. Prefer pasting the model alone, not the tuple
  data in `store.fga.yaml`, which carries real principal names.
- **`openfga_visualized/`** — the repo's own visualizer (image
  `openfga-rbac-visualizer:latest` is already built locally). Offline, and it
  reads the running store directly.
- **VS Code** — the OpenFGA extension gives syntax highlighting, validation and
  inline checks against `.fga` / `.fga.yaml` files.
- **CLI, offline** — `fga model test` as above; no server or upload needed.
