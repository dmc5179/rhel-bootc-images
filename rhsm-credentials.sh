#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Script: rhsm-credentials.sh
# Purpose: Prompt for Red Hat (RHSM) credentials and cache them as podman build
#          secrets so lib/rhsm-dnf-install.sh can register, install RHEL packages, and
#          unregister on a non-RHEL (e.g. Fedora) host. See KB 5558771.
# Storage: ${XDG_RUNTIME_DIR}/rhsm-build (tmpfs, user-only, cleared on logout/reboot).
#          Nothing is written to persistent disk or baked into the image.
# ------------------------------------------------------------------------------

SECRETS_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/rhsm-build"
RHSM_API="https://subscription.rhsm.redhat.com/subscription"
RHSM_CA="/etc/rhsm/ca/redhat-uep.pem"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--clear | --status] [-h|--help]

With no options, prompts for your Red Hat username and password (used only for
subscription-manager registration to get RPM content, not for registry pulls),
verifies them and looks up your organization via the RHSM API (needs
${RHSM_CA}), and caches them in ${SECRETS_DIR}
for build-image.sh.

Options:
  --clear     Delete the cached credentials.
  --status    Show whether credentials are cached (never prints the password).
  -h, --help  Show this help.
EOF
}

# Escape a value for a double-quoted curl config string
curl_quote() {
    local s="${1//\\/\\\\}"
    printf '"%s"' "${s//\"/\\\"}"
}

case "${1:-}" in
    --clear)
        rm -rf "${SECRETS_DIR}"
        echo "Cached RHSM credentials removed."
        exit 0
        ;;
    --status)
        if [[ -s "${SECRETS_DIR}/rhsm_user" && -s "${SECRETS_DIR}/rhsm_pass" ]]; then
            echo "Cached for user: $(cat "${SECRETS_DIR}/rhsm_user")"
            [[ -s "${SECRETS_DIR}/rhsm_org" ]] && echo "Organization:    $(cat "${SECRETS_DIR}/rhsm_org")"
        else
            echo "No RHSM credentials cached."
        fi
        exit 0
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    "")
        ;;
    *)
        echo "[ERROR] Unknown argument: $1"
        usage
        exit 1
        ;;
esac

command -v curl >/dev/null 2>&1 || { echo "[ERROR] curl is required. Run: sudo dnf install -y curl"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq is required. Run: sudo dnf install -y jq"; exit 1; }

# 1. Prompt (password is never echoed or placed on a command line)
read -rp "Red Hat username: " RHSM_USER
read -rsp "Red Hat password: " RHSM_PASS
echo
[[ -n "${RHSM_USER}" && -n "${RHSM_PASS}" ]] || { echo "[ERROR] Username and password are required."; exit 1; }

# 2. Validate credentials and look up organizations via the RHSM API.
#    It is signed by Red Hat's entitlement CA (not a public CA), so --cacert is required.
RESPONSE_FILE=$(mktemp)
trap 'rm -f "${RESPONSE_FILE}"' EXIT
RHSM_ORG=""
if [[ -f "${RHSM_CA}" ]]; then
    echo "Checking credentials with Red Hat Subscription Management..."
    USER_ENC=$(jq -rn --arg u "${RHSM_USER}" '$u | @uri')
    # Credentials go to curl via stdin config so they don't show up in `ps`
    HTTP_CODE=$(printf 'user = %s\n' "$(curl_quote "${RHSM_USER}:${RHSM_PASS}")" \
        | curl -sS -K - --cacert "${RHSM_CA}" -o "${RESPONSE_FILE}" -w '%{http_code}' \
            "${RHSM_API}/users/${USER_ENC}/owners" 2>/dev/null) || HTTP_CODE="000"
else
    HTTP_CODE="no-ca"
fi

case "${HTTP_CODE}" in
    200)
        ORG_COUNT=$(jq 'length' "${RESPONSE_FILE}")
        if (( ORG_COUNT == 1 )); then
            RHSM_ORG=$(jq -r '.[0].key' "${RESPONSE_FILE}")
            echo "  - Credentials OK. Organization: ${RHSM_ORG} ($(jq -r '.[0].displayName' "${RESPONSE_FILE}"))"
        elif (( ORG_COUNT > 1 )); then
            echo "  - Credentials OK. Your account belongs to multiple organizations:"
            jq -r 'to_entries[] | "      \(.key + 1)) \(.value.key)  \(.value.displayName)"' "${RESPONSE_FILE}"
            read -rp "Select organization [1-${ORG_COUNT}]: " CHOICE
            [[ "${CHOICE}" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ORG_COUNT )) \
                || { echo "[ERROR] Invalid selection."; exit 1; }
            RHSM_ORG=$(jq -r --argjson i "$(( CHOICE - 1 ))" '.[$i].key' "${RESPONSE_FILE}")
        else
            echo "  - Credentials OK. No organizations returned; registration will use your default."
        fi
        ;;
    401|403)
        echo "[ERROR] Red Hat Subscription Management rejected these credentials (HTTP ${HTTP_CODE})."
        exit 1
        ;;
    no-ca)
        echo "[WARNING] ${RHSM_CA} not found, so credentials can't be verified before the build"
        echo "          and registration will use your default org. To enable the check:"
        echo "          sudo dnf install -y subscription-manager-rhsm-certificates"
        ;;
    *)
        echo "[WARNING] Could not reach RHSM (HTTP ${HTTP_CODE}); credentials not verified,"
        echo "          registration will use your default org."
        ;;
esac

# 3. Cache as podman secret source files
( umask 077 && mkdir -p "${SECRETS_DIR}" )
chmod 700 "${SECRETS_DIR}"
( umask 077
  printf '%s' "${RHSM_USER}" > "${SECRETS_DIR}/rhsm_user"
  printf '%s' "${RHSM_PASS}" > "${SECRETS_DIR}/rhsm_pass"
  if [[ -n "${RHSM_ORG}" ]]; then
      printf '%s' "${RHSM_ORG}" > "${SECRETS_DIR}/rhsm_org"
  else
      rm -f "${SECRETS_DIR}/rhsm_org"
  fi
)
unset RHSM_PASS

echo "Credentials cached in ${SECRETS_DIR} (tmpfs; cleared on logout/reboot)."
echo "Next: ./build-image.sh --target <name>    |    Remove early: $(basename "$0") --clear"
