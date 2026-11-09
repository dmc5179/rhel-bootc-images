#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Script: build-image.sh
# Purpose: Build a RHEL bootc container image from targets/<name>/Containerfile and
#          turn it into disk image(s) with bootc-image-builder (vhd, qcow2, ami, raw, ...)
# Platform: Fedora or RHEL with Podman
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGETS_DIR="${SCRIPT_DIR}/targets"
BUILDER_IMAGE="registry.redhat.io/rhel10/bootc-image-builder:latest"
DEFAULT_CONFIG_TOML="${SCRIPT_DIR}/config.toml"
RHSM_HELPER="${SCRIPT_DIR}/rhsm-credentials.sh"
RHSM_SECRETS_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/rhsm-build"
PULL_SECRET="${PULL_SECRET:-${HOME}/Downloads/pull-secret}"
TARGET=""
TYPES=()
CONFIG_TOML=""
PACKAGE="true"
BUILD_NET_ARGS=()
RECHUNK="true"
MAX_LAYERS=""
SKIP_BUILD="false"

list_targets() {
    for dir in "${TARGETS_DIR}"/*/; do
        [[ -f "${dir}Containerfile" ]] || continue
        local name default=""
        name="$(basename "${dir}")"
        [[ -f "${dir}target.conf" ]] && default="$(. "${dir}target.conf" && echo "${DEFAULT_TYPES:-}")"
        printf '  %-18s default type: %s\n' "${name}" "${default:-qcow2}"
    done
}

usage() {
    cat <<EOF
Usage: $(basename "$0") --target NAME [--type TYPE]... [--pull-secret PATH] [--config [PATH]]
       $(basename "$0") --list-targets | -h | --help

Options:
  --target NAME    Build targets/NAME/Containerfile into localhost/rhel10-NAME:latest.
  --type TYPE      bootc-image-builder output type (repeatable), e.g. vhd, qcow2, ami,
                   raw, vmdk, gce, anaconda-iso. Default: DEFAULT_TYPES from
                   targets/NAME/target.conf, else qcow2.
  --pull-secret PATH
                   Pull secret (auth.json format) used for registry.redhat.io
                   image pulls. Default: \$PULL_SECRET or ${HOME}/Downloads/pull-secret.
                   If missing, falls back to root's existing podman login.
  --config [PATH]  Pass a bootc-image-builder config.toml (e.g. to bake in a
                   break-glass user). PATH defaults to ${DEFAULT_CONFIG_TOML}.
                   Without this flag no config is used.
  --no-package     Don't create the transfer archive for VHDs. By default each .vhd gets a
                   sparse-aware <name>.vhd.tar.zst plus .sha256: a fixed VHD is mostly
                   zeros, so the archive is about the size of the real data.
  --host-network   Run the image build (podman build) in the host's network namespace. Use it
                   when root containers can't resolve names but the host can, e.g. while
                   sshuttle --dns or a VPN intercepts DNS.
  --no-rechunk     Don't flatten the final image. By default it's rechunked with
                   bootc-base-imagectl rechunk: layers are regenerated from the final
                   filesystem, so files removed or replaced by later build steps (old RPM
                   versions) aren't left in lower layers for scanners to flag.
  --max-layers N   Number of layers rechunk produces (default: the tool's default).
  --skip-build     Don't build; make disk images from the existing local
                   localhost/rhel10-NAME:latest (e.g. after update-image.sh).
  --list-targets   List available targets.
  -h, --help       Show this help.

Output: ${SCRIPT_DIR}/output/NAME/

If the target Containerfile installs RHEL packages (via lib/rhsm-dnf-install.sh) and
this is a non-RHEL host (e.g. Fedora), you'll be prompted for your Red Hat username
and password via rhsm-credentials.sh. They're cached in ${RHSM_SECRETS_DIR}
(tmpfs) and used only for subscription-manager registration inside the build
(RPM content), never for registry.redhat.io.

Targets:
$(list_targets)
EOF
}

# 0. Argument parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            [[ $# -gt 1 ]] || { echo "[ERROR] --target requires a name"; exit 1; }
            TARGET="$2"
            shift
            ;;
        --target=*)
            TARGET="${1#--target=}"
            ;;
        --type)
            [[ $# -gt 1 ]] || { echo "[ERROR] --type requires a value"; exit 1; }
            TYPES+=("$2")
            shift
            ;;
        --type=*)
            TYPES+=("${1#--type=}")
            ;;
        --config)
            if [[ $# -gt 1 && "$2" != -* ]]; then
                CONFIG_TOML="$2"
                shift
            else
                CONFIG_TOML="${DEFAULT_CONFIG_TOML}"
            fi
            ;;
        --config=*)
            CONFIG_TOML="${1#--config=}"
            ;;
        --pull-secret)
            [[ $# -gt 1 ]] || { echo "[ERROR] --pull-secret requires a path"; exit 1; }
            PULL_SECRET="$2"
            shift
            ;;
        --pull-secret=*)
            PULL_SECRET="${1#--pull-secret=}"
            ;;
        --no-package)
            PACKAGE="false"
            ;;
        --host-network)
            BUILD_NET_ARGS=(--network host)
            ;;
        --no-rechunk)
            RECHUNK="false"
            ;;
        --max-layers)
            [[ $# -gt 1 && "$2" =~ ^[0-9]+$ ]] || { echo "[ERROR] --max-layers requires a number"; exit 1; }
            MAX_LAYERS="$2"
            shift
            ;;
        --skip-build)
            SKIP_BUILD="true"
            ;;
        --list-targets)
            list_targets
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

if [[ -z "${TARGET}" ]]; then
    echo "[ERROR] --target is required. Available targets:"
    list_targets
    exit 1
fi

TARGET_DIR="${TARGETS_DIR}/${TARGET}"
CONTAINERFILE="${TARGET_DIR}/Containerfile"
[[ -f "${CONTAINERFILE}" ]] || { echo "[ERROR] Unknown target '${TARGET}' (no ${CONTAINERFILE}). Available targets:"; list_targets; exit 1; }

if (( ${#TYPES[@]} == 0 )); then
    DEFAULT_TYPES=""
    # shellcheck source=/dev/null
    [[ -f "${TARGET_DIR}/target.conf" ]] && . "${TARGET_DIR}/target.conf"
    read -ra TYPES <<<"${DEFAULT_TYPES:-qcow2}"
fi

LOCAL_IMAGE="localhost/rhel10-${TARGET}:latest"
OUTPUT_DIR="${SCRIPT_DIR}/output/${TARGET}"

# Targets can layer on another target (PARENT_TARGET in target.conf, with the Containerfile
# starting FROM localhost/rhel10-<parent>:latest). Build the chain root-first.
BUILD_CHAIN=("${TARGET}")
while :; do
    parent="$(PARENT_TARGET=""; [[ -f "${TARGETS_DIR}/${BUILD_CHAIN[0]}/target.conf" ]] \
        && . "${TARGETS_DIR}/${BUILD_CHAIN[0]}/target.conf"; echo "${PARENT_TARGET:-}")"
    [[ -n "${parent}" ]] || break
    [[ -f "${TARGETS_DIR}/${parent}/Containerfile" ]] || { echo "[ERROR] ${BUILD_CHAIN[0]}: unknown PARENT_TARGET '${parent}'"; exit 1; }
    [[ " ${BUILD_CHAIN[*]} " != *" ${parent} "* ]] || { echo "[ERROR] PARENT_TARGET loop at '${parent}'"; exit 1; }
    BUILD_CHAIN=("${parent}" "${BUILD_CHAIN[@]}")
done

if [[ -n "${CONFIG_TOML}" ]]; then
    [[ -f "${CONFIG_TOML}" ]] || { echo "[ERROR] Config file not found: ${CONFIG_TOML}"; exit 1; }
    CONFIG_TOML="$(realpath "${CONFIG_TOML}")"
fi

# 1. Dependency checks
command -v podman >/dev/null 2>&1 || { echo "[ERROR] podman is required but not installed. Run: sudo dnf install -y podman"; exit 1; }
command -v qemu-img >/dev/null 2>&1 || { echo "[ERROR] qemu-img is required for verification. Run: sudo dnf install -y qemu-img"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq is required for verification. Run: sudo dnf install -y jq"; exit 1; }
if [[ "${PACKAGE}" == "true" && " ${TYPES[*]} " == *" vhd "* ]]; then
    command -v zstd >/dev/null 2>&1 || { echo "[ERROR] zstd is required to package VHDs (or pass --no-package). Run: sudo dnf install -y zstd"; exit 1; }
fi

if [[ -n "${CONFIG_TOML}" ]] && grep -q 'REPLACE_WITH_YOUR_PUBLIC_KEY' "${CONFIG_TOML}"; then
    echo "[ERROR] ${CONFIG_TOML} still contains the placeholder SSH key. Edit it before building."
    exit 1
fi

echo "Target: ${TARGET}    Types: ${TYPES[*]}    Image: ${LOCAL_IMAGE}"
(( ${#BUILD_CHAIN[@]} > 1 )) && echo "Build chain: ${BUILD_CHAIN[*]}"

# 2. Credentials
# If the target installs RHEL packages on a non-RHEL host, the build needs RHSM credentials
# (RPM content), passed as build secrets. These are NOT used for registry.redhat.io.
HOST_ID=$(. /etc/os-release && echo "${ID}")
CHAIN_CONTAINERFILES=()
for t in "${BUILD_CHAIN[@]}"; do CHAIN_CONTAINERFILES+=("${TARGETS_DIR}/${t}/Containerfile"); done
if [[ "${SKIP_BUILD}" != "true" ]] && grep -qE '^[^#]*rhsm-dnf-install' "${CHAIN_CONTAINERFILES[@]}" && [[ "${HOST_ID}" != "rhel" ]] \
   && [[ ! -s "${RHSM_SECRETS_DIR}/rhsm_user" || ! -s "${RHSM_SECRETS_DIR}/rhsm_pass" ]]; then
    echo "[0/5] Non-RHEL host (${HOST_ID}): Red Hat credentials are needed to install RHEL packages in the build."
    "${RHSM_HELPER}"
fi

# Image pulls from registry.redhat.io use the pull secret. All pulls happen as root
# (bootc-image-builder reads root's container storage), so it's passed with --authfile.
echo "[1/5] Checking registry.redhat.io pull credentials..."
AUTH_ARGS=()
if [[ -f "${PULL_SECRET}" ]]; then
    jq -e '.auths["registry.redhat.io"].auth // empty' "${PULL_SECRET}" >/dev/null 2>&1 \
        || { echo "[ERROR] ${PULL_SECRET} has no auth entry for registry.redhat.io."; exit 1; }
    PULL_SECRET="$(realpath "${PULL_SECRET}")"
    AUTH_ARGS=(--authfile "${PULL_SECRET}")
    echo "  - Using pull secret: ${PULL_SECRET}"
    [[ "$(stat -c '%a' "${PULL_SECRET}")" =~ [1-7]$ ]] \
        && echo "[WARNING] ${PULL_SECRET} is readable by other users. Consider: chmod 600 ${PULL_SECRET}"
elif sudo podman login --get-login registry.redhat.io >/dev/null 2>&1; then
    echo "  - Pull secret not found at ${PULL_SECRET}; using root's existing registry.redhat.io login"
else
    echo "[ERROR] No pull secret at ${PULL_SECRET} and root is not logged in to registry.redhat.io."
    echo "        Download one from https://console.redhat.com/openshift/install/pull-secret"
    echo "        and pass it with --pull-secret PATH (or set PULL_SECRET)."
    exit 1
fi

# shellcheck source=lib/rechunk.sh
. "${SCRIPT_DIR}/lib/rechunk.sh"

if [[ "${SKIP_BUILD}" == "true" ]]; then
    sudo podman image exists "${LOCAL_IMAGE}" \
        || { echo "[ERROR] --skip-build: ${LOCAL_IMAGE} not found in root container storage."; exit 1; }
    echo "[2/5] Skipping build; using existing ${LOCAL_IMAGE} ($(image_summary "${LOCAL_IMAGE}"))"
else
    # 3. Build the target image (and any parents) in root's container storage (context = repo root, for lib/)
    SECRET_ARGS=()
    for secret in rhsm_user rhsm_pass rhsm_org; do
        if [[ -s "${RHSM_SECRETS_DIR}/${secret}" ]]; then
            SECRET_ARGS+=(--secret "id=${secret},src=${RHSM_SECRETS_DIR}/${secret}")
        fi
    done
    for t in "${BUILD_CHAIN[@]}"; do
        # The final image is built under :unchunked and flattened into :latest below. The :unchunked
        # tag is kept so its layers serve as the build cache next time.
        tag="latest"
        [[ "${t}" == "${TARGET}" && "${RECHUNK}" == "true" ]] && tag="unchunked"
        echo "[2/5] Building localhost/rhel10-${t}:${tag} from targets/${t}/Containerfile..."
        (( ${#SECRET_ARGS[@]} > 0 )) && echo "  - Passing cached RHSM credentials as build secrets"
        # Children start FROM a parent image that was just built locally, so don't try to pull it
        PULL_POLICY="newer"
        [[ "${t}" == "${BUILD_CHAIN[0]}" ]] || PULL_POLICY="never"
        sudo podman build --pull="${PULL_POLICY}" "${BUILD_NET_ARGS[@]}" "${AUTH_ARGS[@]}" "${SECRET_ARGS[@]}" \
            -t "localhost/rhel10-${t}:${tag}" -f "${TARGETS_DIR}/${t}/Containerfile" "${SCRIPT_DIR}"
    done

    # 3b. Flatten the final image
    if [[ "${RECHUNK}" == "true" ]]; then
        echo "[2/5] Flattening localhost/rhel10-${TARGET}:unchunked ($(image_summary "localhost/rhel10-${TARGET}:unchunked")) with bootc-base-imagectl rechunk..."
        rechunk_image "localhost/rhel10-${TARGET}:unchunked" "${LOCAL_IMAGE}" "${MAX_LAYERS}"
        echo "  - ${LOCAL_IMAGE}: $(image_summary "${LOCAL_IMAGE}")"
    fi
fi

mkdir -p "${OUTPUT_DIR}"

# 4. Run bootc-image-builder
echo "[3/5] Running bootc-image-builder (${TYPES[*]}) from ${LOCAL_IMAGE}..."
BIB_ARGS=()
for type in "${TYPES[@]}"; do
    BIB_ARGS+=(--type "${type}")
done
CONFIG_MOUNT=()
if [[ -n "${CONFIG_TOML}" ]]; then
    echo "  - Using config: ${CONFIG_TOML}"
    CONFIG_MOUNT=(-v "${CONFIG_TOML}:/config.toml:ro")
    BIB_ARGS+=(--config /config.toml)
else
    echo "  - No config.toml (login relies on the image itself, e.g. cloud-init)"
fi

# Note: Privileged mode and loop control access are required to format and assemble disk images
sudo podman run \
  --rm \
  --privileged \
  --pull=newer \
  "${AUTH_ARGS[@]}" \
  --security-opt label=type:unconfined_t \
  -v "${OUTPUT_DIR}:/output" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  "${CONFIG_MOUNT[@]}" \
  "${BUILDER_IMAGE}" \
  "${BIB_ARGS[@]}" \
  "${LOCAL_IMAGE}"

# Fix local ownership of output directory
sudo chown -R "$(id -u):$(id -g)" "${OUTPUT_DIR}"

# 5. Inspect the generated artifacts
echo "[4/5] Generated artifacts in ${OUTPUT_DIR}:"
mapfile -t ARTIFACTS < <(find "${OUTPUT_DIR}" -type f ! -name 'manifest-*.json' ! -name '*.tar.zst' ! -name '*.sha256' | sort)
if (( ${#ARTIFACTS[@]} == 0 )); then
    echo "[ERROR] Build completed, but no artifacts were found in ${OUTPUT_DIR}."
    exit 1
fi

MB=1048576
for artifact in "${ARTIFACTS[@]}"; do
    echo "  - ${artifact} ($(du -h --apparent-size "${artifact}" | cut -f1) apparent, $(du -h "${artifact}" | cut -f1) allocated)"
    case "${artifact}" in
        *.vhd)
            # Azure requirements: fixed VHD ('vpc') with a 1 MB-aligned virtual size.
            # Use jq on top-level keys only; qemu-img also reports nested "children" with their own format/size
            INFO=$(qemu-img info -f vpc --output=json "${artifact}")
            DISK_FORMAT=$(jq -r '.format' <<<"${INFO}")
            VIRTUAL_BYTES=$(jq -r '."virtual-size"' <<<"${INFO}")
            if [[ "${DISK_FORMAT}" != "vpc" ]]; then
                echo "[WARNING] Expected format 'vpc', found '${DISK_FORMAT}'."
            else
                echo "      Format: VPC/VHD (OK)"
            fi
            REMAINDER=$(( VIRTUAL_BYTES % MB ))
            if (( REMAINDER == 0 )); then
                echo "      Virtual Size: ${VIRTUAL_BYTES} bytes ($(( VIRTUAL_BYTES / MB )) MB, 1 MB aligned - OK)"
            else
                # qemu's vpc driver cannot resize in place, so round-trip through raw
                ALIGNED_BYTES=$(( (VIRTUAL_BYTES / MB + 1) * MB ))
                echo "[WARNING] Disk is not aligned to a 1 MB boundary (remainder: ${REMAINDER} bytes)."
                echo "[5/5] Realigning to ${ALIGNED_BYTES} bytes..."
                RAW_TMP="${artifact%.vhd}.raw"
                qemu-img convert -f vpc -O raw "${artifact}" "${RAW_TMP}"
                qemu-img resize -f raw "${RAW_TMP}" "${ALIGNED_BYTES}"
                qemu-img convert -f raw -O vpc -o subformat=fixed,force_size "${RAW_TMP}" "${artifact}"
                rm -f "${RAW_TMP}"
                echo "      Virtual Size: $(qemu-img info -f vpc --output=json "${artifact}" | jq -r '."virtual-size"') bytes (realigned)"
            fi
            ;;
        *.qcow2|*.raw|*.vmdk)
            INFO=$(qemu-img info --output=json "${artifact}")
            echo "      Format: $(jq -r '.format' <<<"${INFO}"), virtual size: $(( $(jq -r '."virtual-size"' <<<"${INFO}") / MB )) MB"
            ;;
    esac
done

# 6. Package VHDs for transfer. A fixed VHD's apparent size is the whole disk (e.g. 10 GiB) but only
#    the real data is allocated; sparse-aware tar + zstd keeps the archive near the data size, and
#    GNU tar restores the VHD as a sparse file on extraction.
PACKAGES=()
if [[ "${PACKAGE}" == "true" ]]; then
    for artifact in "${ARTIFACTS[@]}"; do
        [[ "${artifact}" == *.vhd ]] || continue
        archive="${artifact}.tar.zst"
        echo "[5/5] Packaging $(basename "${artifact}") for transfer..."
        tar --sparse -I 'zstd -T0' -cf "${archive}" -C "$(dirname "${artifact}")" "$(basename "${artifact}")"
        ( cd "$(dirname "${archive}")" && sha256sum "$(basename "${archive}")" > "$(basename "${archive}").sha256" )
        echo "      ${archive} ($(du -h "${archive}" | cut -f1)) + .sha256"
        PACKAGES+=("${archive}")
    done
fi

echo "=========================================================="
echo "Build complete! Target: ${TARGET}"
echo "Artifacts: ${OUTPUT_DIR}"
for archive in "${PACKAGES[@]}"; do
    echo "Transfer:  ${archive#"${SCRIPT_DIR}/"} (+ .sha256)"
    echo "           unpack with: sha256sum -c $(basename "${archive}").sha256 && tar -xf $(basename "${archive}")"
done
[[ -x "${TARGET_DIR}/upload.sh" ]] && echo "Upload:    ${TARGET_DIR#"${SCRIPT_DIR}/"}/upload.sh (see --help)"
echo "=========================================================="
