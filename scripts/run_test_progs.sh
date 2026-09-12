#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Run test_progs under riscv64 vmtest inside the container.

set -euo pipefail

DEFAULT_ROOTFS="$(ls /root/libbpf-vmtest-rootfs-*.tar.zst 2>/dev/null | sort -V | tail -n 1 || true)"
ROOTFS="${ROOTFS:-${DEFAULT_ROOTFS}}"
if [[ ! -f "${ROOTFS}" ]]; then
    echo "::error::Rootfs image not found at ${ROOTFS}"
    exit 1
fi

WORKSPACE="/workspace"
LOGFILE="${WORKSPACE}/test_progs.log"
ERRORLOGS="${WORKSPACE}/test_progs_errors.txt"
DENYLIST_FILE="${WORKSPACE}/DENYLIST.merged"

DENYLIST=""
[[ -f "${DENYLIST_FILE}" ]] && DENYLIST="$(cat "${DENYLIST_FILE}")"
PROGS_ARGS="${TEST_PROGS_ARGS:--a mmap -w 0}"

cd "${WORKSPACE}/bpf"

if command -v ccache > /dev/null 2>&1; then
    ccache -z > /dev/null 2>&1 || true
fi

echo "::group::vmtest test_progs"
set +e
PLATFORM=riscv64 CROSS_COMPILE=riscv64-linux-gnu- \
    tools/testing/selftests/bpf/vmtest.sh \
        -l "${ROOTFS}" -- \
        ./test_progs ${PROGS_ARGS} ${DENYLIST:+-d "${DENYLIST}"} \
    2>&1 | tee "${LOGFILE}"
TEST_RC="${PIPESTATUS[0]}"
echo "::endgroup::"

# Extract strictly from "All error logs:" to "Summary: ..."
awk '/^[[:space:]]*All error logs:/{p=1} p{print; if (/^[[:space:]]*Summary:/) exit}' "${LOGFILE}" > "${ERRORLOGS}" || true
if [[ -s "${ERRORLOGS}" ]] && (( $(wc -l < "${ERRORLOGS}") > 250 )); then
    head -n 250 "${ERRORLOGS}" > "${ERRORLOGS}.tmp"
    echo -e "\n... [Logs truncated] ..." >> "${ERRORLOGS}.tmp"
    mv "${ERRORLOGS}.tmp" "${ERRORLOGS}"
fi

echo "===== test_progs error logs ====="
cat "${ERRORLOGS}"
echo "===== end test_progs error logs ====="
echo "vmtest.sh exit code: ${TEST_RC}"

if command -v ccache > /dev/null 2>&1; then
    echo "::group::ccache stats"
    ccache -s || true
    echo "::endgroup::"
fi

exit "${TEST_RC}"
