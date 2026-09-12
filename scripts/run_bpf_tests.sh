#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Run the BPF selftests test_progs suite under the riscv64 vmtest, skipping
# every test listed in DENYLIST.riscv64. Intended to run *inside* the
# riscv-bpf-vmtest container (see Dockerfile.riscv-bpf-vmtest).
#
# Usage:
#   run_bpf_tests.sh [PATCHES_DIR]
#
#   PATCHES_DIR  - directory of git format-patch files applied with `git am`
#                  after the clone (default: <repo>/patches)
#
# Outputs:
#   /workspace/bpf_vmtest.log   full vmtest + test_progs output
#   stdout                      a trimmed summary (tail) used for issue bodies
#
# Exit code:
#   0  if test_progs reports success
#   1  if test_progs reports failures (or any setup step failed)
#
# The caller (GitHub Action) uses `if: always()` so that the issue-creation
# step still runs when this script exits non-zero.

set -euo pipefail

BPF_URL="https://git.kernel.org/pub/scm/linux/kernel/git/bpf/bpf-next.git"
BPF_BRANCH="master"

# Patches live in this repo (mounted at /repo in the container). Derive the
# location from the script itself so no mount point is hard-coded.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_DIR="${1:-${SCRIPT_DIR}/../patches}"

# Rootfs image baked into the container by the Dockerfile (COPY image/... /root).
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

# Record the exact commit that was cloned (shallow clone => HEAD is the tip).
BPF_BASE_SHA="$(git rev-parse HEAD)"
echo "bpf base commit: ${BPF_BASE_SHA}"

# --------------------------------------------------------------------------
# 1b. Apply local patches from PATCHES_DIR with `git am`.
#
#     Patches are git format-patch files applied in filename order on top of
#     the freshly cloned tree (see patches/README.md). A marker file keeps a
#     reused clone from being patched twice. If any patch fails to apply the
#     whole run aborts: testing an unpatched tree would be misleading.
# --------------------------------------------------------------------------
MARKER="${WORKSPACE}/.patches-applied"
shopt -s nullglob
PATCH_FILES=("${PATCHES_DIR}"/*.patch)
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
        echo "::error::git am failed for patches in ${PATCHES_DIR}; rebase them and update patches/"
        exit 1
    fi
    touch "${MARKER}"
fi

BPF_SHA="$(git rev-parse HEAD)"
if [[ "${BPF_SHA}" != "${BPF_BASE_SHA}" ]]; then
    echo "bpf patches applied: ${#PATCH_FILES[@]} ${PATCH_FILES[*]##*/}"
fi

# --------------------------------------------------------------------------
# 2. Build the comma-separated denylist from DENYLIST.riscv64.
#
#     Mirrors the exact pipeline specified for the daily run:
#       - strip inline comments (cut -d'#' -f1)
#       - trim leading/trailing whitespace per line
#       - collapse to single commas, joining lines
#     An empty denylist is fine (no skips).
# --------------------------------------------------------------------------
DENYLIST_FILE="tools/testing/selftests/bpf/DENYLIST.riscv64"
DENYLIST=""
if [[ -f "${DENYLIST_FILE}" ]]; then
    DENYLIST="$(cut -d'#' -f1 "${DENYLIST_FILE}" \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | grep -v '^$' \
        | tr '\n' ',' \
        | sed -e 's/^,//' -e 's/,$//')"
fi

echo "::group::Denylist"
echo "${DENYLIST}"
echo "::endgroup::"

# --------------------------------------------------------------------------
# 2b. Reset ccache stats so the run's hit/miss numbers below are clean.
#     Builds go through ccache via compiler symlinks baked into the image
#     (see Dockerfile.riscv-bpf-vmtest); the cache dir itself may be a
#     mounted volume persisted by the workflow.
# --------------------------------------------------------------------------
if command -v ccache > /dev/null 2>&1; then
    ccache -z > /dev/null 2>&1 || true
fi

# --------------------------------------------------------------------------
# 3. Run the tests. vmtest.sh builds the kernel + selftests and boots qemu,
#     then runs the command after `--` inside the guest. Capture everything.
#
#     Do NOT let set -e abort here: we want the issue step to see the log.
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
# 4. Emit the focused error logs to stdout and a side file.
#
#     On failure test_progs prints a trailing "All error logs:" block that
#     replays each failed case's captured output. Extract that whole block
#     (from the "All error logs:" line to EOF) into bpf_error_logs.txt so the
#     GitHub issue body can paste the focused failures instead of a crude tail
#     of the raw stdout. If the marker is missing (e.g. test_progs crashed
#     before summarizing) the file is empty and the workflow falls back to the
#     stdout tail.
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

# Show this run's compile-cache outcome (hits saved real riscv64 work).
if command -v ccache > /dev/null 2>&1; then
    echo "::group::ccache stats"
    ccache -s || true
    echo "::endgroup::"
fi

exit "${TEST_RC}"
