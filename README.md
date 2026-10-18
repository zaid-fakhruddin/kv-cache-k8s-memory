# kv-cache-k8s-memory

vLLM CPU KV offload on Kubernetes. How much pod memory it takes, when it actually helps, and what breaks.

Everything here was run on one rented A100 (Lambda, 1x A100-SXM4-40GB, driver 580.105.08 open module, kernel 6.8) with
vLLM 0.32.0 and Qwen3-8B, mostly in k3s v1.36.5 pods. The no-GPU demos run on kind.

## Results

Returning 17.4k-token request after it was pushed out of GPU memory, k3s pod, limit 32Gi, /dev/shm emptyDir 24Gi:

| host tier | pod memory.current | return TTFT | loaded from host |
|---|---|---|---|
| off | 2.9 GiB | ~1.7 s | - |
| 8 GiB | 11.1 GiB | ~1.7 s | 0 |
| 12 GiB | 15.3 GiB | ~1.7 s | 0 |
| 16 GiB | 19.4 GiB | 1.1 s once, then ~1.7 s | partial once |
| 20 GiB | 23.5 GiB | 221-254 ms | 2.65 GB |

That's with ~116k tokens of other traffic between turns. Traffic sweep with a restore-blocked control
(`kv_transfer_params.max_load_tokens=0`), see `gpu/a100-2026-10-18/traffic_sweep.csv`:

- 20 GiB: 210-235 ms up to ~116k tokens between turns, blocked control 1.73 s. Gone by ~160k.
- 12 GiB: ~220 ms at ~38k, partial at ~78k, gone by ~116k.

Other stuff we saw:

- The whole tier is charged at startup as shmem. kubelet pod rssBytes 2346 MiB vs workingSet 23037 MiB at 20 GiB.
- `vllm:kv_offload_cpu_cache_usage_perc` only counts in-flight transfers. Read 0.0-0.04 with 20 GiB charged.
- Limit below tier + ~3 GiB: OOMKilled at boot (137). /dev/shm below tier: `Insufficient space in /dev/shm` at boot.
- CUDA pinned host memory (cudaHostAlloc, cudaHostRegister, shm + register) is charged to the cgroup on this driver. Shows as shmem, not anon.
- vllm#57303 (TieringOffloadingSpec) reproduced in a pod: leftover 8 GiB file survives a container restart in the emptyDir,
  pod sits at 9.5 GiB while the new container reads 1.2 GiB, 5 restarts ending in `Insufficient space in /dev/shm`.
- Mixed open-loop load (`mixed_workload.jsonl`) was overloaded at that arrival rate, so all TTFTs are queueing. 20 GiB was ~3 s better at p50 for every request type. Not a production number.

## Layout

- `demos/` kind demos, no GPU. Each has a `run.sh` and the `RESULT.txt` from our run.
- `gpu/a100-2026-10-18/` scripts, pod template and raw results from the A100. `RESULT-*.md` has the writeups.
- `docs/ISSUES.md` related upstream issues.

## Caveats

One node, one model, synthetic random-word prompts, 3 reps per point, single client except the mixed run.
Cold prefill itself varied between ~1.04 s and ~1.74 s across reps, so compare within a rep. Not tested: LMCache, other drivers,
other engines. Numbers will move with versions.

Apache-2.0.
