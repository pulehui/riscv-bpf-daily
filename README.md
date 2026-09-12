# riscv-bpf-daily

Automated daily riscv bpf test runner tracking upstream `bpf-next`, executing `test_progs` and `test_verifier` via QEMU riscv64 TCG.

## Workflow

Runs daily on the follow schedule:

1. **Sync**: Pulls the latest `bpf-next` commit.
2. **Preprocess**: Applies custom patches (`patches/`, `overrides/`) and updates the DENYLIST.
3. **Build**: Builds the kernel and bpf selftests inside Docker.
4. **Test**: Executes `test_progs` and `test_verifier` in QEMU.
5. **Notify**: Automatically opens a GitHub Issue if any step fails.
