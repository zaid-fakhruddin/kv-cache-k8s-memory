# 03: in-place resize does not grow /dev/shm

Kubernetes 1.37 supports in-place pod resize (`kubectl patch --subresource resize`).
This demo starts a pod with a 256Mi memory limit and a memory-backed emptyDir
at `/dev/shm` with no `sizeLimit`. The kubelet mounts that tmpfs with a size
taken from the pod memory limit at mount time (`size=262144k`).

Then it raises the limit to 1Gi in place.

## What `RESULT.txt` shows

- The resize worked. `memory.max` went from 268435456 to 1073741824. The
  container was not restarted (restartCount 0, same start time).
- `/dev/shm` stayed 256M. The mount options did not change.
- Writing 400 MiB to `/dev/shm` after the resize stopped at about 256 MiB
  with `ENOSPC`. The pod had 1Gi of limit and could not use it for the tier.

So raising the pod limit gives the process more headroom, but a host KV tier
that lives in that emptyDir does not get bigger. Resizing the volume is a
separate control (alpha and off by default in 1.37, per the research notes),
and an engine that sized its pool at startup would not grow it anyway.

This demo does not show what any inference engine does on resize. It only
shows the Kubernetes side.

## Run

```
./run.sh
kubectl --context kind-kv-validate delete namespace kv-demo-resize
```
