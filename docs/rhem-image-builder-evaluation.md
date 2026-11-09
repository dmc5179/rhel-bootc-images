# Evaluation: Red Hat Edge Manager (RHEM) Image Builder on OpenShift

Date: 2026-11-09. Sources: Red Hat official documentation via the Red Hat knowledge portal.
RHEM **1.3** per-topic pages returned only navigation, so findings come from the **1.2** (and 1.1)
`html-single` guides and may differ slightly in 1.3.

## Summary and recommendation

RHEM's Image Builder **is not a fit for this repo's images.** It doesn't build from our
Containerfiles: you give it a base image, it adds the RHEM agent, pushes an OCI image, and
optionally exports ISO, VMDK or QCOW2. There's no AMI, VHD or GCE output, and nothing documents
adding arbitrary packages or our FIPS configuration. For full customization the docs point to the
"advanced" path, which is podman plus bootc-image-builder run by hand. That's what our scripts
already do.

RHEM itself is GA and supported, but its value is **fleet management of hosts running the RHEM
agent**. For what we build today, a **Tekton pipeline on OpenShift running our existing scripts**
(based on the community examples in Red Hat article 7134398) is the better fit. Those example
pipelines aren't supported by Red Hat, but the tools they use are.

Use RHEM Image Builder only if we start managing an agent-enrolled fleet (edge, or VMware/KVM
VMs) and "base image + agent" is enough.

## Findings

| # | Question | Finding | Confidence |
|---|---|---|---|
| 1 | Support status and requirements | RHEM is GA (product support from 1.0). No Technology Preview notice in the 1.2 Image Builder sections, but its support level isn't stated explicitly. Runs on OpenShift 4.19+ or RHEL 9/10. Needs an RHEM subscription. Standalone (own route) or inside the ACM console (`global.enableMulticlusterExtensions`); ACM is optional. | Confirmed (Image Builder support level: partial) |
| 2 | What it does | Resources: `ImageBuild` (`flightctl.io/v1alpha1`), `ImageExport`, `ImagePromotion`. Driven from the web UI or `flightctl apply` / `flightctl logs imagebuild/<name>` / `flightctl download imageexport/<name>`. Inputs: source repository, image name and tag, destination, early or late binding. Output: an OCI image pushed to a configured repository. Exports: ISO, VMDK, QCOW2 (download) and QCOW2 for OpenShift Virtualization. Builds can't be changed after they run; a new version means a new ImageBuild. | Confirmed |
| 3 | Our Containerfiles? Cloud targets? | **No.** The simplified workflow is for when you "do not require advanced customization (custom layers, drivers, or manual signing)". Full Containerfile control is the manual "advanced" path. No AMI, VHD or GCE export. It always adds the RHEM agent. | Confirmed |
| 4 | RHEL entitlements | The worker gets entitlements from Kubernetes secrets: copy `etc-pki-entitlement` from `openshift-config-managed`, plus a cleaned-up `redhat.repo`, `/etc/rhsm`, and the `redhat-uep.pem` CA. Helm values: `entitlementCertsSecretName`, `yumReposSecretName`, `rhsmSecretName`, `rhsmCaSecretName`, `rpmRepoAdd`, `rpmRepoEnable`. The documented purpose is installing the agent RPM from your subscription, not arbitrary packages. | Confirmed |
| 5 | Security on OpenShift | The worker is `privileged: true` with SYS_ADMIN, MKNOD, SYS_CHROOT, SETFCAP. Helm creates a cluster-scoped SCC `flightctl-imagebuilder-worker` for that service account. Image Builder is optional (`imageBuilderWorker.enabled: false`). It runs nested podman build, bootc-image-builder and osbuild. | Confirmed (FIPS clusters, node requirements: not found) |
| 6 | Supply chain | Trusted base images: admins list them in `spec.baseImages` on a Repository. SBOM: CycloneDX generated automatically (syft). Vulnerabilities: `flightctl-periodic` queries Trusted Profile Analyzer by digest every 15 minutes. Promotion: `ImagePromotion` publishes to a Software Catalog item in the `testing` channel; moving to other channels is a separate step. Sigstore signing is documented only for the manual path. | Confirmed (service-side signing: not found) |
| 7 | Updates | Set `spec.os.image` on a device or a fleet's device template. The agent downloads in the background, applies per the update policy, and rolls back automatically through greenboot if health checks fail. **Requires the RHEM agent on enrolled devices**; plain bootc cloud hosts don't benefit. | Confirmed (rollout policy details: partial) |
| 8 | Rechunking | Not mentioned. We'd still run `bootc-base-imagectl rechunk` ourselves. | Not found |
| 9 | Disconnected | Supported: mirrored Helm chart plus an ImageTagMirrorSet. Mirror rhel-bootc, bootc-image-builder, podman and syft locally, and use an offline `.repo` in the secret (no cdn.redhat.com). Builder-image registry auth is a separate `auth.json` mount. | Confirmed |

