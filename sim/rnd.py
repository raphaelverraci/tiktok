import sim, numpy as np, pandas as pd, sys
rng=np.random.default_rng(7)
sym=sys.argv[1]; m1=sim.load(sym); D=sim.prep(m1); P=sim.BASE; sp=sim.SPEC[sym]["spread"]
rows=[]
for d,b5 in D["m5g"].items():
    if d.weekday()>=5 or d not in D["m1g"] or len(b5)<100: continue
    kzb=b5[[sim.in_kz(t,P) and t>=d for t in b5.index]]
    if len(kzb)<10: continue
    for _ in range(3):
        k=rng.integers(0,len(kzb)); s=kzb.iloc[k]; dirn=rng.choice([1,-1])
        b1=D["m1g"][d]; t1=b1.index.values; st=np.searchsorted(t1,np.datetime64(kzb.index[k]+pd.Timedelta(minutes=5)))
        if st>=len(t1): continue
        E=b1.o.values[st]+(sp if dirn==1 else 0); R=3.2*s.atr; sl=E-R*dirn
        close_t=np.datetime64(d+pd.Timedelta(hours=16)); mae=0; hit={1:0,2:0}; mae1=None
        for i in range(st,len(t1)):
            if t1[i]>=close_t: break
            adv=(E-b1.l.values[i])/R if dirn==1 else (b1.h.values[i]+sp-E)/R
            fav=(b1.h.values[i]-E)/R if dirn==1 else (E-b1.l.values[i]-sp)/R
            if adv>=1: mae=1; break
            mae=max(mae,adv)
            for q in (1,2):
                if not hit[q] and fav>=q:
                    hit[q]=1
                    if q==1: mae1=mae
            if hit[2]: break
        mae1=mae if mae1 is None else mae1
        rows.append(dict(h1=hit[1],h2=hit[2],green=int(hit[1] and mae1<0.25),mae1=mae1))
df=pd.DataFrame(rows); print(sym,"ALEATORIO n=",len(df),"h1=%.2f h2=%.2f green=%.2f mae1_med=%.2f"%(df.h1.mean(),df.h2.mean(),df.green.mean(),df.mae1.median()))
