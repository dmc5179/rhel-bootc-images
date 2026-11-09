#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Script: update-image.sh
# Purpose: Update an existing bootc image in place (dnf upgrade, optionally install packages)
#          and flatten the result with bootc-base-imagectl rechunk, so superseded RPM versions
#          from the original layers don't remain in the shipped image.
#          Produces a new localhost/rhel10-<target>:latest; optionally builds disk images from it.
# Status:  Draft. The image-mode-native alternative is a full rebuild
#          (./build-image.sh --target <target>), which picks up a newer base image as well.
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGETS_DIR="${SCRIPT_DIR}/targets"
RHSM_HELPER="${SCRIPT_DIR}/rhsm-credentials.sh"
RHSM_SECRETS_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/rhsm-build"
PULL_SECRET="${PULL_SECRET:-${HOME}/Downloads/pull-secret}"
TARGET=""
FROM_IMAGE=""
PACKAGES=()
RECHUNK="true"
MAX_LAYERS=""
MAKE_DISK="false"
BUILD_NET_ARGS=()
STAMP="$(date +%Y%m%d-%H%M%S)"

usage() {
    cat <<EOF
Usage: $(basename "$0") --target NAME [--from IMAGE] [--install PKG]... [--disk]
                        [--no-rechunk] [--max-layers N] [--host-network] [--pull-secret PATH]

Updates an existing image and writes the result to localhost/rhel10-NAME:latest.

Options:
  --target NAME    Target whose image to update (localhost/rhel10-NAME:latest).
  --from IMAGE     Image to update instead, e.g. a registry reference or an older local tag.
                   Default: localhost/rhel10-NAME:latest.
  --install PKG    Also install PKG (repeatable), in the same registration as the upgrade.
  --disk           Then build disk images from the result (./build-image.sh --skip-build).
  --no-rechunk     Don't flatten the updated image (not recommended; see build-image.sh -h).
  --max-layers N   Number of layers rechunk produces.
  --host-network   Run the update build in the host's network namespace (sshuttle/VPN DNS).
  --pull-secret PATH
                   Pull secret for registry.redhat.io. Default: \$PULL_SECRET or
                   ${HOME}/Downloads/pull-secret.
  -h, --help       Show this help.

The previous localhost/rhel10-NAME:latest is kept as :pre-update-<timestamp>, the result is
also tagged :<timestamp>, and an RPM change report goes to output/NAME/update-<timestamp>.txt.
Running hosts pick the update up after you push it to their registry (bootc upgrade).
EOF
}