## Gaps compared with this repo

- No Containerfile input, so none of our in-build RHSM package installs, FIPS kernel argument and
  crypto policy, cloud-init enablement, or parent and child targets.
- No AMI, VHD or GCE output and no cloud upload. Our VHD alignment checks and sparse packaging would
  still be needed.
- It always adds the RHEM agent, and early binding bakes in enrollment, which our cloud images
  don't want.
- No documented rechunking.
- It needs a privileged SCC and an RHEM subscription.

## Ideas worth borrowing

- **CycloneDX SBOMs** (syft) fed to **Red Hat Trusted Profile Analyzer** for vulnerability tracking
  by image digest.
- **Trusted base image allow-lists.**
- On OpenShift, the **privileged-SCC pattern scoped to one service account** and the
  **entitlement-secret pattern** (`etc-pki-entitlement` from `openshift-config-managed`) apply
  equally to a Tekton pipeline running our scripts.

## Open questions (not answered by the docs we could read)

- Whether the RHEM 1.3 Image Builder carries a Technology Preview label.
- Whether `ImageBuild` in 1.3 accepts packages, a Containerfile, or other customizations beyond 1.2.
- Whether the build works on a FIPS-mode OpenShift cluster, or can produce FIPS-enabled images.
- Whether the service signs images itself (Sigstore).
- Fleet rollout policy details (batches, success thresholds).
- Worker node requirements (/dev/fuse, loop devices, storage).
- Whether an RHEM subscription is included with OpenShift or ACM bundles.

## Sources that returned real content

- https://access.redhat.com/documentation/en-us/red_hat_edge_manager/1.2/html-single/operating_system_images_for_the_red_hat_edge_manager/index
- https://access.redhat.com/documentation/en-us/red_hat_edge_manager/1.1/html-single/operating_system_images_for_the_red_hat_edge_manager/index
- https://access.redhat.com/documentation/en-us/red_hat_edge_manager/1.2/html-single/installing_red_hat_edge_manager_on_red_hat_openshift_container_platform/index
- https://access.redhat.com/documentation/en-us/red_hat_edge_manager/1.2/html-single/introduction_to_red_hat_edge_manager/index
- https://access.redhat.com/documentation/en-us/red_hat_edge_manager/1.2/html-single/managing_vulnerabilities/index
- https://access.redhat.com/documentation/en-us/red_hat_edge_manager/1.2/html-single/managing_devices/index
- https://access.redhat.com/documentation/en-us/red_hat_edge_manager/1.2/html-single/managing_device_fleets/index
- Related: Red Hat article 7134398, "CI/CD Workflows with Image Mode for RHEL" (community pipeline
  examples, including OpenShift Pipelines/Tekton).

RHEM 1.3 per-topic pages (for example `install-con_imagebuilder_security_requirements`,
`whats_new-what_s_new`) returned only navigation through the knowledge portal tools.
