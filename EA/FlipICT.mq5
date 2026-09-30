//+------------------------------------------------------------------+
//|                                                     FlipICT.mq5  |
//|  Flip de conta com alavancagem alta: 1 operação por dia.         |
//|  Setup ICT (killzone + varredura de liquidez + MSS + FVG) e      |
//|  pirâmide a favor que reinveste o lucro flutuante.               |
//|  Ativos: XAUUSDm e USTECm (Exness, servidor GMT+0)               |
//+------------------------------------------------------------------+
#property copyright "FlipICT"
#property version   "1.00"
#property description "Flip diário: 1 trade por dia, risco total do capital, pirâmide até o alvo (5x ou 10x)."

#include <Trade/Trade.mqh>

//=== Parâmetros (só os principais) =================================
input double InpAlvo    = 5.0;    // Alvo do flip (x capital): 5 ou 10
input double InpCapital = 3000;   // Capital do flip por dia ($). 0 = saldo inteiro

//=== Regras internas (calibradas na simulação) ======================
// Horários em Nova York (minutos desde 00:00). O EA converte do servidor.
#define KZ_LONDON_START  (2*60)
#define KZ_LONDON_END    (5*60)
#define KZ_NY_START      (7*60)
#define KZ_NY_END        (10*60)
#define ASIA_START       (20*60)   // range da Ásia: 20:00-00:00 NY
#define LON_START        (2*60)    // range de Londres (liquidez para a killzone de NY)
#define LON_END          (5*60)
#define DAY_START        (18*60)   // dia de negociação começa 18:00 NY
#define CLOSE_ALL        (16*60)   // fecha tudo 16:00 NY
const ENUM_TIMEFRAMES TF = PERIOD_M5;
const int    SWING_LB      = 3;      // candles p/ topo/fundo que o MSS precisa romper
const int    MAX_AFTER     = 36;     // candles máx. entre varredura e MSS
const double MIN_FVG_ATR   = 0.10;   // tamanho mínimo do FVG (x ATR14)
const bool   MARKET_ENTRY  = true;   // entra a mercado na quebra (MSS) após confirmar o FVG
const double ENTRY_FRAC    = 0.0;    // se ordem limite: 0 = borda do FVG, 0.5 = meio
const double SL_BUF_ATR    = 0.10;   // folga do stop além do extremo (x ATR14)
const double RISK_FRAC     = 0.95;   // risco da 1ª entrada (fração do capital)
const double ADD_TRIGGER_R = 1.5;    // adiciona após andar X vezes o stop inicial
const double LOCK_FRAC     = 0.30;   // fração do lucro flutuante travada a cada adição
const int    MAX_ADDS      = 8;
const long   MAGIC         = 77007700;

//=== Estado ========================================================
CTrade trade;
int    hATR = INVALID_HANDLE;
int    gmtOffset = 0;               // horas do servidor em relação ao GMT
bool   isGold = true;
double maxSpread = 0;

datetime dayKey = 0;                // início (NY) do dia de negociação atual
double   dayBase = 0;               // capital do flip no dia
bool     tradedToday = false;
bool     dayFinished = false;
string   dayStatus = "";

double asiaH = 0, asiaL = 0, pdh = 0, pdl = 0, lonH = 0, lonL = 0;
bool   takenAsiaH, takenAsiaL, takenPDH, takenPDL, takenLonH, takenLonL;

struct Arm { bool on; double ext; datetime extTime; double ref; int bars; };
Arm armBuy, armSell;

// cesta
bool     basketActive = false;
int      bDir = 0;
double   bInitDist = 0, bLastEntry = 0, bSL = 0, bRiskMoney = 0;
int      bAdds = 0;
datetime pendingExpiry = 0;
datetime lastBar = 0;

