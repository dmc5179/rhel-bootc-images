#!/bin/sh
# ------------------------------------------------------------------------------
# Script: lib/rhsm-dnf-install.sh
# Purpose: Install RHEL packages during a container build on any host (KB 5558771).
#          - With rhsm_user/rhsm_pass(/rhsm_org) build secrets (non-RHEL host): registers
#            the build container, installs, and always unregisters, so no credentials or
#            system identity land in any layer.
#          - Without secrets (registered RHEL host): podman passes the host subscription
#            through and this just runs dnf.
#          Afterwards it removes dnf/RHSM state from /var and new /run content so
#          `bootc container lint` stays clean.
#
# Usage in a target Containerfile (build context is the repo root):
#   RUN --mount=type=bind,source=lib/rhsm-dnf-install.sh,target=/tmp/rhsm-dnf-install.sh,z \
#       --mount=type=secret,id=rhsm_user --mount=type=secret,id=rhsm_pass --mount=type=secret,id=rhsm_org \
#       sh /tmp/rhsm-dnf-install.sh <package>...
#   or, to update everything (optionally installing more packages in the same registration):
#       sh /tmp/rhsm-dnf-install.sh --upgrade [<package>...]
# ------------------------------------------------------------------------------
set -eu

UPGRADE=0
if [ "${1:-}" = "--upgrade" ]; then
    UPGRADE=1
    shift
fi
[ "${UPGRADE}" -eq 1 ] || [ "$#" -gt 0 ] || { echo "usage: rhsm-dnf-install.sh [--upgrade] <package>..." >&2; exit 1; }

REGISTERED=0
RUN_BEFORE=" $(ls -A /run | tr '\n' ' ') "
# State/log/cache trees where anything created during this step is build residue
# (RHSM facts/productid/logs, ldconfig cache, root dotfiles, kernel-update leftovers such as
# /boot/symvers-*.xz, ...). Pre-existing entries are kept.
VAR_STATE_DIRS="/var/cache /var/log /var/lib/rhsm /var/lib/rpm-state /var/roothome /boot"
NL='
'
VAR_BEFORE="${NL}$(find ${VAR_STATE_DIRS} 2>/dev/null || true)${NL}"

cleanup() {
    if [ "${REGISTERED}" -eq 1 ]; then
        subscription-manager unregister || true
        subscription-manager clean || true
    fi
    # /var is only seeded at install time on bootc systems; don't ship build-time state in it
    rm -rf /var/cache/dnf /var/lib/dnf /var/log/dnf*.log /var/log/hawkey.log /var/cache/ldconfig/aux-cache
    # Depth-first so new directories are empty by the time they're reached
    find ${VAR_STATE_DIRS} -depth 2>/dev/null | while IFS= read -r path; do
        case "${VAR_BEFORE}" in
            *"${NL}${path}${NL}"*) ;;
            *) if [ -d "${path}" ] && [ ! -L "${path}" ]; then rmdir "${path}" 2>/dev/null || true; else rm -f "${path}"; fi ;;
        esac
    done
    # /run is runtime-only; drop anything created during this step (leave mounts like /run/secrets)
    for entry in $(ls -A /run); do
        case "${RUN_BEFORE}" in
            *" ${entry} "*) ;;
            *) rm -rf "/run/${entry}" ;;
        esac
    done
}
trap cleanup EXIT

if [ -s /run/secrets/rhsm_user ] && [ -s /run/secrets/rhsm_pass ]; then
    export SMDEV_CONTAINER_OFF=1
    REGISTERED=1
    if [ -s /run/secrets/rhsm_org ]; then
        subscription-manager register --username="$(cat /run/secrets/rhsm_user)" \
            --password="$(cat /run/secrets/rhsm_pass)" --org="$(cat /run/secrets/rhsm_org)"
    else
        subscription-manager register --username="$(cat /run/secrets/rhsm_user)" \
            --password="$(cat /run/secrets/rhsm_pass)"
    fi
    # Install from the base image's own minor release (e.g. 10.2), not the newest one, so a
    # pinned base (build-image.sh --rhel-version) doesn't get packages from a later release
    subscription-manager release --set="$(. /etc/os-release && echo "${VERSION_ID}")"
fi

if [ "${UPGRADE}" -eq 1 ]; then
    dnf -y upgrade
fi
if [ "$#" -gt 0 ]; then
    dnf -y install "$@"
fi
dnf clean all
