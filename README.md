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
optional input `bpf_ref` (default `master`) to choose which `kernel-patches/bpf`
ref to test.

Steps:

1. **Build & push the image** to `ghcr.io/<owner>/riscv-bpf-vmtest:latest` (also
   tagged with the commit SHA), using the GitHub Actions Docker cache
   (`cache-from/cache-to: type=gha, mode=max`). Unchanged layers — the qemu
   build, pahole, and the 36 MB rootfs `COPY` — are reused across runs, so the
   image is rebuilt only when the `Dockerfile` or its build context actually
   changes.
2. **Run the tests** inside the image: `scripts/run_bpf_tests.sh` clones
   `kernel-patches/bpf` into `/workspace`, builds the riscv64 denylist, and
   invokes `vmtest.sh … -- ./test_progs -w 0 -d <denylist>`.
3. **Upload the log** as the `bpf_vmtest-log` artifact (30-day retention).
4. **On failure**, comment on (or create) the tracking issue titled
   `BPF vmtest failure (riscv64) — daily`, with the `test_progs` summary tail
   and a link to the run. On success, nothing happens.

## Running locally

Build and run the image directly:

```bash
docker build -f Dockerfile.riscv-bpf-vmtest -t riscv-bpf-vmtest .
docker run --rm -v "$PWD:/repo" riscv-bpf-vmtest bash /repo/scripts/run_bpf_tests.sh master
# full log lands at /workspace/bpf_vmtest.log inside the container
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
