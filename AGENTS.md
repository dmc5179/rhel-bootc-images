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
| `build-image.sh` | Main entry point. `--target NAME` (required) builds `targets/NAME/Containerfile` into `localhost/rhel10-NAME:latest` (context = repo root), then runs bootc-image-builder for each `--type` (default from `target.conf`). Pulls use the pull secret via `--authfile`. Output goes to `output/NAME/`; VHDs get Azure format/alignment checks and, unless `--no-package`, a sparse-aware `<file>.vhd.tar.zst` + `.sha256` for transfer. `--list-targets`, `-h`. |
| `targets/<name>/Containerfile` | Image definition per target. `azure`: cloud-init (Azure datasource), hyperv-daemons, Azure kargs. `generic`: plain `rhel-bootc`. |
| `targets/<name>/target.conf` | `DEFAULT_TYPES="..."` for the target; optional `PARENT_TARGET="..."` to layer on another target (built first; child Containerfile starts `FROM localhost/rhel10-<parent>:latest`). |
| `targets/gcp/upload.sh` | GCP upload (shared by `gcp` and `gcp-fips` via symlink): GCS upload → `gcloud compute images create` with guest OS features `UEFI_COMPATIBLE,GVNIC,VIRTIO_SCSI_MULTIQUEUE`. Auth via gcloud login or `GCP_CREDENTIALS_FILE` (service account key under `secrets/`, applied with `CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE` for the run only). Settings in gitignored `upload.env`. |
| `targets/{aws,vmware}/upload.sh` | Upload scripts. AWS (shared by all `aws*` targets via symlink; the target comes from the invoking directory): S3 → `import-snapshot` → `register-image` → optional `copy-image` to `COPY_TO_REGIONS`. VMware: `govc import.vmdk` → `vm.create` → optional cloud-init guestinfo. Settings come from gitignored `upload.env` (template `upload.env.example`); the vCenter password is prompted for. |
| `update-image.sh` | Draft update flow: `dnf upgrade` (+ `--install`) on an existing image (`--from`, default `localhost/rhel10-<t>:latest`) via the shared installer, rechunk into `:latest` + `:<timestamp>`, keep `:pre-update-<timestamp>`, RPM change report in `output/<t>/update-<timestamp>.txt`, optional `--disk` (calls `build-image.sh --skip-build`). |
| `lib/rechunk.sh` | `rechunk_image` (root `bootc-base-imagectl rechunk` with `/var/lib/containers` mounted, per RHEL 10 image mode guide 9.5) and `image_summary`. Sourced by both scripts. |
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
- **Cloud targets must enable cloud-init explicitly**: symlink `cloud-init.target` into
  `/usr/lib/systemd/system/default.target.wants/` (Red Hat docs pattern). Installing the package in
  a container build does not enable it. Same for other services (e.g. `systemctl enable vmtoolsd`).
- **Upload settings and credentials stay out of git**: `targets/*/upload.env` and
  `targets/*/user-data.yaml` are gitignored. AWS uses CLI profiles; never store keys.
- **FIPS (RHEL 10) must be built in**: RHEL 10 removed `fips-mode-setup`, so FIPS can't be turned
  on after install (KB 7056059). Per the RHEL 10 image mode guide (chapter 11), add `fips=1` via
  `/usr/lib/bootc/kargs.d/01-fips.toml`, install `crypto-policies-scripts`, and run
  `update-crypto-policies --no-reload --set FIPS`. To check a built disk image without root, grep
  its `/boot` partition bytes for the BLS `options` line containing `fips=1`.
- **Read-only `/usr/local` and `/opt` are RHEL 10 base-image behaviour**, not ours (real dirs in
  the image; the base ships `/var/usrlocal`, `/var/opt` tmpfiles and SELinux equivalences for the
  old link model). Only `aws-fips-bastion` restores the links. Root auto-grow comes from the base
  image's `bootc-generic-growpart.service`.
