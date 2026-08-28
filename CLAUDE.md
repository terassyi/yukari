# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Multi-Cluster Services (MCS) controller in Rust, implementing
[KEP-1645](https://github.com/kubernetes/enhancements/tree/master/keps/sig-multicluster/1645-multi-cluster-services-api)
— the `multicluster.x-k8s.io` group defined by
[kubernetes-sigs/mcs-api](https://github.com/kubernetes-sigs/mcs-api). `api/` holds the generated CRD
bindings, `controller/` the binary. The reconciler is not written yet.

## Working here

`just --list` is the source of truth for commands, and CI runs those same recipes. Two things it does
not tell you:

- `just ci` calls the GitHub API (in `checksum-check` and `lint-actions`), so set `GITHUB_TOKEN`.
- `checksum-check` and `generate-check` regenerate a tracked file before diffing it, so a failure
  leaves the regenerated file in the working tree.

Tools are pinned by [aqua](https://aquaproj.github.io/), with `require_checksum: true`. After
changing a version in `aqua.yaml`, refresh `aqua-checksums.json` — otherwise every aqua-managed
tool, `just` included, stops working.

## Generated code

`api/src/v1beta1/` is **entirely generated**: `just generate` deletes and rebuilds the directory,
`mod.rs` included. Never hand-edit it; hand-written helpers belong beside `lib.rs`.

```
api/Cargo.toml [package.metadata.mcs-api]   # the pin: version + commit
  -> just vendor-crd                        # needs the git-ignored ./mcs-api clone
  -> manifests/crd/*.yaml                   # committed, with a provenance header
  -> just generate                          # kopium
  -> api/src/v1beta1/                       # committed
```

The **commit** is the pin; the tag is only cross-checked against it. Bumping upstream means editing
`version` and `commit` in `api/Cargo.toml` *and* `MCS_API_VERSION` in `api/src/lib.rs`, then
re-vendoring and regenerating — the recipes abort on any mismatch. Renovate deliberately does not
manage this pin, because bumping it also requires regenerating the bindings.

kopium runs with its default `--schema=disabled`, so the derived CRD schema is empty: install CRDs
from `manifests/crd/*.yaml`, never via `ServiceExport::crd()` / `ServiceImport::crd()`.

## Before writing the reconciler

- `kube` and `kube-runtime` are at 4.x, well past the 0.8x/0.9x API that most kube-rs examples and
  remembered snippets use. Check the installed version's docs before writing `Controller`/`watcher`
  code.
- `./mcs-api/controllers/` is upstream's reference reconciler for these exact CRDs, and
  `./mcs-api/conformance/` is the conformance suite. Read them before designing reconciliation.
- `aqua.yaml` already pins `kind`, `helm`, `kustomize`, `kubectl`, and `containerlab`, none of them
  wired into a recipe or CI job yet. `containerlab` implies e2e is meant to exercise real
  cross-cluster networking, not two kind clusters side by side.
- `rstest` is a workspace dependency with no users yet; add `rstest.workspace = true` under
  `[dev-dependencies]` in whichever crate gets the first tests.

## Domain notes

- Upstream defines exactly two kinds, `ServiceExport` and `ServiceImport`. "ClusterSet" is a concept
  (the `clusterset.local` domain, the `ClusterSetIP` type), not a CRD.
- MCS needs a **cluster ID** — it appears in `ServiceImport.status.clusters[].cluster`, the
  `multicluster.kubernetes.io/source-cluster` label, and headless DNS names. It does *not* need the
  `about.k8s.io` `ClusterProperty` CRD: KEP-1645 lists KEP-2149 only as a graduation criterion, and
  upstream's own e2e supplies the ID from a ConfigMap.
- EndpointSlice and Service are core APIs, so they come from `k8s-openapi`.

## Conventions

- Comments and tool output are written in English, including in the justfile and workflows.
- `controller` sets `publish = false`. That is also what lets cargo-deny's `allow-wildcard-paths`
  accept its path dependency on `yukari-api`, which has no version requirement.
- `kube` is `default-features = false` at the workspace level so each crate opts into exactly the
  features it needs. A member can re-enable defaults, but cannot disable them unless the workspace
  already does.
