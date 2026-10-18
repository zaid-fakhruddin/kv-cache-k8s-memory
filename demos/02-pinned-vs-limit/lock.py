"""Allocate host memory in steps, optionally mlock it, and print cgroup counters.

Stands in for a pinned host KV buffer. CUDA pins host memory through the
NVIDIA driver, not through mlock, so this only approximates the cgroup side.

env:
  MODE=lock|plain       mlock each chunk or not
  MAP=shared|private    MAP_SHARED|MAP_ANONYMOUS (shmem) or MAP_PRIVATE|MAP_ANONYMOUS (anon)
  STEP_MB=128 TOTAL_MB=768
"""
import ctypes, mmap, os, resource, time

MODE = os.environ.get("MODE", "lock")
MAP = os.environ.get("MAP", "shared")
STEP = int(os.environ.get("STEP_MB", "128")) << 20
TOTAL = int(os.environ.get("TOTAL_MB", "768")) << 20
libc = ctypes.CDLL("libc.so.6", use_errno=True)
libc.mlock.argtypes = [ctypes.c_void_p, ctypes.c_size_t]


def cg(name):
    try:
        return open(f"/sys/fs/cgroup/{name}").read().strip()
    except OSError as e:
        return f"<{e.strerror}>"


def stat(key):
    for line in cg("memory.stat").splitlines():
        k, v = line.split()
        if k == key:
            return int(v) >> 20
    return -1


soft, hard = resource.getrlimit(resource.RLIMIT_MEMLOCK)
caps = [l for l in open("/proc/self/status") if l.startswith("CapEff")][0].split()[1]
print(f"mode={MODE} map={MAP} memory.max={cg('memory.max')} swap.max={cg('memory.swap.max')} "
      f"RLIMIT_MEMLOCK={soft},{hard} CAP_IPC_LOCK={'yes' if int(caps, 16) >> 14 & 1 else 'no'}",
      flush=True)

flags = mmap.MAP_ANONYMOUS | (mmap.MAP_SHARED if MAP == "shared" else mmap.MAP_PRIVATE)
bufs, done = [], 0
while done < TOTAL:
    m = mmap.mmap(-1, STEP, flags=flags)
    addr = ctypes.addressof(ctypes.c_char.from_buffer(m))
    if MODE == "lock" and libc.mlock(ctypes.c_void_p(addr), ctypes.c_size_t(STEP)) != 0:
        print(f"mlock FAILED at {done >> 20} MiB: {os.strerror(ctypes.get_errno())}", flush=True)
        break
    ctypes.memset(addr, 1, STEP)  # touch every page, no Python-side temporary
    bufs.append(m)
    done += STEP
    print(f"held={done >> 20}MiB memory.current={int(cg('memory.current')) >> 20}MiB "
          f"anon={stat('anon')}MiB shmem={stat('shmem')}MiB unevictable={stat('unevictable')}MiB",
          flush=True)
    time.sleep(0.3)
print(f"DONE holding {done >> 20} MiB", flush=True)
time.sleep(3600)
