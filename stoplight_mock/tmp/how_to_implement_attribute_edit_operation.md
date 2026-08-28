# How to Implement Attribute Edit Operations on Terraform-Managed Resources

This guide describes the pre-apply workflow required before modifying any
attribute on a resource managed by Terraform. Following these steps ensures
that Terraform state, the HCL configuration, and the live provider-side
resource remain in sync.

---

## Universal Pre-Apply Sequence

Every attribute edit via `terraform apply` must follow this ordered sequence:

```
terraform init  →  (apply -refresh-only if drifted)  →  terraform plan  →  terraform apply
```

---

## Step 1 — Initialize the Working Directory

```bash
terraform init -upgrade
```

| Required | Scope |
|----------|-------|
| Once per workspace, or after provider/backend changes | Per `terraform` block |

This downloads the required providers, initializes the configured backend
(local or remote), and installs any modules. Without a successful `init`,
no other Terraform command will function.

**When to re-run:**
- First time in a new working directory
- After changing `required_providers` or provider version constraints
- After changing the `backend` block

---

## Step 2 — Sync State to Live Provider (Conditional)

```bash
terraform apply -refresh-only -auto-approve
```

| Required | Scope |
|----------|-------|
| Only when drift is suspected or known | Per-resource or per-state |

This step updates the **Terraform state file** to match the live state at the
provider (e.g., AWS) **without modifying any infrastructure**. It is the
correct modern replacement for the deprecated `terraform refresh` command.

**When to run:**
- After any out-of-band change made via CLI, console, or SDK
- After discovering that `terraform plan` shows unexpected diffs
- When state may be stale (e.g., after an incident or manual recovery)

**Why it matters:**
A stale state produces incorrect plans. If state says attribute X is "A" but
AWS says "B", then a plan computed from stale state may propose the wrong
change, or miss a change entirely.

**Note:** `terraform import` is **not** suitable here — `import` is for bringing
an unmanaged resource under Terraform for the first time. For a resource already
in state, `apply -refresh-only` is the correct state-synchronization mechanism.

---

## Step 3 — Preview the Change with `terraform plan`

```bash
terraform plan -out=/tmp/changes.tfplan
```

| Required | Scope |
|----------|-------|
| **Always — before every apply** | The full configuration |

`terraform plan` does two things:

1. **Refreshes state implicitly** — queries the live provider for current
   attribute values (a lighter refresh than `-refresh-only` apply, but
   sufficient for planning purposes).
2. **Produces a diff** between the desired state (HCL config) and the
   refreshed state.

The diff uses symbols to indicate the nature of each change:

| Symbol | Meaning |
|--------|---------|
| `~`    | **Update in-place** — the attribute value changes on the existing resource without replacement |
| `-/+`  | **ForceNew / destroy-recreate** — the resource must be destroyed and re-created to apply this change |
| `+`    | **Create** — a new resource will be provisioned |
| `-`    | **Destroy** — the resource will be removed |

**Key decision point:** If the plan shows `-/+` (ForceNew) for a change you
expected to be in-place, **stop** and investigate before applying. ForceNew
changes destroy data, change resource identities (IDs, IPs, ARNs), and may
cause downtime.

**Additional signals in the plan output:**
- **No changes** — the infrastructure matches the configuration; nothing to do.
- **Unexpected changes** — attributes appearing in the diff that you did not
  intend to change may indicate drift or unintended side effects.
- **Missing changes** — an attribute you changed in HCL not appearing in the
  diff may mean the attribute is not managed by Terraform (absent from config
  or ignored via `lifecycle { ignore_changes }`).

---

## Step 4 — Apply the Change

```bash
terraform apply /tmp/changes.tfplan
# or, without a saved plan:
terraform apply -auto-approve
```

| Required | Scope |
|----------|-------|
| After reviewing and accepting the plan | Whatever the plan covers |

Using a saved plan file (`/tmp/changes.tfplan`) guarantees that the exact
changes you reviewed are what gets applied. Running `terraform apply` without
a plan file re-computes the plan, which could produce a different result if
state or provider reality changed in the interim.

---

## Complete Cheat Sheet

```bash
# 1. Initialize (once)
terraform init -upgrade

# 2. If drift exists — sync state to live provider
terraform apply -refresh-only -auto-approve

# 3. Preview changes (always)
terraform plan -out=/tmp/changes.tfplan

# 4. Inspect the plan output for:
#    - ~ (in-place) vs -/+ (ForceNew)
#    - Unexpected additions or removals
#    - Missing changes you expected to see

# 5. Apply
terraform apply /tmp/changes.tfplan
```

---

## Managed vs. Unmanaged Attributes

The behaviour of `terraform plan` and `terraform apply` differs depending on
whether an attribute is declared in the HCL configuration:

| Attribute status | Plan behaviour | Apply behaviour |
|------------------|----------------|-----------------|
| **Managed** (declared in config) | Shows drift as a change to reconcile | Will modify the attribute to match config |
| **Unmanaged** (absent from config) | Shows no diff for out-of-band changes | Will **not** touch the attribute — whatever value exists at the provider persists |

**Implication:** If you want Terraform to own an attribute and prevent drift,
declare it explicitly in the HCL config. If you intentionally want out-of-band
changes to persist (e.g., an attribute managed by another team or tool),
omit it from the config.

---

## Evidence Capture (for Auditing and Debugging)

When implementing a new edit operation, capture the following at each step
to build a traceable audit trail:

| Artifact | Command |
|----------|---------|
| Terraform state show | `terraform state show <resource>` |
| Full Terraform state (JSON) | `terraform show -json` |
| Saved plan (binary + JSON) | `terraform plan -out=<file>` then `terraform show -json <file>` |
| Provider-side resource state | e.g., `aws ec2 describe-instances --instance-ids <id>` |
| Specific attribute at provider | e.g., `aws ec2 describe-instance-attribute --attribute <attr>` |

These artifacts let you compare the three sources of truth at each step:

| Source | Represents |
|--------|------------|
| **Provider live state** (AWS API) | What actually exists |
| **Terraform state file** (`terraform.tfstate`) | What Terraform believes exists |
| **Terraform config** (`.tf` files) | What you declared as the desired state |

A resource is fully in-sync when all three sources agree.

---

## Summary Table of Three-Way Agreement

| Step | Provider (Live) | Terraform State | Terraform Config | In sync? |
|------|-----------------|-----------------|------------------|----------|
| After init + apply | Matches config | Matches config | Desired value | ✓ |
| After out-of-band change | **Drifted** | Stale | Unchanged | ✗ |
| After refresh-only | Matches state now | Matches provider | Unchanged | Partial (config still differs) |
| After apply (with config change) | Matches config | Matches config | Desired value | ✓ |
