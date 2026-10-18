#!/usr/bin/env bash
# NOT YET RUN. Written for a disposable single-GPU Linux VM (cgroup v2, systemd,
# NVIDIA driver already installed). Run as root: sudo ./run.sh
#
# Question: does host memory pinned by CUDA count against a cgroup memory limit
# the same way ordinary and mlocked memory do?
#
# Each mode runs in a fresh process inside its own transient systemd scope with
# MemoryMax set and swap off. With the defaults (2G limit, 6 x 512 MiB = 3 GiB)
# a mode whose pages are charged to the cgroup should be OOMKilled partway
# through. A mode that gets through all six steps is not being charged.
set -uo pipefail
LIMIT=${LIMIT:-2G}
STEPS=${STEPS:-6}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/result-$(hostname)-$(date -u +%Y%m%dT%H%M%SZ).txt"

[ "$(id -u)" = 0 ] || { echo "run as root (systemd-run --scope needs it)"; exit 1; }
[ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ] || { echo "needs cgroup v2"; exit 1; }
command -v nvidia-smi >/dev/null || { echo "nvidia-smi not found"; exit 1; }
python3 -c 'import torch' 2>/dev/null || python3 -m pip install torch

{
  echo "date:    $(date -u +%FT%TZ)"
  echo "kernel:  $(uname -r)"
  echo "os:      $(. /etc/os-release && echo "$PRETTY_NAME")"
  echo "systemd: $(systemctl --version | head -1)"
  echo "driver:  $(nvidia-smi --query-gpu=driver_version,name,memory.total --format=csv,noheader)"
  echo "limit:   MemoryMax=$LIMIT MemorySwapMax=0 steps=$STEPS x 512MiB"
  for mode in plain pinned register; do
    echo
    echo "=== $mode ==="
    systemd-run --scope --quiet -p MemoryMax="$LIMIT" -p MemorySwapMax=0 \
      python3 -u "$HERE/probe.py" "$mode" "$STEPS"
    echo "exit code: $? (137 = SIGKILL, usually the cgroup OOM killer)"
  done
  echo
  echo "kernel OOM messages from this run:"
  dmesg | grep -iE 'oom|memory cgroup out of memory' | tail -20
} 2>&1 | tee "$OUT"
echo "saved to $OUT"
