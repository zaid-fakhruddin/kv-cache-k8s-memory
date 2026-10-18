# Test 4: real k3s pods (k3s v1.36.5+k3s1, NVIDIA device plugin v0.20.1, Guaranteed QoS), 2026-10-18
Same A100 / vLLM 0.32.0 / Qwen3-8B. Pod: limit=request 32Gi, cpu 8, emptyDir medium=Memory sizeLimit 24Gi at /dev/shm.

## K1: offload 20 GiB, memory accounting
pod cgroup memory.current 23487 MiB (anon 2752, shmem 20530). kubelet stats/summary pod: workingSet 23037 MiB, **rssBytes 2346 MiB**.
No-offload pod: memory.current 2917 MiB, kubelet rss 2414 MiB.
vllm:kv_offload_cpu_cache_usage_perc 0.0 at end of run while 20 GiB shmem charged (gauge = in-flight transfers only).

## K1: TTFT returning request (3 reps), restore pod vs recompute pod
~150 tok: 23.5/24.8/23.2 vs 22.5/23.1/22.9 ms (no benefit). ~445 tok: ~27 vs ~41 ms. ~1,450 tok: ~39 vs ~108 ms.
~17,400 tok restore: 199.5/195.6/208.2 ms (cold prefill ~1676 ms).
4 concurrent returns of ~5,800 tok: restore max 204 ms vs recompute max 1811 ms. (n=8 excluded: harness overflowed the tier, not verified with load counters.)

## K2: limit 20Gi with offload 20 GiB -> OOMKilled, exit 137, restartCount 1 (kubelet). Exit-1 behaviour seen in Docker does NOT occur in the pod.
## K3: limit 32Gi, emptyDir sizeLimit 8Gi, offload 20 GiB -> Failed, RuntimeError from check_shm_free_space (insufficient /dev/shm).

## K4: vllm#57303 reproduced in a pod (TieringOffloadingSpec, cpu_bytes 8 GiB, emptyDir 12Gi, restartPolicy Always)
Before kill: /dev/shm has `vllm_offload_<id>.mmap` 8587837440 bytes; pod cgroup 11167 MiB (shmem 8240).
After host SIGKILL of the container: same file still in emptyDir; new container cgroup 1224 MiB, shmem 0; **pod cgroup 9483 MiB, shmem 8190 MiB**.
Final: restartCount 5, `Error`, log: `RuntimeError: Insufficient space in /dev/shm for CPU KV offload shared region in /dev/shm: 8190 MiB required, 4098 MiB free.`

## Sweep: host-tier size vs returning 17.4k-token request, fixed limit 32Gi / shm 24Gi, ~40k words (~116k tokens) of other traffic between turns
Metric deltas measured around the returning request (vllm:prompt_tokens_cached_by_source_total{source="host"}, kv_offload_load_bytes_total).
| tier | pod memory.current | return ms (r0/r1/r2) | host cached tokens / load bytes |
|---|---|---|---|
| 0 | 2885 MiB | 1708 / 1044 / 1045 | 0 / 0 |
| 8 GiB | 11142 MiB | 1708 / 1718 / 1724 | 0 / 0 |
| 12 GiB | 15261 MiB | 1044 / 1721 / 1725 | 0 / 0 |
| 16 GiB | 19368 MiB | 1140 / 1721 / 1726 | 8496 tok, 1.25 GB / 0 / 0 |
| 20 GiB | 23488 MiB | 694 / 254 / 221 | 13648 tok 2.01 GB / 18000 tok 2.65 GB / 18000 tok 2.65 GB |
Note: cold/recompute TTFT itself varied between ~1.04 s and ~1.72 s across reps (seen in cold_ms too); compare return to cold within a rep.
