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
# ------------------------------------------------------------------------------
set -eu

[ "$#" -gt 0 ] || { echo "usage: rhsm-dnf-install.sh <package>..." >&2; exit 1; }

REGISTERED=0
RUN_BEFORE=" $(ls -A /run | tr '\n' ' ') "

cleanup() {
    if [ "${REGISTERED}" -eq 1 ]; then
        subscription-manager unregister || true
        subscription-manager clean || true
    fi
    # /var is only seeded at install time on bootc systems; don't ship build-time state in it
    rm -rf /var/cache/dnf /var/lib/dnf /var/log/dnf*.log /var/log/hawkey.log \
           /var/log/rhsm /var/lib/rhsm/cache
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
fi

dnf -y install "$@"
dnf clean all
