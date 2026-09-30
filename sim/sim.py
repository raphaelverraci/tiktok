"""Simulador do FlipICT: 1 tentativa por dia, conta nova de $3000, risco total.
Sinal em M5 (sweep Asia/PD -> MSS -> FVG), execução em M1 (conservadora)."""
import glob, os, sys, math
import numpy as np, pandas as pd

DATA = os.path.dirname(os.path.abspath(__file__)) + "/data/duka"

SPEC = {  # custo em unidades de preço, alavancagem da corretora (None = ilimitada)
    "XAUUSD":        dict(spread=0.25, slip=0.10, lev_idx=None),
    "USATECHIDXUSD": dict(spread=1.5,  slip=0.5,  lev_idx=400),
}

HD = os.path.dirname(os.path.abspath(__file__)) + "/../data/hd/csv"
HDNAME = {"XAUUSD": "XAUUSD", "USATECHIDXUSD": "NSXUSD"}

def load(sym):
    fs = sorted(glob.glob(f"{HD}/DAT_ASCII_{HDNAME[sym]}_M1_*.csv"))
    df = pd.concat([pd.read_csv(f, sep=";", header=None, names="t o h l c v".split()) for f in fs])
    t = pd.to_datetime(df.t, format="%Y%m%d %H%M%S") + pd.Timedelta(hours=5)   # EST fixo -> UTC
    df["ny"] = t.dt.tz_localize("UTC").dt.tz_convert("America/New_York").dt.tz_localize(None)
    df = df.drop_duplicates("ny").sort_values("ny")
    return df.set_index("ny")[["o", "h", "l", "c"]]

def exness_lev(equity, lev_idx):
    if lev_idx: return lev_idx
    if equity < 5000: return 1e9
    return 2000 if equity < 30000 else 1000

def prep(m1):
    m5 = m1.resample("5min", label="left", closed="left").agg({"o": "first", "h": "max", "l": "min", "c": "last"}).dropna()
    tr = np.maximum(m5.h - m5.l, np.maximum(abs(m5.h - m5.c.shift()), abs(m5.l - m5.c.shift())))
    m5["atr"] = tr.rolling(14).mean()
    tday = lambda idx: (idx + pd.Timedelta(hours=6)).normalize()
    m5["day"] = tday(m5.index); m1 = m1.copy(); m1["day"] = tday(m1.index)
    dstat = m5.groupby("day").agg(dh=("h", "max"), dl=("l", "min"))
    return dict(m5g=dict(tuple(m5.groupby("day"))), m1g=dict(tuple(m1.groupby("day"))), dstat=dstat)

def signals(sym, D, P):
    sp = SPEC[sym]; dstat = D["dstat"]; days = dstat.index; out = []
    for k in range(1, len(days)):
        d = days[k]
        if d.weekday() >= 5: continue
        b5 = D["m5g"][d]; b1 = D["m1g"].get(d)
        if b1 is None or len(b5) < 100: continue
        o = one_day(b5, b1, dstat.dh.iloc[k - 1], dstat.dl.iloc[k - 1], d, P, sp["spread"], sp["slip"], sp["lev_idx"])
        out.append((d, o))
    return out

def manage_all(sym, D, sig, P):
    sp = SPEC[sym]; res = []
    for d, o in sig:
        if o is None: r = dict(traded=0, mult=1.0, adds=0, why="nosetup")
        else: r = manage(o, D["m1g"][d], D["m5g"][d], P, sp["spread"], sp["slip"], sp["lev_idx"], 3000.0)
        res.append(dict(day=d, **r))
    return pd.DataFrame(res)

def run(sym, m1, P):
    D = prep(m1); return manage_all(sym, D, signals(sym, D, P), P)

def in_kz(ts, P):
    m = ts.hour * 60 + ts.minute
    return any(a <= m < b for a, b in P["kz"])

