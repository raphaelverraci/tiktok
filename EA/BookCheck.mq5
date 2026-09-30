//+------------------------------------------------------------------+
//|                                                   BookCheck.mq5  |
//|  Diagnóstico do book (DOM) e dos negócios do símbolo do gráfico. |
//|  Mostra no gráfico se o book/volume parecem reais e grava tudo   |
//|  em MQL5/Files/book_<símbolo>.csv para análise.                  |
//|  Não abre operações.                                             |
//+------------------------------------------------------------------+
#property copyright "FlipICT"
#property version   "1.00"

input int InpMinutos = 30;   // Tempo de coleta (minutos)

int      fh = INVALID_HANDLE;
datetime t0;
long     nBook = 0, nLevelsSum = 0, maxLevels = 0, volChanges = 0;
double   lastTopVol = -1;
long     nTicks = 0, nTicksWithVolume = 0, nBuyAggr = 0, nSellAggr = 0;
bool     bookOk = false;
ulong    lastTickMsc = 0;

int OnInit()
{
   bookOk = MarketBookAdd(_Symbol);
   fh = FileOpen("book_" + _Symbol + ".csv", FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
   if(fh != INVALID_HANDLE) FileWrite(fh, "time_msc", "tipo", "nivel", "preco", "volume");
   t0 = TimeCurrent();
   lastTickMsc = (ulong)TimeCurrent() * 1000;
   EventSetTimer(5);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(bookOk) MarketBookRelease(_Symbol);
   if(fh != INVALID_HANDLE) FileClose(fh);
   EventKillTimer();
}

void OnBookEvent(const string &symbol)
{
   if(symbol != _Symbol) return;
   MqlBookInfo b[];
   if(!MarketBookGet(_Symbol, b)) return;
   int n = ArraySize(b);
   nBook++; nLevelsSum += n; maxLevels = MathMax(maxLevels, n);
   // volume do melhor nível de compra: muda com o tempo?
   for(int i = 0; i < n; i++)
      if(b[i].type == BOOK_TYPE_BUY || b[i].type == BOOK_TYPE_BUY_MARKET)
      {
         if(lastTopVol >= 0 && b[i].volume_real != lastTopVol) volChanges++;
         lastTopVol = b[i].volume_real;
         break;
      }
   if(fh != INVALID_HANDLE)
   {
      long msc = (long)GetTickCount64();
      for(int i = 0; i < n; i++)
         FileWrite(fh, msc, (b[i].type == BOOK_TYPE_SELL || b[i].type == BOOK_TYPE_SELL_MARKET) ? "venda" : "compra",
                   i, DoubleToString(b[i].price, _Digits), DoubleToString(b[i].volume_real, 2));
   }
}

void OnTimer()
{
   // negócios: ticks com volume e lado agressor (só existem em bolsa)
   MqlTick t[];
   int k = CopyTicks(_Symbol, t, COPY_TICKS_ALL, lastTickMsc + 1, 100000);
   for(int i = 0; i < k; i++)
   {
      nTicks++;
      // agressão só conta se o tick for um negócio real (preço "last" e volume)
      bool deal = (t[i].volume_real > 0 || t[i].volume > 0) && t[i].last > 0;
      if(deal) nTicksWithVolume++;
      bool buy = deal && (t[i].flags & TICK_FLAG_BUY) != 0, sell = deal && (t[i].flags & TICK_FLAG_SELL) != 0;
      if(buy && !sell) nBuyAggr++;
      if(sell && !buy) nSellAggr++;
      lastTickMsc = t[i].time_msc;
   }

   double avgLv = nBook > 0 ? (double)nLevelsSum / nBook : 0;
   string veredito;
   if(!bookOk || nBook == 0)                 veredito = "SEM BOOK: a corretora não envia profundidade.";
   else if(nBuyAggr + nSellAggr == 0)        veredito = "Book de CFD/cotações: sem negócios reais nem agressão. NÃO serve para fluxo.";
   else if(maxLevels >= 10 && volChanges > 50) veredito = "Parece BOOK REAL (bolsa): níveis, volumes variando e agressão.";
   else                                       veredito = "Inconclusivo: colete por mais tempo.";

   Comment(StringFormat(
      "BookCheck  |  %s\n"
      "Book ativo: %s   atualizações: %I64d\n"
      "Níveis por lado (média/máx): %.1f / %I64d\n"
      "Mudanças de volume no melhor nível: %I64d\n"
      "Ticks: %I64d   com volume: %I64d\n"
      "Agressão compra/venda: %I64d / %I64d\n\n"
      "VEREDITO: %s",
      _Symbol, bookOk ? "sim" : "não", nBook, avgLv / 2.0, maxLevels, volChanges,
      nTicks, nTicksWithVolume, nBuyAggr, nSellAggr, veredito));

   if(TimeCurrent() - t0 >= InpMinutos * 60)
   {
      Print("BookCheck: coleta encerrada. Arquivo em MQL5/Files/book_", _Symbol, ".csv");
      ExpertRemove();
   }
}
