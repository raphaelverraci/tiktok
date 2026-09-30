//+------------------------------------------------------------------+
//|                                                FlowRecorder.mq5  |
//|  EA gravador (não opera): grava o book (10 níveis de cada lado)  |
//|  e os negócios com lado agressor, um arquivo por dia em          |
//|  MQL5/Files/flow_<símbolo>_<AAAAMMDD>.csv                        |
//+------------------------------------------------------------------+
#property copyright "FlipICT"
#property version   "1.00"

#define LEVELS 10

int      fh = INVALID_HANDLE;
string   curDay = "";
ulong    lastTickMsc = 0;
long     nBook = 0, nDeals = 0;

void OpenFile()
{
   string day = TimeToString(TimeCurrent(), TIME_DATE);
   StringReplace(day, ".", "");
   if(day == curDay && fh != INVALID_HANDLE) return;
   if(fh != INVALID_HANDLE) FileClose(fh);
   curDay = day;
   string fn = "flow_" + _Symbol + "_" + day + ".csv";
   bool exists = FileIsExist(fn);
   fh = FileOpen(fn, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
   if(fh == INVALID_HANDLE) return;
   FileSeek(fh, 0, SEEK_END);
   if(!exists)
   {
      // B = book: preços/volumes de compra (bid1..10) e venda (ask1..10)
      // T = negócio: preço, volume, lado (1 compra agressora, -1 venda agressora, 0 indefinido)
      string h = "tipo;time_msc";
      for(int i = 1; i <= LEVELS; i++) h += ";bp" + (string)i + ";bv" + (string)i;
      for(int i = 1; i <= LEVELS; i++) h += ";ap" + (string)i + ";av" + (string)i;
      FileWriteString(fh, h + "\r\n");
   }
}

int OnInit()
{
   if(!MarketBookAdd(_Symbol)) Print("FlowRecorder: book indisponível para ", _Symbol);
   lastTickMsc = (ulong)TimeCurrent() * 1000;
   OpenFile();
   EventSetMillisecondTimer(500);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   MarketBookRelease(_Symbol);
   EventKillTimer();
   if(fh != INVALID_HANDLE) FileClose(fh);
   Comment("");
}

void OnBookEvent(const string &symbol)
{
   if(symbol != _Symbol) return;
   MqlBookInfo b[];
   if(!MarketBookGet(_Symbol, b)) return;
   OpenFile();
   if(fh == INVALID_HANDLE) return;
   // o MT5 entrega vendas (preço decrescente) e depois compras (preço decrescente)
   double bp[LEVELS], bv[LEVELS], ap[LEVELS], av[LEVELS];
   ArrayInitialize(bp, 0); ArrayInitialize(bv, 0); ArrayInitialize(ap, 0); ArrayInitialize(av, 0);
   int nb = 0, na = 0, n = ArraySize(b);
   for(int i = 0; i < n; i++)
      if((b[i].type == BOOK_TYPE_BUY || b[i].type == BOOK_TYPE_BUY_MARKET) && nb < LEVELS)
      { bp[nb] = b[i].price; bv[nb] = b[i].volume_real; nb++; }
   for(int i = n - 1; i >= 0; i--)
      if((b[i].type == BOOK_TYPE_SELL || b[i].type == BOOK_TYPE_SELL_MARKET) && na < LEVELS)
      { ap[na] = b[i].price; av[na] = b[i].volume_real; na++; }
   string s = "B;" + (string)(long)GetMicrosecondCount();
   MqlTick tk;
   if(SymbolInfoTick(_Symbol, tk)) s = "B;" + (string)tk.time_msc;
   for(int i = 0; i < LEVELS; i++) s += ";" + DoubleToString(bp[i], _Digits) + ";" + DoubleToString(bv[i], 0);
   for(int i = 0; i < LEVELS; i++) s += ";" + DoubleToString(ap[i], _Digits) + ";" + DoubleToString(av[i], 0);
   FileWriteString(fh, s + "\r\n");
   nBook++;
}

void OnTimer()
{
   OpenFile();
   if(fh == INVALID_HANDLE) return;
   MqlTick t[];
   int k = CopyTicks(_Symbol, t, COPY_TICKS_TRADE, lastTickMsc + 1, 100000);
   for(int i = 0; i < k; i++)
   {
      int side = 0;
      bool buy = (t[i].flags & TICK_FLAG_BUY) != 0, sell = (t[i].flags & TICK_FLAG_SELL) != 0;
      if(buy && !sell) side = 1; else if(sell && !buy) side = -1;
      FileWriteString(fh, StringFormat("T;%I64d;%s;%.0f;%d\r\n", t[i].time_msc,
                      DoubleToString(t[i].last, _Digits), t[i].volume_real, side));
      lastTickMsc = t[i].time_msc;
      nDeals++;
   }
   FileFlush(fh);
   Comment(StringFormat("FlowRecorder | %s\nBook gravados: %I64d   Negócios gravados: %I64d\nArquivo: flow_%s_%s.csv",
                        _Symbol, nBook, nDeals, _Symbol, curDay));
}
