# yukari - Multi Cluster Service controller
#
# Recipe list: just --list

# Where CRD manifests are vendored to
crd_dir := "manifests/crd"
# Crate holding the MCS API bindings
api_crate := "yukari-api"
api_crate_dir := "api"
# API version to generate bindings for (the CRD storage version)
api_version := "v1beta1"
# Upstream CRD kinds to vendor, paired with the module each is generated into.
# just has no list type, so the pairs are colon-packed and split in the recipes.
mcs_crds := "serviceexports:service_export serviceimports:service_import"
# Filename prefix shared by the upstream CRD manifests
crd_prefix := "multicluster.x-k8s.io_"
# Reference clone of upstream kubernetes-sigs/mcs-api (git-ignored)
mcs_api_dir := env("MCS_API_DIR", "mcs-api")

# List the available recipes
default:
    @just --list

# --- Rust -------------------------------------------------------------------

# Build the whole workspace
build:
    cargo build --workspace

# Build the whole workspace with the release profile
build-release:
    cargo build --workspace --release

# Run the tests of the whole workspace
test:
    cargo test --workspace

# Type-check only, including test and bench targets
check:
    cargo check --workspace --all-targets

# Apply formatting
fmt:
    cargo fmt --all

# Verify that no formatting change is pending
fmt-check:
    cargo fmt --all -- --check

# Run clippy, treating warnings as errors
lint:
    cargo clippy --workspace --all-targets -- -D warnings

# Remove build artifacts
clean:
    cargo clean

# --- codegen ----------------------------------------------------------------
#
# api/Cargo.toml's [package.metadata.mcs-api] is the single source of truth for
# the upstream release the bindings are generated from. The commit recorded there
# is the actual pin: tags are mutable, so they are only ever used to cross-check
# that the pin still refers to the release it claims.

# Print the pinned upstream mcs-api release and commit
#
# This stays a recipe rather than a backtick variable on purpose: just evaluates
# backtick assignments on every invocation, which would run cargo metadata even
# for `just build`.
mcs-api-pin:
    #!/usr/bin/env bash
    set -euo pipefail
    pin="$(cargo metadata --format-version 1 --no-deps \
        | jq -r '.packages[] | select(.name == "{{ api_crate }}") | .metadata."mcs-api" | "\(.version) \(.commit)"')"
    case "${pin}" in
        *null*|" "|"")
            echo "error: [package.metadata.mcs-api] in {{ api_crate_dir }}/Cargo.toml must set both version and commit" >&2
            exit 1
            ;;
    esac
    echo "${pin}"

# Vendor the CRD manifests of the pinned commit from the upstream clone
vendor-crd:
    #!/usr/bin/env bash
    set -euo pipefail
    read -r version commit <<<"$(just mcs-api-pin)"
    if [ ! -d "{{ mcs_api_dir }}/.git" ]; then
        echo "error: no upstream clone at {{ mcs_api_dir }}:" >&2
        echo "  git clone https://github.com/kubernetes-sigs/mcs-api {{ mcs_api_dir }}" >&2
        exit 1
    fi
    if ! git -C "{{ mcs_api_dir }}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
        # Fetch only when the pinned commit is missing locally, so the common case
        # stays offline. Tolerate a failing fetch so that an unreachable remote is
        # reported as a missing commit rather than as git's own transport error.
        git -C "{{ mcs_api_dir }}" fetch --tags --force || true
        if ! git -C "{{ mcs_api_dir }}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
            echo "error: pinned commit ${commit} is not in {{ mcs_api_dir }}" >&2
            exit 1
        fi
    fi
    # The tag must still resolve to the pinned commit. A mismatch means either
    # upstream moved the tag or the pin is stale; both need a deliberate update
    # of [package.metadata.mcs-api] rather than a silent content change.
    tagged="$(git -C "{{ mcs_api_dir }}" rev-parse --verify --quiet "refs/tags/${version}^{commit}" || true)"
    if [ -z "${tagged}" ]; then
        echo "error: tag ${version} does not exist in {{ mcs_api_dir }}" >&2
        exit 1
    fi
    if [ "${tagged}" != "${commit}" ]; then
        echo "error: tag ${version} points at ${tagged}, but the pin is ${commit}" >&2
        echo "  update [package.metadata.mcs-api] in {{ api_crate_dir }}/Cargo.toml if this is intended" >&2
        exit 1
    fi
    mkdir -p "{{ crd_dir }}"
    for entry in {{ mcs_crds }}; do
        file="{{ crd_prefix }}${entry%%:*}.yaml"
        # Read from the pinned commit, not from the tag, and without touching the
        # clone's working tree
        {
            echo "# Vendored from kubernetes-sigs/mcs-api ${version} (${commit})"
            echo "# Do not edit; regenerate with: just vendor-crd"
            git -C "{{ mcs_api_dir }}" show "${commit}:config/crd/${file}"
        } > "{{ crd_dir }}/${file}"
    done
    echo "vendored CRD manifests from mcs-api ${version} (${commit}) into {{ crd_dir }}/"

