#!/usr/bin/env bash
# Show that an in-place memory resize changes memory.max but not the size of an
# already-mounted memory-backed emptyDir. Usage: ./run.sh
set -euo pipefail
CTX=${CTX:-kind-kv-validate}
NS=kv-demo-resize
POD=tier
HERE=$(cd "$(dirname "$0")" && pwd)
k() { kubectl --context "$CTX" "$@"; }

show() {
  echo "--- $1"
  echo "spec limit:       $(k -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].resources.limits.memory}')"
  echo "status limit:     $(k -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].resources.limits.memory}')"
  echo "restartCount:     $(k -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
  echo "container start:  $(k -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}')"
  echo "memory.max:       $(k -n "$NS" exec "$POD" -- cat /sys/fs/cgroup/memory.max)"
  echo "df -h /dev/shm:"
  k -n "$NS" exec "$POD" -- df -h /dev/shm | sed 's/^/  /'
  echo "mount options:    $(k -n "$NS" exec "$POD" -- sh -c "grep ' /dev/shm ' /proc/mounts")"
}

echo "server version: $(k version -o json | jq -r .serverVersion.gitVersion)"
k delete namespace "$NS" --ignore-not-found --wait=true >/dev/null
k apply -f "$HERE/pod.yaml" >/dev/null
k -n "$NS" wait --for=condition=Ready pod/"$POD" --timeout=120s >/dev/null
show "before resize"

echo
echo "+ kubectl patch pod $POD --subresource resize: memory 256Mi -> 1Gi"
k -n "$NS" patch pod "$POD" --subresource resize --type strategic \
  -p '{"spec":{"containers":[{"name":"engine","resources":{"requests":{"memory":"1Gi"},"limits":{"memory":"1Gi"}}}]}}'
for _ in $(seq 1 30); do
  [ "$(k -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].resources.limits.memory}')" = "1Gi" ] && break
  sleep 1
done
echo "pod conditions: $(k -n "$NS" get pod "$POD" -o json | jq -c '[.status.conditions[] | select(.type|test("Resize")) | {type,status,reason,message}]')"
echo
show "after resize"

echo
echo "+ write 400 MiB to /dev/shm (more than the old 256Mi tmpfs size, less than the new 1Gi limit)"
k -n "$NS" exec "$POD" -- python3 -c '
buf = b"\x01" * (1 << 20)
n = 0
try:
    with open("/dev/shm/kv-tier", "wb") as f:
        for n in range(1, 401):
            f.write(buf); f.flush()
    print(f"wrote {n} MiB")
except OSError as e:
    print(f"write stopped after about {n - 1} MiB: {e}")
' || true
k -n "$NS" exec "$POD" -- df -h /dev/shm | sed 's/^/  /'
echo "restartCount after write: $(k -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