//+------------------------------------------------------------------+
//| Tempo: servidor -> Nova York (com horário de verão americano)    |
//+------------------------------------------------------------------+
datetime NthSunday(int year, int mon, int n, int hourUTC)
{
   MqlDateTime s; ZeroMemory(s); s.year = year; s.mon = mon; s.day = 1;
   datetime d = StructToTime(s);
   MqlDateTime t; TimeToStruct(d, t);
   int first = 1 + (7 - t.day_of_week) % 7;
   s.day = first + 7 * (n - 1); s.hour = hourUTC;
   return StructToTime(s);
}
int NYOffset(datetime utc)
{
   MqlDateTime s; TimeToStruct(utc, s);
   datetime a = NthSunday(s.year, 3, 2, 7), b = NthSunday(s.year, 11, 1, 6);
   return (utc >= a && utc < b) ? -4 : -5;
}
datetime ToNY(datetime srv)     { datetime u = srv - gmtOffset * 3600; return u + NYOffset(u) * 3600; }
datetime FromNY(datetime ny)    { datetime u = ny + 5 * 3600; u = ny - NYOffset(u) * 3600; return u + gmtOffset * 3600; }
int      MinOfDay(datetime t)   { return (int)(((long)t % 86400) / 60); }
datetime Midnight(datetime t)   { return (datetime)((long)t - ((long)t % 86400)); }
datetime TradingDayStart(datetime ny)
{
   return (MinOfDay(ny) >= DAY_START) ? Midnight(ny) + DAY_START * 60 : Midnight(ny) - 86400 + DAY_START * 60;
}
bool InKillzone(int m) { return (m >= KZ_LONDON_START && m < KZ_LONDON_END) || (m >= KZ_NY_START && m < KZ_NY_END); }
datetime KillzoneEndNY(datetime ny)
{
   int m = MinOfDay(ny);
   if(m < KZ_LONDON_END) return Midnight(ny) + KZ_LONDON_END * 60;
   return Midnight(ny) + KZ_NY_END * 60;
}

//+------------------------------------------------------------------+
bool RangeHL(datetime nyFrom, datetime nyTo, double &hi, double &lo)
{
   MqlRates r[];
   int n = CopyRates(_Symbol, TF, FromNY(nyFrom), FromNY(nyTo) - 1, r);
   if(n <= 0) return false;
   hi = r[0].high; lo = r[0].low;
   for(int i = 1; i < n; i++) { hi = MathMax(hi, r[i].high); lo = MathMin(lo, r[i].low); }
   return true;
}

void NewDay(datetime tds, datetime ny)
{
   dayKey = tds;
   bInitDist = 0; bRiskMoney = 0; bAdds = 0;
   tradedToday = false; dayFinished = false; dayStatus = "Aguardando setup";
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   dayBase = (InpCapital > 0) ? MathMin(InpCapital, bal) : bal;
   armBuy.on = false; armSell.on = false;
   // máxima/mínima do dia anterior (pula fins de semana)
   datetime to = tds, from = tds - 86400;
   pdh = pdl = 0;
   for(int k = 0; k < 4; k++, to -= 86400, from -= 86400)
      if(RangeHL(from, to, pdh, pdl)) break;
   asiaH = asiaL = 0; lonH = lonL = 0;
   takenAsiaH = takenAsiaL = takenLonH = takenLonL = false; takenPDH = takenPDL = (pdh == 0);
   // se o EA iniciou no meio do dia, níveis já rompidos não contam
   double hi, lo;
   if(ny > tds && RangeHL(tds, ny, hi, lo)) UpdateTaken(hi, lo);
}

//+------------------------------------------------------------------+
int OnInit()
{
   // fuso do servidor: no tester não dá para medir; Exness = GMT+0
   gmtOffset = MQLInfoInteger(MQL_TESTER) ? 0 : (int)MathRound((double)(TimeTradeServer() - TimeGMT()) / 3600.0);
   isGold = (StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0);
   maxSpread = isGold ? 0.60 : 5.0;
   hATR = iATR(_Symbol, TF, 14);
   if(hATR == INVALID_HANDLE) return INIT_FAILED;
   trade.SetExpertMagicNumber(MAGIC);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(50);
   if(InpAlvo <= 1.0) { Print("Alvo precisa ser maior que 1"); return INIT_PARAMETERS_INCORRECT; }
   SyncBasket();
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) { Comment(""); }

