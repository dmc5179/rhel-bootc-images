#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Script: targets/aws/upload.sh
# Purpose: Turn output/<target>/image/disk.raw (from `build-image.sh --target <target>`) into a
#          registered EC2 AMI: S3 upload -> import-snapshot -> register-image.
#          Shared by AWS targets: targets/<target>/upload.sh symlinks here, and <target> is
#          taken from the directory it's invoked from.
# Config:  targets/aws/upload.env (gitignored; copy upload.env.example). AWS credentials come
#          from the normal AWS CLI chain (AWS_PROFILE, ~/.aws, env vars) and are never stored here.
# Status:  Rough draft, not yet run against a real account.
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET="$(basename "${SCRIPT_DIR}")"
ENV_FILE="${SCRIPT_DIR}/upload.env"

# shellcheck source=/dev/null
[[ -f "${ENV_FILE}" ]] && set -a && . "${ENV_FILE}" && set +a
[[ -n "${AWS_PROFILE:-}" ]] || unset AWS_PROFILE

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
IMAGE="${IMAGE:-${REPO_DIR}/output/${TARGET}/image/disk.raw}"
AMI_NAME="${AMI_NAME:-rhel10-bootc-${TARGET}-$(date +%Y%m%d-%H%M%S)}"
S3_KEY="${S3_KEY:-bootc-imports/${AMI_NAME}.raw}"
ARCH="${ARCH:-x86_64}"
KEEP_S3_OBJECT="${KEEP_S3_OBJECT:-false}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help]

Settings (env vars or ${ENV_FILE}):
  AWS_REGION       Target region (required; falls back to AWS_DEFAULT_REGION)
  AWS_S3_BUCKET    Existing S3 bucket for the intermediate upload (required)
  AWS_PROFILE      AWS CLI profile (optional; otherwise the default credential chain)
  AMI_NAME         Default: rhel10-bootc-${TARGET}-<timestamp>
  IMAGE            Default: output/${TARGET}/image/disk.raw
  ARCH             x86_64 (default) or arm64
  KEEP_S3_OBJECT   true to keep the raw image in S3 after import (default: false)

Prerequisite: the account needs the 'vmimport' service role that VM Import/Export uses
to read from S3. See the AWS "VM Import/Export required service role" docs.
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) echo "[ERROR] Unknown argument: $1"; usage; exit 1 ;;
esac

# 1. Checks
command -v aws >/dev/null 2>&1 || { echo "[ERROR] aws CLI is required. Run: sudo dnf install -y awscli2"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq is required. Run: sudo dnf install -y jq"; exit 1; }
[[ -n "${AWS_REGION:-}" ]] || { echo "[ERROR] AWS_REGION is not set (see ${ENV_FILE})."; exit 1; }
[[ -n "${AWS_S3_BUCKET:-}" ]] || { echo "[ERROR] AWS_S3_BUCKET is not set (see ${ENV_FILE})."; exit 1; }
[[ -f "${IMAGE}" ]] || { echo "[ERROR] ${IMAGE} not found. Run: ./build-image.sh --target ${TARGET}"; exit 1; }
export AWS_REGION

echo "[1/5] Checking AWS credentials..."
aws sts get-caller-identity --query 'Arn' --output text
aws iam get-role --role-name vmimport >/dev/null 2>&1 \
    || echo "[WARNING] IAM role 'vmimport' not found (or not visible to you); import-snapshot will fail without it."

# 2. Upload
echo "[2/5] Uploading ${IMAGE} to s3://${AWS_S3_BUCKET}/${S3_KEY}..."
aws s3 cp "${IMAGE}" "s3://${AWS_S3_BUCKET}/${S3_KEY}"

# 3. Import as an EBS snapshot
echo "[3/5] Importing snapshot..."
TASK_ID=$(aws ec2 import-snapshot \
    --description "${AMI_NAME}" \
    --disk-container "Format=raw,UserBucket={S3Bucket=${AWS_S3_BUCKET},S3Key=${S3_KEY}}" \
    --query 'ImportTaskId' --output text)
echo "  - Task: ${TASK_ID}"

while true; do
    DETAIL=$(aws ec2 describe-import-snapshot-tasks --import-task-ids "${TASK_ID}" \
        --query 'ImportSnapshotTasks[0].SnapshotTaskDetail' --output json)
    STATUS=$(jq -r '.Status' <<<"${DETAIL}")
    case "${STATUS}" in
        completed) SNAPSHOT_ID=$(jq -r '.SnapshotId' <<<"${DETAIL}"); break ;;
        deleted|deleting) echo "[ERROR] Import failed: $(jq -r '.StatusMessage // "unknown"' <<<"${DETAIL}")"; exit 1 ;;
        *) echo "  - ${STATUS} $(jq -r '.Progress // ""' <<<"${DETAIL}")% $(jq -r '.StatusMessage // ""' <<<"${DETAIL}")"; sleep 30 ;;
    esac
done
echo "  - Snapshot: ${SNAPSHOT_ID}"

# 4. Register the AMI. bootc-image-builder disks boot with BIOS or UEFI, so prefer UEFI.
echo "[4/5] Registering AMI ${AMI_NAME}..."
AMI_ID=$(aws ec2 register-image \
    --name "${AMI_NAME}" \
    --architecture "${ARCH}" \
    --virtualization-type hvm \
    --ena-support \
    --boot-mode uefi-preferred \
    --imds-support v2.0 \
    --root-device-name /dev/xvda \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=${SNAPSHOT_ID},DeleteOnTermination=true,VolumeType=gp3}" \
    --query 'ImageId' --output text)

# 5. Clean up the intermediate object
if [[ "${KEEP_S3_OBJECT}" != "true" ]]; then
    echo "[5/5] Removing s3://${AWS_S3_BUCKET}/${S3_KEY}..."
    aws s3 rm "s3://${AWS_S3_BUCKET}/${S3_KEY}"
fi

echo "=========================================================="
echo "AMI registered: ${AMI_ID} (${AMI_NAME}) in ${AWS_REGION}"
echo "Launch with your EC2 key pair; cloud-init creates the default user 'cloud-user'."
echo "=========================================================="
