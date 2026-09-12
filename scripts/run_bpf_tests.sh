#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${SCRIPT_DIR}/setup_bpf.sh"
bash "${SCRIPT_DIR}/run_test_progs.sh"
bash "${SCRIPT_DIR}/run_test_verifier.sh"
