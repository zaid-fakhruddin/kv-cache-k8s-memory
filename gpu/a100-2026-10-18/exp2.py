"""(A) traffic-between-turns sweep with a restore-blocked control arm, (B) open-loop mixed workload.
usage: python3 exp2.py traffic <tier> | python3 exp2.py mixed <tier>"""
import json, random, string, sys, time, urllib.request, re, threading
URL="http://localhost:8001"; MODE=sys.argv[1]; TIER=sys.argv[2]
W=[''.join(random.Random(i).choices(string.ascii_lowercase,k=5)) for i in range(5000)]
txt=lambda s,n:" ".join(random.Random(s).choice(W) for _ in range(n))
def req(p,max_tokens=1,block=False):
    body={"model":"Qwen/Qwen3-8B","prompt":p,"max_tokens":max_tokens,"temperature":0,"stream":True}
    if block: body["kv_transfer_params"]={"max_load_tokens":0}
    t0=time.perf_counter(); first=None
    with urllib.request.urlopen(urllib.request.Request(URL+"/v1/completions",json.dumps(body).encode(),{"Content-Type":"application/json"}),timeout=900) as r:
        for line in r:
            if first is None and line.startswith(b"data:") and b'"text"' in line: first=time.perf_counter()
    end=time.perf_counter(); return ((first or end)-t0)*1000,(end-t0)*1000
def metrics():
    m=urllib.request.urlopen(URL+"/metrics").read().decode(); d={}
    for k,pat in {"host_tok":r'^vllm:prompt_tokens_cached_by_source_total\{[^}]*source="host"[^}]*\} (\S+)',
                  "load_bytes":r'^vllm:kv_offload_load_bytes_total\{[^}]*\} (\S+)'}.items():
        d[k]=sum(float(x) for x in re.findall(pat,m,re.M))
    return d
if MODE=="traffic":
    out=open("exp2_traffic.jsonl","a")
    for words in [0,13000,27000,40000,55000]:          # ~0 / 38k / 78k / 116k / 160k tokens between turns
        for rep in range(3):
            for arm in ["normal","blocked"]:
                s=random.Random(f"{TIER}-{words}-{rep}-{arm}").randint(0,10**9)
                ctx=txt(s,6000); cold,_=req(ctx+" q0"); time.sleep(1)   # seed, let async store finish
                k=0
                while k<words: req(txt(s+10**6+k,min(6000,words-k))); k+=6000
                time.sleep(1); m0=metrics(); ret,_=req(ctx+" q2",block=(arm=="blocked")); time.sleep(0.5); m1=metrics()
                rec={"tier":TIER,"between_words":words,"rep":rep,"arm":arm,"cold_ms":round(cold,1),"return_ms":round(ret,1),
                     "d_host_tok":m1["host_tok"]-m0["host_tok"],"d_load_bytes":m1["load_bytes"]-m0["load_bytes"]}
                print(json.dumps(rec),flush=True); out.write(json.dumps(rec)+"\n"); out.flush()
else:
    # open-loop: same schedule every run. 8 long conversations seeded, then 60 s of arrivals every 0.75 s:
    # pattern R,N,S,S (returning long / new long / short), outputs 64 tokens.
    out=open("exp2_mixed.jsonl","a"); rng=random.Random(42)
    convs=[txt(7000+i,6000) for i in range(8)]
    for c in convs: req(c+" q0")
    res=[]; lock=threading.Lock(); th=[]
    def go(kind,p):
        t,e=req(p,max_tokens=64)
        with lock: res.append((kind,t,e))
    t0=time.perf_counter()
    for i in range(80):
        kind="RNSS"[i%4]
        p={"R":convs[i//4%8]+f" turn{i}","N":txt(9000+i,6000),"S":txt(20000+i,50)}[kind]
        while time.perf_counter()-t0<i*0.75: time.sleep(0.005)
        x=threading.Thread(target=go,args=(kind,p)); x.start(); th.append(x)
    [x.join() for x in th]
    for kind in "RNS":
        v=sorted(t for k,t,e in res if k==kind); n=len(v)
        rec={"tier":TIER,"kind":{"R":"returning_long","N":"new_long","S":"short"}[kind],"n":n,"ttft_p50":round(v[n//2],1),"ttft_p90":round(v[int(n*0.9)-1],1),"ttft_max":round(v[-1],1)}
        print(json.dumps(rec),flush=True); out.write(json.dumps(rec)+"\n")
