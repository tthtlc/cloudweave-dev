###  1. Write the policy document

cat > /tmp/libcloud-aws2.json <<'JSON'
{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "EC2Write",
        "Effect": "Allow",
        "Action": [
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:RebootInstances",
          "ec2:ModifyInstanceAttribute",
          "ec2:CreateTags",
          "ec2:DeleteTags"
        ],
        "Resource": "*"
      },
      {
        "Sid": "S3Read",
        "Effect": "Allow",
        "Action": [
          "s3:ListAllMyBuckets",
          "s3:GetBucketLocation"
        ],
        "Resource": "*"
      }
    ]
}
JSON

  ###2. Attach it as an inline policy

  aws iam put-user-policy \
    --user-name aws2 \
    --policy-name LibcloudTenantAccess \
    --policy-document file:///tmp/libcloud-aws2.json

  ###3. Verify

  aws iam list-user-policies --user-name aws2
  aws iam get-user-policy --user-name aws2 --policy-name LibcloudTenantAccess

  ###Optional: decode the exact denial you already saw
  #
  #

  ###AWS returned an Encoded authorization failure message — this decodes it to the
  ###precise missing action(s):

#  aws sts decode-authorization-message \
#    --encoded-message "VM0b1MBsznho8ZBbut1WYJd7oWLjAU5DlLoGbwP3F7hUBihCtA_ha_iZZhV_7lhWBC"
