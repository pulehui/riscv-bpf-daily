#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Run the BPF selftests test_progs suite under the riscv64 vmtest, skipping
# every test listed in DENYLIST.riscv64. Intended to run *inside* the
# riscv-bpf-vmtest container (see Dockerfile.riscv-bpf-vmtest).
#
# Usage:
#   run_bpf_tests.sh [BPF_REF] [PATCHES_DIR]
#
#   BPF_REF      - git ref/branch of github.com/kernel-patches/bpf to clone
#                  (default: bpf-next, the repo's default branch)
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

BPF_REF="${1:-bpf-next}"
BPF_URL="https://github.com/kernel-patches/bpf"

# Patches live in this repo (mounted at /repo in the container). Derive the
# location from the script itself so no mount point is hard-coded.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_DIR="${2:-${SCRIPT_DIR}/../patches}"

# Rootfs image baked into the container by the Dockerfile (COPY image/... /root).
ROOTFS="/root/libbpf-vmtest-rootfs-2026.08.17-resolute-riscv64.tar.zst"

WORKSPACE="/workspace"
LOGFILE="${WORKSPACE}/bpf_vmtest.log"

mkdir -p "${WORKSPACE}"
cd "${WORKSPACE}"

# --------------------------------------------------------------------------
# 1. Fetch the bpf tree.
# --------------------------------------------------------------------------
if [[ ! -d bpf/.git ]]; then
    echo "::group::Clone kernel-patches/bpf (${BPF_REF})"
    git clone --depth 1 --branch "${BPF_REF}" "${BPF_URL}" "${WORKSPACE}/bpf" \
        2>&1 | sed 's/^/  /'
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
    git -c user.name="riscv-bpf-daily" -c user.email="riscv-bpf-daily@users.noreply.github.com" \
        am --3way "${PATCH_FILES[@]}" 2>&1 | sed 's/^/  /'
    echo "::endgroup::"
    if (( PIPESTATUS[0] != 0 )); then
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
#    Mirrors the exact pipeline specified for the daily run:
#      - strip inline comments (cut -d'#' -f1)
#      - trim leading/trailing whitespace per line
#      - collapse to single commas, joining lines
#    An empty denylist is fine (no skips).
# --------------------------------------------------------------------------
DENYLIST_FILE="tools/testing/selftests/bpf/DENYLIST.riscv64"
DENYLIST="$(cut -d'#' -f1 "${DENYLIST_FILE}" \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | tr -s '\n' ',' \
    | sed -e 's/^,//' -e 's/,$//')"

echo "::group::Denylist"
echo "${DENYLIST}"
echo "::endgroup::"

# --------------------------------------------------------------------------
# 3. Run the tests. vmtest.sh builds the kernel + selftests and boots qemu,
#    then runs the command after `--` inside the guest. Capture everything.
#
#    Do NOT let set -e abort here: we want the issue step to see the log.
# --------------------------------------------------------------------------
echo "::group::vmtest test_progs"
set +e
PLATFORM=riscv64 CROSS_COMPILE=riscv64-linux-gnu- \
    tools/testing/selftests/bpf/vmtest.sh \
        -l "${ROOTFS}" -- \
        ./test_progs -w 0 -d "${DENYLIST}" \
    2>&1 | tee "${LOGFILE}"
TEST_RC="${PIPESTATUS[0]}"
echo "::endgroup::"

# --------------------------------------------------------------------------
# 4. Emit the focused error logs to stdout and a side file.
#
#    On failure test_progs prints a trailing "All error logs:" block that
#    replays each failed case's captured output. Extract that whole block
#    (from the "All error logs:" line to EOF) into bpf_error_logs.txt so the
#    GitHub issue body can paste the focused failures instead of a crude tail
#    of the raw stdout. If the marker is missing (e.g. test_progs crashed
#    before summarizing) the file is empty and the workflow falls back to the
#    stdout tail.
# --------------------------------------------------------------------------
ERRORLOGS="${WORKSPACE}/bpf_error_logs.txt"
awk '/^[[:space:]]*All error logs:/{p=1} p' "${LOGFILE}" > "${ERRORLOGS}" || true

echo "===== error logs ====="
cat "${ERRORLOGS}"
echo "===== end error logs ====="
echo "bpf ref tested: ${BPF_REF} @ ${BPF_SHA}"
echo "vmtest.sh exit code: ${TEST_RC}"

exit "${TEST_RC}"
