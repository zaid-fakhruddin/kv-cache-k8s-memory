# Test 3: native offload 8 GiB under container memory limits (2026-10-18, in progress)

Same node/engine as Test 2. `--kv-offloading-size 8 --kv-offloading-backend native`, `--shm-size 12g`,
`docker --memory X --memory-swap X`. bench: 6000 words (~17.4k tokens), 3 reps, ~40k words of eviction traffic.

| Limit | Started? | memory.current after start | Return TTFT (ms) | GPU hit | Cold |
|---|---|---|---|---|---|
| 16g | yes | 11148 MiB (anon 2754, shmem 8240) | 1661.0 / 1661.4 / 1674.0 | ~73 | ~1680 |
| 12g | yes | 11153 MiB (anon 2758, shmem 8240) | 1666.7 / 1674.3 / 1668.7 | ~75 | ~1677 |

## Finding: an undersized tier silently stops paying
With a 20 GiB tier (Test 2) the returning 17.4k-token conversation took ~202 ms. With an 8 GiB tier and the same
~40k words (~116k tokens, ~16 GB of KV at ~144 KiB/token) of other traffic in between, it took ~1665 ms, the same as recompute:
the conversation had been pushed out of the host tier as well. The pod is still charged the full 8.2 GiB of shmem.
No error, no metric change a platform team would notice; TTFT just goes back to recompute.

## Finding: /dev/shm file is unlinked after mapping
`df -h /dev/shm` inside the container: `12G size, 8.0G used`. `ls -la /dev/shm`: only a 32-byte semaphore, no offload file.
vLLM 0.32 CPUOffloadingSpec unlinks the region file once all workers map it (eager unlink, PR #52596). The bytes are still
in tmpfs and still charged; tools that list files (or du-based checks) don't see them.

## More rows
| Limit | shm | Result |
|---|---|---|
| 11g (11264 MiB) | 12g | started; memory.current 11150–11163 MiB (about 100 MiB headroom); returns 1654.7 / 1678.0 / 1676.5 ms; not OOM-killed |
| 10g | 12g | **failed at startup**: docker `OOMKilled=true`, container **exit code 1** (not 137). The OOM killer hit the EngineCore subprocess; the API server then raised `RuntimeError: Engine core initialization failed`. Anything keyed on exit 137 misses it. |
| 16g | **4g** | **failed at startup**: `RuntimeError: Insufficient space in /dev/shm for CPU KV offload shared region in /dev/shm: 8190 MiB required, 4096 MiB free.` exit 1, not OOM. |

Rule of thumb on this node (INFERRED from these rows): limit must be ≥ offload size + ~3 GiB of process memory (Qwen3-8B, vLLM 0.32);
/dev/shm must be ≥ offload size (+ a little). Below either, the pod fails at boot.
