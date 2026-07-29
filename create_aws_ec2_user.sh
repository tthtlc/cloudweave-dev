#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# create_aws_ec2_user.sh
#
# Creates an AWS IAM user with full EC2 provisioning/deprovisioning privileges,
# generates an access key, and logs in as that user via aws configure.
#
# Usage:
#   ./create_aws_ec2_user.sh <username> [profile_name]
#
#   username     – The IAM user name to create (required)
#   profile_name – AWS CLI --profile name to store the credentials under
#                  (defaults to the same value as <username>)
#
# Prerequisites: aws CLI installed and an admin session active.
# ---------------------------------------------------------------------------
set -euo pipefail

# ---- helpers ---------------------------------------------------------------
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[INFO]  $*"; }
ok()   { echo "[OK]    $*"; }

# ---- arguments -------------------------------------------------------------
USERNAME="${1:?Usage: $0 <username> [profile_name]}"
PROFILE="${2:-$USERNAME}"

# ---- policy name -----------------------------------------------------------
POLICY_NAME="EC2FullProvisionDeprovision-${USERNAME}"

# ---- 1. Create the IAM user ------------------------------------------------
info "Creating IAM user: ${USERNAME}"
if aws iam get-user --user-name "${USERNAME}" &>/dev/null; then
    info "User ${USERNAME} already exists — skipping creation."
else
    aws iam create-user --user-name "${USERNAME}"
    ok "User ${USERNAME} created."
fi

# ---- 2. Attach the EC2 full-access policy ----------------------------------
# The AWS-managed policy AmazonEC2FullAccess covers ec2:* on all resources,
# which includes provisioning (RunInstances, etc.) and deprovisioning
# (TerminateInstances, etc.).
info "Attaching AmazonEC2FullAccess to ${USERNAME}"
aws iam attach-user-policy \
    --user-name "${USERNAME}" \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
ok "AmazonEC2FullAccess attached."

# ---- 3. Also attach IAM PassRole (needed to pass instance profiles to EC2) -
info "Creating & attaching inline policy '${POLICY_NAME}' (PassRole + Describe*)"

TRUST_POLICY=$(cat <<'EOF'
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

# Delete the old version of the inline policy if it already exists
if aws iam get-user-policy --user-name "${USERNAME}" --policy-name "${POLICY_NAME}" &>/dev/null; then
    info "Inline policy '${POLICY_NAME}' already exists — replacing."
    aws iam delete-user-policy --user-name "${USERNAME}" --policy-name "${POLICY_NAME}"
fi

aws iam put-user-policy \
    --user-name "${USERNAME}" \
    --policy-name "${POLICY_NAME}" \
    --policy-document "${TRUST_POLICY}"
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

# ---- 5. Store credentials as an AWS CLI profile ----------------------------
info "Configuring AWS CLI profile '${PROFILE}'"
aws configure set aws_access_key_id "${ACCESS_KEY_ID}"     --profile "${PROFILE}"
aws configure set aws_secret_access_key "${SECRET_ACCESS_KEY}" --profile "${PROFILE}"

# Determine the default region from the current session, fall back to us-east-1
REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
aws configure set region "${REGION}" --profile "${PROFILE}"
aws configure set output json        --profile "${PROFILE}"
ok "Profile '${PROFILE}' saved in ~/.aws/credentials  &  ~/.aws/config"

# ---- 6. Verify the new user can make an EC2 call ---------------------------
info "Verifying the new credentials with a dry-run ec2:DescribeRegions call..."
if aws ec2 describe-regions \
        --region "${REGION}" \
        --profile "${PROFILE}" \
        --no-cli-pager \
        --max-items 1 &>/dev/null; then
    ok "Credentials verified — user '${USERNAME}' can call EC2 APIs."
else
    die "Credential verification failed — check the IAM policies."
fi

# ---- 7. How to use ---------------------------------------------------------
echo ""
echo "Done.  To use the new user:"
echo "  export AWS_PROFILE=${PROFILE}"
echo "  aws ec2 describe-instances"
echo ""
echo "Or pass --profile to every command:"
echo "  aws ec2 run-instances --profile ${PROFILE} ..."
echo ""
echo "Full EC2 provisioning + deprovisioning is now available."
