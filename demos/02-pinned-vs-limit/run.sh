#!/usr/bin/env bash
# Run the four demo 02 pods, wait, then print each pod's outcome, its log, and
# the kubelet's view of its memory (stats/summary). Usage: ./run.sh
set -euo pipefail
CTX=${CTX:-kind-kv-validate}
NS=kv-demo-pinned
HERE=$(cd "$(dirname "$0")" && pwd)
k() { kubectl --context "$CTX" "$@"; }

k delete namespace "$NS" --ignore-not-found --wait=true >/dev/null
k create namespace "$NS" >/dev/null
k -n "$NS" create configmap lockpy --from-file=lock.py="$HERE/lock.py" >/dev/null
k apply -f "$HERE/pods.yaml" >/dev/null
echo "waiting 60s for allocations and for kubelet stats to refresh..."
sleep 60
NODE=$(k -n "$NS" get pod a-plain-over -o jsonpath='{.spec.nodeName}')
SUMMARY=$(k get --raw "/api/v1/nodes/$NODE/proxy/stats/summary")

for p in a-plain-over b-lock-under c-lock-over d-lock-under-priv; do
  echo
  echo "=== $p ==="
  J=$(k -n "$NS" get pod "$p" -o json)
  echo "env:     $(jq -c '[.spec.containers[0].env[] | "\(.name)=\(.value)"]' <<<"$J")"
  echo "limit:   $(jq -r '.spec.containers[0].resources.limits.memory' <<<"$J")  caps.add: $(jq -c '.spec.containers[0].securityContext.capabilities.add' <<<"$J")"
  echo "state:   $(jq -c '.status.containerStatuses[0].state | to_entries[0] | {state: .key, reason: .value.reason, exitCode: .value.exitCode}' <<<"$J")"
  echo "--- log"
  k -n "$NS" logs "$p" 2>/dev/null | sed 's/^/  /'
  if [ "$(jq -r '.status.containerStatuses[0].state | keys[0]' <<<"$J")" = "running" ]; then
    echo "--- kubelet stats/summary (container memory)"
    jq -r --arg ns "$NS" --arg p "$p" '.pods[] | select(.podRef.namespace==$ns and .podRef.name==$p) |
      .containers[0].memory | "  usageBytes=\(.usageBytes/1048576|floor)MiB workingSetBytes=\(.workingSetBytes/1048576|floor)MiB rssBytes=\(.rssBytes/1048576|floor)MiB"' <<<"$SUMMARY"
  fi
done
