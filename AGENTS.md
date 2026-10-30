# AGENTS.md

Guidance for AI coding agents (and humans) working in this repo (**rhel-bootc-images**).

## Project purpose

Build RHEL 10 **image mode (bootc)** container images from per-target Containerfiles and turn
them into disk images (VHD, qcow2, AMI, raw, ISO, ...) with bootc-image-builder, on a Fedora
workstation or a RHEL host. The first use case is the `azure` target: a fixed VHD transferred
into an isolated Azure account, where VMs get their SSH keys from Azure via cloud-init.

The working directory is still named `composer-cli`; the user will rename it to
`rhel-bootc-images` later (not during a running session).

## Files

| File | Purpose |
|---|---|
| `build-image.sh` | Main entry point. `--target NAME` (required) builds `targets/NAME/Containerfile` into `localhost/rhel10-NAME:latest` (context = repo root), then runs bootc-image-builder for each `--type` (default from `target.conf`). Pulls use the pull secret via `--authfile`. Output goes to `output/NAME/`; VHDs get Azure format/alignment checks. `--list-targets`, `-h`. |
| `targets/<name>/Containerfile` | Image definition per target. `azure`: cloud-init (Azure datasource), hyperv-daemons, Azure kargs. `generic`: plain `rhel-bootc`. |
| `targets/<name>/target.conf` | `DEFAULT_TYPES="..."` for the target. |
| `lib/rhsm-dnf-install.sh` | Shared in-build package installer, bind-mounted into `RUN` steps. With secrets: register → dnf → unregister/clean (EXIT trap). Without: plain dnf. Always cleans dnf/RHSM state from `/var` and new `/run` entries for `bootc container lint`. |
| `rhsm-credentials.sh` | Prompts for Red Hat username/password, verifies them and looks up the org via the RHSM API (needs `/etc/rhsm/ca/redhat-uep.pem`; otherwise cached unverified), and caches them in `$XDG_RUNTIME_DIR/rhsm-build/` (tmpfs). `--status`, `--clear`. `build-image.sh` calls it automatically on non-RHEL hosts when the target uses the helper. |
| `config.toml` | Optional bootc-image-builder config with a break-glass user. Used **only** with `--config`. Holds a placeholder SSH key, which the script refuses to build with. |
| `RHSM-BUILD-ON-NON-RHEL-HOST.md` | How in-build RHSM registration works on non-RHEL hosts (KB 5558771). |
| `README.md` | User-facing overview, layout, and how to add a target. |

## Conventions and constraints

- **Everything container-related runs as root** (`sudo podman ...`). bootc-image-builder reads
  root's storage (`/var/lib/containers/storage`), so the pull and build must all
  happen as root, with the pull secret passed via `--authfile`.
- **Two separate credentials; don't mix them.** `registry.redhat.io` image pulls use the **pull
  secret**. The Red Hat **username/password** are only for `subscription-manager register` (RPM
  content) inside the build. Never use the username/password for registry login or validation.
- **Targets install RHEL packages only through `lib/rhsm-dnf-install.sh`.** `build-image.sh`
  detects the string `rhsm-dnf-install` in a target's Containerfile to decide whether to prompt
  for credentials. Bind mounts from the build context need the `,z` option, or SELinux denies access.
- **Every target ends with `RUN bootc container lint`.** Keep `/var` and `/run` clean in image layers.
- **Parse `qemu-img info` JSON with `jq` using top-level keys only.** qemu 8+ adds nested
  `children` entries with their own `format`/`virtual-size`, which breaks grep-based parsing.
- **Don't resize VHDs in place.** qemu's `vpc` driver doesn't support resize. Convert to raw,
  resize, and convert back with `-O vpc -o subformat=fixed,force_size`.
- **Never bake credentials into the image.** RHSM credentials are passed with
  `podman build --secret` (`rhsm_user`, `rhsm_pass`, optional `rhsm_org`). Cache credentials only
  in tmpfs (`$XDG_RUNTIME_DIR`), never in the project directory.
- **The RHSM API (`subscription.rhsm.redhat.com`) is signed by Red Hat's entitlement CA**
  (`/etc/rhsm/ca/redhat-uep.pem`), not a public CA. Plain `curl` fails on Fedora without
  `--cacert /etc/rhsm/ca/redhat-uep.pem` (package `subscription-manager-rhsm-certificates`).
- **Don't run the real build without the user.** It needs sudo, Red Hat credentials, and
  network access. Test with `bash -n`, the script's early-exit paths, local `qemu-img`
  experiments in `/tmp`, and rootless offline `podman build --network=none` against
  `registry.fedoraproject.org/fedora:44` with stub `dnf`/`subscription-manager`.
- Keep the script style: numbered step comments, `[ERROR]`/`[WARNING]` prefixes,
  `set -euo pipefail`.

## TODO

Keep this list current: check items off when done, add new ones as they come up.

- [ ] Real rebuild of `--target azure` with the refactored layout; confirm `bootc container lint` shows no `/var`/`/run` warnings
- [ ] First real build of `--target generic`
- [ ] Decide whether to keep `config.toml` (break-glass user) or delete it
- [ ] Decide whether to add `WALinuxAgent` to `targets/azure/Containerfile` (needed for Azure VM extensions)
- [ ] Boot-test the Azure VHD locally (e.g. libvirt/qemu) before transfer
- [ ] Document sparse-preserving transfer (e.g. `tar -Sczf` / zstd), since the fixed VHD is 10 GiB but only ~1.8 GB allocated
- [ ] Document the Azure side: upload the VHD (azcopy / page blob), create the image (Gen1 vs Gen2), launch a VM with an Azure-generated SSH key, and check that cloud-init provisioning works
- [ ] Consider more targets (e.g. `aws` → `ami`, `gce`, `vmware` → `vmdk`)

### Done

- [x] Fix bootc-image-builder invocation: mount container storage, pull as root, remove `-it`
- [x] Fix VHD verification: `jq` parsing; realign by raw round-trip
- [x] Make `config.toml` opt-in via `--config [PATH]`
- [x] Write `RHSM-BUILD-ON-NON-RHEL-HOST.md` (KB 5558771)
- [x] Use the pull secret for `registry.redhat.io`; RH username/password only for RHSM
- [x] Add `rhsm-credentials.sh` with RHSM API validation and org lookup
- [x] First end-to-end Azure build on Fedora 44 succeeded (2026-10-30): fixed VHD, 10 GiB virtual / ~1.8 GB allocated, 1 MB aligned; image verified (packages present, no RHSM identity), lint passed with 3 `/var`/`/run` warnings
- [x] Refactor into generic `rhel-bootc-images` layout: `build-image.sh` with `--target`/`--type`, `targets/{azure,generic}`, shared `lib/rhsm-dnf-install.sh` (with `/var`/`/run` cleanup), README, `.gitignore`; moved existing VHD to `output/azure/`
- [x] Published as public repo https://github.com/dmc5179/rhel-bootc-images (2026-10-30)
