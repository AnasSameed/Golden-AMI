#!/usr/bin/env bash
# cleanup.sh - remove everything this project created (tagged Project=golden-ami) in the current Region.
#   bash scripts/cleanup.sh
source "$(dirname "$0")/common.sh"

echo "This will DELETE every instance, AMI, snapshot and the security group tagged"
echo "Project=$PROJECT_TAG in $REGION."
read -r -p "Type yes to continue: " ANSWER
[ "$ANSWER" = "yes" ] || { echo "Cancelled."; exit 1; }

log "Terminating instances"
IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$IDS" ]; then
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --instance-ids $IDS >/dev/null
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --instance-ids $IDS
  echo "Terminated: $IDS"
else
  echo "No instances found."
fi

log "Deregistering AMIs and deleting their snapshots"
for AMI in $(aws ec2 describe-images --owners self \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" --query 'Images[].ImageId' --output text); do
  SNAPS=$(aws ec2 describe-images --image-ids "$AMI" \
    --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text)
  aws ec2 deregister-image --image-id "$AMI"
  for SNAP in $SNAPS; do
    [ "$SNAP" = "None" ] || aws ec2 delete-snapshot --snapshot-id "$SNAP"
  done
  echo "Removed AMI $AMI and snapshots: $SNAPS"
done

log "Deleting the security group"
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_ID" != "None" ]; then
  aws ec2 delete-security-group --group-id "$SG_ID" \
    || echo "Could not delete $SG_ID yet. Wait a minute and run cleanup again."
fi
rm -f .last-ami-id
log "Cleanup finished."
