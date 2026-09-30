"""Estudo de qualidade de entrada: quanto o preço vai contra (MAE) antes de ir a favor.
Coleta TODOS os setups (sweep -> MSS -> FVG) nas killzones e mede cada variante de entrada."""
import sys, numpy as np, pandas as pd
import sim

VARIANTS = ["mkt", "fvg0", "fvg50", "fvg100", "ote62", "ote705", "ote79"]

def ema_h1(m5, n=200):
    h1 = m5.c.resample("1h").last().dropna()
    e = h1.ewm(span=n, adjust=False).mean().shift(1)          # só usa hora fechada
    return e.reindex(m5.index, method="ffill")

def setups_day(b5, d, pdh, pdl, P):
    t5 = b5.index; H, L, C, A, E = b5.h.values, b5.l.values, b5.c.values, b5.atr.values, b5.ema.values
    asia = b5[(t5 >= d - pd.Timedelta(hours=4)) & (t5 < d)]
    lv = {1: [], -1: []}
    if len(asia) > 10:
        lv[1].append(("asia", asia.l.min(), d)); lv[-1].append(("asia", asia.h.max(), d))
    lv[1].append(("PD", pdl, d - pd.Timedelta(hours=6))); lv[-1].append(("PD", pdh, d - pd.Timedelta(hours=6)))
    lon = b5[(t5 >= d + pd.Timedelta(hours=2)) & (t5 < d + pd.Timedelta(hours=5))]
    if len(lon) > 10:
        lv[1].append(("lon", lon.l.min(), d + pd.Timedelta(hours=5))); lv[-1].append(("lon", lon.h.max(), d + pd.Timedelta(hours=5)))
    # quando cada nível foi tomado pela 1ª vez
    first = {}
    for dirn in (1, -1):
        for name, lvl, since in lv[dirn]:
            m = (t5 >= since) & ((L < lvl) if dirn == 1 else (H > lvl))
            idx = np.flatnonzero(m)
            first[(dirn, name)] = idx[0] if len(idx) else None
    out = []; LB = P["lb"]
    for dirn in (1, -1):
        for name, lvl, since in lv[dirn]:
            i0 = first[(dirn, name)]
            if i0 is None or i0 < LB + 3: continue
            ts0 = t5[i0]
            if not sim.in_kz(ts0, P) or ts0 < d: continue
            ext, ei = (L[i0], i0) if dirn == 1 else (H[i0], i0)
            ref = H[i0 - LB:i0].max() if dirn == 1 else L[i0 - LB:i0].min()
            for i in range(i0 + 1, min(i0 + 1 + P["max_after"], len(b5))):
                if not sim.in_kz(t5[i], P): break
                if (dirn == 1 and L[i] < ext) or (dirn == -1 and H[i] > ext):
                    ext, ei = (L[i] if dirn == 1 else H[i]), i
                    ref = H[i - LB:i].max() if dirn == 1 else L[i - LB:i].min(); continue
                if not ((C[i] > ref) if dirn == 1 else (C[i] < ref)): continue
                atr = A[i]; fvg = None
                for j in range(i, ei + 1, -1):
                    if dirn == 1 and L[j] - H[j - 2] >= P["min_fvg"] * atr: fvg = (H[j - 2], L[j]); break
                    if dirn == -1 and L[j - 2] - H[j] >= P["min_fvg"] * atr: fvg = (H[j], L[j - 2]); break
                if fvg:
                    leg = H[ei:i + 1].max() if dirn == 1 else L[ei:i + 1].min()
                    out.append(dict(day=d, t=t5[i], dir=dirn, lvl=name, kz="LON" if t5[i].hour < 6 else "NY",
                                    ext=ext, atr=atr, lo=fvg[0], hi=fvg[1], leg=leg, close=C[i],
                                    ema=np.sign(C[i] - E[i]) * dirn if not np.isnan(E[i]) else 0,
                                    sweep_atr=abs(ext - lvl) / atr, leg_atr=abs(leg - ext) / atr,
                                    fvg_atr=(fvg[1] - fvg[0]) / atr, bars=i - i0))
                break
    return out

