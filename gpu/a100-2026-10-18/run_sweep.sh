#!/bin/bash
# Real-pod capacity sweep: fixed limit 32Gi and /dev/shm 24Gi, vary only --kv-offloading-size.
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; cd /home/ubuntu/kv
until grep -q ALL_K4_DONE runs_k4.txt 2>/dev/null; do sleep 10; done
cgp() { local uid=$(kubectl get pod $1 -o jsonpath='{.metadata.uid}' | tr - _); P=$(sudo find /sys/fs/cgroup/kubepods.slice -maxdepth 3 -type d -name "*pod${uid}.slice" | head -1)
  echo "  pod memory.current=$(( $(sudo cat $P/memory.current) >> 20 ))MiB shmem=$(sudo awk '/^shmem /{print int($2/1048576)}' $P/memory.stat)MiB"; }
{
for T in 0 8 12 16 20; do
  echo "### tier=${T}GiB"
  if [ "$T" = 0 ]; then sed -e "s/NAME/sw$T/" -e "s/LIMIT/32Gi/g" -e "s/SHMSZ/24Gi/" -e "s/RESTARTPOLICY/Never/" -e 's/,"--kv-offloading-size","OFFLOAD","--kv-offloading-backend","native"//' pod.yaml.tpl | kubectl apply -f -
  else sed -e "s/NAME/sw$T/" -e "s/LIMIT/32Gi/g" -e "s/SHMSZ/24Gi/" -e "s/OFFLOAD/$T/" -e "s/RESTARTPOLICY/Never/" pod.yaml.tpl | kubectl apply -f -; fi
  for i in $(seq 1 120); do curl -sf localhost:8001/v1/models >/dev/null && break; sleep 5; done
  cgp sw$T
  python3 sweep.py $T sweep.jsonl 3
  kubectl delete pod sw$T --wait=true >/dev/null
done
echo ALL_SWEEP_DONE
} > runs_sweep.txt 2>&1
