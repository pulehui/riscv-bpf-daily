#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Run the BPF selftests test_progs suite under the riscv64 vmtest, skipping
# tests listed in upstream DENYLIST.riscv64 and overrides/DENYLIST.ext.
# Intended to run *inside* the riscv-bpf-vmtest container.
#
# Usage:
#   run_bpf_tests.sh
#
# Patch search order:
#   1. overrides/patches/*.patch (environment/pre-test overrides)
#   2. patches/*.patch           (target patchset under test)
#
# Outputs:
#   /workspace/bpf_vmtest.log   full vmtest + test_progs output
#   stdout                      a trimmed summary (tail) used for issue bodies
#
# Exit code:
#   0  if test_progs reports success
#   1  if test_progs reports failures (or any setup step failed)

set -euo pipefail

BPF_URL="https://git.kernel.org/pub/scm/linux/kernel/git/bpf/bpf-next.git"
BPF_BRANCH="master"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OVERRIDES_DIR="${REPO_DIR}/overrides"
OVERRIDES_PATCHES_DIR="${OVERRIDES_DIR}/patches"
ROOT_PATCHES_DIR="${REPO_DIR}/patches"
LOCAL_DENYLIST="${OVERRIDES_DIR}/DENYLIST.ext"

# Rootfs image baked into the container by the Dockerfile.
DEFAULT_ROOTFS="$(ls /root/libbpf-vmtest-rootfs-*.tar.zst 2>/dev/null | sort -V | tail -n 1 || true)"
ROOTFS="${ROOTFS:-${DEFAULT_ROOTFS}}"
if [[ ! -f "${ROOTFS}" ]]; then
    echo "::error::Rootfs image not found at ${ROOTFS}"
    exit 1
fi

WORKSPACE="/workspace"
LOGFILE="${WORKSPACE}/bpf_vmtest.log"

mkdir -p "${WORKSPACE}"
cd "${WORKSPACE}"

# --------------------------------------------------------------------------
# 1. Fetch the bpf tree.
# --------------------------------------------------------------------------
if [[ ! -d "${WORKSPACE}/bpf/.git" ]]; then
    echo "::group::Clone bpf-next (${BPF_BRANCH})"
    git clone --depth 1 --branch "${BPF_BRANCH}" "${BPF_URL}" "${WORKSPACE}/bpf" \
        2>&1 | sed 's/^/  /'
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

# --------------------------------------------------------------------------
# 1b. Apply patches (overrides/patches first, then root patches/)
# --------------------------------------------------------------------------
apply_patch_dir() {
    local dir="$1"
    local desc="$2"
    local tag="$3"
    local marker="${WORKSPACE}/.patches-applied-${tag}"

    shopt -s nullglob
    local patches=()
    if [[ -d "${dir}" ]]; then
        patches=("${dir}"/*.patch)
    fi
    shopt -u nullglob

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

# 1. First apply overrides patches
apply_patch_dir "${OVERRIDES_PATCHES_DIR}" "overrides patches" "overrides"

# 2. Then apply root patches
apply_patch_dir "${ROOT_PATCHES_DIR}" "root patches" "root"

BPF_SHA="$(git rev-parse HEAD)"
if [[ "${BPF_SHA}" != "${BPF_BASE_SHA}" ]]; then
    echo "bpf patches applied: ${BPF_BASE_SHA:0:12} -> ${BPF_SHA:0:12}"
fi

# --------------------------------------------------------------------------
# 2. Build denylist by merging upstream and overrides/DENYLIST.ext
# --------------------------------------------------------------------------
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

echo "::group::Merged Denylist"
echo "${DENYLIST}"
echo "::endgroup::"

# --------------------------------------------------------------------------
# 2b. Reset ccache stats
# --------------------------------------------------------------------------
if command -v ccache > /dev/null 2>&1; then
    ccache -z > /dev/null 2>&1 || true
fi

# --------------------------------------------------------------------------
# 3. Run the tests.
# --------------------------------------------------------------------------
echo "::group::vmtest test_progs"
set +e
PLATFORM=riscv64 CROSS_COMPILE=riscv64-linux-gnu- \
    tools/testing/selftests/bpf/vmtest.sh \
        -l "${ROOTFS}" -- \
        ./test_progs -a mmap -w 0 ${DENYLIST:+-d "${DENYLIST}"} \
    2>&1 | tee "${LOGFILE}"
TEST_RC="${PIPESTATUS[0]}"
echo "::endgroup::"

# --------------------------------------------------------------------------
# 4. Emit focused error logs.
# --------------------------------------------------------------------------
ERRORLOGS="${WORKSPACE}/bpf_error_logs.txt"
awk '/^[[:space:]]*All error logs:/{p=1} p' "${LOGFILE}" > "${ERRORLOGS}" || true
if [[ -s "${ERRORLOGS}" ]] && (( $(wc -l < "${ERRORLOGS}") > 250 )); then
    head -n 250 "${ERRORLOGS}" > "${ERRORLOGS}.tmp"
    echo -e "\n... [Logs truncated. See bpf_vmtest-log artifact for full output] ..." >> "${ERRORLOGS}.tmp"
    mv "${ERRORLOGS}.tmp" "${ERRORLOGS}"
fi

echo "===== error logs ====="
cat "${ERRORLOGS}"
echo "===== end error logs ====="
echo "bpf branch tested: ${BPF_BRANCH} @ ${BPF_SHA}"
echo "vmtest.sh exit code: ${TEST_RC}"

if command -v ccache > /dev/null 2>&1; then
    echo "::group::ccache stats"
    ccache -s || true
    echo "::endgroup::"
fi

exit "${TEST_RC}"
