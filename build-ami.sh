#!/usr/bin/env bash
# build-ami.sh - bake a golden AMI from user-data/bake.sh.
# Run it in AWS CloudShell (already signed in, so no access keys are needed):
#   bash scripts/build-ami.sh
source "$(dirname "$0")/common.sh"

NAME_PREFIX="${NAME_PREFIX:-golden-web}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"

log "Looking up the latest Amazon Linux 2023 AMI in $REGION"
BASE_AMI=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text)
echo "Base AMI: $BASE_AMI"

log "Launching the temporary builder ($INSTANCE_TYPE)"
BUILDER_ID=$(aws ec2 run-instances \
  --image-id "$BASE_AMI" \
  --instance-type "$INSTANCE_TYPE" \
  --user-data "file://user-data/bake.sh" \
  --instance-initiated-shutdown-behavior stop \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME_PREFIX}-builder},{Key=Project,Value=${PROJECT_TAG}}]" \
  --query 'Instances[0].InstanceId' --output text)
echo "Builder: $BUILDER_ID"

cleanup() {
  log "Terminating the builder $BUILDER_ID"
  aws ec2 terminate-instances --instance-ids "$BUILDER_ID" >/dev/null || true
}
trap cleanup EXIT          # the builder is always removed, even if something fails

log "Baking: the builder installs everything, then stops itself (about 3 to 5 minutes)"
aws ec2 wait instance-stopped --instance-ids "$BUILDER_ID"

log "Creating the AMI from the stopped builder"
AMI_NAME="${NAME_PREFIX}-$(date -u +%Y%m%d-%H%M%S)"
AMI_ID=$(aws ec2 create-image \
  --instance-id "$BUILDER_ID" \
  --name "$AMI_NAME" \
  --description "Golden web server: Apache, hardening, per-boot instance info page" \
  --tag-specifications \
    "ResourceType=image,Tags=[{Key=Name,Value=${AMI_NAME}},{Key=Project,Value=${PROJECT_TAG}}]" \
    "ResourceType=snapshot,Tags=[{Key=Project,Value=${PROJECT_TAG}}]" \
  --query 'ImageId' --output text)
echo "AMI: $AMI_ID  ($AMI_NAME)"
aws ec2 wait image-available --image-ids "$AMI_ID"

echo "$AMI_ID" > .last-ami-id
log "Done. $AMI_ID is available. Next:  bash scripts/launch-from-ami.sh"
