import sim, pandas as pd, itertools, sys
sym=sys.argv[1]; m1=sim.load(sym); D=sim.prep(m1); rows=[]
for mkt in (False,True):
    Ps=dict(sim.BASE,lb=3,max_after=36,lon=True,market=mkt)
    sig=sim.signals(sym,D,Ps)
    for trig,lock,tgt in itertools.product((0.5,1.0,1.5),(0.0,0.3,0.6),(5.0,10.0)):
        df=sim.manage_all(sym,D,sig,dict(Ps,trig=trig,lock=lock,target=tgt))
        s=sim.summarize(df,tgt); rows.append(dict(mkt=mkt,trig=trig,lock=lock,tgt=tgt,**s))
r=pd.DataFrame(rows); r.to_pickle(f"grid2_{sym}.pkl")
pd.set_option("display.width",200)
print(sym); print(r[["mkt","trig","lock","tgt","trades","alvo","taxa_alvo","zerou","ev_por_dia","resultado_total"]].round(3).to_string())
