"""N returning conversations at once: warm N contexts, evict them from GPU, then return all N concurrently.
usage: python3 conc.py --url http://localhost:8001 --label X --n 1 4 8 --words 2000"""
import argparse, json, random, string, time, urllib.request, threading
p=argparse.ArgumentParser(); p.add_argument("--url",default="http://localhost:8001"); p.add_argument("--model",default="Qwen/Qwen3-8B")
p.add_argument("--label",required=True); p.add_argument("--n",type=int,nargs="+",default=[1,4,8]); p.add_argument("--words",type=int,default=2000)
p.add_argument("--evict_words",type=int,default=40000); p.add_argument("--out",default="conc.jsonl"); a=p.parse_args()
W=[''.join(random.Random(i).choices(string.ascii_lowercase,k=5)) for i in range(5000)]
txt=lambda s,n:" ".join(random.Random(s).choice(W) for _ in range(n))
def ttft(prompt,res=None,i=0):
    b=json.dumps({"model":a.model,"prompt":prompt,"max_tokens":1,"temperature":0,"stream":True}).encode()
    t0=time.perf_counter()
    with urllib.request.urlopen(urllib.request.Request(a.url+"/v1/completions",b,{"Content-Type":"application/json"}),timeout=900) as r:
        for line in r:
            if line.startswith(b"data:") and b"choices" in line: break
    v=(time.perf_counter()-t0)*1000
    if res is not None: res[i]=v
    return v
out=open(a.out,"a")
for n in a.n:
    base=random.Random(f"{a.label}{n}").randint(0,10**9)
    ctx=[txt(base+i,a.words) for i in range(n)]
    for c in ctx: ttft(c+" q0")
    k=0
    while k<a.evict_words: ttft(txt(base+10**6+k,min(a.words,8000))); k+=min(a.words,8000)
    res=[None]*n; th=[threading.Thread(target=ttft,args=(ctx[i]+" q2",res,i)) for i in range(n)]
    t0=time.perf_counter(); [t.start() for t in th]; [t.join() for t in th]; wall=(time.perf_counter()-t0)*1000
    rec={"label":a.label,"n":n,"words":a.words,"ttft_ms":[round(x,1) for x in res],"max_ms":round(max(res),1),"wall_ms":round(wall,1)}
    print(json.dumps(rec),flush=True); out.write(json.dumps(rec)+"\n"); out.flush()
