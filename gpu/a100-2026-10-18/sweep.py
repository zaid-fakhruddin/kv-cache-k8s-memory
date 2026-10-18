"""Capacity sweep probe: for one server, warm a 6000-word conversation, push it out of the GPU with other traffic,
return to it, and record TTFT plus metric deltas around the return (host-sourced cached tokens, load bytes, external hits)."""
import json, random, string, sys, time, urllib.request, re
URL="http://localhost:8001"; TIER=sys.argv[1]; OUT=sys.argv[2]; REPS=int(sys.argv[3]) if len(sys.argv)>3 else 3
W=[''.join(random.Random(i).choices(string.ascii_lowercase,k=5)) for i in range(5000)]
txt=lambda s,n:" ".join(random.Random(s).choice(W) for _ in range(n))
def ttft(p):
    b=json.dumps({"model":"Qwen/Qwen3-8B","prompt":p,"max_tokens":1,"temperature":0,"stream":True}).encode(); t0=time.perf_counter()
    with urllib.request.urlopen(urllib.request.Request(URL+"/v1/completions",b,{"Content-Type":"application/json"}),timeout=900) as r:
        for line in r:
            if line.startswith(b"data:") and b'"text"' in line: break
    return (time.perf_counter()-t0)*1000
def metrics():
    m=urllib.request.urlopen(URL+"/metrics").read().decode(); d={}
    for k,pat in {"host_cached_tokens":r'^vllm:prompt_tokens_cached_by_source_total\{[^}]*source="host"[^}]*\} (\S+)',
                  "load_bytes":r'^vllm:kv_offload_load_bytes_total\{[^}]*\} (\S+)',
                  "ext_hits":r'^vllm:external_prefix_cache_hits_total\{[^}]*\} (\S+)'}.items():
        d[k]=sum(float(x) for x in re.findall(pat,m,re.M))
    return d
out=open(OUT,"a")
for rep in range(REPS):
    s=random.Random(f"{TIER}-{rep}").randint(0,10**9); ctx=txt(s,6000)
    cold=ttft(ctx+" q0"); hit=ttft(ctx+" q1")
    k=0
    while k<40000: ttft(txt(s+10**6+k,6000)); k+=6000
    m0=metrics(); ret=ttft(ctx+" q2"); m1=metrics()
    rec={"tier_gib":TIER,"rep":rep,"cold_ms":round(cold,1),"gpu_hit_ms":round(hit,1),"return_ms":round(ret,1),**{f"d_{x}":m1[x]-m0[x] for x in m0}}
    print(json.dumps(rec),flush=True); out.write(json.dumps(rec)+"\n"); out.flush()
