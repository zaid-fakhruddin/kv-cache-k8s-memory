apiVersion: v1
kind: Pod
metadata: {name: NAME, labels: {app: vllm}}
spec:
  runtimeClassName: nvidia
  hostNetwork: true
  restartPolicy: RESTARTPOLICY
  containers:
  - name: vllm
    image: docker.io/vllm/vllm-openai:v0.32.0
    imagePullPolicy: Never
    args: ["--model","Qwen/Qwen3-8B","--port","8001","--max-model-len","32768","--num-gpu-blocks-override","2304",
           "--gpu-memory-utilization","0.85","--enable-prefix-caching","--kv-offloading-size","OFFLOAD","--kv-offloading-backend","native"]
    resources:
      requests: {cpu: "8", memory: LIMIT, nvidia.com/gpu: 1}
      limits: {cpu: "8", memory: LIMIT, nvidia.com/gpu: 1}
    volumeMounts:
    - {name: shm, mountPath: /dev/shm}
    - {name: hf, mountPath: /root/.cache/huggingface}
  volumes:
  - name: shm
    emptyDir: {medium: Memory, sizeLimit: SHMSZ}
  - name: hf
    hostPath: {path: /home/ubuntu/hf, type: Directory}
