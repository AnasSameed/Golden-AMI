#!/usr/bin/env bash
# launch-from-ami.sh - launch test instance(s) from your golden AMI and check they serve the page.
#   bash scripts/launch-from-ami.sh [ami-id]        (defaults to the AMI built last)
#   COUNT=2 bash scripts/launch-from-ami.sh         (launch two to compare them)
source "$(dirname "$0")/common.sh"

AMI_ID="${1:-$(cat .last-ami-id 2>/dev/null || true)}"
[ -n "$AMI_ID" ] || { echo "No AMI id. Run build-ami.sh first or pass an id." >&2; exit 1; }
COUNT="${COUNT:-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"

log "Finding or creating the web security group (HTTP 80 from anywhere, demo only)"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
[ "$VPC_ID" != "None" ] || { echo "No default VPC in $REGION." >&2; exit 1; }
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_ID" = "None" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" \
    --description "HTTP for the golden AMI demo" --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=${PROJECT_TAG}}]" \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
fi
echo "Security group: $SG_ID"

log "Launching $COUNT instance(s) from $AMI_ID (no user data: everything is already baked in)"
IDS=$(aws ec2 run-instances \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --count "$COUNT" \
  --security-group-ids "$SG_ID" \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=golden-web-test},{Key=Project,Value=${PROJECT_TAG}}]" \
  --query 'Instances[].InstanceId' --output text)
echo "Instances: $IDS"
# shellcheck disable=SC2086
aws ec2 wait instance-running --instance-ids $IDS
# shellcheck disable=SC2086
IPS=$(aws ec2 describe-instances --instance-ids $IDS \
  --query 'Reservations[].Instances[].PublicIpAddress' --output text)

log "Checking the health page on each instance"
for IP in $IPS; do
  OK=0
  for _ in $(seq 1 30); do
    if curl -fs --max-time 3 "http://$IP/health.html" | grep -q OK; then OK=1; break; fi
    sleep 5
  done
  if [ "$OK" = 1 ]; then echo "UP    http://$IP"; else echo "DOWN  http://$IP  (see README troubleshooting)"; fi
done
echo
echo "Open the URLs above in your browser (http, not https)."
echo "When finished:  bash scripts/cleanup.sh"
