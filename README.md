# rhel-bootc-images

Build RHEL 10 image mode (bootc)
container images and turn them into disk images (VHD, qcow2, AMI, raw, ISO, ...) with
bootc-image-builder. Works on Fedora or RHEL hosts.

## Quick start

```bash
./build-image.sh --list-targets
./build-image.sh --target azure                 # fixed VHD for Azure
./build-image.sh --target generic --type qcow2  # plain image for a local VM
```

Artifacts land in `output/<target>/`, for example `output/azure/vpc/disk.vhd`.

## Requirements

- `podman`, `qemu-img`, `jq`, and sudo access
- A Red Hat **pull secret** for `registry.redhat.io`, default `~/Downloads/pull-secret`
  ([download](https://console.redhat.com/openshift/install/pull-secret)); override with
  `--pull-secret PATH` or `PULL_SECRET=...`
- On non-RHEL hosts, for targets that install RHEL packages: your Red Hat username and password,
  prompted once and cached in tmpfs. See [RHSM-BUILD-ON-NON-RHEL-HOST.md](RHSM-BUILD-ON-NON-RHEL-HOST.md).
- Optional: `subscription-manager-rhsm-certificates`, so credentials are checked before the build

## Layout

```
build-image.sh              Main entry point (--target, --type, --pull-secret, --config, --no-package,
                            --no-rechunk, --max-layers, --skip-build, --host-network)
update-image.sh             Update an existing image (dnf upgrade, --install), flatten it, report changes
rhsm-credentials.sh         Prompt for and cache RHSM credentials (--status, --clear)
lib/rhsm-dnf-install.sh     Shared in-build package installer (register → dnf install/upgrade → unregister → clean)
lib/rechunk.sh              Shared flattening step (bootc-base-imagectl rechunk)
targets/<name>/Containerfile  Image definition for a target
targets/<name>/target.conf    DEFAULT_TYPES for the target
targets/<name>/upload.sh      Optional upload/import script (aws, vmware)
config.toml                 Optional bootc-image-builder config (break-glass user), used with --config
```

## Targets

| Target | Default type | Adds |
|---|---|---|
| `azure` | `vhd` | cloud-init (Azure datasource), hyperv-daemons, Azure kernel args |
| `aws` | `ami` | cloud-init (EC2 datasource), EC2 serial console and NVMe timeout kernel args |
| `aws-fips` | `ami` | Same as `aws`, plus FIPS mode: `fips=1` kernel arg and the `FIPS` crypto policy |
| `aws-fips-bastion` | `ami` | Layers on `aws-fips` (`PARENT_TARGET`): writable `/usr/local` and `/opt`, sudo `secure_path` with `/usr/local/bin`, and bastion tools (`wget`, `unzip`, `nmstate`, `xorriso`, `tmux`, `vim-enhanced`, `git`, `python3-pip`, `awscli2`, `bash-completion`) |
| `gcp` | `gce` | cloud-init (GCE datasource), GCE serial console kernel args |
| `gcp-fips` | `gce` | Layers on `gcp` (`PARENT_TARGET`): FIPS mode (`fips=1` kernel arg and the `FIPS` crypto policy) |
| `vmware` | `vmdk` | cloud-init (VMware guestinfo datasource), open-vm-tools |
| `generic` | `qcow2` | Nothing; plain `rhel-bootc` |

All cloud targets enable `cloud-init.target` explicitly, since installing the package in a
container build doesn't enable it.

### Uploading

Some targets include an `upload.sh`. Settings go in `targets/<name>/upload.env` (gitignored;
copy `upload.env.example`). Credentials are never stored in the repo.

| Target | Script | Does | Needs |
|---|---|---|---|
| `aws`, `aws-fips`, `aws-fips-bastion` | `targets/aws/upload.sh` (the others link to it); `COPY_TO_REGIONS` copies the AMI to more regions | S3 upload → `import-snapshot` → `register-image` (UEFI-preferred, ENA, IMDSv2) | AWS CLI profile, S3 bucket, `vmimport` IAM role |
| `gcp`, `gcp-fips` | `targets/gcp/upload.sh` (`gcp-fips/upload.sh` links to it) | GCS upload → `gcloud compute images create` (guest OS features `UEFI_COMPATIBLE,GVNIC,VIRTIO_SCSI_MULTIQUEUE`, optional family) | `gcloud` login or a service account key (`GCP_CREDENTIALS_FILE`), GCS bucket |
| `vmware` | `targets/vmware/upload.sh` | `govc import.vmdk` → `vm.create` (EFI, pvscsi, vmxnet3) → optional cloud-init user-data via guestinfo | `govc`, vCenter login (password prompted) |

For Azure, the upload steps live in a separate repo.

### Flattened images (rechunk)

Every build flattens the final image with `bootc-base-imagectl rechunk` (RHEL 10 image mode guide,
section 9.5). The layers are regenerated from the final filesystem, so packages or files that one
build step added and a later step removed or upgraded aren't left in lower layers, where
layer-by-layer vulnerability scanners would still flag them. It also gives reproducible,
content-addressed layers, so updates move less data.

- The pre-flattening image is kept as `localhost/rhel10-<target>:unchunked` (it's the build cache).
- `--no-rechunk` skips it; `--max-layers N` tunes the layer count.
- Scanners that read the RPM database already see only final packages; some known false positives
  (e.g. Go modules vendored into binaries) aren't layer-related and remain.

### Updating an existing image

```bash
./update-image.sh --target aws-fips-bastion            # dnf upgrade + flatten
./update-image.sh --target azure --install WALinuxAgent --disk   # also install, then make the VHD
./update-image.sh --target gcp-fips --from <registry>/<image>:<tag>
```

It runs `dnf upgrade` (plus any `--install` packages) on the existing image in one RHSM
registration, flattens the result into `localhost/rhel10-<target>:latest` (also tagged
`:<timestamp>`), keeps the previous image as `:pre-update-<timestamp>`, and writes an RPM change
report to `output/<target>/update-<timestamp>.txt`. Then either:

- make new disk images: `./build-image.sh --target <target> --skip-build` (or pass `--disk`), or
- push the image to the registry your hosts track and run `bootc upgrade` on them.

A full rebuild (`./build-image.sh --target <target>`) is the image-mode-native alternative and also
picks up a newer base image. Note: a host installed from a locally built disk image re-downloads
all layers on its first `bootc upgrade` (known limitation, bootc#1197 / RHEL-147106).

### SSH keys on GCP

The GCP images use cloud-init (Google's guest agent isn't in the RHEL repos), so GCE's usual
dynamic key handling doesn't apply:

- Put the key in instance metadata **when you create the VM**, for user `cloud-user`:
  `--metadata=ssh-keys="cloud-user:$(cat ~/.ssh/id_ed25519.pub)"`. cloud-init ignores keys for
  other usernames and only reads them at first boot.
- Keys added later (including by `gcloud compute ssh`) and OS Login aren't applied. If your
  organization enforces OS Login, the project needs `enable-oslogin=FALSE` for these VMs.

### Transferring a VHD

A fixed VHD's apparent size is the whole disk (10 GiB by default), but only the real data
(about 1.8 GB) is allocated. A plain copy moves all 10 GiB, so `build-image.sh` packages every
VHD by default (skip with `--no-package`):

```
output/azure/vpc/disk.vhd.tar.zst          # sparse-aware tar + zstd, ~1 GB
output/azure/vpc/disk.vhd.tar.zst.sha256
```

Copy both files, then on the receiving side (GNU tar 1.31+ for built-in zstd):

```bash
sha256sum -c disk.vhd.tar.zst.sha256
tar -xf disk.vhd.tar.zst                    # restores disk.vhd as a sparse file
# older tar: zstd -dc disk.vhd.tar.zst | tar -xf -
```

Keep the extracted VHD sparse when copying it further (`cp --sparse=always`, `rsync --sparse`).

### Boot-testing a disk image locally

Before deploying, boot the disk image in a throwaway VM (`snapshot=on` leaves the file unchanged):

```bash
# BIOS
qemu-system-x86_64 -m 2048 -smp 2 -enable-kvm -cpu host \
  -drive file=output/generic/qcow2/disk.qcow2,if=virtio,snapshot=on

# UEFI (closer to cloud VMs; Azure Gen2 is UEFI-only)
qemu-system-x86_64 -m 2048 -smp 2 -enable-kvm -cpu host \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
  -drive file=output/generic/qcow2/disk.qcow2,if=virtio,snapshot=on
```

For a VHD use `file=output/azure/vpc/disk.vhd,format=vpc,if=virtio,snapshot=on`. Reaching the login
prompt means the image boots. Images without a login user (generic, or cloud targets that rely on
cloud-init) can't be logged into locally; keep the graphical window, since only the cloud targets
send their console to the serial port. Cloud-init may wait a while for a metadata service it can't find locally.

### Image mode behaviour on a running system

These are by design in RHEL 10 image mode, not build problems:

- **Read-only `/usr`, including `/usr/local` and `/opt`.** RHEL 10 bootc base images keep both
  as read-only image content (older images linked them into `/var`). Writable: `/etc`, `/var`,
  `/home` (`/var/home`), `/root` (`/var/roothome`). The `aws-fips-bastion` target restores the old
  links (`/usr/local` -> `/var/usrlocal`, `/opt` -> `/var/opt`). For your own targets, see
  KB 7137990.
- **No package repos until registered.** Custom AMIs are bring-your-own-subscription (no RHUI).
  Register at runtime with `sudo rhc connect --activation-key=<key> --organization=<org_id>`
  (or `sudo subscription-manager register`); `rhc` and `subscription-manager` are in the image.
  Then:
  - Permanent packages: add them to the target Containerfile and rebuild (the image-mode way).
  - Temporary packages: `sudo bootc usr-overlay`, then `sudo dnf install ...` (gone after reboot).
- **Root disk grows automatically.** `bootc-generic-growpart.service` (in the base image) expands
  the root partition and filesystem at first boot, so the 10 GiB AMI disk fills any larger EBS volume.

### Adding a target

1. Create `targets/<name>/Containerfile` starting `FROM registry.redhat.io/rhel10/rhel-bootc:latest`.
2. Install RHEL packages with the shared helper (see the comment in `targets/generic/Containerfile`).
3. End with `RUN bootc container lint`.
4. Optionally add `targets/<name>/target.conf` with `DEFAULT_TYPES="..."`.
5. To build on another target, start `FROM localhost/rhel10-<parent>:latest` and set
   `PARENT_TARGET="<parent>"` in `target.conf`. `build-image.sh` builds the parent first.
