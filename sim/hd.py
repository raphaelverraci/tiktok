import requests, re, sys, os
UA={"User-Agent":"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126 Safari/537.36"}
def get(pair, year, month=None):
    path=f"{pair}/{year}" + (f"/{month}" if month else "")
    fn=f"{pair}_{year}{'_%02d'%month if month else ''}.zip"
    if os.path.exists(fn) and os.path.getsize(fn)>10000: return fn
    s=requests.Session(); s.headers.update(UA)
    url=f"https://www.histdata.com/download-free-forex-historical-data/?/ascii/1-minute-bar-quotes/{path}"
    h=s.get(url,timeout=60).text
    f={k:re.search(f'name="{k}" id="{k}" value="([^"]*)"',h) for k in "tk date datemonth platform timeframe fxpair".split()}
    if not f["tk"]: print("no form",path); return None
    data={k:v.group(1) for k,v in f.items()}
    r=s.post("https://www.histdata.com/get.php",data=data,headers={"Referer":url},timeout=300)
    open(fn,"wb").write(r.content); print(fn,len(r.content),r.headers.get("content-type"),flush=True); return fn
for pair in sys.argv[1:]:
    get(pair,2025)
    for m in range(1,10): get(pair,2026,m)