def one_day(b5, b1, pdh, pdl, d, P, spread, slip, lev_idx):
    START = 3000.0
    t5 = b5.index; H, L, C, A = b5.h.values, b5.l.values, b5.c.values, b5.atr.values
    mins = t5.hour * 60 + t5.minute
    # Asia range 20:00-00:00 NY (day start is 18:00 prev calendar day)
    asia = b5[(t5 >= d - pd.Timedelta(hours=4)) & (t5 < d)]
    lv_buy, lv_sell = [], []
    if len(asia) > 10:
        lv_buy.append(("asiaL", asia.l.min(), d)); lv_sell.append(("asiaH", asia.h.max(), d))
    lv_buy.append(("PDL", pdl, d - pd.Timedelta(hours=6))); lv_sell.append(("PDH", pdh, d - pd.Timedelta(hours=6)))
    if P.get("lon"):
        lon = b5[(t5 >= d + pd.Timedelta(hours=2)) & (t5 < d + pd.Timedelta(hours=5))]
        if len(lon) > 10:
            lv_buy.append(("lonL", lon.l.min(), d + pd.Timedelta(hours=5))); lv_sell.append(("lonH", lon.h.max(), d + pd.Timedelta(hours=5)))
    taken = set()
    arm = {1: None, -1: None}
    order = None
    LB = P["lb"]
    for i in range(LB + 3, len(b5)):
        ts = t5[i]
        if ts >= d and ts.hour * 60 + ts.minute >= P["close_min"]: break
        if not in_kz(ts, P):
            arm = {1: None, -1: None}
            if order is not None: break
            continue
        # mark levels taken outside killzone / before
        for dirn, lvls in ((1, lv_buy), (-1, lv_sell)):
            for name, lvl, since in lvls:
                if name in taken or ts < since: continue
                seg = b5[(t5 >= since) & (t5 < ts)]
                if dirn == 1 and len(seg) and seg.l.min() < lvl: taken.add(name)
                if dirn == -1 and len(seg) and seg.h.max() > lvl: taken.add(name)
        if order is not None:
            break  # order placed; handled below
        for dirn, lvls in ((1, lv_buy), (-1, lv_sell)):
            a = arm[dirn]
            px_ext = L[i] if dirn == 1 else H[i]
            if a is None:
                for name, lvl, since in lvls:
                    if name in taken or ts < since: continue
                    if (dirn == 1 and L[i] < lvl) or (dirn == -1 and H[i] > lvl):
                        taken.add(name)
                        ref = H[i - LB:i].max() if dirn == 1 else L[i - LB:i].min()
                        arm[dirn] = dict(ext=px_ext, ei=i, ref=ref, n=0)
                        break
                continue
            a["n"] += 1
            if (dirn == 1 and L[i] < a["ext"]) or (dirn == -1 and H[i] > a["ext"]):
                a["ext"] = px_ext; a["ei"] = i
                a["ref"] = H[i - LB:i].max() if dirn == 1 else L[i - LB:i].min()
                continue
            if a["n"] > P["max_after"]: arm[dirn] = None; continue
            mss = (C[i] > a["ref"]) if dirn == 1 else (C[i] < a["ref"])
            if not mss: continue
            atr = A[i]
            fvg = None
            for j in range(i, a["ei"] + 1, -1):
                if dirn == 1 and L[j] - H[j - 2] >= P["min_fvg"] * atr: fvg = (H[j - 2], L[j]); break
                if dirn == -1 and L[j - 2] - H[j] >= P["min_fvg"] * atr: fvg = (H[j], L[j - 2]); break
            arm[dirn] = None
            if fvg is None: continue
            lo, hi = fvg
            entry = hi - P["frac"] * (hi - lo) if dirn == 1 else lo + P["frac"] * (hi - lo)
            sl = a["ext"] - P["buf"] * atr if dirn == 1 else a["ext"] + P["buf"] * atr
            if P.get("ema") is not None and P["ema"](ts) * dirn < 0: continue
            order = dict(dir=dirn, entry=entry, sl=sl, t=ts, kz_end=kz_end(ts, P), market=P.get("market", False))
            break
        if order is not None: break
    return order

def kz_end(ts, P):
    m = ts.hour * 60 + ts.minute
    for a, b in P["kz"]:
        if a <= m < b: return ts.normalize() + pd.Timedelta(minutes=b)

