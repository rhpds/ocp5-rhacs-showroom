# OpenShift Security Roadshow

Hands-on Showroom labs for Kubernetes-native security on Red Hat OpenShift Container Platform. The catalog covers platform foundations, Red Hat Advanced Cluster Security (RHACS), Lightwell Trusted Software Supply Chain, and OpenShift Virtualization hardening.

**Live site:** [[https://mfosterrox.github.io/ocp5-rhacs-showroom/](https://rhpds.github.io/ocp5-rhacs-showroom/) 

Catalog source of truth for RHDP: [rhpds/ocp5-rhacs-showroom](https://github.com/rhpds/ocp5-rhacs-showroom).

Public GitHub Pages is a read-only preview of the lab website. Cluster URLs and passwords on that site are placeholders; RHDP injects the real environment at runtime.

## Preview locally

```bash
make build
make serve
```

The site is at http://localhost:8080/. Override the port with `make serve PORT=9090`.

GitHub Pages builds from `gh-pages-site.yml` via [`.github/workflows/gh-pages.yml`](.github/workflows/gh-pages.yml). Local `make build` uses `site.yml` (same content, RHDP-oriented playbook).
