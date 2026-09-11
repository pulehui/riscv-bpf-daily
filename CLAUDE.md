# CLAUDE.md

Guidance for Claude (and any AI) working in this repo. This project is
developed AI-first (vibe coding) — most code is written with Claude's help,
so follow the conventions below.

## Project

`riscv-bpf-daily` — a RISC-V BPF selftests daily runner. It builds a vmtest
container image, clones [`kernel-patches/bpf`](https://github.com/kernel-patches/bpf),
and runs the `test_progs` suite for `riscv64` under QEMU, skipping tests
listed in `tools/testing/selftests/bpf/DENYLIST.riscv64`.

Layout:

- `Dockerfile.riscv-bpf-vmtest` — the vmtest image (Ubuntu + llvm-21, qemu 11.1, pahole, rootfs).
- `image/` — the riscv64 rootfs tarball, `COPY`ed into the image.
- `scripts/run_bpf_tests.sh` — in-container test runner.
- `patches/` — git format-patch files `git am`-ed onto the bpf tree after
  clone (see `patches/README.md`).
- `.github/workflows/riscv-bpf-daily.yml` — the GitHub Action (manual trigger).

## Language

- All code-facing text is in **English**: commit messages, code comments, PR
  descriptions, issue bodies, workflow `run:` logs, and documentation files
  (including this one). Conversation with the user can be in whatever language
  the user uses.

## Workflow

- One logical subtask per commit — don't bundle unrelated changes. Write a
  clear commit message body explaining *why*, not just *what*.
- Conventional Commits prefixes: `feat:` / `fix:` / `chore:` / `docs:` / `refactor:`.
- Commit/push only when asked. If on the default branch (`main`), branch first
  unless told otherwise.
- Every commit is signed by default. Add both trailers to the commit
  message body (blank line before them):
  ```
  Signed-off-by: Pu Lehui <pulehui@gmail.com>
  Co-Authored-By: Claude <noreply@anthropic.com>
  ```
  Skip a trailer only if the user explicitly opts out for that commit.

## Directory & file conventions

- The rootfs under `image/` is date-stamped (e.g.
  `libbpf-vmtest-rootfs-2026.08.17-resolute-riscv64.tar.zst`). When refreshing
  it, update **both** the `COPY` line in `Dockerfile.riscv-bpf-vmtest` and the
  `ROOTFS` variable in `scripts/run_bpf_tests.sh` — they must stay in sync.
- `.semcode.db/` is a local index database — **never commit it** (already in
  `.gitignore`).
- `/workspace/` is the in-container bind-mount source-tree dir; don't commit
  it locally.
- The rootfs is a large binary committed as a plain file (no LFS).

## Build & run

```bash
# Build the image
docker build -f Dockerfile.riscv-bpf-vmtest -t riscv-bpf-vmtest .

# Run the tests locally (full log -> container /workspace/bpf_vmtest.log)
docker run --rm -v "$PWD:/repo" riscv-bpf-vmtest bash /repo/scripts/run_bpf_tests.sh master
```

Remote: Actions → **riscv-bpf-daily** → **Run workflow** (optional `bpf_ref`
input selects the `kernel-patches/bpf` ref; default `master`).

## Code style

- Shell scripts use `set -euo pipefail`; pass `bash -n` before committing.
  Put complex commands in a script rather than cramming them into a YAML `run:`
  block.
- After editing a workflow YAML, validate syntax (Python `yaml.safe_load` or
  `actionlint` if available).

## Environment notes

- The dev environment has **no outbound network** to `github.com` /
  `raw.githubusercontent.com` via WebFetch. To inspect upstream content, use
  `git clone` (locally or inside the container) rather than WebFetch.
- `gh` CLI is **not installed** locally. GitHub issue/PR operations on the
  runner use `actions/github-script` + the automatic `GITHUB_TOKEN`.
