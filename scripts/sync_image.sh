#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/${GITHUB_REPOSITORY_OWNER}/riscv-bpf-vmtest}"
DOCKERFILE="components/Dockerfile.riscv-bpf-vmtest"

DOCKER_HASH=$(git hash-object "${DOCKERFILE}" | cut -c1-12)
TARGET_TAG="${IMAGE}:df-${DOCKER_HASH}"

echo "::group::Pull or build test image (${TARGET_TAG})"
if docker pull "${TARGET_TAG}"; then
    echo "Found existing image in GHCR: ${TARGET_TAG}. Tagging as latest."
    docker tag "${TARGET_TAG}" "${IMAGE}:latest"
else
    echo "Image ${TARGET_TAG} not found in GHCR. Building and pushing..."
    docker buildx build \
        --cache-from type=gha \
        --cache-to type=gha,mode=max \
        --file "./${DOCKERFILE}" \
        --tag "${TARGET_TAG}" \
        --tag "${IMAGE}:latest" \
        --push .
    echo "Pulling newly built image to local daemon..."
    docker pull "${IMAGE}:latest"
fi
echo "::endgroup::"
