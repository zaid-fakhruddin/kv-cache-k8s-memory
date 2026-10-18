#!/bin/bash
# usage: run_vllm.sh <label> <mem_limit|none> <offload_gib|0> [shm]
# Starts vLLM 0.32.0 in Docker (cgroup memory limit = what a pod limit does), waits, runs bench, records memory.
set -u
L=$1; MEM=$2; OFF=$3; SHM=${4:-32g}
IMG=vllm/vllm-openai:v0.32.0
sudo docker rm -f vllm >/dev/null 2>&1
ARGS=(--model Qwen/Qwen3-8B --max-model-len 32768 --num-gpu-blocks-override 2304 --gpu-memory-utilization 0.85 --enable-prefix-caching)
[ "$OFF" != "0" ] && ARGS+=(--kv-offloading-size "$OFF" --kv-offloading-backend native)
MEMARGS=(); [ "$MEM" != "none" ] && MEMARGS=(--memory "$MEM" --memory-swap "$MEM")
sudo docker run -d --name vllm --gpus all --ipc=private --shm-size "$SHM" "${MEMARGS[@]}" -p 8000:8000 \
  -v /home/ubuntu/hf:/root/.cache/huggingface $IMG "${ARGS[@]}" > /dev/null
echo "label=$L mem=$MEM offload=${OFF}GiB shm=$SHM"
for i in $(seq 1 180); do
  curl -sf localhost:8000/v1/models >/dev/null && break
  st=$(sudo docker inspect -f '{{.State.Status}} {{.State.OOMKilled}} {{.State.ExitCode}}' vllm 2>/dev/null)
  case "$st" in exited*) echo "SERVER EXITED: $st"; sudo docker logs vllm 2>&1 | grep -i -E "error|memory|shm|oom|insufficient" | tail -8; exit 0;; esac
  sleep 5
done
CID=$(sudo docker inspect -f '{{.Id}}' vllm); CG=/sys/fs/cgroup/system.slice/docker-$CID.scope
mem() { echo "$1 memory.current=$(( $(cat $CG/memory.current) >> 20 ))MiB $(awk '$1~/^(anon|shmem|file|unevictable)$/{printf "%s=%dMiB ",$1,$2/1048576}' $CG/memory.stat) $(grep oom_kill $CG/memory.events | tr '\n' ' ')"; }
mem "after-start"
python3 /home/ubuntu/kv/bench.py --label "$L" --lens 500 2000 6000 --reps 5 --evict_tokens 40000 --out /home/ubuntu/kv/results.jsonl > /home/ubuntu/kv/bench_$L.log 2>&1
echo "bench exit=$?"
mem "after-bench"
sudo docker logs vllm 2>&1 | grep -i -E "offload|kv cache|prefix cache hit|external" | tail -6
sudo docker inspect -f 'status={{.State.Status}} oomkilled={{.State.OOMKilled}} exit={{.State.ExitCode}}' vllm
