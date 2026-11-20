#!/bin/bash
# Your group's deploy script. Put every command you run here, in order,
# so any member can rebuild your infra from zero on their machine.
set -e
cd "$(dirname "$0")/.." && . ./env.sh
: "${GROUP:?export GROUP=gXX first}"

# ---------- M0, setup + IAM ----------

# One IAM user per member (replace member2/member3 with your teammates' names)
MEMBERS="thomas member2 member3"
for u in $MEMBERS; do
  aws iam create-user --user-name $GROUP-$u >/dev/null
done

# A group that holds the admin rights, so rights are managed once, not per person
aws iam create-group --group-name $GROUP-admins >/dev/null
aws iam attach-group-policy \
  --group-name $GROUP-admins \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
for u in $MEMBERS; do
  aws iam add-user-to-group --group-name $GROUP-admins --user-name $GROUP-$u
done

# Read-only auditor: read S3 and EC2, nothing else (no Allow means denied)
aws iam create-user --user-name $GROUP-auditor >/dev/null
aws iam put-user-policy \
  --user-name $GROUP-auditor \
  --policy-name read-only \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["s3:List*", "s3:Get*", "ec2:Describe*"],
      "Resource": "*"
    }]
  }'

# The group bucket (status page from M1)
aws s3api create-bucket --bucket $GROUP-site >/dev/null

# The auditor's AccessDenied proof is run by hand once, see NOTES.md (M0)
