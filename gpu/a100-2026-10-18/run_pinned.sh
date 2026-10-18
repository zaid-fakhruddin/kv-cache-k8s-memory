#!/bin/bash
# Each mode in its own transient systemd scope: MemoryMax=4G, no swap, trying to hold 6 GiB.
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader; uname -r; head -1 /proc/driver/nvidia/version
for m in plain pin register shmreg; do
  echo "=== MODE=$m MemoryMax=4G ==="
  sudo systemd-run --scope --quiet -p MemoryMax=4G -p MemorySwapMax=0 --uid=$(id -u) --gid=$(id -g) --setenv=MODE=$m --setenv=STEPS=6 \
    python3 $HOME/kv/pinned.py 2>&1 | grep -v -i warn
  echo "exit=${PIPESTATUS[0]}"
  rm -f /dev/shm/kvtest_* 
  sleep 1
done
