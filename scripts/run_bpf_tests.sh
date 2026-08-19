#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Run the BPF selftests test_progs suite under the riscv64 vmtest, skipping
# every test listed in DENYLIST.riscv64. Intended to run *inside* the
# riscv-bpf-vmtest container (see Dockerfile.riscv-bpf-vmtest).
#
# Usage:
#   run_bpf_tests.sh [BPF_REF]
#
#   BPF_REF  - git ref/branch of github.com/kernel-patches/bpf to clone
#              (default: bpf-next, the repo's default branch)
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

# Record the exact commit that was tested (shallow clone => HEAD is the tip).
BPF_SHA="$(git rev-parse HEAD)"
echo "bpf_commit=${BPF_SHA}"

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
# 4. Emit a trimmed summary to stdout (used verbatim in the GitHub issue).
#    test_progs prints a "#<n> NNN,MMM ..." summary block near the end.
# --------------------------------------------------------------------------
echo "===== test_progs summary (last 200 lines) ====="
tail -n 200 "${LOGFILE}"
echo "================================================"
echo "bpf ref tested: ${BPF_REF} @ ${BPF_SHA}"
echo "vmtest.sh exit code: ${TEST_RC}"

exit "${TEST_RC}"