//+------------------------------------------------------------------+
//| Posições / ordens do EA                                          |
//+------------------------------------------------------------------+
int CollectPositions(ulong &tk[], double &vol[], double &price[], int &dir)
{
   ArrayResize(tk, 0); ArrayResize(vol, 0); ArrayResize(price, 0); dir = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MAGIC || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int n = ArraySize(tk);
      ArrayResize(tk, n + 1); ArrayResize(vol, n + 1); ArrayResize(price, n + 1);
      tk[n] = t; vol[n] = PositionGetDouble(POSITION_VOLUME); price[n] = PositionGetDouble(POSITION_PRICE_OPEN);
      dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
   }
   return ArraySize(tk);
}
int CountPending()
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(OrderSelect(t) && OrderGetInteger(ORDER_MAGIC) == MAGIC && OrderGetString(ORDER_SYMBOL) == _Symbol) n++;
   }
   return n;
}
void DeletePending()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(OrderSelect(t) && OrderGetInteger(ORDER_MAGIC) == MAGIC && OrderGetString(ORDER_SYMBOL) == _Symbol)
         trade.OrderDelete(t);
   }
}
void CloseAll(string why)
{
   DeletePending();
   ulong tk[]; double v[], p[]; int d;
   int n = CollectPositions(tk, v, p, d);
   for(int i = 0; i < n; i++) trade.PositionClose(tk[i]);
   if(n > 0) PrintFormat("FlipICT: fechando cesta (%s)", why);
   basketActive = false;
}

// lucro (moeda da conta) de 'lots' saindo de 'from' para 'to'
double ProfitAt(int dir, double lots, double from, double to)
{
   double p = 0;
   if(!OrderCalcProfit(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, from, to, p)) return 0;
   return p;
}
double BasketProfitAt(double px, const double &vol[], const double &price[], int dir)
{
   double s = 0;
   for(int i = 0; i < ArraySize(vol); i++) s += ProfitAt(dir, vol[i], price[i], px);
   return s;
}
double NormLots(double lots)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   int dg = (int)MathMax(0, -MathFloor(MathLog10(step) + 1e-9));
   lots = NormalizeDouble(MathFloor(lots / step + 1e-9) * step, dg);
   return (lots < mn) ? 0 : lots;
}
// reduz o lote até caber na margem livre
double CapByMargin(int dir, double lots, double price)
{
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE), m = 0;
   for(int k = 0; k < 40 && lots > 0; k++)
   {
      if(!OrderCalcMargin(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, price, m)) return 0;
      if(m <= free * 0.98) return lots;
      lots = NormLots(lots * 0.85);
   }
   return 0;
}
// envia volume em partes respeitando o lote máximo por ordem
bool SendSplit(int dir, double lots, double price, double sl, bool pending)
{
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   bool ok = true;
   while(lots > 0)
   {
      double v = NormLots(MathMin(lots, mx));
      if(v <= 0) break;
      bool r;
      if(pending)
         r = (dir > 0) ? trade.BuyLimit(v, price, _Symbol, sl, 0, ORDER_TIME_GTC, 0, "FlipICT")
                       : trade.SellLimit(v, price, _Symbol, sl, 0, ORDER_TIME_GTC, 0, "FlipICT");
      else
         r = (dir > 0) ? trade.Buy(v, _Symbol, 0, sl, 0, "FlipICT add")
                       : trade.Sell(v, _Symbol, 0, sl, 0, "FlipICT add");
      ok = ok && r;
      if(!r) { PrintFormat("FlipICT: falha na ordem (%d) %s", trade.ResultRetcode(), trade.ResultRetcodeDescription()); break; }
      lots -= v;
   }
   return ok;
}
void SetBasketSL(double sl)
{
   ulong tk[]; double v[], p[]; int d;
   int n = CollectPositions(tk, v, p, d);
   sl = NormalizeDouble(sl, _Digits);
   for(int i = 0; i < n; i++)
      if(PositionSelectByTicket(tk[i]) && MathAbs(PositionGetDouble(POSITION_SL) - sl) > _Point)
         trade.PositionModify(tk[i], sl, 0);
   bSL = sl;
}
void SyncBasket()
{
   ulong tk[]; double v[], p[]; int d;
   int n = CollectPositions(tk, v, p, d);
   if(n > 0 && !basketActive)
   {
      // cesta encontrada (1º fill ou reinício do EA)
      basketActive = true; bDir = d; bAdds = 0;
      PositionSelectByTicket(tk[0]);
      bSL = PositionGetDouble(POSITION_SL);
      double avg = 0, tv = 0;
      for(int i = 0; i < n; i++) { avg += v[i] * p[i]; tv += v[i]; }
      avg /= tv;
      bLastEntry = avg;
      if(bInitDist <= 0) bInitDist = MathAbs(avg - bSL);
      if(bRiskMoney <= 0) bRiskMoney = -BasketProfitAt(bSL, v, p, d);
      tradedToday = true;
      dayStatus = "Em operação";
   }
   else if(n == 0 && basketActive)
   {
      basketActive = false;
      dayFinished = true;
      if(dayStatus == "Em operação") dayStatus = "Stop atingido - fim do dia";
   }
}

