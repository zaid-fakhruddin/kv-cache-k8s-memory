#!/usr/bin/env bash
# Apply demo 01, sample pod-level and container-level cgroup counters from the
# kind node, then print a summary. Usage: ./run.sh [seconds]  (default 100)
set -euo pipefail
CTX=${CTX:-kind-kv-validate}
NODE=${NODE:-kv-validate-control-plane}
NS=kv-demo-shm
POD=retained-tier
DURATION=${1:-100}
HERE=$(cd "$(dirname "$0")" && pwd)
k() { kubectl --context "$CTX" "$@"; }
node() { docker exec "$NODE" "$@"; }

mib() { [ -n "${1:-}" ] && [ "$1" != "-" ] && echo $(( $1 >> 20 )) || echo "-"; }
shmem() { node sh -c "grep '^shmem ' $1/memory.stat 2>/dev/null | cut -d' ' -f2" || true; }
cur() { node cat "$1/memory.current" 2>/dev/null || true; }

k delete namespace "$NS" --ignore-not-found --wait=true >/dev/null
k apply -f "$HERE/manifest.yaml" >/dev/null
k -n "$NS" wait --for=condition=Ready pod/"$POD" --timeout=120s >/dev/null || true

UID_=$(k -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}')
POD_CG=$(node find /sys/fs/cgroup -maxdepth 4 -type d -name "*pod${UID_//-/_}.slice" | head -1)
echo "pod UID:        $UID_"
echo "QoS class:      $(k -n "$NS" get pod "$POD" -o jsonpath='{.status.qosClass}')"
echo "pod cgroup:     $POD_CG"
echo "pod memory.max: $(node cat "$POD_CG/memory.max")"
echo
printf '%-5s %-9s %-22s %-24s %-24s\n' "t(s)" "restarts" "state" "POD current/shmem MiB" "CONTAINER current/shmem MiB"

START=$(date +%s)
while :; do
  T=$(( $(date +%s) - START ))
  [ "$T" -ge "$DURATION" ] && break
  J=$(k -n "$NS" get pod "$POD" -o json)
  RC=$(jq -r '.status.containerStatuses[0].restartCount' <<<"$J")
  STATE=$(jq -r '.status.containerStatuses[0].state | keys[0]' <<<"$J")
  WHY=$(jq -r '.status.containerStatuses[0].state[].reason // ""' <<<"$J")
  CID=$(jq -r '.status.containerStatuses[0].containerID // "" | sub("containerd://"; "")' <<<"$J")
  P_CUR=$(cur "$POD_CG"); P_SH=$(shmem "$POD_CG")
  C_CG="$POD_CG/cri-containerd-$CID.scope"
  if [ "$STATE" = "running" ] && [ -n "$CID" ]; then
    C_CUR=$(cur "$C_CG"); C_SH=$(shmem "$C_CG")
  else
    C_CUR="-"; C_SH="-"
  fi
  printf '%-5s %-9s %-22s %-24s %-24s\n' "$T" "$RC" "${STATE}${WHY:+/$WHY}" \
    "$(mib "$P_CUR") / $(mib "$P_SH")" "$(mib "$C_CUR") / $(mib "$C_SH")"
  sleep 3
done

echo
echo "== summary =="
J=$(k -n "$NS" get pod "$POD" -o json)
echo "restartCount:            $(jq -r '.status.containerStatuses[0].restartCount' <<<"$J")"
echo "current state:           $(jq -c '.status.containerStatuses[0].state' <<<"$J")"
echo "last termination reason: $(jq -r '.status.containerStatuses[0].lastState.terminated.reason // "-"' <<<"$J") (exit $(jq -r '.status.containerStatuses[0].lastState.terminated.exitCode // "-"' <<<"$J"))"
echo "pod UID unchanged:       $( [ "$(jq -r .metadata.uid <<<"$J")" = "$UID_" ] && echo yes || echo no)"
echo "pod memory.current:      $(mib "$(cur "$POD_CG")") MiB"
echo "pod memory.stat shmem:   $(mib "$(shmem "$POD_CG")") MiB"
echo "pod memory.events:       $(node cat "$POD_CG/memory.events" | tr '\n' ' ')"
echo "tier files left in the pod's emptyDir (on the node):"
node sh -c "ls -l /var/lib/kubelet/pods/$UID_/volumes/kubernetes.io~empty-dir/shm/" | sed 's/^/  /' 
echo
echo "== container log (most recent start) =="
k -n "$NS" logs "$POD" 2>/dev/null || k -n "$NS" logs "$POD" --previous 2>/dev/null || echo "(log not available)"
echo
echo "== events =="
k -n "$NS" get events --sort-by=.lastTimestamp -o custom-columns=REASON:.reason,MSG:.message --no-headers | tail -8
