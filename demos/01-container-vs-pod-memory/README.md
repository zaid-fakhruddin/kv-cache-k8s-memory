# 01: container memory vs pod memory

A pod mounts a memory-backed emptyDir at `/dev/shm`. Each start of the container
writes a new 300 MiB "KV tier" file there, holds it for 8 seconds, then exits
with code 1. That is a stand-in for an inference engine that keeps its host KV
tier in shared memory and then crashes.

The emptyDir belongs to the pod, not the container. So the file from the first
start is still there when the container restarts. Its pages stay charged to the
pod cgroup. The next start tries to write another tier, the pod cgroup hits its
512 MiB limit, and the container is OOMKilled. From then on every restart dies
the same way until someone deletes the pod.

The container's own cgroup does not show the leftover memory. In `RESULT.txt`
the pod cgroup reads 511 MiB current and 500 MiB shmem while the new container
reads 9 MiB current and 0 MiB shmem. A dashboard that only looks at container
memory sees a nearly empty container that keeps getting OOMKilled.

## Run

```
./run.sh        # samples for 100 s, then prints a summary
kubectl --context kind-kv-validate delete namespace kv-demo-shm
```

`run.sh` needs `kubectl`, `jq`, and `docker exec` access to the kind node. It
finds the pod cgroup on the node from the pod UID and the container cgroup from
the container ID, and reads `memory.current` and the `shmem` line of
`memory.stat` from both.

## Reading the output

- `POD` columns are the pod-level cgroup (`kubepods-pod<uid>.slice`).
- `CONTAINER` columns are the running container's scope (`cri-containerd-<id>.scope`).
  They show `-` when no container is running.
- The pod and container values are read a few milliseconds apart while the
  writer is active, so the first row can show the container above the pod.
  That is sampling skew, not a real difference.
- The first exit is the simulated crash (exit 1). Every exit after that is
  `OOMKilled` (exit 137).
- The container log section can be empty. The OOMKilled starts are killed
  before Python prints anything.

## Relation to vLLM

This mirrors the failure class reported in
[vllm-project/vllm#57303](https://github.com/vllm-project/vllm/issues/57303)
(open as of 2026-10-18; tiering offload spec on a Kubernetes memory emptyDir).
It does not run vLLM. The engine here is a 20-line Python script.

## Environment

kind v0.33.0, Kubernetes v1.37.0, containerd 2.3.4, kernel 6.12.76-linuxkit
(arm64, Docker Desktop), cgroup v2. Pod QoS is Guaranteed (CPU and memory
requests equal limits).
