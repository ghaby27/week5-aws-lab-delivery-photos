#!/usr/bin/env bash
# Run by onward-bootstrap/teardown.sh so the lab's stacks can be deleted:
#   - empties the template bucket, the photos bucket and the replica bucket (every
#     version and delete marker: both photo buckets are versioned);
#   - turns off deletion protection on the database.
# ECR deletes its own images (EmptyOnDelete). This deletes every photo: lab use only.
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-onward-logistics} AWS_REGION=${AWS_REGION:-eu-west-1}
account=$(aws sts get-caller-identity --query Account --output text)

empty_bucket() { # bucket region
  local bucket=$1 region=$2 batch
  aws s3api head-bucket --bucket "$bucket" --region "$region" 2>/dev/null || return 0
  while :; do
    batch=$(aws s3api list-object-versions --bucket "$bucket" --region "$region" --max-items 500 --output json |
      jq -c '{Objects: [(.Versions // [])[], (.DeleteMarkers // [])[] | {Key, VersionId}], Quiet: true}')
    [ "$(jq '.Objects | length' <<<"$batch")" -gt 0 ] || break
    aws s3api delete-objects --bucket "$bucket" --region "$region" --delete "$batch" >/dev/null
  done
  echo "  emptied $bucket"
}

empty_bucket "onward-dev-photos-templates-$account" "$AWS_REGION"
empty_bucket "onward-dev-photos-$account" "$AWS_REGION"
empty_bucket "onward-dev-photos-replica-$account" eu-central-1

db=onward-dev-photos-db
if aws rds describe-db-instances --db-instance-identifier $db >/dev/null 2>&1; then
  aws rds modify-db-instance --db-instance-identifier $db --no-deletion-protection --apply-immediately >/dev/null
  echo "  turned off deletion protection on $db"
fi