//+------------------------------------------------------------------+
//| Liquidez: marca níveis já tomados                                |
//+------------------------------------------------------------------+
void UpdateTaken(double hi, double lo)
{
   if(asiaH > 0 && hi > asiaH) takenAsiaH = true;
   if(asiaL > 0 && lo < asiaL) takenAsiaL = true;
   if(pdh > 0 && hi > pdh) takenPDH = true;
   if(pdl > 0 && lo < pdl) takenPDL = true;
   if(lonH > 0 && hi > lonH) takenLonH = true;
   if(lonL > 0 && lo < lonL) takenLonL = true;
}

//+------------------------------------------------------------------+
//| Procura o setup no candle fechado                                |
//+------------------------------------------------------------------+
void CheckSetup(const MqlRates &r[], double atr, int nyMin, datetime ny)
{
   bool kz = InKillzone(nyMin);
   if(!kz) { armBuy.on = armSell.on = false; UpdateTaken(r[1].high, r[1].low); return; }
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int side = 0; side < 2; side++)
   {
      int dir = side == 0 ? 1 : -1;
      Arm a;
      if(dir > 0) a = armBuy; else a = armSell;
      double ext = dir > 0 ? r[1].low : r[1].high;

      if(!a.on)
      {
         bool swept = false;
         if(dir > 0)
         {
            if(!takenAsiaL && asiaL > 0 && r[1].low < asiaL) { takenAsiaL = true; swept = true; }
            if(!takenPDL && pdl > 0 && r[1].low < pdl)       { takenPDL = true;   swept = true; }
            if(!takenLonL && lonL > 0 && r[1].low < lonL)    { takenLonL = true;  swept = true; }
         }
         else
         {
            if(!takenAsiaH && asiaH > 0 && r[1].high > asiaH) { takenAsiaH = true; swept = true; }
            if(!takenPDH && pdh > 0 && r[1].high > pdh)       { takenPDH = true;   swept = true; }
            if(!takenLonH && lonH > 0 && r[1].high > lonH)    { takenLonH = true;  swept = true; }
         }
         if(swept)
         {
            a.on = true; a.ext = ext; a.extTime = r[1].time; a.bars = 0;
            a.ref = dir > 0 ? r[2].high : r[2].low;
            for(int k = 2; k <= SWING_LB + 1; k++) a.ref = dir > 0 ? MathMax(a.ref, r[k].high) : MathMin(a.ref, r[k].low);
         }
      }
      else
      {
         a.bars++;
         if((dir > 0 && r[1].low < a.ext) || (dir < 0 && r[1].high > a.ext))
         {
            a.ext = ext; a.extTime = r[1].time;
            a.ref = dir > 0 ? r[2].high : r[2].low;
            for(int k = 2; k <= SWING_LB + 1; k++) a.ref = dir > 0 ? MathMax(a.ref, r[k].high) : MathMin(a.ref, r[k].low);
         }
         else if(a.bars > MAX_AFTER) a.on = false;
         else if((dir > 0 && r[1].close > a.ref) || (dir < 0 && r[1].close < a.ref))
         {
            // MSS: procura o FVG mais recente entre o extremo e o candle da quebra
            a.on = false;
            double lo = 0, hi = 0; bool found = false;
            for(int j = 1; j + 2 < ArraySize(r) && r[j + 2].time >= a.extTime; j++)
            {
               if(dir > 0 && r[j].low - r[j + 2].high >= MIN_FVG_ATR * atr) { lo = r[j + 2].high; hi = r[j].low; found = true; break; }
               if(dir < 0 && r[j + 2].low - r[j].high >= MIN_FVG_ATR * atr) { lo = r[j].high; hi = r[j + 2].low; found = true; break; }
            }
            if(found && spread <= maxSpread)
            {
               double entry = dir > 0 ? hi - ENTRY_FRAC * (hi - lo) : lo + ENTRY_FRAC * (hi - lo);
               double sl    = dir > 0 ? a.ext - SL_BUF_ATR * atr : a.ext + SL_BUF_ATR * atr;
               PlaceEntry(dir, entry, sl, ny);
            }
         }
      }
      if(dir > 0) armBuy = a; else armSell = a;
      if(tradedToday) break;
   }
   UpdateTaken(r[1].high, r[1].low);
}