def entry_price(s, v):
    d, lo, hi, leg, ext = s["dir"], s["lo"], s["hi"], s["leg"], s["ext"]
    if v == "fvg0":   return hi if d == 1 else lo
    if v == "fvg50":  return (hi + lo) / 2
    if v == "fvg100": return lo if d == 1 else hi
    f = {"ote62": .62, "ote705": .705, "ote79": .79}[v]
    return leg - f * (leg - ext) if d == 1 else leg + f * (ext - leg)

def measure(s, v, b1, spread, P):
    d = s["dir"]; sl = s["ext"] - P["buf"] * s["atr"] * d
    t1 = b1.index.values; O, H, L = b1.o.values, b1.h.values, b1.l.values
    st = np.searchsorted(t1, np.datetime64(s["t"] + pd.Timedelta(minutes=5)))
    if st >= len(t1): return None
    close_t = np.datetime64(s["day"] + pd.Timedelta(minutes=P["close_min"]))
    kz_end = np.datetime64(sim.kz_end(s["t"], P))
    fi = None
    if v == "mkt":
        E = O[st] + spread if d == 1 else O[st]; fi = st
    else:
        E = entry_price(s, v)
        if (E - sl) * d <= 0: return None
        for i in range(st, len(t1)):
            if t1[i] >= kz_end: break
            if d == 1:
                if L[i] <= sl: break
                if L[i] + spread <= E: fi = i; break
            else:
                if H[i] + spread >= sl: break
                if H[i] >= E: fi = i; break
    if fi is None: return dict(fill=0)
    R = abs(E - sl)
    if R <= 0: return None
    mae = 0.0; hit = {1: 0, 2: 0, 3: 0}; mae1 = None; res = None
    for i in range(fi, len(t1)):
        if t1[i] >= close_t: break
        adv = (E - L[i]) / R if d == 1 else (H[i] + spread - E) / R
        fav = (H[i] - E) / R if d == 1 else (E - L[i] - spread) / R
        # na barra de entrada, o lado adverso já inclui o preço de entrada
        if adv >= (E - sl) * d / R:          # stop
            res = "sl"; mae = max(mae, 1.0); break
        mae = max(mae, adv)
        for k in (1, 2, 3):
            if not hit[k] and fav >= k:
                hit[k] = 1
                if k == 1: mae1 = mae
        if hit[3]: break
    if mae1 is None: mae1 = mae
    return dict(fill=1, R=R, R_atr=R / s["atr"], mae=mae, mae1=mae1, h1=hit[1], h2=hit[2], h3=hit[3],
                green=int(hit[1] and mae1 < 0.25), sl=int(res == "sl"))

def study(sym, P):
    m1 = sim.load(sym); D = sim.prep(m1)
    rows = []
    dstat = D["dstat"]; days = dstat.index
    for k in range(1, len(days)):
        d = days[k]
        if d.weekday() >= 5 or d not in D["m1g"]: continue
        b5 = D["m5g"][d]
        if len(b5) < 100: continue
        for s in setups_day(b5, d, dstat.dh.iloc[k - 1], dstat.dl.iloc[k - 1], P):
            for v in VARIANTS:
                r = measure(s, v, D["m1g"][d], sim.SPEC[sym]["spread"], P)
                if r is None: continue
                rows.append(dict(s, var=v, **r))
    return pd.DataFrame(rows)

if __name__ == "__main__":
    sym = sys.argv[1]
    P = dict(sim.BASE, lb=3, max_after=36)
    # EMA H1 precisa estar nas barras M5
    _prep = sim.prep
    def prep2(m1):
        D = _prep(m1)
        m5 = pd.concat(D["m5g"].values()).sort_index(); m5["ema"] = ema_h1(m5)
        D["m5g"] = dict(tuple(m5.groupby("day"))); return D
    sim.prep = prep2
    df = study(sym, P)
    df.to_pickle(f"mae_{sym}.pkl")
    print(sym, "setups:", df.drop_duplicates(["day", "t", "dir", "lvl"]).shape[0])
    f = df[df.fill == 1]
    g = f.groupby("var").agg(n=("fill", "size"), green=("green", "mean"), h1=("h1", "mean"), h2=("h2", "mean"),
                             h3=("h3", "mean"), sl=("sl", "mean"), mae1_med=("mae1", "median"), R_atr=("R_atr", "median"))
    g["fill_rate"] = f.groupby("var").size() / df.groupby("var").size()
    print(g.round(3).to_string())
