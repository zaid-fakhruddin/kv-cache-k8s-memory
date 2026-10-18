#!/bin/bash
# K4: vllm#57303 in a real pod. TieringOffloadingSpec 8 GiB, memory emptyDir sizeLimit 12Gi, restartPolicy Always.
# SIGKILL the container from the host; kubelet restarts it in the same pod; emptyDir keeps the old tier file.
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cd /home/ubuntu/kv
until grep -q ALL_K_DONE runs_k.txt 2>/dev/null; do sleep 15; done
{
echo "### K4: TieringOffloadingSpec pod, emptyDir medium=Memory sizeLimit=12Gi, limit 32Gi"
cat <<'Y' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: {name: vk4}
spec:
  runtimeClassName: nvidia
  hostNetwork: true
  restartPolicy: Always
  containers:
  - name: vllm
    image: docker.io/vllm/vllm-openai:v0.32.0
    imagePullPolicy: Never
    args: ["--model","Qwen/Qwen3-8B","--port","8001","--max-model-len","32768","--num-gpu-blocks-override","2304","--gpu-memory-utilization","0.85","--enable-prefix-caching",
           "--kv-transfer-config","{\"kv_connector\":\"OffloadingConnector\",\"kv_role\":\"kv_both\",\"kv_connector_extra_config\":{\"cpu_bytes_to_use\":8589934592,\"spec_name\":\"TieringOffloadingSpec\"}}"]
    resources:
      requests: {cpu: "8", memory: 32Gi, nvidia.com/gpu: 1}
      limits: {cpu: "8", memory: 32Gi, nvidia.com/gpu: 1}
    volumeMounts: [{name: shm, mountPath: /dev/shm}, {name: hf, mountPath: /root/.cache/huggingface}]
  volumes:
  - {name: shm, emptyDir: {medium: Memory, sizeLimit: 12Gi}}
  - {name: hf, hostPath: {path: /home/ubuntu/hf, type: Directory}}
Y
for i in $(seq 1 120); do curl -sf localhost:8001/v1/models >/dev/null && break; sleep 5; done; echo "ready after ~$((i*5))s"
podcg() { local uid=$(kubectl get pod vk4 -o jsonpath='{.metadata.uid}' | tr - _); P=$(sudo find /sys/fs/cgroup/kubepods.slice -maxdepth 3 -type d -name "*pod${uid}.slice" | head -1)
  echo "  pod cgroup: current=$(( $(sudo cat $P/memory.current) >> 20 ))MiB shmem=$(sudo awk '/^shmem /{print int($2/1048576)}' $P/memory.stat)MiB oom_kill=$(sudo awk '/oom_kill /{print $2}' $P/memory.events)"
  for C in $(sudo find $P -maxdepth 1 -type d -name "cri-containerd-*.scope"); do echo "  container cgroup: current=$(( $(sudo cat $C/memory.current) >> 20 ))MiB shmem=$(sudo awk '/^shmem /{print int($2/1048576)}' $C/memory.stat)MiB"; done; }
kubectl exec vk4 -- sh -c 'df -h /dev/shm | tail -1; ls -la /dev/shm | grep -v total'
podcg
for k in 1 2; do
  echo "== SIGKILL #$k from the host (container init pid)"
  CID=$(sudo k3s crictl ps --name vllm -q | head -1); PID=$(sudo k3s crictl inspect -o go-template --template '{{.info.pid}}' $CID)
  sudo kill -9 $PID; sleep 25
  kubectl get pod vk4 -o jsonpath='  restarts={.status.containerStatuses[0].restartCount} state={.status.containerStatuses[0].state} last={.status.containerStatuses[0].lastState.terminated.reason}/{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
  kubectl exec vk4 -- sh -c 'df -h /dev/shm | tail -1; ls -la /dev/shm | grep -v total' 2>&1 | head -6
  podcg
  for i in $(seq 1 60); do curl -sf localhost:8001/v1/models >/dev/null && { echo "  server came back"; break; }; sleep 5; done
  kubectl logs vk4 2>&1 | grep -E "Insufficient space|RuntimeError" | tail -2
done
sleep 60; kubectl get pod vk4 | tail -1
kubectl get pod vk4 -o jsonpath='  restarts={.status.containerStatuses[0].restartCount} waiting={.status.containerStatuses[0].state.waiting.reason} last={.status.containerStatuses[0].lastState.terminated.reason}/{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
kubectl logs vk4 2>&1 | grep -E "Insufficient space" | tail -1
podcg
kubectl delete pod vk4 --wait=true >/dev/null
echo ALL_K4_DONE
} > runs_k4.txt 2>&1
