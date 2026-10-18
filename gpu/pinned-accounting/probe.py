# NOT YET RUN. Written for a single-GPU Linux VM; never executed.
"""Allocate host memory in 512 MiB steps and print the cgroup counters after each step.

usage: python3 probe.py MODE [STEPS]
  MODE=pinned    torch.empty(..., pin_memory=True)        (cudaHostAlloc via PyTorch)
  MODE=register  torch.empty(...) + cudart().cudaHostRegister
  MODE=plain     torch.empty(...)                          (ordinary pageable memory)

Run it inside a memory-limited cgroup (see run.sh). It reads the counters of
the cgroup it is running in, from /proc/self/cgroup.
"""
import subprocess, sys, time
import torch

MODE = sys.argv[1]
STEPS = int(sys.argv[2]) if len(sys.argv) > 2 else 6
STEP = 512 << 20
assert MODE in ("pinned", "register", "plain"), MODE

rel = [l.split(":", 2)[2].strip() for l in open("/proc/self/cgroup") if l.startswith("0::")][0]
CG = "/sys/fs/cgroup" + rel


def read(name):
    try:
        return open(f"{CG}/{name}").read().strip()
    except OSError as e:
        return f"<{e.strerror}>"


def stat():
    s = dict(l.split() for l in read("memory.stat").splitlines())
    return " ".join(f"{k}={int(s.get(k, -1)) >> 20}MiB" for k in ("anon", "shmem", "unevictable", "kernel"))


def driver():
    try:
        return subprocess.run(["nvidia-smi", "--query-gpu=driver_version", "--format=csv,noheader"],
                              capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception as e:
        return f"<{e}>"


def report(label):
    print(f"{label}: memory.current={int(read('memory.current')) >> 20}MiB {stat()} "
          f"driver={driver()}", flush=True)


print(f"mode={MODE} cgroup={CG} memory.max={read('memory.max')} swap.max={read('memory.swap.max')} "
      f"torch={torch.__version__} cuda={torch.version.cuda} gpu={torch.cuda.get_device_name(0)}", flush=True)
report("before CUDA init")
torch.cuda.init()
torch.zeros(1, device="cuda")  # create the CUDA context so its cost is not counted in step 1
report("after CUDA init ")

held = []
cudart = torch.cuda.cudart()
for i in range(1, STEPS + 1):
    if MODE == "pinned":
        t = torch.empty(STEP, dtype=torch.uint8, pin_memory=True)
        t.fill_(1)
    else:
        t = torch.empty(STEP, dtype=torch.uint8)
        t.fill_(1)  # touch every page before registering
        if MODE == "register":
            err = cudart.cudaHostRegister(t.data_ptr(), STEP, 0)
            if int(err) != 0:
                print(f"cudaHostRegister failed at step {i}: {err}", flush=True)
                break
    held.append(t)
    report(f"step {i} held={i * 512}MiB pinned={t.is_pinned()}")
    time.sleep(0.5)

print(f"DONE mode={MODE} held={len(held) * 512}MiB memory.events: {read('memory.events').replace(chr(10), ' ')}",
      flush=True)
