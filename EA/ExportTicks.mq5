//+------------------------------------------------------------------+
//|                                                 ExportTicks.mq5  |
//|  Script: exporta o histórico de negócios (ticks com volume e     |
//|  lado agressor) do símbolo do gráfico para MQL5/Files.           |
//|  Um arquivo por dia: ticks_<símbolo>_<AAAAMMDD>.csv              |
//+------------------------------------------------------------------+
#property copyright "FlipICT"
#property version   "1.00"
#property script_show_inputs

input int InpDias = 60;   // Quantos dias para trás exportar

void OnStart()
{
   datetime today = TimeCurrent() - (TimeCurrent() % 86400);
   int files = 0; long total = 0;
   for(int d = InpDias; d >= 0; d--)
   {
      datetime from = today - d * 86400, to = from + 86400;
      MqlTick t[];
      int n = CopyTicksRange(_Symbol, t, COPY_TICKS_TRADE, (ulong)from * 1000, (ulong)to * 1000 - 1);
      if(n <= 0) continue;
      string fn = "ticks_" + _Symbol + "_" + TimeToString(from, TIME_DATE) + ".csv";
      StringReplace(fn, ".", "");
      StringReplace(fn, "csv", ".csv");
      int fh = FileOpen(fn, FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
      if(fh == INVALID_HANDLE) continue;
      FileWrite(fh, "time_msc", "bid", "ask", "last", "volume", "flags");
      for(int i = 0; i < n; i++)
         FileWrite(fh, t[i].time_msc, DoubleToString(t[i].bid, _Digits), DoubleToString(t[i].ask, _Digits),
                   DoubleToString(t[i].last, _Digits), DoubleToString(t[i].volume_real, 2), (int)t[i].flags);
      FileClose(fh);
      files++; total += n;
      Comment(StringFormat("ExportTicks %s: %d dias, %I64d ticks...", _Symbol, files, total));
   }
   Comment("");
   string msg = StringFormat("ExportTicks: %d arquivos, %I64d ticks exportados em MQL5/Files", files, total);
   Print(msg); Alert(msg);
}
