#!/usr/bin/env bash
# Run by onward-bootstrap/deploy.sh before the platform root stack is synced. The platform
# needs two things the artifacts stack only holds the place for:
#   1. Its nested templates in the template bucket, under the TemplatesVersion that
#      infra/platform/deployment.yaml names. Normally publish-templates.yml uploads them; on
#      a first build, or after a teardown, the bucket is new and empty, so upload them from
#      this repository (and commit the version if main does not name it yet).
#   2. An image in ECR, or the ECS service cannot start. If there is no "latest" image, push
#      a build-* tag to the app repository so its workflow builds one, and wait for it.
# Set APP_REPO if the app repository is not cloned next to this one.
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-onward-logistics} AWS_REGION=${AWS_REGION:-eu-west-1}
HERE=$(cd "$(dirname "$0")/../.." && pwd)
APP_REPO=${APP_REPO:-$HERE/../week5-aws-lab-delivery-photos-app}
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET=onward-dev-photos-templates-$ACCOUNT
REPO=onward-dev-photos
FILE=infra/platform/deployment.yaml

# 1. Nested templates, exactly as committed on main (what Git sync will deploy).
git -C "$HERE" pull -q --ff-only origin main
tree=$(git -C "$HERE" rev-parse HEAD:infra/platform/stacks)
version=$(sed -n 's/^  TemplatesVersion: *//p' "$HERE/$FILE")
if ! aws s3api head-object --bucket "$BUCKET" --key "$tree/service.yaml" >/dev/null 2>&1; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  git -C "$HERE" archive HEAD infra/platform/stacks | tar -x -C "$tmp"
  aws s3 cp "$tmp/infra/platform/stacks/" "s3://$BUCKET/$tree/" --recursive --quiet
  echo "  uploaded nested templates $tree to $BUCKET"
else
  echo "  nested templates $tree are in $BUCKET"
fi
if [ "$version" != "$tree" ]; then
  sed -i "s/^  TemplatesVersion: .*/  TemplatesVersion: $tree/" "$HERE/$FILE"
  git -C "$HERE" commit -q -m "chore: deploy nested templates ${tree::7}" "$FILE"
  git -C "$HERE" push -q origin HEAD:main
  echo "  committed TemplatesVersion $tree"
fi

# 2. A first image for the service.
has_image() { aws ecr describe-images --repository-name $REPO --image-ids imageTag=latest >/dev/null 2>&1; }
if has_image; then echo "  image $REPO:latest exists"; exit 0; fi
git -C "$APP_REPO" fetch -q origin main
tag="build-$(date -u +%Y%m%d%H%M%S)"
git -C "$APP_REPO" push -q origin "$(git -C "$APP_REPO" rev-parse FETCH_HEAD):refs/tags/$tag"
echo "  pushed tag $tag to the app repository; waiting for GitHub Actions to push the image"
for _ in $(seq 1 60); do
  if has_image; then echo "  image $REPO:latest pushed"; exit 0; fi
  sleep 10
done
echo "  no image after 10 minutes - check the app repository's Actions tab"; exit 1
