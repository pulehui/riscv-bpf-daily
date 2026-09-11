# Local patches

Git-format-patch files (`git format-patch` output) applied with `git am` on
top of the freshly cloned `kernel-patches/bpf` tree, before the vmtest builds
the kernel and runs the BPF selftests.

Conventions:

- Name files `NNNN-short-desc.patch`; they are applied in filename
  (lexicographic) order.
- Patches are applied with `git am --3way` against the tip of the ref named by
  `BPF_REF`. When upstream moves and a patch stops applying, rebase it on the
  new base and replace the file here.
- An empty `patches/` directory means no local patches: the runner skips the
  apply step entirely.
