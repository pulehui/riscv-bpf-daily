#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Setup bpf-next tree, apply patches, and generate merged denylist.
# Intended to run inside the riscv-bpf-vmtest container.

set -euo pipefail

BPF_URL="https://git.kernel.org/pub/scm/linux/kernel/git/bpf/bpf-next.git"
BPF_BRANCH="master"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OVERRIDES_DIR="${REPO_DIR}/overrides"
OVERRIDES_PATCHES_DIR="${OVERRIDES_DIR}/patches"
USER_PATCHES_DIR="${REPO_DIR}/patches"
LOCAL_DENYLIST="${OVERRIDES_DIR}/DENYLIST.ext"

WORKSPACE="/workspace"
mkdir -p "${WORKSPACE}"
cd "${WORKSPACE}"

# 1. Fetch the bpf tree.
if [[ ! -d "${WORKSPACE}/bpf/.git" ]]; then
    echo "::group::Clone bpf-next (${BPF_BRANCH})"
    git clone --depth 1 --branch "${BPF_BRANCH}" "${BPF_URL}" "${WORKSPACE}/bpf" 2>&1 | sed 's/^/  /'
    echo "::endgroup::"
else
    echo "::group::Fetch latest bpf-next (${BPF_BRANCH})"
    cd "${WORKSPACE}/bpf"
    git fetch --depth 1 origin "${BPF_BRANCH}" 2>&1 | sed 's/^/  /'
    git checkout -f FETCH_HEAD
    rm -f "${WORKSPACE}"/.patches-applied-*
    echo "::endgroup::"
fi
cd "${WORKSPACE}/bpf"

BPF_BASE_SHA="$(git rev-parse HEAD)"
echo "bpf base commit: ${BPF_BASE_SHA}"

# 1b. Apply patches (overrides/patches first, then user patches/)
apply_patch_dir() {
    local dir="$1"
    local desc="$2"
    local tag="$3"
    local marker="${WORKSPACE}/.patches-applied-${tag}"

    shopt -s nullglob
    local raw_patches=()
    if [[ -d "${dir}" ]]; then
        raw_patches=("${dir}"/*.patch)
    fi
    shopt -u nullglob

    # Filter out README or non-patch documentation files
    local patches=()
    for p in "${raw_patches[@]}"; do
        local filename="$(basename "${p}")"
        if [[ "${filename,,}" =~ ^readme ]]; then
            continue
        fi
        patches+=("${p}")
    done

    if [[ -e "${marker}" ]]; then
        echo "${desc} already applied (marker exists), skipping"
        return 0
    fi

    if (( ${#patches[@]} == 0 )); then
        echo "No ${desc} found in ${dir}, skipping"
        return 0
    fi

    echo "::group::Apply ${desc} (${#patches[@]})"
    printf '%s\n' "${patches[@]##*/}"
    set +e
    git -c user.name="riscv-bpf-daily" -c user.email="riscv-bpf-daily@users.noreply.github.com" \
        am --3way "${patches[@]}" 2>&1 | sed 's/^/  /'
    local am_rc="${PIPESTATUS[0]}"
    set -e
    echo "::endgroup::"

    if (( am_rc != 0 )); then
        git am --abort 2>/dev/null || true
        echo "::error::git am failed for ${desc} in ${dir}; please rebase or update them"
        exit 1
    fi
    touch "${marker}"
}

apply_patch_dir "${OVERRIDES_PATCHES_DIR}" "overrides patches" "overrides"
apply_patch_dir "${USER_PATCHES_DIR}" "user patches" "user"

BPF_SHA="$(git rev-parse HEAD)"
if [[ "${BPF_SHA}" != "${BPF_BASE_SHA}" ]]; then
    echo "bpf patches applied: ${BPF_BASE_SHA:0:12} -> ${BPF_SHA:0:12}"
fi
echo "bpf branch tested: ${BPF_BRANCH} @ ${BPF_SHA}"

# 2. Build denylist by merging upstream and overrides/DENYLIST.ext
UPSTREAM_DENYLIST="tools/testing/selftests/bpf/DENYLIST.riscv64"
DENYLIST=""
DENYLIST_FILES=()
[[ -f "${UPSTREAM_DENYLIST}" ]] && DENYLIST_FILES+=("${UPSTREAM_DENYLIST}")
[[ -f "${LOCAL_DENYLIST}" ]]    && DENYLIST_FILES+=("${LOCAL_DENYLIST}")

if (( ${#DENYLIST_FILES[@]} > 0 )); then
    DENYLIST="$(cat "${DENYLIST_FILES[@]}" \
        | cut -d'#' -f1 \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | grep -v '^$' \
        | sort -u \
        | tr '\n' ',' \
        | sed -e 's/^,//' -e 's/,$//')"
fi

echo "${DENYLIST}" > "${WORKSPACE}/DENYLIST.merged"
echo "::group::Merged Denylist"
echo "${DENYLIST}"
echo "::endgroup::"
