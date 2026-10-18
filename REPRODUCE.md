# Reproduce

What we used: Lambda `gpu_1x_a100_sxm4` (A100-SXM4-40GB), Lambda Stack Ubuntu 22.04, driver 580.105.08, kernel 6.8.0-1046-nvidia.
Any single-GPU VM with root works. About 2-3 GPU hours for everything.

All scripts live in `gpu/a100-2026-10-18/` and expect to be copied to `/home/ubuntu/kv` on the node.

```bash
mkdir -p ~/kv ~/hf && cp gpu/a100-2026-10-18/* ~/kv/ && cd ~/kv
```

## 1. Pinned host memory vs cgroup limit (no Kubernetes, ~2 min)
```bash
bash run_pinned.sh > pinned_result.txt
```
Each mode runs in a systemd scope with MemoryMax=4G and tries to hold 6 GiB. Expect OOM-kill at the limit for all four modes.

## 2. Docker: restore vs recompute, limit and /dev/shm sweep (~30 min)
```bash
sudo docker pull vllm/vllm-openai:v0.32.0
bash run_vllm.sh recompute none 0 && bash run_vllm.sh restore none 20   # writes results.jsonl
bash run_b.sh                                                            # writes runs_b.txt
```

## 3. k3s + GPU device plugin (~5 min)
```bash
bash k3s_setup.sh > k3s_setup.txt 2>&1
```
k3s v1.36.5+k3s1, NVIDIA device plugin v0.20.1 patched with `runtimeClassName: nvidia`, vLLM image imported from Docker.

## 4. Pod tests (~40 min)
```bash
bash run_k.sh      # K1 accounting + restore/recompute, K2 OOM at boot, K3 small /dev/shm -> runs_k.txt
bash run_k4.sh     # vllm#57303 kill test in a pod -> runs_k4.txt
bash run_sweep.sh  # tier 0/8/12/16/20 GiB with metric deltas -> sweep.jsonl
bash run_exp2.sh   # traffic sweep + blocked-restore control, mixed load -> exp2_traffic.jsonl, exp2_mixed.jsonl
```
Each runner waits for the previous one's done-marker, so you can start them all at once.
Pod template: `pod.yaml.tpl` (Guaranteed QoS, limit 32Gi, memory emptyDir at /dev/shm, hostNetwork, port 8001).

## How the measurement works
`bench.py` / `sweep.py` / `exp2.py`: send a ~6000-word prompt (~17.4k tokens), push it out of GPU KV with unrelated prompts
(GPU KV is pinned small with `--num-gpu-blocks-override 2304`), then send it again and time the first streamed token.
Around that last request we diff `vllm:prompt_tokens_cached_by_source_total{source="host"}` and `vllm:kv_offload_load_bytes_total`.
The control arm sends `kv_transfer_params: {max_load_tokens: 0}` on an equivalent request with the same traffic history.

Known gap: the host-cached-token delta reads 18,000 for a ~17.4k-token prompt. Not reconciled yet; latency and load-bytes are the evidence we rely on.
