#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Run the BPF selftests test_progs suite under the riscv64 vmtest, skipping
# every test listed in DENYLIST.riscv64 and local overrides/DENYLIST.ext.
# Intended to run *inside* the riscv-bpf-vmtest container.
#
# Usage:
#   run_bpf_tests.sh [OVERRIDES_DIR]
#
#   OVERRIDES_DIR - directory containing local overrides:
#                   - patches/      (git format-patch files applied with git am)
#                   - DENYLIST.ext  (extra tests to skip)
#                   (default: <repo>/overrides)
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

# Derive paths from the script's location so no container mount point is hard-coded.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERRIDES_DIR="${1:-${SCRIPT_DIR}/../overrides}"
PATCHES_DIR="${OVERRIDES_DIR}/patches"
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
    echo "::endgroup::"
fi
cd "${WORKSPACE}/bpf"

BPF_BASE_SHA="$(git rev-parse HEAD)"
echo "bpf base commit: ${BPF_BASE_SHA}"

# --------------------------------------------------------------------------
# 1b. Apply local patches from overrides/patches with `git am`.
# --------------------------------------------------------------------------
MARKER="${WORKSPACE}/.patches-applied"
shopt -s nullglob
PATCH_FILES=()
if [[ -d "${PATCHES_DIR}" ]]; then
    PATCH_FILES=("${PATCHES_DIR}"/*.patch)
fi
shopt -u nullglob

if [[ -e "${MARKER}" ]]; then
    echo "patches already applied (marker ${MARKER} exists), skipping"
elif (( ${#PATCH_FILES[@]} == 0 )); then
    echo "no local patches in ${PATCHES_DIR}, nothing to apply"
else
    echo "::group::Apply local patches (${#PATCH_FILES[@]})"
    printf '%s\n' "${PATCH_FILES[@]##*/}"
    set +e
    git -c user.name="riscv-bpf-daily" -c user.email="riscv-bpf-daily@users.noreply.github.com" \
        am --3way "${PATCH_FILES[@]}" 2>&1 | sed 's/^/  /'
    AM_RC="${PIPESTATUS[0]}"
    set -e
    echo "::endgroup::"
    if (( AM_RC != 0 )); then
        git am --abort 2>/dev/null || true
        echo "::error::git am failed for patches in ${PATCHES_DIR}; rebase them and update overrides/patches/"
        exit 1
    fi
    touch "${MARKER}"
fi

BPF_SHA="$(git rev-parse HEAD)"
if [[ "${BPF_SHA}" != "${BPF_BASE_SHA}" ]]; then
    echo "bpf patches applied: ${#PATCH_FILES[@]} ${PATCH_FILES[*]##*/}"
fi

# --------------------------------------------------------------------------
# 2. Build the comma-separated denylist from upstream + overrides/DENYLIST.ext.
# --------------------------------------------------------------------------
UPSTREAM_DENYLIST="tools/testing/selftests/bpf/DENYLIST.riscv64"
DENYLIST=""

if [[ -f "${UPSTREAM_DENYLIST}" ]] || [[ -f "${LOCAL_DENYLIST}" ]]; then
    DENYLIST="$(cat "${UPSTREAM_DENYLIST}" "${LOCAL_DENYLIST}" 2>/dev/null \
        | cut -d'#' -f1 \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | grep -v '^$' \
        | sort -u \
        | tr '\n' ',' \
        | sed -e 's/^,//' -e 's/,$//')"
fi

echo "::group::Denylist"
echo "${DENYLIST}"
echo "::endgroup::"

# --------------------------------------------------------------------------
# 2b. Reset ccache stats.
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
        ./test_progs -w 0 ${DENYLIST:+-d "${DENYLIST}"} \
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
