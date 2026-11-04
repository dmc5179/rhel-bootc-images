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
build-image.sh              Main entry point (--target, --type, --pull-secret, --config)
rhsm-credentials.sh         Prompt for and cache RHSM credentials (--status, --clear)
lib/rhsm-dnf-install.sh     Shared in-build package installer (register → dnf → unregister → clean)
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
| `vmware` | `vmdk` | cloud-init (VMware guestinfo datasource), open-vm-tools |
| `generic` | `qcow2` | Nothing; plain `rhel-bootc` |

All cloud targets enable `cloud-init.target` explicitly, since installing the package in a
container build doesn't enable it.

### Uploading

Some targets include an `upload.sh`. Settings go in `targets/<name>/upload.env` (gitignored;
copy `upload.env.example`). Credentials are never stored in the repo.

| Target | Script | Does | Needs |
|---|---|---|---|
| `aws`, `aws-fips` | `targets/aws/upload.sh` (`aws-fips/upload.sh` links to it) | S3 upload → `import-snapshot` → `register-image` (UEFI-preferred, ENA, IMDSv2) | AWS CLI profile, S3 bucket, `vmimport` IAM role |
| `vmware` | `targets/vmware/upload.sh` | `govc import.vmdk` → `vm.create` (EFI, pvscsi, vmxnet3) → optional cloud-init user-data via guestinfo | `govc`, vCenter login (password prompted) |

For Azure, the upload steps live in a separate repo.

### Adding a target

1. Create `targets/<name>/Containerfile` starting `FROM registry.redhat.io/rhel10/rhel-bootc:latest`.
2. Install RHEL packages with the shared helper (see the comment in `targets/generic/Containerfile`).
3. End with `RUN bootc container lint`.
4. Optionally add `targets/<name>/target.conf` with `DEFAULT_TYPES="..."`.