- **Check package names before adding them**: rootless `podman run -v $XDG_RUNTIME_DIR/rhsm-build:/run/secrets:ro,z`
  on `rhel10/rhel-bootc`, register, `dnf repoquery --available`, unregister. (`podman run --secret`
  doesn't take `id=,src=` like `podman build`.)
- **cloud-init must not resize the disk**: every cloud target ships
  `/etc/cloud/cloud.cfg.d/91-bootc-no-resize.cfg` (`growpart: mode: "off"`, `resize_rootfs: false`).
  `/` is read-only composefs, so cloud-init's resize fails and marks it "degraded";
  `bootc-generic-growpart` grows the disk. Children (`gcp-fips`, `aws-fips-bastion`) inherit it.
- **FIPS hosts refuse ssh-ed25519 keys**: sshd accepts only ecdsa-sha2-nistp256/384/521 and
  rsa-sha2-256/512. Use ECDSA or RSA keys for `cloud-user`.
- **GCP uses cloud-init, not Google's guest agent** (not in the RHEL repos). cloud-init's GCE
  datasource only accepts metadata `ssh-keys` entries for `cloud-user` (or `cloudinit`) and only at
  first boot, so `gcloud compute ssh` key pushes and OS Login don't work. The bootc kernel has
  `gve` (gVNIC), `nvme` and `virtio_scsi`.
- **Every target ends with `RUN bootc container lint`.** Keep `/var` and `/run` clean in image layers.
  The only expected lint warning is `var/roothome/buildinfo/content-sets.json` from the base image.
  When verifying an image, run `bootc container lint` before any `subscription-manager` command,
  which writes `/run/rhsm` and `/var/lib/rhsm` itself (so do `cloud-init` commands, in `/run/cloud-init`). Packages that create `/var` dirs need
  `/usr/lib/tmpfiles.d` entries in the target Containerfile.
- **Parse `qemu-img info` JSON with `jq` using top-level keys only.** qemu 8+ adds nested
  `children` entries with their own `format`/`virtual-size`, which breaks grep-based parsing.
- **`rhel-bootc:latest` moves to new minor releases** (it was 10.3 by 2026-11-11). Use
  `build-image.sh --rhel-version X.Y` to pin; base targets take `ARG RHEL_BOOTC_TAG`. While
  registered, the shared installer runs `subscription-manager release --set=<base VERSION_ID>`, so
  packages match the base (verified: a 10.2 bastion build had 0 `el10_3` packages). On a RHEL build
  host that passes its own subscription through (no registration), the lock doesn't apply.
- **`build-image.sh` doesn't touch the cloud.** The target's `upload.sh` uploads and waits until the
  image is usable (AWS: `wait_for_ami` until `available`, retrying past the AWS waiter's ~10 min
  limit; GCP: `gcloud compute images create` is synchronous). `--upload` chains it after the build.
- **Images are flattened by default.** `build-image.sh` builds the final target as `:unchunked`
  and rechunks it into `:latest` (`--no-rechunk` to skip). Verified: a file added in one layer and
  deleted in the next was in 2 layers before rechunk and 0 after; a real kernel update shrank the
  image from 1.86 GB to 1.66 GB. Rootless rechunk testing needs the user's storage mounted at its
  own path (under `/var/home/...` inside the container) plus a matching `storage.conf`.
- **Kernel updates in images** leave `/boot/symvers-*.xz` and `/var/lib/rpm-state/kernel`; the
  shared installer's cleanup covers `/boot` and `/var/lib/rpm-state`. dnf keeps a single kernel.
- **Transfer VHDs sparse.** Package with `tar --sparse -I 'zstd -T0'` (done by default in
  `build-image.sh`); a 10 GiB fixed VHD with ~1.9 GB of data packs to ~945 MB in seconds and
  extracts back sparse and byte-identical. The artifact scan ignores `*.tar.zst` and `*.sha256`.
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

- [ ] Decide whether to keep `config.toml` (break-glass user) or delete it
- [ ] Decide whether to add `WALinuxAgent` to `targets/azure/Containerfile` (needed for Azure VM extensions)
- [ ] Boot-test the Azure VHD locally (e.g. libvirt/qemu) before transfer
- [ ] Verify the existing Azure image has cloud-init enabled; rebuild `--target azure` with the explicit `cloud-init.target` enable
- [ ] First real build of `--target vmware` (check lint is clean). (`aws` is covered: `aws-fips` = `aws` + FIPS, built as root twice and verified on running instances)
- [ ] Test `targets/vmware/upload.sh` once vCenter access is available; confirm EFI + pvscsi boot (fall back to `VM_FIRMWARE=bios`/`VM_DISK_CONTROLLER=lsilogic` if not), and check the `rhel10_64Guest` guest ID availability
- [ ] Prototype a Tekton (OpenShift Pipelines) pipeline that runs our build: Containerfile build → rechunk → push to Quay → bootc-image-builder. Use a privileged SCC scoped to the pipeline service account and RHEL entitlements from the cluster (`etc-pki-entitlement` in `openshift-config-managed`); consider CycloneDX SBOMs for Trusted Profile Analyzer. Start from the community examples in Red Hat article 7134398 (not supported by Red Hat). See `docs/rhem-image-builder-evaluation.md`

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
- [x] Rebuilt `--target azure` with refactored layout (2026-10-30): lint down to 1 warning, `var/roothome/buildinfo/content-sets.json`, which ships in the Red Hat base image (expected, not ours)
- [x] Azure-side steps (upload, image creation, VM launch, cloud-init check) are documented in a separate repo of the user's; out of scope here
- [x] Built `--target aws-fips` and registered the AMI in us-east-1 (2026-11-03); `fips=1` confirmed in the disk image's BLS entry. Created IAM role `vmimport` (S3 access limited to the upload bucket); `targets/aws/upload.sh` worked end to end
- [x] Built `--target aws-fips-bastion` (2026-11-04) in response to the openshift5-disconnected review, registered it directly in us-east-2 via a dedicated import bucket, and sent them the AMI details
- [x] openshift5-disconnected verified the `aws-fips-bastion` AMI on m6i.2xlarge (2026-11-04): fips_enabled=1, FIPS policy, `/usr/local` and `/opt` writable via `/var` links, sudo secure_path, all tools present, IMDSv2 enforced, SELinux enforcing, root grew to the volume size. Now their default RHEL 10 test-host AMI
- [x] FIPS on the `aws-fips` image considered verified (2026-11-04): the bastion AMI layers on it and was confirmed on a running instance (fips_enabled=1, FIPS policy, UEFI boot, `cloud-user` login)
- [x] Sparse VHD transfer is now the default (2026-11-04): `build-image.sh` writes `<file>.vhd.tar.zst` + `.sha256` (`--no-package` to skip); documented in README "Transferring a VHD"
- [x] Added `gcp` and `gcp-fips` (layers on `gcp`) targets and `targets/gcp/upload.sh` (2026-11-08); rootless real build of both layers passed (lint clean, fips=1 + GCE console kargs, FIPS policy, cloud-init GCE datasource); upload flow checked against a stub gcloud
- [x] Flatten by default (2026-11-08): `build-image.sh` rechunks the final image (`lib/rechunk.sh`), `--skip-build` added; draft `update-image.sh` (upgrade + rechunk + report); shared installer gained `--upgrade` and `/boot` + `/var/lib/rpm-state` cleanup. Verified rootless end to end with a real kernel update
- [x] Default rechunk verified as root (2026-11-08): `./build-image.sh --target gcp-fips --host-network` flattened and produced the GCE image (fips=1 + GCE console kargs confirmed)
- [x] GCP FIPS verified on a real VM (2026-11-08): flattened `gcp-fips` image (CMEK, us-east4) launched by the ocp-in-gcp-il5 session as a Shielded VM with Secure Boot (shim boots with GCE default keys), gVNIC (gve), CMEK disk, no external IP, IAP SSH. fips_enabled=1, FIPS policy, fips provider active, root grew to the 50 GB disk, cloud-init GCE datasource OK, metadata SA token OK, 0 failed units, SELinux enforcing
- [x] cloud-init resize disabled in azure, aws, aws-fips, gcp, vmware (2026-11-08); merged config verified in a rootless gcp build (growpart off, resize_rootfs false), lint clean
- [x] GCP FIPS image used as a keyless OpenShift install host (2026-11-09, by the ocp-in-gcp-il5 session): openshift-install-fips 4.22.18, oc and ccoctl from ~/bin on the RHEL 10.2 FIPS host, credentials only from the metadata server (attached service account, no key file, no gcloud); resulting cluster FIPS on all nodes, all operators healthy
- [x] GCP test resources cleaned up (2026-11-09): image, bucket and IAP firewall rule deleted after the image was used for OpenShift tests R4/R9 (both passed); nothing left in the sandbox
- [x] Evaluated RHEM Image Builder on OpenShift (2026-11-09; `docs/rhem-image-builder-evaluation.md`): not a fit. No Containerfile input, no AMI/VHD/GCE output, always adds the RHEM agent; its value is fleet management of agent-enrolled hosts. A Tekton pipeline running our scripts is the better OpenShift path (reuse RHEM's privileged-SCC and entitlement-secret patterns)
- [x] First real build of `--target generic` (2026-11-09): flattened, qcow2 10 GiB virtual / ~1.06 GB on disk, `qemu-img check` clean; no RHSM prompt after fixing RHSM detection to ignore commented lines
- [x] Local QEMU boot test of the generic qcow2 (2026-11-09): reached the login prompt with both BIOS (SeaBIOS) and UEFI (OVMF, no Secure Boot) firmware. Commands are in the README section "Boot-testing a disk image locally"
- [x] RHEL 10.2 `aws-fips-bastion` AMI rebuilt for the openshift5-disconnected session in its new AWS account (2026-11-11): `--rhel-version 10.2` (0 el10_3 packages), `acl` added, fapolicyd guard, AMI/snapshot tagged via `AWS_TAGS`, private; `upload.sh` now waits for `available`. New `build-image.sh --upload`
- [x] First root run of `update-image.sh` (2026-11-11): `--target generic --host-network` on the 2026-11-09 image; 2 changes (curl, libcurl el10_2.7 -> el10_2.8), stayed 10.2 via the release lock (0 el10_3 packages), flattened, lint clean, one kernel, no RHSM identity, report in `output/generic/update-<timestamp>.txt`