# 0. Argument parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) [[ $# -gt 1 ]] || { echo "[ERROR] --target requires a name"; exit 1; }; TARGET="$2"; shift ;;
        --target=*) TARGET="${1#--target=}" ;;
        --from) [[ $# -gt 1 ]] || { echo "[ERROR] --from requires an image"; exit 1; }; FROM_IMAGE="$2"; shift ;;
        --from=*) FROM_IMAGE="${1#--from=}" ;;
        --install) [[ $# -gt 1 ]] || { echo "[ERROR] --install requires a package"; exit 1; }; PACKAGES+=("$2"); shift ;;
        --install=*) PACKAGES+=("${1#--install=}") ;;
        --disk) MAKE_DISK="true" ;;
        --no-rechunk) RECHUNK="false" ;;
        --max-layers)
            [[ $# -gt 1 && "$2" =~ ^[0-9]+$ ]] || { echo "[ERROR] --max-layers requires a number"; exit 1; }
            MAX_LAYERS="$2"; shift ;;
        --host-network) BUILD_NET_ARGS=(--network host) ;;
        --pull-secret) [[ $# -gt 1 ]] || { echo "[ERROR] --pull-secret requires a path"; exit 1; }; PULL_SECRET="$2"; shift ;;
        --pull-secret=*) PULL_SECRET="${1#--pull-secret=}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[ERROR] Unknown argument: $1"; usage; exit 1 ;;
    esac
    shift
done

[[ -n "${TARGET}" ]] || { echo "[ERROR] --target is required."; usage; exit 1; }
[[ -f "${TARGETS_DIR}/${TARGET}/Containerfile" ]] || { echo "[ERROR] Unknown target '${TARGET}'."; exit 1; }
LOCAL_IMAGE="localhost/rhel10-${TARGET}:latest"
FROM_IMAGE="${FROM_IMAGE:-${LOCAL_IMAGE}}"
OUTPUT_DIR="${SCRIPT_DIR}/output/${TARGET}"

# 1. Dependency checks
command -v podman >/dev/null 2>&1 || { echo "[ERROR] podman is required. Run: sudo dnf install -y podman"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq is required. Run: sudo dnf install -y jq"; exit 1; }

echo "Target: ${TARGET}    From: ${FROM_IMAGE}    To: ${LOCAL_IMAGE}"

# 2. Credentials: RHSM (RPM content, build secrets) on non-RHEL hosts; pull secret for registry.redhat.io
HOST_ID=$(. /etc/os-release && echo "${ID}")
if [[ "${HOST_ID}" != "rhel" ]] \
   && [[ ! -s "${RHSM_SECRETS_DIR}/rhsm_user" || ! -s "${RHSM_SECRETS_DIR}/rhsm_pass" ]]; then
    echo "[0/5] Non-RHEL host (${HOST_ID}): Red Hat credentials are needed to download RHEL updates."
    "${RHSM_HELPER}"
fi
AUTH_ARGS=()
if [[ -f "${PULL_SECRET}" ]]; then
    PULL_SECRET="$(realpath "${PULL_SECRET}")"
    AUTH_ARGS=(--authfile "${PULL_SECRET}")
fi
SECRET_ARGS=()
for secret in rhsm_user rhsm_pass rhsm_org; do
    [[ -s "${RHSM_SECRETS_DIR}/${secret}" ]] && SECRET_ARGS+=(--secret "id=${secret},src=${RHSM_SECRETS_DIR}/${secret}")
done

# shellcheck source=lib/rechunk.sh
. "${SCRIPT_DIR}/lib/rechunk.sh"

# 3. Make sure the source image is in root's storage, and record its packages
echo "[1/5] Preparing source image ${FROM_IMAGE}..."
if ! sudo podman image exists "${FROM_IMAGE}"; then
    [[ "${FROM_IMAGE}" != localhost/* ]] || { echo "[ERROR] ${FROM_IMAGE} not found. Build it first: ./build-image.sh --target ${TARGET}"; exit 1; }
    sudo podman pull "${AUTH_ARGS[@]}" "${FROM_IMAGE}"
fi
FROM_ID=$(sudo podman image inspect --format '{{.Id}}' "${FROM_IMAGE}")
echo "  - ${FROM_IMAGE}: $(image_summary "${FROM_ID}")"
mkdir -p "${OUTPUT_DIR}"
RPMS_BEFORE=$(mktemp)
RPMS_AFTER=$(mktemp)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${RPMS_BEFORE}" "${RPMS_AFTER}" "${WORK_DIR}"' EXIT
sudo podman run --rm "${FROM_ID}" rpm -qa --qf '%{NAME}.%{ARCH} %{EVR}\n' | LC_ALL=C sort > "${RPMS_BEFORE}"

# 4. Apply updates as a new layer (no cache, so dnf always checks for current updates)
echo "[2/5] Applying updates${PACKAGES[*]:+ and installing: ${PACKAGES[*]}}..."
cat > "${WORK_DIR}/Containerfile" <<EOF
FROM ${FROM_ID}
RUN --mount=type=bind,source=lib/rhsm-dnf-install.sh,target=/tmp/rhsm-dnf-install.sh,z \\
    --mount=type=secret,id=rhsm_user --mount=type=secret,id=rhsm_pass --mount=type=secret,id=rhsm_org \\
    sh /tmp/rhsm-dnf-install.sh --upgrade ${PACKAGES[*]}
RUN bootc container lint
EOF
UPDATED="localhost/rhel10-${TARGET}:unchunked"
sudo podman build --no-cache --pull=never "${BUILD_NET_ARGS[@]}" "${SECRET_ARGS[@]}" \
    -t "${UPDATED}" -f "${WORK_DIR}/Containerfile" "${SCRIPT_DIR}"

# 5. Keep the current :latest for rollback, then flatten into :latest
if sudo podman image exists "${LOCAL_IMAGE}"; then
    sudo podman tag "${LOCAL_IMAGE}" "localhost/rhel10-${TARGET}:pre-update-${STAMP}"
    echo "  - Previous ${LOCAL_IMAGE} kept as :pre-update-${STAMP}"
fi
if [[ "${RECHUNK}" == "true" ]]; then
    echo "[3/5] Flattening ${UPDATED} ($(image_summary "${UPDATED}")) with bootc-base-imagectl rechunk..."
    rechunk_image "${UPDATED}" "${LOCAL_IMAGE}" "${MAX_LAYERS}"
else
    echo "[3/5] Skipping flattening (--no-rechunk)"
    sudo podman tag "${UPDATED}" "${LOCAL_IMAGE}"
fi
sudo podman tag "${LOCAL_IMAGE}" "localhost/rhel10-${TARGET}:${STAMP}"
echo "  - ${LOCAL_IMAGE} (also :${STAMP}): $(image_summary "${LOCAL_IMAGE}")"

# 6. Report what changed
echo "[4/5] Writing RPM change report..."
sudo podman run --rm "${LOCAL_IMAGE}" rpm -qa --qf '%{NAME}.%{ARCH} %{EVR}\n' | LC_ALL=C sort > "${RPMS_AFTER}"
REPORT="${OUTPUT_DIR}/update-${STAMP}.txt"
{
    echo "# ${TARGET} update ${STAMP}: ${FROM_IMAGE} -> ${LOCAL_IMAGE}"
    echo "# name.arch old-version -> new-version ('-' = not installed)"
    LC_ALL=C join -a1 -a2 -e '-' -o '0,1.2,2.2' "${RPMS_BEFORE}" "${RPMS_AFTER}" \
        | awk '$2 != $3 && $1 !~ /^gpg-pubkey/ {print $1, $2, "->", $3}'
} > "${REPORT}"
CHANGES=$(grep -vc '^#' "${REPORT}" || true)
echo "  - ${CHANGES} package change(s): ${REPORT#"${SCRIPT_DIR}/"}"
grep -v '^#' "${REPORT}" | head -20 | sed 's/^/      /'
(( CHANGES > 20 )) && echo "      ... (see report)"

# 7. Optional disk images
if [[ "${MAKE_DISK}" == "true" ]]; then
    echo "[5/5] Building disk images from ${LOCAL_IMAGE}..."
    exec "${SCRIPT_DIR}/build-image.sh" --target "${TARGET}" --skip-build --pull-secret "${PULL_SECRET}"
fi

echo "=========================================================="
echo "Update complete! ${LOCAL_IMAGE} (:${STAMP}), ${CHANGES} package change(s)"
echo "Disk images:   ./build-image.sh --target ${TARGET} --skip-build"
echo "Running hosts: push ${LOCAL_IMAGE} to their registry, then 'bootc upgrade' on each host"
echo "Rollback:      sudo podman tag localhost/rhel10-${TARGET}:pre-update-${STAMP} ${LOCAL_IMAGE}"
echo "=========================================================="