def manage(o, b1, b5, P, spread, slip, lev_idx, START):
    dirn = o["dir"]; entry, sl = o["entry"], o["sl"]
    t1 = b1.index.values; O1, H1, L1 = b1.o.values, b1.h.values, b1.l.values
    st = np.searchsorted(t1, np.datetime64(o["t"] + pd.Timedelta(minutes=5)))
    if st >= len(t1): return dict(traded=0, mult=1.0, adds=0, why="nofill")
    close_t = np.datetime64(pd.Timestamp(t1[st]).normalize() + pd.Timedelta(minutes=P["close_min"]))
    kz_end = np.datetime64(o["kz_end"])
    fi = None
    if o.get("market"):
        entry = O1[st] + spread + slip if dirn == 1 else O1[st] - slip
        if (entry - sl) * dirn > 0: fi = st
    else:
        for i in range(st, len(t1)):
            if t1[i] >= kz_end or t1[i] >= close_t: break
            if dirn == 1:
                if L1[i] <= sl: break
                if L1[i] + spread <= entry: fi = i; break
            else:
                if H1[i] + spread >= sl: break
                if H1[i] >= entry: fi = i; break
    if fi is None: return dict(traded=0, mult=1.0, adds=0, why="nofill")
    dist = abs(entry - sl)
    lots0 = min(START * P["risk"] / dist, START * exness_lev(START, lev_idx) / entry)
    lots = [lots0]; prices = [entry]
    last_entry = entry; adds = 0; cur_sl = sl; target = START * P["target"]
    t5 = b5.index.values; C5, H5, L5, A5 = b5.c.values, b5.h.values, b5.l.values, b5.atr.values
    def pnl(px):
        return sum(l * (px - p) * dirn for l, p in zip(lots, prices))
    for i in range(fi, len(t1)):
        h, l = H1[i], L1[i]
        adv = l if dirn == 1 else h + spread
        fav = h if dirn == 1 else l + spread
        if (dirn == 1 and l <= cur_sl) or (dirn == -1 and h + spread >= cur_sl):
            eq = START + pnl(cur_sl - slip * dirn)
            return dict(traded=1, mult=max(eq, 0) / START, adds=adds, why="sl" if eq > 0 else "stopout")
        if START + pnl(adv) <= 0:
            return dict(traded=1, mult=0.0, adds=adds, why="stopout")
        if START + pnl(fav) >= target:
            return dict(traded=1, mult=P["target"], adds=adds, why="target")
        if t1[i] >= close_t:
            px = O1[i] if dirn == 1 else O1[i] + spread
            return dict(traded=1, mult=max(START + pnl(px), 0) / START, adds=adds, why="eod")
        ts = pd.Timestamp(t1[i])
        if ts.minute % 5 == 4 and adds < P["max_adds"]:
            k = np.searchsorted(t5, np.datetime64(ts.floor("5min")))
            if k < 2 or k >= len(t5): continue
            c = C5[k]
            if (c - last_entry) * dirn < P["trig"] * dist: continue
            if dirn == 1:
                if L5[k] - H5[k - 2] <= 0: continue
                nsl = max(cur_sl, L5[k - 2] - P["buf"] * A5[k])
            else:
                if L5[k - 2] - H5[k] <= 0: continue
                nsl = min(cur_sl, H5[k - 2] + P["buf"] * A5[k])
            px = c + spread + slip if dirn == 1 else c - slip
            if (px - nsl) * dirn <= 0: continue
            flt = pnl(c if dirn == 1 else c + spread)
            floor = -START * P["risk"] + P["lock"] * max(flt, 0)
            add = (pnl(nsl) - floor) / ((px - nsl) * dirn)
            eq_now = START + flt
            add = min(add, eq_now * exness_lev(eq_now, lev_idx) / c - sum(lots))
            cur_sl = nsl
            if add > 0.01:
                lots.append(add); prices.append(px); last_entry = px; adds += 1
    return dict(traded=1, mult=1.0, adds=adds, why="end")

BASE = dict(kz=[(120, 300), (420, 600)], close_min=16 * 60, lb=10, max_after=24, min_fvg=0.1,
            frac=0.0, buf=0.1, risk=0.95, trig=1.0, lock=0.3, max_adds=8, target=5.0)

def summarize(df, tgt):
    t = df[df.traded == 1]
    n = len(df); nt = len(t)
    hit = (t.mult >= tgt - 1e-9).sum()
    ev = (df.mult.mean() - 1) * 3000
    return dict(dias=n, trades=nt, alvo=int(hit), taxa_alvo=hit / max(nt, 1), zerou=int((t.mult < 0.05).sum()),
                mult_medio=t.mult.mean() if nt else 0, ev_por_dia=ev,
                resultado_total=(df.mult - 1).sum() * 3000)

if __name__ == "__main__":
    sym = sys.argv[1]
    m1 = load(sym)
    print(sym, m1.index.min(), m1.index.max(), len(m1))
    for tgt in (5.0, 10.0):
        P = dict(BASE, target=tgt)
        df = run(sym, m1, P)
        print(tgt, summarize(df, tgt)); print(df.why.value_counts().to_dict())
