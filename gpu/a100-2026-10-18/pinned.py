"""Does CUDA-pinned host memory count against the cgroup memory limit?
Run inside a memory-limited cgroup. Prints cgroup counters after each 1 GiB step.
usage: MODE=pin|register|plain STEPS=6 python3 pinned.py"""
import os, time, torch
MODE=os.environ.get("MODE","pin"); STEPS=int(os.environ.get("STEPS","6")); GB=1<<30
cg="/sys/fs/cgroup"+open("/proc/self/cgroup").read().strip().split("::")[1]
def r(n):
    try: return open(f"{cg}/{n}").read().strip()
    except Exception as e: return f"<{e}>"
def st():
    d={}
    for l in r("memory.stat").splitlines():
        k,v=l.split(); d[k]=int(v)>>20
    return {k:d.get(k) for k in ("anon","shmem","file","unevictable","kernel","sock")}
torch.cuda.init(); torch.zeros(1,device="cuda")
print(f"mode={MODE} torch={torch.__version__} cuda={torch.version.cuda} memory.max={r('memory.max')}",flush=True)
print(f"baseline current={int(r('memory.current'))>>20}MiB {st()}",flush=True)
keep=[]
for i in range(1,STEPS+1):
    if MODE=="pin":
        t=torch.empty(GB,dtype=torch.uint8,pin_memory=True); t.fill_(1)
    elif MODE=="register":
        t=torch.ones(GB,dtype=torch.uint8)
        rc=torch.cuda.cudart().cudaHostRegister(t.data_ptr(),t.numel(),0); assert int(rc)==0, rc
    elif MODE=="shmreg":  # what vLLM 0.32 does: /dev/shm file, mmap shared, touch, cudaHostRegister
        import mmap, numpy as np
        fd=os.open(f"/dev/shm/kvtest_{os.getpid()}_{i}",os.O_RDWR|os.O_CREAT,0o600); os.ftruncate(fd,GB)
        m=mmap.mmap(fd,GB,mmap.MAP_SHARED); a_=np.frombuffer(m,dtype=np.uint8); a_[:]=1
        t=torch.from_numpy(a_)
        rc=torch.cuda.cudart().cudaHostRegister(t.data_ptr(),t.numel(),0); assert int(rc)==0, rc
        keep.append(m)
    else:
        t=torch.ones(GB,dtype=torch.uint8)
    keep.append(t); time.sleep(0.5)
    print(f"held={i}GiB current={int(r('memory.current'))>>20}MiB {st()} events={r('memory.events').replace(chr(10),' ')}",flush=True)
print("DONE",flush=True)