# Generate the Rust bindings from the vendored CRD manifests with kopium
generate:
    #!/usr/bin/env bash
    set -euo pipefail
    read -r version commit <<<"$(just mcs-api-pin)"
    lib="{{ api_crate_dir }}/src/lib.rs"
    out="{{ api_crate_dir }}/src/{{ api_version }}"
    # ${lib} restates the pinned release for runtime use, so it has to move with
    # the pin
    if ! grep -q "MCS_API_VERSION.*\"${version}\"" "${lib}"; then
        echo "error: MCS_API_VERSION in ${lib} does not match the pinned ${version}" >&2
        exit 1
    fi
    # Resolve and validate every manifest before writing anything, so a rejected
    # manifest cannot leave a half-generated module directory behind. Only
    # manifests carrying the pinned commit are accepted, which keeps the bindings
    # from silently drifting from [package.metadata.mcs-api].
    jobs=()
    for entry in {{ mcs_crds }}; do
        manifest="{{ crd_dir }}/{{ crd_prefix }}${entry%%:*}.yaml"
        if [ ! -f "${manifest}" ]; then
            echo "error: ${manifest} is missing; run 'just vendor-crd'" >&2
            exit 1
        fi
        if ! head -n 2 "${manifest}" | grep -q "${commit}"; then
            echo "error: ${manifest} was not vendored from ${version} (${commit}); run 'just vendor-crd'" >&2
            exit 1
        fi
        jobs+=("${entry##*:} ${manifest}")
    done
    # Everything under ${out} is generated, so rebuild the directory from scratch:
    # otherwise dropping a kind leaves an orphan module that nothing references
    rm -rf "${out}"
    mkdir -p "${out}"
    for job in "${jobs[@]}"; do
        read -r module manifest <<<"${job}"
        kopium \
            --filename "${manifest}" \
            --api-version "{{ api_version }}" \
            --docs \
            --derive PartialEq \
            --derive @enum:simple=Copy \
            --derive @enum:simple=Eq \
            --derive @enum:simple=Hash \
            > "${out}/${module}.rs"
    done
    # The module index is generated as well, so that adding or removing a kind
    # cannot leave a stale mod.rs behind. kopium stamps each binding with the
    # command that produced it but knows nothing about the pin, so record the
    # upstream release here: this is the only provenance the Rust tree carries.
    {
        echo "// WARNING: generated by \`just generate\` - manual changes will be overwritten"
        echo "//! Bindings for \`multicluster.x-k8s.io/{{ api_version }}\`, generated from"
        echo "//! kubernetes-sigs/mcs-api ${version} (${commit})."
        echo
        # Every type kopium emits is prefixed with its kind, so the glob
        # re-exports cannot collide and the flat module needs no curation
        for job in "${jobs[@]}"; do
            read -r module _ <<<"${job}"
            echo "mod ${module};"
        done
        echo
        for job in "${jobs[@]}"; do
            read -r module _ <<<"${job}"
            echo "pub use ${module}::*;"
        done
    } > "${out}/mod.rs"
    cargo fmt -p {{ api_crate }}
    # ${lib} is hand-written, so fail loudly rather than leaving generated files
    # that nothing compiles: generate-check only diffs generated paths and cannot
    # see a missing module declaration.
    if ! grep -q "pub mod {{ api_version }};" "${lib}"; then
        echo "error: add 'pub mod {{ api_version }};' to ${lib}" >&2
        exit 1
    fi

# Verify that the committed generated code is up to date
generate-check: generate
    git diff --exit-code -- {{ api_crate_dir }}/src {{ crd_dir }}
