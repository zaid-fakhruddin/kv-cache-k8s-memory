#!/bin/bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; cd /home/ubuntu/kv
until grep -q ALL_SWEEP_DONE runs_sweep.txt 2>/dev/null; do sleep 5; done
up() { for i in $(seq 1 120); do curl -sf localhost:8001/v1/models >/dev/null && return 0; sleep 5; done; return 1; }
pod() { if [ "$1" = 0 ]; then sed -e "s/NAME/e$1/" -e "s/LIMIT/32Gi/g" -e "s/SHMSZ/24Gi/" -e "s/RESTARTPOLICY/Never/" -e 's/,"--kv-offloading-size","OFFLOAD","--kv-offloading-backend","native"//' pod.yaml.tpl | kubectl apply -f -
  else sed -e "s/NAME/e$1/" -e "s/LIMIT/32Gi/g" -e "s/SHMSZ/24Gi/" -e "s/OFFLOAD/$1/" -e "s/RESTARTPOLICY/Never/" pod.yaml.tpl | kubectl apply -f -; fi; up; }
{
echo "### A: traffic sweep, tier 20"; pod 20 && python3 exp2.py traffic 20; echo "### B: mixed, tier 20"; python3 exp2.py mixed 20; kubectl delete pod e20 --wait=true
echo "### B: mixed, tier 0"; pod 0 && python3 exp2.py mixed 0; kubectl delete pod e0 --wait=true
echo "### A: traffic sweep, tier 12"; pod 12 && python3 exp2.py traffic 12; echo "### B: mixed, tier 12"; python3 exp2.py mixed 12; kubectl delete pod e12 --wait=true
echo ALL_EXP2_DONE
} > runs_exp2.txt 2>&1
