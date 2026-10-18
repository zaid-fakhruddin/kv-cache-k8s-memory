# GPU: pinned host memory accounting (NOT YET RUN)

Nothing in this directory has been executed. There are no results yet.

`demos/02-pinned-vs-limit` uses `mlock` as a stand-in for CUDA pinning. This
kit checks the real thing on a single-GPU Linux VM: does host memory pinned
through CUDA count against a cgroup memory limit?

`run.sh` runs `probe.py` three times, each in its own transient systemd scope
with `MemoryMax=2G` and swap off. Each run allocates 512 MiB at a time, up to
3 GiB, and prints `memory.current`, the `anon`, `shmem`, `unevictable` and
`kernel` lines of `memory.stat`, and the `nvidia-smi` driver version after
every step.

| Mode | Allocation |
|---|---|
| plain | `torch.empty(n)` (pageable) |
| pinned | `torch.empty(n, pin_memory=True)` |
| register | `torch.empty(n)` then `torch.cuda.cudart().cudaHostRegister` |

Requirements: root, cgroup v2, systemd, an NVIDIA driver, Python 3. The only
thing it installs is `pip install torch`, and only if torch is missing.

```
sudo ./run.sh                  # writes result-<host>-<time>.txt here
LIMIT=4G STEPS=10 sudo ./run.sh
```

Notes for reading the output:
- The CUDA context itself uses host memory. The probe reports counters before
  and after CUDA init so step 1 is not blamed for it.
- PyTorch's pinned allocator rounds sizes up to a power of two. 512 MiB is
  already one, so each step should be exactly 512 MiB.
- Charging can depend on the driver branch. Record the driver version with
  every result.
