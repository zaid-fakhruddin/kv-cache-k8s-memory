# Test 2: returning-conversation TTFT, GPU hit vs restore from host RAM vs recompute (2026-10-18)

Node: Lambda 1x A100-SXM4-40GB, driver 580.105.08 (open), kernel 6.8.0-1046-nvidia. Engine: `vllm/vllm-openai:v0.32.0`,
Qwen/Qwen3-8B bf16, `--max-model-len 32768 --num-gpu-blocks-override 2304 --gpu-memory-utilization 0.85 --enable-prefix-caching`.
Docker container (cgroup v2), no memory limit for this test, `--shm-size 32g`, `--ipc=private`.
Restore arm adds `--kv-offloading-size 20 --kv-offloading-backend native` (CPUOffloadingSpec).
Method (`bench.py`): send context C (cold prefill), send C again (GPU prefix hit), then push C out of the GPU cache with
~40k words of unrelated prompts, then send C again ("return"). TTFT = time to first streamed token, max_tokens=1, single client,
no concurrency. 5 reps per length. Medians below (ms).

| Prompt tokens | GPU hit | Return, recompute arm | Return, restore arm | Restore speedup vs recompute |
|---|---|---|---|---|
| ~1,460 | 24.5 | 109.2 (108.6–109.9) | 38.7 (38.4–39.6) | 2.8x |
| ~5,800 | 37–38 | 455.2 (454.6–457.0) | 80.1 (79.0–87.7) | 5.7x |
| ~17,400 | 68–71 | 1680.5 (1679.9–1685.3) | 201.6 (191.4–208.7) | 8.3x |

Recompute-arm "return" equals cold prefill at every length, so the eviction step really emptied the GPU cache.

## Memory (container cgroup, restore arm, offload 20 GiB)
- Right after startup, before any traffic: `memory.current=23495MiB` = anon 2758 MiB + **shmem 20530 MiB**.
  The full offload size is charged at boot (vLLM touches every page), not as the cache fills.
- After the benchmark: 23514 MiB. oom_kill 0.
- Recompute arm after start: 2898 MiB (anon 2729, shmem 50).
- vLLM's own `vllm:kv_offload_cpu_cache_usage_perc` read **0.042** (4%) at the end while 20.5 GiB was charged to the cgroup,
  and `kv_offload_store_bytes` had reached 15.1 GB. The usage gauge is not a capacity/occupancy number for platform alerts.
- One restore of 2.57 GB took 0.111 s (`kv_offload_load_*`), about 23 GB/s host-to-device.

## Caveats
Single client, no concurrent load, one model, synthetic random-word prompts, one node. Speedups will shrink under concurrent
restores sharing PCIe. Docker cgroup, not yet a kubelet-managed pod.
