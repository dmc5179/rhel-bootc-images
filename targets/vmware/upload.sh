#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Script: targets/vmware/upload.sh
# Purpose: Import output/vmware/vmdk/disk.vmdk (from `build-image.sh --target vmware`) into
#          vSphere with govc and create a VM from it, optionally passing cloud-init
#          user-data via guestinfo (VMware datasource).
# Config:  targets/vmware/upload.env (gitignored; copy upload.env.example). The vCenter password
#          is prompted for if GOVC_PASSWORD is unset, and never written to disk.
# Status:  Rough draft, not yet run against a real vCenter.
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/upload.env"

# shellcheck source=/dev/null
[[ -f "${ENV_FILE}" ]] && set -a && . "${ENV_FILE}" && set +a

IMAGE="${IMAGE:-${REPO_DIR}/output/vmware/vmdk/disk.vmdk}"
VM_NAME="${VM_NAME:-rhel10-bootc-$(date +%Y%m%d-%H%M%S)}"
DATASTORE_DIR="${DATASTORE_DIR:-${VM_NAME}}"
VM_CPUS="${VM_CPUS:-2}"
VM_MEMORY_MB="${VM_MEMORY_MB:-4096}"
# Use rhel10_64Guest if your vSphere version lists it (govc vm.create -g fails on unknown IDs)
VM_GUEST_ID="${VM_GUEST_ID:-rhel9_64Guest}"
VM_FIRMWARE="${VM_FIRMWARE:-efi}"
VM_DISK_CONTROLLER="${VM_DISK_CONTROLLER:-pvscsi}"
POWER_ON="${POWER_ON:-false}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help]

Settings (env vars or ${ENV_FILE}):
  GOVC_URL            vCenter URL, e.g. https://vcenter.example.com (required)
  GOVC_USERNAME       vCenter user (required)
  GOVC_PASSWORD       Prompted for if unset (recommended: leave unset)
  GOVC_INSECURE       1 to skip TLS verification (self-signed vCenter certs)
  GOVC_DATACENTER, GOVC_DATASTORE, GOVC_NETWORK, GOVC_RESOURCE_POOL, GOVC_FOLDER
                      Standard govc placement settings
  VM_NAME             Default: rhel10-bootc-<timestamp>
  DATASTORE_DIR       Datastore folder for the imported disk (default: VM_NAME)
  VM_CPUS / VM_MEMORY_MB   Default: 2 / 4096
  VM_GUEST_ID         Default: rhel9_64Guest
  VM_FIRMWARE         efi (default) or bios; bootc-image-builder disks support both
  VM_DISK_CONTROLLER  pvscsi (default), lsilogic, or ide
  USERDATA_FILE       Optional cloud-init user-data (e.g. users + ssh_authorized_keys)
  POWER_ON            true to power on after creation (default: false)
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) echo "[ERROR] Unknown argument: $1"; usage; exit 1 ;;
esac

# 1. Checks
command -v govc >/dev/null 2>&1 || { echo "[ERROR] govc is required. Download it from https://github.com/vmware/govmomi/releases"; exit 1; }
[[ -n "${GOVC_URL:-}" ]] || { echo "[ERROR] GOVC_URL is not set (see ${ENV_FILE})."; exit 1; }
[[ -n "${GOVC_USERNAME:-}" ]] || { echo "[ERROR] GOVC_USERNAME is not set (see ${ENV_FILE})."; exit 1; }
[[ -f "${IMAGE}" ]] || { echo "[ERROR] ${IMAGE} not found. Run: ./build-image.sh --target vmware"; exit 1; }
if [[ -n "${USERDATA_FILE:-}" ]]; then
    [[ -f "${USERDATA_FILE}" ]] || { echo "[ERROR] USERDATA_FILE not found: ${USERDATA_FILE}"; exit 1; }
fi
if [[ -z "${GOVC_PASSWORD:-}" ]]; then
    read -rsp "vCenter password for ${GOVC_USERNAME}: " GOVC_PASSWORD
    echo
fi
export GOVC_URL GOVC_USERNAME GOVC_PASSWORD

echo "[1/4] Checking vCenter login..."
govc about | sed -n '1,2p'

# 2. Import the disk (govc converts the stream-optimized VMDK to a datastore disk)
echo "[2/4] Importing ${IMAGE} to [${GOVC_DATASTORE:-default datastore}] ${DATASTORE_DIR}/..."
govc import.vmdk "${IMAGE}" "${DATASTORE_DIR}"

# 3. Create the VM around the imported disk, powered off
echo "[3/4] Creating VM ${VM_NAME}..."
govc vm.create \
    -net.adapter=vmxnet3 \
    -c="${VM_CPUS}" -m="${VM_MEMORY_MB}" \
    -g="${VM_GUEST_ID}" \
    -firmware="${VM_FIRMWARE}" \
    -disk.controller="${VM_DISK_CONTROLLER}" \
    -disk="${DATASTORE_DIR}/$(basename "${IMAGE}")" \
    -on=false \
    "${VM_NAME}"

# 4. Optional cloud-init data via guestinfo (VMware datasource)
if [[ -n "${USERDATA_FILE:-}" ]]; then
    echo "[4/4] Attaching cloud-init user-data from ${USERDATA_FILE}..."
    METADATA=$(printf 'instance-id: %s\nlocal-hostname: %s\n' "${VM_NAME}" "${VM_NAME}" | gzip -c9 | base64 -w0)
    USERDATA=$(gzip -c9 <"${USERDATA_FILE}" | base64 -w0)
    govc vm.change -vm "${VM_NAME}" \
        -e guestinfo.metadata="${METADATA}" \
        -e guestinfo.metadata.encoding="gzip+base64" \
        -e guestinfo.userdata="${USERDATA}" \
        -e guestinfo.userdata.encoding="gzip+base64"
else
    echo "[4/4] No USERDATA_FILE; skipping cloud-init guestinfo (no login user will be configured)."
fi

if [[ "${POWER_ON}" == "true" ]]; then
    govc vm.power -on "${VM_NAME}"
fi

echo "=========================================================="
echo "VM created: ${VM_NAME}$( [[ "${POWER_ON}" == "true" ]] && echo " (powered on)" )"
echo "=========================================================="
