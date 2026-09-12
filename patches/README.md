# User Patches

This directory contains target patches to be evaluated by the RISC-V BPF CI.

## How to use
Users can submit a **Pull Request** adding their patch(es) (`*.patch`) to this directory.

- Generate patches via `git format-patch` (e.g. `0001-feature.patch`, `0002-fix.patch`).
- Patches will be applied sequentially using `git am --3way` on top of the latest `bpf-next` master and `overrides/patches/`.
- Once your PR is created, the CI workflow will build and run the test suites on riscv64 QEMU/vmtest.
