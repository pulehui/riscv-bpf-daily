# riscv-bpf-daily

Daily-ish RISC-V BPF selftests runner. It builds the vmtest container image,
clones [`kernel-patches/bpf`](https://github.com/kernel-patches/bpf), and runs
the `test_progs` suite for `riscv64` under QEMU — skipping every test listed
in `tools/testing/selftests/bpf/DENYLIST.riscv64`.

## Layout

```
Dockerfile.riscv-bpf-vmtest          # the vmtest image (Ubuntu + llvm-21, qemu 11.1, pahole, rootfs)
image/                               # the riscv64 rootfs tarball, COPYed into the image
scripts/run_bpf_tests.sh             # in-container test runner
.github/workflows/riscv-bpf-daily.yml# the GitHub Action
```

## The workflow

`.github/workflows/riscv-bpf-daily.yml` is **manually triggered**
(`workflow_dispatch`, the "Run workflow" button in the Actions tab). It has an
optional input `bpf_ref` (default `bpf-next`) to choose which `kernel-patches/bpf`
ref to test.

Steps:

1. **Build & push the image** to `ghcr.io/<owner>/riscv-bpf-vmtest:latest` (also
   tagged with the commit SHA), using the GitHub Actions Docker cache
   (`cache-from/cache-to: type=gha, mode=max`). Unchanged layers — the qemu
   build, pahole, and the 36 MB rootfs `COPY` — are reused across runs, so the
   image is rebuilt only when the `Dockerfile` or its build context actually
   changes.
2. **Run the tests** inside the image: `scripts/run_bpf_tests.sh` clones
   `kernel-patches/bpf` into `/workspace` (shallow, `--depth 1`), records the
   exact tested commit, builds the riscv64 denylist, and invokes
   `vmtest.sh … -- ./test_progs -w 0 -d <denylist>`. On failure it extracts the
   `All error logs:` block into `/workspace/bpf_error_logs.txt`.
3. **Upload the logs** as the `bpf_vmtest-log` artifact (30-day retention):
   `bpf_vmtest.stdout`, `bpf_vmtest.log`, and `bpf_error_logs.txt`.
4. **On failure**, create a new GitHub issue titled
   `Daily failed at <YYYY-MM-DD> commit <12-char bpf SHA>` (date in +08:00). The
   issue body is structured Markdown: run link, `bpf tested @<sha>` link, repo
   commit, then the `All error logs:` block (falling back to the stdout tail if
   that block is absent). Each failing bpf version gets its own issue. On
   success, nothing happens.

## Running locally

Build and run the image directly:

```bash
docker build -f Dockerfile.riscv-bpf-vmtest -t riscv-bpf-vmtest .
docker run --rm -v "$PWD:/repo" riscv-bpf-vmtest bash /repo/scripts/run_bpf_tests.sh bpf-next
# full log -> /workspace/bpf_vmtest.log ; error logs -> /workspace/bpf_error_logs.txt
```

## Notes

- **Rootfs path coupling.** The rootfs file is date-stamped
  (`image/libbpf-vmtest-rootfs-2026.08.17-resolute-riscv64.tar.zst`). Both the
  `COPY` line in `Dockerfile.riscv-bpf-vmtest` and the `ROOTFS` variable in
  `scripts/run_bpf_tests.sh` reference that name — update them together if you
  refresh the rootfs.
- The container builds `qemu 11.1.0` from source for `riscv64-softmmu`; the
  runner is `amd64` and qemu user/system emulation is what runs the riscv64
  guest.
