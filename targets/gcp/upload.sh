#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Script: targets/gcp/upload.sh
# Purpose: Turn output/<target>/gce/image.tar.gz (from `build-image.sh --target <target>`) into a
#          Compute Engine custom image: GCS upload -> gcloud compute images create.
#          Shared by GCP targets: targets/<target>/upload.sh symlinks here, and <target> is
#          taken from the directory it's invoked from.
# Config:  targets/<target>/upload.env (gitignored; copy upload.env.example). Credentials come from
#          your gcloud login, or a service account key file via GCP_CREDENTIALS_FILE; never stored here.
# Status:  Rough draft, not yet run against a real project.
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET="$(basename "${SCRIPT_DIR}")"
ENV_FILE="${SCRIPT_DIR}/upload.env"

# shellcheck source=/dev/null
[[ -f "${ENV_FILE}" ]] && set -a && . "${ENV_FILE}" && set +a

IMAGE="${IMAGE:-${REPO_DIR}/output/${TARGET}/gce/image.tar.gz}"
IMAGE_NAME="${IMAGE_NAME:-rhel10-bootc-${TARGET}-$(date +%Y%m%d-%H%M%S)}"
GCS_KEY="${GCS_KEY:-bootc-imports/${IMAGE_NAME}.tar.gz}"
GUEST_OS_FEATURES="${GUEST_OS_FEATURES:-UEFI_COMPATIBLE,GVNIC,VIRTIO_SCSI_MULTIQUEUE}"
IMAGE_FAMILY="${IMAGE_FAMILY:-}"
STORAGE_LOCATION="${STORAGE_LOCATION:-}"
KEEP_GCS_OBJECT="${KEEP_GCS_OBJECT:-false}"
KMS_KEY="${KMS_KEY:-}"
LABELS="${LABELS:-}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help]

Settings (env vars or ${ENV_FILE}):
  GCP_PROJECT          Project ID (required; falls back to CLOUDSDK_CORE_PROJECT or gcloud config)
  GCS_BUCKET           Existing Cloud Storage bucket for the intermediate upload (required)
  GCP_CREDENTIALS_FILE Service account key JSON (optional; otherwise your gcloud login).
                       Keep it under secrets/ (gitignored).
  IMAGE_NAME           Default: rhel10-bootc-${TARGET}-<timestamp> (lowercase, digits, hyphens)
  IMAGE_FAMILY         Optional image family, e.g. rhel10-bootc-${TARGET}
  STORAGE_LOCATION     Optional image storage location, e.g. us-east1 or us
  GUEST_OS_FEATURES    Default: ${GUEST_OS_FEATURES}
  IMAGE                Default: output/${TARGET}/gce/image.tar.gz
  KEEP_GCS_OBJECT      true to keep the tarball in GCS after import (default: false)
  KMS_KEY              Optional CMEK key for the image, e.g.
                       projects/<p>/locations/<loc>/keyRings/<ring>/cryptoKeys/<key>
  LABELS               Optional image labels, e.g. purpose=bootc-test,owner=me
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) echo "[ERROR] Unknown argument: $1"; usage; exit 1 ;;
esac

# 1. Checks
command -v gcloud >/dev/null 2>&1 || { echo "[ERROR] gcloud is required. See https://cloud.google.com/sdk/docs/install"; exit 1; }
[[ -f "${IMAGE}" ]] || { echo "[ERROR] ${IMAGE} not found. Run: ./build-image.sh --target ${TARGET}"; exit 1; }
if [[ -n "${GCP_CREDENTIALS_FILE:-}" ]]; then
    [[ "${GCP_CREDENTIALS_FILE}" == /* ]] || GCP_CREDENTIALS_FILE="${REPO_DIR}/${GCP_CREDENTIALS_FILE}"
    [[ -f "${GCP_CREDENTIALS_FILE}" ]] || { echo "[ERROR] GCP_CREDENTIALS_FILE not found: ${GCP_CREDENTIALS_FILE}"; exit 1; }
    # Use the key for this run only, without touching the user's gcloud configuration
    export CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="${GCP_CREDENTIALS_FILE}"
fi
GCP_PROJECT="${GCP_PROJECT:-${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}}"
[[ -n "${GCP_PROJECT}" ]] || { echo "[ERROR] GCP_PROJECT is not set (see ${ENV_FILE})."; exit 1; }
[[ -n "${GCS_BUCKET:-}" ]] || { echo "[ERROR] GCS_BUCKET is not set (see ${ENV_FILE})."; exit 1; }
[[ "${IMAGE_NAME}" =~ ^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$ ]] \
    || { echo "[ERROR] IMAGE_NAME '${IMAGE_NAME}' must be lowercase letters, digits and hyphens (max 63)."; exit 1; }

echo "[1/4] Checking Google Cloud credentials (project ${GCP_PROJECT})..."
gcloud auth print-access-token >/dev/null || { echo "[ERROR] Not authenticated. Run: gcloud auth login (or set GCP_CREDENTIALS_FILE)"; exit 1; }
gcloud projects describe "${GCP_PROJECT}" --format='value(projectId)'

# 2. Upload
echo "[2/4] Uploading ${IMAGE} to gs://${GCS_BUCKET}/${GCS_KEY}..."
gcloud storage cp "${IMAGE}" "gs://${GCS_BUCKET}/${GCS_KEY}" --project "${GCP_PROJECT}"

# 3. Create the image. bootc-image-builder disks boot with BIOS or UEFI; the kernel has gve (gVNIC).
echo "[3/4] Creating image ${IMAGE_NAME}..."
CREATE_ARGS=(--project "${GCP_PROJECT}" --source-uri "gs://${GCS_BUCKET}/${GCS_KEY}"
             --guest-os-features "${GUEST_OS_FEATURES}" --description "RHEL 10 bootc image (${TARGET})")
[[ -n "${IMAGE_FAMILY}" ]] && CREATE_ARGS+=(--family "${IMAGE_FAMILY}")
[[ -n "${STORAGE_LOCATION}" ]] && CREATE_ARGS+=(--storage-location "${STORAGE_LOCATION}")
[[ -n "${KMS_KEY}" ]] && CREATE_ARGS+=(--kms-key "${KMS_KEY}")
[[ -n "${LABELS}" ]] && CREATE_ARGS+=(--labels "${LABELS}")
gcloud compute images create "${IMAGE_NAME}" "${CREATE_ARGS[@]}"

# 4. Clean up the intermediate object
if [[ "${KEEP_GCS_OBJECT}" != "true" ]]; then
    echo "[4/4] Removing gs://${GCS_BUCKET}/${GCS_KEY}..."
    gcloud storage rm "gs://${GCS_BUCKET}/${GCS_KEY}" --project "${GCP_PROJECT}"
fi

echo "=========================================================="
echo "Image created: ${IMAGE_NAME} in project ${GCP_PROJECT}"
echo "Launch it with an SSH key for 'cloud-user' (cloud-init reads it once, at first boot):"
echo "  gcloud compute instances create <name> --project ${GCP_PROJECT} --zone <zone> \\"
echo "    --image ${IMAGE_NAME} --machine-type n2-standard-2 \\"
echo "    --metadata=ssh-keys=\"cloud-user:\$(cat ~/.ssh/id_ed25519.pub)\""
echo "  ssh cloud-user@<external-ip>"
echo "=========================================================="
