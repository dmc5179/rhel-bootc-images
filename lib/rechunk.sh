# shellcheck shell=bash
# ------------------------------------------------------------------------------
# Library: lib/rechunk.sh (sourced by build-image.sh and update-image.sh)
# Purpose: Flatten a bootc image into content-addressed, reproducible layers with
#          `bootc-base-imagectl rechunk` ("Optimizing container images to a smaller version",
#          RHEL 10 "Using image mode for RHEL", section 9.5). The layers are regenerated from the
#          image's final filesystem, so files that an earlier build step added and a later step
#          removed or replaced (e.g. superseded RPM versions) are not carried in any layer.
# Needs:   root container storage (the tool runs as root with /var/lib/containers mounted) and
#          AUTH_ARGS from the caller for pulling the tool image.
# ------------------------------------------------------------------------------

RECHUNK_TOOL_IMAGE="${RECHUNK_TOOL_IMAGE:-registry.redhat.io/rhel10/rhel-bootc:latest}"

# rechunk_image <from-image> <to-image> [max-layers]
rechunk_image() {
    local from="$1" to="$2" max_layers="${3:-}" args=()
    [[ -n "${max_layers}" ]] && args+=(--max-layers "${max_layers}")
    sudo podman run --rm --privileged --pull=missing "${AUTH_ARGS[@]}" \
        -v /var/lib/containers:/var/lib/containers \
        "${RECHUNK_TOOL_IMAGE}" \
        /usr/libexec/bootc-base-imagectl rechunk "${args[@]}" "${from}" "${to}"
}

# image_summary <image>: "<layers> layers, <size>"
image_summary() {
    local layers size
    layers=$(sudo podman image inspect --format '{{len .RootFS.Layers}}' "$1")
    size=$(sudo podman image inspect --format '{{.Size}}' "$1" | numfmt --to=iec)
    echo "${layers} layers, ${size}"
}
