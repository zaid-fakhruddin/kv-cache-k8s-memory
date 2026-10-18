# Test 1: is CUDA-pinned host memory charged to the cgroup memory limit? (2026-10-18)

Hardware: Lambda gpu_1x_a100_sxm4, NVIDIA A100-SXM4-40GB, driver 580.105.08 (NVIDIA UNIX **Open** Kernel Module),
kernel 6.8.0-1046-nvidia, Ubuntu 22.04, cgroup v2, torch 2.7.0 / CUDA 12.8.
Method: each mode runs in its own transient systemd scope, `MemoryMax=4G`, `MemorySwapMax=0`, and tries to hold 6 GiB
in 1 GiB steps. Script: scratch `pinned.py` / `run_pinned.sh` (to be copied into the demo repo).

| Mode | How the 1 GiB steps are allocated | Shows up in memory.stat as | At 3 GiB held: memory.current | Result at the 4G limit |
|---|---|---|---|---|
| plain | `torch.ones` (pageable) | anon | 3376 MiB (anon 3352) | OOM-killed, exit 137 |
| pin | `torch.empty(pin_memory=True)` (cudaHostAlloc) | **shmem / file** (anon flat at 280) | 3384 MiB (shmem 3082) | OOM-killed, exit 137 |
| register | `torch.ones` + `cudaHostRegister` | anon | 3376 MiB (anon 3352) | OOM-killed, exit 137 |
| shmreg | /dev/shm file, mmap shared, touched, `cudaHostRegister` (vLLM 0.32 native offload path) | **shmem / file** | 3380 MiB (shmem 3082) | OOM-killed, exit 137 |

Baseline (CUDA context, before allocation): ~296 MiB, anon 279.
`unevictable` stayed 0 in every mode: CUDA pinning does not put pages on the unevictable LRU here.

## Findings (VERIFIED on this node only)
1. On driver 580.105.08 (open module), every host-allocation path tested is charged 1:1 to the cgroup and hits the
   OOM killer at the limit. The "pinned memory escapes the pod limit" hypothesis is **refuted for this driver/kernel**.
2. cudaHostAlloc and the vLLM shm+register path are charged as **shmem** (counted under `file`), not anon.
   Anything that watches RSS / anon (e.g. kubelet rssBytes, `container_memory_rss`) misses the KV tier;
   `memory.current` / working set includes it.
3. Pinned pages are not reported as unevictable, but with swap off (`memory.swap.max=0`, Kubernetes NoSwap default)
   they can't be reclaimed either, so the limit is a hard wall.

Not tested: proprietary (closed) kernel module; other driver branches; behavior inside a kubelet-managed pod
(same cgroup v2 mechanism, to be repeated under k3s).
