#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# create_ec2_user.sh  (runs inside Docker)
#
# Creates an IAM user with full EC2 provisioning/deprovisioning privileges,
# generates an access key, and writes the credentials into a persistent
# host-mounted volume so the host can use them after the container exits.
#
# The container expects:
#   /root/.aws  → host admin AWS config  (read-only, the "source" session)
#   /aws_output → host directory where the new credentials file is persisted
#
# Usage:
#   docker compose run --rm aws-bootstrap <username> [profile_name]
# ---------------------------------------------------------------------------
set -euo pipefail

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[INFO]  $*"; }
ok()   { echo "[OK]    $*"; }

USERNAME="${1:?Usage: create_ec2_user.sh <username> [profile_name]}"
PROFILE="${2:-$USERNAME}"

OUTPUT_DIR="${AWS_OUTPUT_DIR:-/aws_output}"
OUTPUT_CRED="${OUTPUT_DIR}/credentials"
OUTPUT_CONF="${OUTPUT_DIR}/config"

POLICY_NAME="EC2FullProvisionDeprovision-${USERNAME}"

# ---- 1. Create the IAM user ------------------------------------------------
info "Creating IAM user: ${USERNAME}"
if aws iam get-user --user-name "${USERNAME}" &>/dev/null; then
    info "User ${USERNAME} already exists — skipping creation."
else
    aws iam create-user --user-name "${USERNAME}"
    ok "User ${USERNAME} created."
fi

# ---- 2. Attach AWS-managed EC2 full-access policy -------------------------
info "Attaching AmazonEC2FullAccess to ${USERNAME}"
aws iam attach-user-policy \
    --user-name "${USERNAME}" \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess \
    || info "Policy may already be attached — continuing."
ok "AmazonEC2FullAccess attached."

# ---- 3. Inline policy — EC2 + PassRole + supporting services ---------------
info "Creating inline policy '${POLICY_NAME}' (ec2:*, iam:PassRole, ELB, ASG, CloudWatch)"

INLINE_POLICY=$(cat <<'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:*"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "iam:PassRole",
                "iam:GetInstanceProfile",
                "iam:ListInstanceProfiles"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "elasticloadbalancing:*",
                "autoscaling:*",
                "cloudwatch:*"
            ],
            "Resource": "*"
        }
    ]
}
EOF
)

if aws iam get-user-policy --user-name "${USERNAME}" --policy-name "${POLICY_NAME}" &>/dev/null; then
    aws iam delete-user-policy --user-name "${USERNAME}" --policy-name "${POLICY_NAME}"
fi

aws iam put-user-policy \
    --user-name "${USERNAME}" \
    --policy-name "${POLICY_NAME}" \
    --policy-document "${INLINE_POLICY}"
ok "Inline policy '${POLICY_NAME}' attached."

# ---- 4. Create an access key -----------------------------------------------
info "Creating access key for ${USERNAME}"
KEY_JSON=$(aws iam create-access-key --user-name "${USERNAME}")

ACCESS_KEY_ID=$(echo "${KEY_JSON}" | jq -r '.AccessKey.AccessKeyId')
SECRET_ACCESS_KEY=$(echo "${KEY_JSON}" | jq -r '.AccessKey.SecretAccessKey')

ok "Access key created."
echo "─────────────────────────────────────────────────────"
echo "  Access Key ID : ${ACCESS_KEY_ID}"
echo "  Secret Key    : ${SECRET_ACCESS_KEY}"
echo "─────────────────────────────────────────────────────"

# ---- 5. Persist credentials to host-mounted volume -------------------------
info "Writing credentials → ${OUTPUT_CRED} (host-persistent)"

# credentials file
cat > "${OUTPUT_CRED}" <<EOF
# Written by create_ec2_user.sh (Docker) on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# IAM user: ${USERNAME}
[${PROFILE}]
aws_access_key_id     = ${ACCESS_KEY_ID}
aws_secret_access_key = ${SECRET_ACCESS_KEY}
EOF

# Determine region from the admin session, fallback to us-east-1
REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

# config file
cat > "${OUTPUT_CONF}" <<EOF
# Written by create_ec2_user.sh (Docker) on $(date -u +%Y-%m-%dT%H:%M:%SZ)
[profile ${PROFILE}]
region = ${REGION}
output = json
EOF

# Merge mode — if the host already has these files, append new sections
# rather than clobbering.  We do this by checking whether the target
# profile already exists in the file; if not, append.
merge_section() {
    local file="$1" section_name="$2" content="$3"
    if [ -f "${file}" ] && grep -qF "[${section_name}]" "${file}"; then
        info "Section [${section_name}] already present in ${file} — skipping (no overwrite)."
    else
        printf '\n%s\n' "${content}" >> "${file}"
        ok "Merged [${section_name}] into ${file}."
    fi
}

merge_section "${OUTPUT_CRED}" "${PROFILE}" \
    "[${PROFILE}]
aws_access_key_id     = ${ACCESS_KEY_ID}
aws_secret_access_key = ${SECRET_ACCESS_KEY}"

merge_section "${OUTPUT_CONF}" "profile ${PROFILE}" \
    "[profile ${PROFILE}]
region = ${REGION}
output = json"

# ---- 6. Verify credentials against EC2 -------------------------------------
info "Verifying the new credentials with ec2:DescribeRegions..."
# Temporarily export the new keys so the verification call uses them
export AWS_ACCESS_KEY_ID="${ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${SECRET_ACCESS_KEY}"
unset AWS_PROFILE AWS_SESSION_TOKEN

if aws ec2 describe-regions \
        --region "${REGION}" \
        --no-cli-pager \
        --max-items 1 \
        --output text &>/dev/null; then
    ok "Credentials verified — user '${USERNAME}' can call EC2 APIs."
else
    die "Credential verification failed — check the IAM policies."
fi

# ---- 7. Summary ------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Done."
echo ""
echo "  Credentials persisted to host:"
echo "    ${OUTPUT_CRED}"
echo "    ${OUTPUT_CONF}"
echo ""
echo "  Profile name: ${PROFILE}"
echo ""
echo "  To use on the HOST:"
echo "    export AWS_PROFILE=${PROFILE}"
echo "    aws ec2 describe-instances"
echo ""
echo "  Or merge into your own ~/.aws files:"
echo "    cat ${OUTPUT_DIR}/credentials >> ~/.aws/credentials"
echo "    cat ${OUTPUT_DIR}/config      >> ~/.aws/config"
echo "═══════════════════════════════════════════════════════════"
