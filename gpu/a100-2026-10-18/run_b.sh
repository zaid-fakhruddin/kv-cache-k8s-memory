#!/bin/bash
# Batch B: memory-limit / shm sweep with native offload (8 GiB), then the TieringOffloadingSpec kill test.
cd /home/ubuntu/kv
IMG=vllm/vllm-openai:v0.32.0
BASE=(--model Qwen/Qwen3-8B --max-model-len 32768 --num-gpu-blocks-override 2304 --gpu-memory-utilization 0.85 --enable-prefix-caching)
start() { # name mem shm extra...
  local n=$1 mem=$2 shm=$3; shift 3
  sudo docker rm -f $n >/dev/null 2>&1
  sudo docker run -d --name $n --gpus all --ipc=private --shm-size $shm --memory $mem --memory-swap $mem -p 8000:8000 \
    -v /home/ubuntu/hf:/root/.cache/huggingface $IMG "${BASE[@]}" "$@" >/dev/null
}
waitup() { # name -> prints READY or EXITED status
  for i in $(seq 1 120); do
    curl -sf localhost:8000/v1/models >/dev/null && { echo READY; return 0; }
    st=$(sudo docker inspect -f '{{.State.Status}} oomkilled={{.State.OOMKilled}} exit={{.State.ExitCode}}' $1)
    case "$st" in exited*) echo "EXITED $st"; sudo docker logs $1 2>&1 | grep -E "Insufficient|Error|error:|OOM|Killed" | grep -v -i warn | tail -4; return 1;; esac
    sleep 5
  done; echo TIMEOUT; return 1
}
cg() { CID=$(sudo docker inspect -f '{{.Id}}' $1); C=/sys/fs/cgroup/system.slice/docker-$CID.scope
  echo "  mem: current=$(( $(cat $C/memory.current) >> 20 ))MiB max=$(cat $C/memory.max) $(awk '$1~/^(anon|shmem|file)$/{printf "%s=%dMiB ",$1,$2/1048576}' $C/memory.stat) $(grep oom_kill $C/memory.events|tr '\n' ' ')"; }
{
echo "### B: native offload 8 GiB, varying container memory limit and shm size"
for cfg in "16g 12g" "12g 12g" "11g 12g" "10g 12g" "16g 4g"; do
  set -- $cfg; echo "== mem=$1 shm=$2 offload=8GiB"
  start vb $1 $2 --kv-offloading-size 8 --kv-offloading-backend native
  if waitup vb; then cg vb
    python3 bench.py --label "lim_$1" --lens 6000 --reps 3 --evict_tokens 40000 --out results_b.jsonl 2>&1 | tail -3
    cg vb; sudo docker exec vb sh -c 'df -h /dev/shm | tail -1; ls -la /dev/shm | tail -3'
    sudo docker inspect -f '  after: status={{.State.Status}} oomkilled={{.State.OOMKilled}}' vb
  fi
done
sudo docker rm -f vb >/dev/null 2>&1
echo "### T: TieringOffloadingSpec kill test (vllm#57303) shm=12g mem=24g cpu_bytes=8GiB"
start vt 24g 12g --kv-transfer-config '{"kv_connector":"OffloadingConnector","kv_role":"kv_both","kv_connector_extra_config":{"cpu_bytes_to_use":8589934592,"spec_name":"TieringOffloadingSpec"}}'
if waitup vt; then
  sudo docker exec vt sh -c 'echo "  before kill:"; df -h /dev/shm | tail -1; ls -la /dev/shm'
  for k in 1 2; do
    echo "== kill -9 #$k, then docker start (same container, same /dev/shm mount)"
    sudo docker kill -s KILL vt >/dev/null; sleep 2; sudo docker start vt >/dev/null; sleep 3
    sudo docker exec vt sh -c 'df -h /dev/shm | tail -1; ls -la /dev/shm' 2>&1
    waitup vt
  done
fi
sudo docker rm -f vt >/dev/null 2>&1
echo ALL_B_DONE
} > runs_b.txt 2>&1
