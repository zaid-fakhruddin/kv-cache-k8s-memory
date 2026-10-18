#!/bin/bash
# After batch B: vLLM as a real k3s pod. Records pod vs container cgroup and kubelet stats, runs bench + short-context + concurrency.
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cd /home/ubuntu/kv
until grep -q ALL_B_DONE runs_b.txt 2>/dev/null; do sleep 15; done
until grep -q K3S_SETUP_DONE k3s_setup.txt 2>/dev/null; do sleep 15; done
sudo docker rm -f vb vt vllm >/dev/null 2>&1
mk() { sed -e "s/NAME/$1/" -e "s/LIMIT/$2/g" -e "s/SHMSZ/$3/" -e "s/OFFLOAD/$4/" -e "s/RESTARTPOLICY/$5/" pod.yaml.tpl | kubectl apply -f - ; }
cgs() { local uid=$(kubectl get pod $1 -o jsonpath='{.metadata.uid}' | tr - _); P=$(sudo find /sys/fs/cgroup/kubepods.slice -maxdepth 3 -type d -name "*pod${uid}.slice" | head -1)
  C=$(sudo find $P -maxdepth 1 -type d -name "cri-containerd-*.scope" | head -1)
  for x in "pod:$P" "container:$C"; do n=${x%%:*}; d=${x#*:}; [ -d "$d" ] || continue
    echo "  $n memory.current=$(( $(sudo cat $d/memory.current) >> 20 ))MiB $(sudo awk '$1~/^(anon|shmem|file)$/{printf "%s=%dMiB ",$1,$2/1048576}' $d/memory.stat) $(sudo grep oom_kill $d/memory.events|tr '\n' ' ')"; done
  kubectl get --raw "/api/v1/nodes/$(hostname)/proxy/stats/summary" | python3 -c "import json,sys;d=json.load(sys.stdin)
for p in d['pods']:
  if p['podRef']['name']=='$1':
    m=p.get('memory',{}); print('  kubelet pod: workingSet=%dMiB rss=%dMiB usage=%dMiB'%(m.get('workingSetBytes',0)>>20,m.get('rssBytes',0)>>20,m.get('usageBytes',0)>>20))
    for c in p.get('containers',[]): m=c.get('memory',{}); print('  kubelet container %s: workingSet=%dMiB rss=%dMiB'%(c['name'],m.get('workingSetBytes',0)>>20,m.get('rssBytes',0)>>20))"; }
waitpod() { for i in $(seq 1 120); do curl -sf localhost:8001/v1/models >/dev/null && { echo READY; return 0; }
  r=$(kubectl get pod $1 -o jsonpath='{.status.containerStatuses[0].restartCount} {.status.containerStatuses[0].lastState.terminated.reason} {.status.containerStatuses[0].state.waiting.reason}')
  case "$r" in *OOMKilled*|*CrashLoop*|*Error*) echo "POD FAILED: restarts/reason=$r"; return 1;; esac; sleep 5; done; echo TIMEOUT; return 1; }
{
echo "### K1: Guaranteed pod, limit 32Gi, /dev/shm emptyDir sizeLimit 24Gi, offload 20 GiB"
mk vk1 32Gi 24Gi 20 Never; kubectl get pod vk1 -o jsonpath='  qos={.status.qosClass}{"\n"}'
if waitpod vk1; then cgs vk1
  python3 bench.py --url http://localhost:8001 --label pod_restore --lens 50 150 500 6000 --reps 3 --evict_tokens 40000 --out results_k.jsonl 2>&1 | tail -12
  python3 conc.py --url http://localhost:8001 --label pod_conc --n 1 4 8 --words 2000 --out conc.jsonl 2>&1 | tail -3
  cgs vk1; curl -s localhost:8001/metrics | grep -E "^vllm:kv_offload_cpu_cache_usage_perc|^vllm:kv_offload_(store|load)_bytes" | head -5
fi
kubectl delete pod vk1 --wait=true >/dev/null
echo "### K1b: same with offload 0 (recompute arm, pod)"
sed -e "s/NAME/vk0/" -e "s/LIMIT/32Gi/g" -e "s/SHMSZ/24Gi/" -e "s/RESTARTPOLICY/Never/" -e 's/,"--kv-offloading-size","OFFLOAD","--kv-offloading-backend","native"//' pod.yaml.tpl | kubectl apply -f -
if waitpod vk0; then cgs vk0
  python3 bench.py --url http://localhost:8001 --label pod_recompute --lens 50 150 500 --reps 3 --evict_tokens 40000 --out results_k.jsonl 2>&1 | tail -9
  python3 conc.py --url http://localhost:8001 --label pod_conc_recompute --n 1 4 8 --words 2000 --out conc.jsonl 2>&1 | tail -3
fi
kubectl delete pod vk0 --wait=true >/dev/null
echo "### K2: limit 20Gi with offload 20 GiB (tier alone = limit)"
mk vk2 20Gi 24Gi 20 Always; waitpod vk2; sleep 20; kubectl get pod vk2 -o wide | tail -1
kubectl get pod vk2 -o jsonpath='  restarts={.status.containerStatuses[0].restartCount} last={.status.containerStatuses[0].lastState.terminated.reason} exit={.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
cgs vk2; kubectl delete pod vk2 --wait=true >/dev/null
echo "### K3: limit 32Gi but /dev/shm sizeLimit 8Gi with offload 20 GiB"
mk vk3 32Gi 8Gi 20 Never; waitpod vk3; kubectl logs vk3 2>&1 | grep -E "Insufficient|shm|RuntimeError" | head -3
kubectl get pod vk3 -o jsonpath='  phase={.status.phase} reason={.status.containerStatuses[0].state.terminated.reason} exit={.status.containerStatuses[0].state.terminated.exitCode}{"\n"}'
kubectl delete pod vk3 --wait=true >/dev/null
echo ALL_K_DONE
} > runs_k.txt 2>&1
