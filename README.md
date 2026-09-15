# OpenShift Security Roadshow

Hands-on Showroom labs for Kubernetes-native security on Red Hat OpenShift Container Platform. The catalog covers platform foundations, Red Hat Advanced Cluster Security (RHACS), Lightwell Trusted Software Supply Chain, and OpenShift Virtualization hardening.

**Live site:** [https://mfosterrox.github.io/ocp5-rhacs-showroom/](https://mfosterrox.github.io/ocp5-rhacs-showroom/)

Catalog source of truth for RHDP: [rhpds/ocp5-rhacs-showroom](https://github.com/rhpds/ocp5-rhacs-showroom).

Public GitHub Pages is a read-only preview of the lab website. Cluster URLs and passwords on that site are placeholders; RHDP injects the real environment at runtime.

## Content

| Path | What you get |
| --- | --- |
| [101 Foundations](content/modules/ROOT/pages/basic-INDEX.adoc) | Secure-by-default OpenShift: projects, RBAC, SCCs, NetworkPolicy, secrets, images, audit |
| [201 Intermediate](content/modules/ROOT/pages/intermediate-INDEX.adoc) | Shift-left, Vault, compliance tailoring, cert-manager, admission governance |
| [301 Advanced](content/modules/ROOT/pages/advanced-INDEX.adoc) | GitOps policy, AdminNetworkPolicy, runtime enforce, supply-chain integrity |
| [RHACS](content/modules/ROOT/pages/acs-INDEX.adoc) | Vulnerabilities, policy and risk, CI/CD gates, compliance, network and runtime, ACS 5 |
| [Lightwell TSSC](content/modules/ROOT/pages/tssc-INDEX.adoc) | Signed Hummingbird, enterprise proxy, pin, build, sign, attest, GitOps admission |
| [Virtualization](content/modules/ROOT/pages/virt-INDEX.adoc) | HyperConverged, virt RBAC, VM/storage isolation, network segmentation |

Start at [`content/modules/ROOT/pages/index.adoc`](content/modules/ROOT/pages/index.adoc).

## Preview locally

```bash
make build
make serve
```

The site is at http://localhost:8080/. Override the port with `make serve PORT=9090`.

GitHub Pages builds from `gh-pages-site.yml` via [`.github/workflows/gh-pages.yml`](.github/workflows/gh-pages.yml). Local `make build` uses `site.yml` (same content, RHDP-oriented playbook).
