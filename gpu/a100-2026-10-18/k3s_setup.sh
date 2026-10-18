#!/bin/bash
# Install k3s + NVIDIA device plugin and import the vLLM image while batch B runs on Docker.
set -x
sudo mkdir -p /etc/rancher/k3s
printf 'write-kubeconfig-mode: "0644"\ndisable:\n  - traefik\n' | sudo tee /etc/rancher/k3s/config.yaml
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.36.5+k3s1 sh -
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for i in $(seq 1 60); do kubectl get nodes | grep -q " Ready" && break; sleep 5; done
kubectl get nodes -o wide; kubectl get runtimeclass
sudo grep -n -A3 '"nvidia"' /var/lib/rancher/k3s/agent/etc/containerd/config.toml | head -8
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.20.1/deployments/static/nvidia-device-plugin.yml
kubectl -n kube-system patch ds nvidia-device-plugin-daemonset --type json -p '[{"op":"add","path":"/spec/template/spec/runtimeClassName","value":"nvidia"}]'
kubectl -n kube-system rollout status ds/nvidia-device-plugin-daemonset --timeout=300s
sleep 10; echo "allocatable gpu: $(kubectl get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}')"
sudo docker save vllm/vllm-openai:v0.32.0 | sudo k3s ctr images import - 2>&1 | tail -2
sudo k3s ctr images ls | grep vllm-openai | cut -c1-120
echo K3S_SETUP_DONE
