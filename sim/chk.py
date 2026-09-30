import sim, pandas as pd
for sym,cfgs in (("XAUUSD",[(True,1.5,0.0,5.0),(True,1.5,0.3,5.0),(True,1.0,0.3,5.0)]),("USATECHIDXUSD",[(True,1.0,0.3,10.0),(True,1.0,0.0,10.0),(True,1.5,0.3,10.0)])):
    m1=sim.load(sym); D=sim.prep(m1)
    Ps=dict(sim.BASE,lb=3,max_after=36,lon=True,market=True); sig=sim.signals(sym,D,Ps)
    for mkt,trig,lock,tgt in cfgs:
        df=sim.manage_all(sym,D,sig,dict(Ps,trig=trig,lock=lock,target=tgt))
        for y in (2024,2025,2026):
            s=sim.summarize(df[df.day.dt.year==y],tgt)
            print(sym,trig,lock,tgt,y,"trades",s["trades"],"alvo",s["alvo"],"taxa %.2f"%s["taxa_alvo"],"EV/dia %.0f"%s["ev_por_dia"],"total %.0f"%s["resultado_total"])
