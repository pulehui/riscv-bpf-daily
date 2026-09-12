#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Run test_verifier under riscv64 vmtest inside the container.

set -euo pipefail

DEFAULT_ROOTFS="$(ls /root/libbpf-vmtest-rootfs-*.tar.zst 2>/dev/null | sort -V | tail -n 1 || true)"
ROOTFS="${ROOTFS:-${DEFAULT_ROOTFS}}"
if [[ ! -f "${ROOTFS}" ]]; then
    echo "::error::Rootfs image not found at ${ROOTFS}"
    exit 1
fi

WORKSPACE="/workspace"
LOGFILE="${WORKSPACE}/test_verifier.log"
ERRORLOGS="${WORKSPACE}/test_verifier_errors.txt"

cd "${WORKSPACE}/bpf"

if command -v ccache > /dev/null 2>&1; then
    ccache -z > /dev/null 2>&1 || true
fi

echo "::group::vmtest test_verifier"
set +e
PLATFORM=riscv64 CROSS_COMPILE=riscv64-linux-gnu- \
    tools/testing/selftests/bpf/vmtest.sh \
        -l "${ROOTFS}" -- \
        ./test_verifier \
    2>&1 | tee "${LOGFILE}"
TEST_RC="${PIPESTATUS[0]}"
echo "::endgroup::"

# Extract strictly from "./test_verifier" invocation down to "Summary: ..."
awk '/(^|[[:space:]]|#|\+)\.\/test_verifier/{p=1} p{print; if (/^[[:space:]]*Summary:/) exit}' "${LOGFILE}" > "${ERRORLOGS}" || true

# Fallback: if invocation line was not caught, match from first testcase #0
if [[ ! -s "${ERRORLOGS}" ]]; then
    awk '/^[[:space:]]*#[0-9]+/{p=1} p{print; if (/^[[:space:]]*Summary:/) exit}' "${LOGFILE}" > "${ERRORLOGS}" || true
fi

# Fallback: if Summary was not caught, retain full log
if [[ ! -s "${ERRORLOGS}" ]]; then
    cat "${LOGFILE}" > "${ERRORLOGS}" || true
fi

echo "===== test_verifier error logs ====="
cat "${ERRORLOGS}"
echo "===== end test_verifier error logs ====="
echo "vmtest.sh exit code: ${TEST_RC}"

if command -v ccache > /dev/null 2>&1; then
    echo "::group::ccache stats"
    ccache -s || true
    echo "::endgroup::"
fi

exit "${TEST_RC}"