void PlaceEntry(int dir, double entry, double sl, datetime ny)
{
   entry = NormalizeDouble(entry, _Digits); sl = NormalizeDouble(sl, _Digits);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   bool market = MARKET_ENTRY || ((dir > 0) ? (ask <= entry + stops) : (bid >= entry - stops));
   double px = market ? (dir > 0 ? ask : bid) : entry;
   if((px - sl) * dir <= stops) return;

   double riskMoney = dayBase * RISK_FRAC;
   double lossPerLot = -ProfitAt(dir, 1.0, px, sl);
   if(lossPerLot <= 0) return;
   double lots = CapByMargin(dir, NormLots(riskMoney / lossPerLot), px);
   if(lots <= 0) { Print("FlipICT: lote insuficiente para o setup"); return; }

   bInitDist = MathAbs(px - sl); bRiskMoney = lots * lossPerLot; bSL = sl;
   if(SendSplit(dir, lots, px, sl, !market))
   {
      tradedToday = true;
      pendingExpiry = FromNY(KillzoneEndNY(ny));
      dayStatus = StringFormat("%s %s @ %s  SL %s  lote %.2f", market ? "Entrada" : "Ordem limite",
                               dir > 0 ? "COMPRA" : "VENDA", DoubleToString(px, _Digits), DoubleToString(sl, _Digits), lots);
      Print("FlipICT: ", dayStatus);
      SyncBasket();
   }
}

