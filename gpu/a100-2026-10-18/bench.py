"""TTFT for a returning conversation: GPU hit vs evicted (recompute or CPU restore, depending on server config).
usage: python3 bench.py --label restore --lens 1000 4000 16000 --reps 5"""
import argparse, json, random, string, time, urllib.request, statistics as S
p=argparse.ArgumentParser(); p.add_argument("--url",default="http://localhost:8000"); p.add_argument("--model",default="Qwen/Qwen3-8B")
p.add_argument("--label",required=True); p.add_argument("--lens",type=int,nargs="+",default=[1000,4000,16000]); p.add_argument("--reps",type=int,default=5)
p.add_argument("--evict_tokens",type=int,default=120000); p.add_argument("--out",default="results.jsonl")
a=p.parse_args()
WORDS=[''.join(random.Random(i).choices(string.ascii_lowercase,k=5)) for i in range(5000)]
def text(seed,n):  # ~1 token per word for random 5-letter words is not exact; we report server-side prompt_tokens
    r=random.Random(seed); return " ".join(r.choice(WORDS) for _ in range(n))
def ttft(prompt):
    body=json.dumps({"model":a.model,"prompt":prompt,"max_tokens":1,"temperature":0,"stream":True,"stream_options":{"include_usage":True}}).encode()
    req=urllib.request.Request(a.url+"/v1/completions",body,{"Content-Type":"application/json"})
    t0=time.perf_counter(); first=None; usage=None
    with urllib.request.urlopen(req,timeout=600) as resp:
        for line in resp:
            line=line.strip()
            if not line.startswith(b"data:") or line.endswith(b"[DONE]"): continue
            d=json.loads(line[5:])
            if first is None and d.get("choices"): first=time.perf_counter()
            if d.get("usage"): usage=d["usage"]
    return (first-t0)*1000, (usage or {}).get("prompt_tokens")
out=open(a.out,"a")
for n in a.lens:
    for rep in range(a.reps):
        seed=hash((a.label,n,rep))&0xffffffff
        ctx=text(seed,n)
        cold,toks=ttft(ctx+" q0")            # first time: full prefill
        hit,_=ttft(ctx+" q1")                 # immediately again: GPU prefix hit
        k=0                                   # push it out of GPU KV with unrelated prompts
        while k<a.evict_tokens:
            ttft(text(seed+1000+k,min(n,8000))); k+=min(n,8000)
        ret,_=ttft(ctx+" q2")                 # returning conversation: restore from CPU or recompute
        rec={"label":a.label,"words":n,"prompt_tokens":toks,"rep":rep,"cold_ms":round(cold,1),"gpu_hit_ms":round(hit,1),"return_after_evict_ms":round(ret,1)}
        print(json.dumps(rec),flush=True); out.write(json.dumps(rec)+"\n"); out.flush()
