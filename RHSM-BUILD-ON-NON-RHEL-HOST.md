# Building RHEL bootc images on a non-RHEL (Fedora) host

Reference: Red Hat KB [5558771 – How to install packages from RHEL in a UBI container running on a non-RHEL host?](https://access.redhat.com/solutions/5558771)

## Quick start (automated)

```bash
./build-image.sh --target azure
```

If the target's `Containerfile` installs RHEL packages through `lib/rhsm-dnf-install.sh` and
the host isn't RHEL, the build script runs `rhsm-credentials.sh` automatically. It:

1. Prompts for your Red Hat username and password (the password isn't echoed).
2. Checks them against the RHSM API and looks up your organization ID, asking you to pick one
   if your account has several. This needs Red Hat's entitlement CA
   (`/etc/rhsm/ca/redhat-uep.pem`, from `sudo dnf install -y subscription-manager-rhsm-certificates`).
   Without it, the credentials are cached unverified and your default org is used.
3. Caches the credentials in `$XDG_RUNTIME_DIR/rhsm-build/` (tmpfs, mode 700, cleared at
   logout or reboot).

The build script passes them to `podman build` as `--secret`s.

**Two different credentials:**

| Credential | Used for | How it's supplied |
|---|---|---|
| Pull secret (`~/Downloads/pull-secret`) | Pulling container images from `registry.redhat.io` | `--authfile` on every root `podman build`/`pull`/`run`. Override with `--pull-secret PATH` or `PULL_SECRET=...` |
| Red Hat username/password | `subscription-manager register` inside the build, for RPM content | Build secrets from `rhsm-credentials.sh` |

Your username and password are never used for `registry.redhat.io`.

| Command | What it does |
|---|---|
| `./rhsm-credentials.sh` | Prompt again and replace the cached credentials |
| `./rhsm-credentials.sh --status` | Show the cached username and org (never the password) |
| `./rhsm-credentials.sh --clear` | Delete the cached credentials now |

On a registered RHEL host, no prompt appears: podman passes the host subscription through and
the helper skips registration.

## Why this is needed

Targets that install extra packages (for example `cloud-init` and `hyperv-daemons` in the
`azure` target) pull them from entitled RHEL repositories.

- On a **registered RHEL host**, Podman automatically passes the host's subscription into
  containers, so `dnf` just works.
- On **Fedora**, that passthrough doesn't exist. Registering the Fedora host itself with
  `subscription-manager` is not supported, and even if it were, the entitlement would not reach
  the build container.

The supported workaround from KB 5558771 is to **register the container itself during the
build**, install the packages, and unregister, all in the same step.

## Installing packages in a target

Use the shared helper in any `targets/<name>/Containerfile` (the build context is the repo root):

```dockerfile
RUN --mount=type=bind,source=lib/rhsm-dnf-install.sh,target=/tmp/rhsm-dnf-install.sh,z \
    --mount=type=secret,id=rhsm_user --mount=type=secret,id=rhsm_pass --mount=type=secret,id=rhsm_org \
    sh /tmp/rhsm-dnf-install.sh <package>...
```

What each part does:

| Piece | Purpose |
|---|---|
| `--mount=type=bind,...,z` | Makes the helper available for this step only, without copying it into the image. `z` relabels it for SELinux; without it the build fails with `Permission denied`. |
| `--mount=type=secret` | Exposes the credentials at `/run/secrets/` for this step only. Secrets are **not** saved in image layers. If no secret is passed (RHEL host), the files are absent and the helper skips registration. |
| `SMDEV_CONTAINER_OFF=1` (inside the helper) | Turns off the check where `subscription-manager` refuses to run inside a container (RHEL 9+). |
| register → `dnf` → unregister → clean in **one** `RUN` | No system identity (consumer certs) is left in any layer. An `EXIT` trap unregisters even if `dnf` fails. |
| `/var` and `/run` cleanup (inside the helper) | Removes dnf/RHSM caches, logs and history from `/var`, plus anything the step created in `/run`, so `bootc container lint` stays clean. |

## Manual alternative: activation key

If you'd rather not use your username and password, create an activation key:

1. Sign in to the Red Hat Hybrid Cloud Console:
   **console.redhat.com → Inventory → System Configuration → Activation Keys**
   (older accounts may still see this under **access.redhat.com → Subscriptions → Activation Keys**).
2. Create a new key, for example `container_builds`.
3. Note your **Organization ID**, which is shown on the Activation Keys page.

With Simple Content Access enabled, the key doesn't need subscriptions attached.

The helper and scripts currently only support username/password. To use a key, change the
`register` call in `lib/rhsm-dnf-install.sh` to
`--org="$(cat /run/secrets/rhsm_org)" --activationkey="$(cat /run/secrets/rhsm_key)"`
and pass `--secret id=rhsm_key,src=...` to `podman build`. Keep any key files out of version
control (they're already in `.gitignore`).

## Verify no identity leaked into the image

```bash
sudo podman run --rm -e SMDEV_CONTAINER_OFF=1 localhost/rhel10-<target>:latest bash -c '
  bootc container lint
  ls -A /etc/pki/consumer /etc/pki/entitlement 2>/dev/null
  subscription-manager identity 2>&1 | head -1'
```

Run `bootc container lint` **first**: `subscription-manager` itself writes `/run/rhsm`,
`/var/log/rhsm` and `/var/lib/rhsm/facts`, which would otherwise show up as lint warnings.

You should see no certificate files, a "not registered" message, and lint passing.

## Cleanup

- Each build briefly registers a system in your account and unregisters it at the end of the step.
- If a build is killed hard (power loss, `kill -9`), check **console.redhat.com → Inventory →
  Systems** for leftover entries with container-style hostnames and remove them.
- Run `./rhsm-credentials.sh --clear` when you're done building.

## Caveats

- **Redistribution:** once RHEL packages are installed, the image falls under your RHEL
  subscription terms. It's fine for your own environments, but don't publish it publicly.
- **Alternative:** run the build on a registered RHEL 10 host or VM. No credentials prompt
  appears there; the helper just runs `dnf`.