//+------------------------------------------------------------------+
//| Pirâmide: a cada M5 fechado                                      |
//+------------------------------------------------------------------+
void ManagePyramid(const MqlRates &r[], double atr)
{
   if(!basketActive || bAdds >= MAX_ADDS) return;
   ulong tk[]; double v[], p[]; int d;
   if(CollectPositions(tk, v, p, d) == 0) return;
   double c = r[1].close;
   if((c - bLastEntry) * bDir < ADD_TRIGGER_R * bInitDist) return;
   // novo FVG a favor no último candle
   double nsl;
   if(bDir > 0) { if(r[1].low <= r[3].high) return; nsl = MathMax(bSL, r[3].low - SL_BUF_ATR * atr); }
   else         { if(r[1].high >= r[3].low) return; nsl = MathMin(bSL, r[3].high + SL_BUF_ATR * atr); }

   double px = bDir > 0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if((px - nsl) * bDir <= stops) return;

   // quanto adicionar: se o preço voltar ao novo stop, a cesta perde no máximo
   // o risco inicial menos a parte travada do lucro flutuante
   double flt   = AccountInfoDouble(ACCOUNT_EQUITY) - AccountInfoDouble(ACCOUNT_BALANCE);
   double floor = -bRiskMoney + LOCK_FRAC * MathMax(flt, 0);
   double atSL  = BasketProfitAt(nsl, v, p, bDir);
   double lossPerLot = -ProfitAt(bDir, 1.0, px, nsl);
   SetBasketSL(nsl);
   if(lossPerLot <= 0) return;
   double lots = CapByMargin(bDir, NormLots((atSL - floor) / lossPerLot), px);
   if(lots <= 0) return;
   if(SendSplit(bDir, lots, px, nsl, false))
   {
      bAdds++; bLastEntry = px;
      PrintFormat("FlipICT: adição %d  lote %.2f  novo SL %s", bAdds, lots, DoubleToString(nsl, _Digits));
      SetBasketSL(nsl);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime now = TimeCurrent();
   datetime ny  = ToNY(now);
   int nyMin    = MinOfDay(ny);
   datetime tds = TradingDayStart(ny);
   if(tds != dayKey) NewDay(tds, ny);

   SyncBasket();
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double target = dayBase * InpAlvo;
   double gain = eq - AccountInfoDouble(ACCOUNT_BALANCE);   // flutuante da cesta

   // alvo do flip
   if(basketActive && dayBase + gain >= target)
   {
      CloseAll("alvo atingido");
      dayFinished = true; dayStatus = StringFormat("ALVO %.0fx ATINGIDO", InpAlvo);
   }
   // capital do dia perdido (quando a conta tem mais saldo que o capital do flip)
   if(basketActive && gain <= -dayBase)
   {
      CloseAll("capital do dia zerado");
      dayFinished = true; dayStatus = "Capital do dia perdido";
   }
   // fechamento do dia (16:00 NY até 18:00 NY) e sexta-feira
   bool closeWindow = (nyMin >= CLOSE_ALL && nyMin < DAY_START);
   if(closeWindow && (basketActive || CountPending() > 0))
   {
      CloseAll("fim do dia");
      dayFinished = true; dayStatus = "Encerrado no fim do dia";
   }
   // ordem limite expira no fim da killzone
   if(CountPending() > 0 && now >= pendingExpiry)
   {
      DeletePending();
      if(!basketActive) { dayFinished = true; dayStatus = "Ordem não executada"; }
   }

   // candle novo de M5
   datetime bt = iTime(_Symbol, TF, 0);
   if(bt != lastBar)
   {
      lastBar = bt;
      MqlRates r[];
      ArraySetAsSeries(r, true);
      if(CopyRates(_Symbol, TF, 0, 200, r) >= SWING_LB + 5)
      {
         double atrb[];
         if(CopyBuffer(hATR, 0, 1, 1, atrb) == 1)
         {
            // range da Ásia fica pronto à meia-noite de NY
            if(asiaH == 0 && MinOfDay(ny) < DAY_START)
            {
               datetime mid = Midnight(ny);
               if(RangeHL(mid - (24 * 60 - ASIA_START) * 60, mid, asiaH, asiaL))
               {
                  // níveis já rompidos desde o fim da Ásia não contam
                  double hi, lo;
                  if(RangeHL(mid, ny, hi, lo)) UpdateTaken(hi, lo);
               }
            }
            // range de Londres fica pronto às 05:00 NY
            if(lonH == 0 && MinOfDay(ny) >= LON_END && MinOfDay(ny) < DAY_START)
            {
               datetime mid = Midnight(ny);
               if(RangeHL(mid + LON_START * 60, mid + LON_END * 60, lonH, lonL))
               {
                  double hi, lo;
                  if(RangeHL(mid + LON_END * 60, ny, hi, lo)) UpdateTaken(hi, lo);
               }
            }
            int barMin = MinOfDay(ToNY(r[1].time));
            if(basketActive) ManagePyramid(r, atrb[0]);
            else if(!tradedToday && !dayFinished && !closeWindow) CheckSetup(r, atrb[0], barMin, ny);
            else UpdateTaken(r[1].high, r[1].low);
         }
      }
   }
   ShowPanel(eq, target);
}

void ShowPanel(double eq, double target)
{
   Comment(StringFormat(
      "FlipICT  |  %s  |  alvo %.0fx\n"
      "Capital do dia: %.2f   Alvo: %.2f\n"
      "Patrimônio: %.2f   (%.2fx)\n"
      "Ásia H/L: %s / %s   Londres H/L: %s / %s   Dia ant. H/L: %s / %s\n"
      "Adições: %d/%d\n"
      "Status: %s",
      _Symbol, InpAlvo, dayBase, target, eq, dayBase > 0 ? (dayBase + eq - AccountInfoDouble(ACCOUNT_BALANCE)) / dayBase : 0,
      DoubleToString(asiaH, _Digits), DoubleToString(asiaL, _Digits), DoubleToString(lonH, _Digits), DoubleToString(lonL, _Digits), DoubleToString(pdh, _Digits), DoubleToString(pdl, _Digits),
      bAdds, MAX_ADDS, dayStatus));
}

// resultado do backtest em "capitais do flip" ganhos/perdidos (ex.: +12 = lucro de 12 x $3000)
double OnTester()
{
   double cap = InpCapital > 0 ? InpCapital : TesterStatistics(STAT_INITIAL_DEPOSIT);
   return TesterStatistics(STAT_PROFIT) / MathMax(cap, 1);
}
//+------------------------------------------------------------------+
