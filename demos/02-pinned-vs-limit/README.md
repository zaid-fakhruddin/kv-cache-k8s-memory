# 02: locked host memory vs the pod limit

`lock.py` maps host memory in 128 MiB chunks, optionally `mlock`s each chunk,
and writes to every page. It prints the container cgroup counters after each
chunk. Four pods run it with a 512 MiB limit (Guaranteed QoS):

| Pod | Mode | Mapping | Target | IPC_LOCK |
|---|---|---|---|---|
| a-plain-over | plain | shared | 768 MiB | no |
| b-lock-under | mlock | shared | 384 MiB | no |
| c-lock-over | mlock | shared | 768 MiB | yes |
| d-lock-under-priv | mlock | private | 384 MiB | no |

## What `RESULT.txt` shows

- Locked memory is charged to the pod cgroup 1:1. With 384 MiB locked,
  `memory.current` is about 390 MiB and `unevictable` is 384 MiB.
- Going over the limit is an OOMKill (exit 137), locked or not. The process
  gets no allocation error it could catch and shrink its cache for. Both
  "over" pods printed 384 MiB held and died on the next 128 MiB chunk.
- `RLIMIT_MEMLOCK` is unlimited in these pods (containerd 2.3.4), so `mlock`
  worked without `CAP_IPC_LOCK`.
- Swap is off for the pod (`memory.swap.max=0`).
- The kubelet's `rssBytes` depends on the mapping type. For the shared mapping
  (pod b) the 384 MiB shows up as `shmem`, and the kubelet reports
  `rssBytes` of about 4 MiB while `workingSetBytes` is about 390 MiB. For the
  private mapping (pod d) `rssBytes` includes it. A monitor that watches RSS
  can miss a shared-memory cache entirely.

## Limits of this demo

`mlock` is only an approximation of CUDA pinning. `cudaHostAlloc` and
`cudaHostRegister` pin pages through the NVIDIA driver, and those pages may be
charged differently. That is what `gpu/pinned-accounting/` is for, and it has
not been run yet.

## Run

```
./run.sh        # about 70 s
kubectl --context kind-kv-validate delete namespace kv-demo-pinned
```
