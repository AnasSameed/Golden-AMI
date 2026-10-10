#!/usr/bin/env bash
# Shared settings for the golden-ami scripts. Sourced, not run directly.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
if [ -z "$REGION" ]; then
  echo "No AWS Region set. Run:  export AWS_REGION=eu-north-1" >&2
  exit 1
fi
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

PROJECT_TAG="golden-ami"                 # every resource is tagged Project=golden-ami
SG_NAME="golden-ami-web-sg"

log() { printf '\n==> %s\n' "$*"; }
