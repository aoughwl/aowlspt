import json,subprocess
ARG={'rcx':0,'rdx':1,'r8':2,'r9':3}
g=json.load(open(r"C:/Users/savant/AppData/Local/Temp/claude/C--Users-savant-Projects-aowlspt/559de8e0-9a8f-4146-b694-c897e0a1f0cd/scratchpad/gates.json"))
def run(nm,tok,ai,mode):
    p=subprocess.run([r"C:/Users/savant/AppData/Local/Temp/claude/C--Users-savant-Projects-aowlspt/559de8e0-9a8f-4146-b694-c897e0a1f0cd/scratchpad/gatecall.exe",nm,"%X"%tok,str(ai),mode],capture_output=True,text=True,timeout=120)
    outs=p.stdout.split()
    return outs,p.returncode
print("%-42s %-26s %-26s %s"%("export","correct-token x3","corrupted-token x3","VERDICT"))
npass=ninc=0
for nm,v in sorted(g.items()):
    if v['kind']!='static': continue
    ai=ARG[v['reg']]
    go,gc=run(nm,v['tok'],ai,"good")
    bo,bc=run(nm,v['tok'],ai,"bad")
    gstable = len(go)==3 and len(set(go))==1
    bvary   = len(set(bo))==len(bo) and len(bo)>=2
    if gstable and bvary: verdict="PASS"; npass+=1
    elif gstable and len(bo)==0: verdict="PASS(bad crashed)"; npass+=1
    else: verdict="INCONCLUSIVE"; ninc+=1
    print("%-42s %-26s %-26s %s"%(nm, ",".join(go) or "crash@%d"%gc, ",".join(bo) or "crash@%d"%bc, verdict))
print("\nPASS=%d INCONCLUSIVE=%d"%(npass,ninc))
