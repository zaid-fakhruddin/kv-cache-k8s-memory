# Related upstream issues

Taken from the research notes for this talk (claims ledger and re-verification
notes, checked 2026-10-16 to 2026-10-17). Only items the notes label VERIFIED
or REPORTED are listed, with the label kept.

- REPORTED: someone reported it in public. Not reproduced by us.
- VERIFIED: checked against source code or merged history at a pinned commit or tag.

| Demo | Issue / PR | Label | What it says |
|---|---|---|---|
| 01 | [vllm-project/vllm#57303](https://github.com/vllm-project/vllm/issues/57303) | REPORTED | Tiering offload spec on a Kubernetes memory emptyDir: after a hard engine kill, the next start fails the shm space check. Open as of 2026-10-18. |
| 01 | [vllm-project/vllm#52596](https://github.com/vllm-project/vllm/pull/52596) | VERIFIED | Eager unlink of the shared offload region. First in v0.29.0. Covers `CPUOffloadingSpec`; `TieringOffloadingSpec` in v0.31.0 does not pass the barrier that enables it. |
| 01 | [sgl-project/sglang#40723](https://github.com/sgl-project/sglang/issues/40723) | REPORTED | Restart loop from leaked shared-memory segments in a per-pod memory emptyDir. The leaked bytes are multimodal IPC, not KV cache. |
| 02 | [sgl-project/sglang#40135](https://github.com/sgl-project/sglang/pull/40135), [#42788](https://github.com/sgl-project/sglang/pull/42788) | VERIFIED | HiCache host-pool sizing reads cgroup `memory.max` / `memory.high` instead of host free memory. #42788 (ancestor walking) is not in stable 0.5.21. |
| 03 | [kvcache-ai/Mooncake#3467](https://github.com/kvcache-ai/Mooncake/pull/3467) | VERIFIED | Disk-cap enforcement is opt-in and does not discover a Kubernetes emptyDir size limit by itself. |

Nothing in the notes labeled VERIFIED or REPORTED is a public issue about CUDA
pinned host memory and cgroup accounting, so `gpu/pinned-accounting` has no row.
Several other OOM reports in the notes (for example the vLLM offload-size
rounding reports) are cited without one of these two labels, so they are left out.
