#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

STEP="${1:-setup}"
IMAGE="${IMAGE:-ghcr.io/${GITHUB_REPOSITORY_OWNER}/riscv-bpf-vmtest}"

mkdir -p ccache-dir logs

run_container_cmd() {
    local script="$1"
    local stdout_log="$2"

    docker run --rm --privileged \
        -v "${PWD}:/repo" \
        -v "${PWD}/ccache-dir:/ccache" \
        -v "${PWD}/logs:/workspace" \
        -e CCACHE_DIR=/ccache \
        -e TEST_PROGS_ARGS="${TEST_PROGS_ARGS:-}" \
        "${IMAGE}:latest" \
        bash "/repo/scripts/${script}" \
        2>&1 | tee "${stdout_log}" || true
}

case "${STEP}" in
    setup)
        run_container_cmd "setup_bpf.sh" "setup.stdout"
        bpf_commit=$(grep -E '^bpf branch tested: ' setup.stdout | tail -1 | awk '{print $NF}')
        if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
            echo "bpf_commit=${bpf_commit}" >> "$GITHUB_OUTPUT"
        fi
        if [[ -z "${bpf_commit}" ]]; then
            echo "::error::Failed to parse bpf commit in setup"
            exit 1
        fi
        ;;
    test_verifier)
        run_container_cmd "run_test_verifier.sh" "test_verifier.stdout"
        cp logs/test_verifier.log ./ 2>/dev/null || true
        cp logs/test_verifier_errors.txt ./ 2>/dev/null || true
        rc=$(grep -E '^vmtest\.sh exit code: ' test_verifier.stdout | tail -1 | awk '{print $NF}')
        if [[ -z "${rc}" || "${rc}" != "0" ]]; then
            exit 1
        fi
        ;;
    test_progs)
        run_container_cmd "run_test_progs.sh" "test_progs.stdout"
        cp logs/test_progs.log ./ 2>/dev/null || true
        cp logs/test_progs_errors.txt ./ 2>/dev/null || true
        rc=$(grep -E '^vmtest\.sh exit code: ' test_progs.stdout | tail -1 | awk '{print $NF}')
        if [[ -z "${rc}" || "${rc}" != "0" ]]; then
            exit 1
        fi
        ;;
    *)
        echo "Unknown step: ${STEP}"
        exit 1
        ;;
esac
