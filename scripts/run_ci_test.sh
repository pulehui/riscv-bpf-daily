#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/${GITHUB_REPOSITORY_OWNER}/riscv-bpf-vmtest}"

mkdir -p ccache-dir logs

docker run --rm --privileged \
    -v "${PWD}:/repo" \
    -v "${PWD}/ccache-dir:/ccache" \
    -v "${PWD}/logs:/workspace" \
    -e CCACHE_DIR=/ccache \
    "${IMAGE}:latest" \
    bash /repo/scripts/run_bpf_tests.sh \
    2>&1 | tee bpf_vmtest.stdout || true

cp logs/bpf_vmtest.log ./ 2>/dev/null || true
cp logs/bpf_error_logs.txt ./ 2>/dev/null || true

echo "::group::Runner error logs summary"
cat bpf_error_logs.txt 2>/dev/null || true
echo "::endgroup::"

rc=$(grep -E '^vmtest\.sh exit code: ' bpf_vmtest.stdout | tail -1 | awk '{print $NF}')
bpf_commit=$(grep -E '^bpf branch tested: ' bpf_vmtest.stdout | tail -1 | awk '{print $NF}')

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "bpf_commit=${bpf_commit}" >> "$GITHUB_OUTPUT"
fi

if [[ -z "${rc}" || "${rc}" != "0" ]]; then
    [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "test_status=failure" >> "$GITHUB_OUTPUT"
    exit 1
fi

[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "test_status=success" >> "$GITHUB_OUTPUT"
exit 0
