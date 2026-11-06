//+------------------------------------------------------------------+
//| XauEurLab.mq5                                                    |
//| Expert Advisor for MetaTrader 5                                  |
//|  Strategy A: Asian range breakout at the London open             |
//|  Strategy B: pullback to the fast EMA in the trend direction     |
//| Same rules as the web backtester (trading/index.html).           |
//| Logs every closed trade to a CSV file and, optionally, Notion.   |
//| All session hours are in UTC.                                    |
//+------------------------------------------------------------------+
#property copyright "XAU-EUR Lab"
#property version   "1.10"
#property description "Ruptura del rango asiatico (A) y retroceso a la EMA (B) con gestion de riesgo y registro en CSV/Notion."

#include <Trade/Trade.mqh>

enum ENUM_XEL_STRATEGY
  {
   XEL_STRAT_A  = 0, // A - Ruptura rango asiatico
   XEL_STRAT_B  = 1, // B - Retroceso EMA
   XEL_STRAT_AB = 2  // A + B (requiere cuenta hedging)
  };

enum ENUM_XEL_SLMODE
  {
   XEL_SL_MID      = 0, // Mitad del rango
   XEL_SL_OPPOSITE = 1, // Lado opuesto del rango
   XEL_SL_ATR      = 2  // ATR x multiplicador
  };

input group "Estrategia"
input ENUM_XEL_STRATEGY InpStrategy      = XEL_STRAT_A;   // Estrategia
input ENUM_TIMEFRAMES   InpTF            = PERIOD_M15;    // Marco temporal de las senales
input double            InpRR            = 2.0;           // Objetivo en R
input double            InpAtrMult       = 1.5;           // Multiplicador ATR para el stop
input int               InpCloseHourUTC  = 20;            // Hora UTC de cierre de todo

input group "A - Rango asiatico"
input int               InpAsiaStartUTC  = 0;             // Rango Asia desde (UTC)
input int               InpAsiaEndUTC    = 7;             // Rango Asia hasta (UTC)
input int               InpTradeStartUTC = 7;             // Entradas desde (UTC)
input int               InpTradeEndUTC   = 11;            // Entradas hasta (UTC)
input ENUM_XEL_SLMODE   InpSLMode        = XEL_SL_MID;    // Tipo de stop
input double            InpMaxRangeATR   = 14.0;          // Rango maximo en multiplos de ATR
input bool              InpTrendFilter   = true;          // Solo a favor de la EMA 200

input group "B - Retroceso EMA"
input int               InpSessStartUTC  = 7;             // Sesion desde (UTC)
input int               InpSessEndUTC    = 17;            // Sesion hasta (UTC)
input int               InpEmaFast       = 20;            // EMA rapida
input int               InpEmaMid        = 50;            // EMA media
input int               InpMaxTradesDayB = 2;             // Maximo operaciones B por dia

input group "Riesgo"
input double            InpRiskPct          = 1.0;        // Riesgo por operacion (% del balance)
input double            InpMaxDailyLossPct  = 2.0;        // Perdida diaria maxima (%)
input int               InpMaxLossesInRow   = 2;          // Stops seguidos que detienen el dia
input double            InpMaxWeeklyLossPct = 5.0;        // Perdida semanal maxima (%)
input int               InpMaxSpreadPoints  = 0;          // Spread maximo en puntos (0 = sin filtro)

input group "Noticias (solo en vivo)"
input bool              InpNewsFilter    = true;          // Bloquear entradas cerca de noticias de alto impacto
input int               InpNewsMinutes   = 15;            // Minutos antes y despues

input group "Hora del servidor"
input int               InpTesterServerGMT = 2;           // Desfase GMT del servidor en el probador (en vivo es automatico)

input group "Registro"
input bool              InpWriteCSV      = true;          // Guardar diario CSV (carpeta Common/Files)
input string            InpCSVName       = "XauEurLab_diario.csv"; // Nombre del CSV
input bool              InpSendNotion    = false;         // Enviar cada operacion a Notion
input string            InpNotionToken   = "";            // Token de la integracion de Notion
input string            InpNotionDB      = "";            // ID de la base de datos de Notion
input string            InpNotionSummary = "";            // ID de la pagina Resumen (opcional, para winrate automatico)
input bool              InpPushNotify    = false;         // Enviar aviso al celular al cerrar cada operacion

input group "General"
input long              InpMagic         = 240611;        // Numero magico (A usa este, B usa +1)

CTrade   trade;
int      hEmaF = INVALID_HANDLE, hEmaM = INVALID_HANDLE, hEmaS = INVALID_HANDLE, hAtr = INVALID_HANDLE;
datetime gLastBar = 0;
string   gStatus  = "";

struct XelStats
  {
   int    entriesA;
   int    entriesB;
   double pnlDay;
   double pnlWeek;
   int    lossesInRow;
  };

//+------------------------------------------------------------------+
//| Time helpers                                                     |
//+------------------------------------------------------------------+
int GmtOffset()
  {
   if(MQLInfoInteger(MQL_TESTER))
      return InpTesterServerGMT * 3600;
   long d = (long)TimeTradeServer() - (long)TimeGMT();
   return (int)(MathRound(d / 1800.0) * 1800);
  }

datetime ToUTC(const datetime srv) { return (datetime)((long)srv - GmtOffset()); }

double HourUTC(const datetime srv)
  {
   long u = (long)ToUTC(srv);
   return (double)(u % 86400) / 3600.0;
  }

datetime DayStartUTC(const datetime srv)
  {
   long u = (long)ToUTC(srv);
   return (datetime)(u - (u % 86400));
  }

string IsoUTC(const datetime srv)
  {
   MqlDateTime d;
   TimeToStruct(ToUTC(srv), d);
   return StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ", d.year, d.mon, d.day, d.hour, d.min, d.sec);
  }

//+------------------------------------------------------------------+
//| Indicator helpers                                                |
//+------------------------------------------------------------------+
double Buf(const int handle, const int shift)
  {
   double b[];
   if(CopyBuffer(handle, 0, shift, 1, b) != 1)
      return EMPTY_VALUE;
   return b[0];
  }

bool IsOurMagic(const long m) { return (m == InpMagic || m == InpMagic + 1); }

bool HasPosition(const long magic)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == magic)
         return true;
     }
   return false;
  }

bool HasAnyPositionOnSymbol()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
     }
   return false;
  }

double FloatingPnl()
  {
   double s = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(IsOurMagic(PositionGetInteger(POSITION_MAGIC)))
         s += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return s;
  }

void CloseOurPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC))) continue;
      if(!trade.PositionClose(t))
         PrintFormat("No pude cerrar la posicion %I64u: %s", t, trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Daily / weekly statistics from history (survives restarts)       |
//+------------------------------------------------------------------+
void GetStats(XelStats &s)
  {
   s.entriesA = 0; s.entriesB = 0; s.pnlDay = 0; s.pnlWeek = 0; s.lossesInRow = 0;
   datetime nowSrv = TimeCurrent();
   int      off    = GmtOffset();
   datetime dayUTC = DayStartUTC(nowSrv);
   MqlDateTime dt;
   TimeToStruct(dayUTC, dt);
   int back = (dt.day_of_week + 6) % 7;                // days since Monday
   datetime daySrv  = (datetime)((long)dayUTC + off);
   datetime weekSrv = (datetime)((long)dayUTC - back * 86400 + off);
   if(!HistorySelect(weekSrv, nowSrv + 60))
      return;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      long mg = HistoryDealGetInteger(d, DEAL_MAGIC);
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      string sym = HistoryDealGetString(d, DEAL_SYMBOL);
      bool ours = IsOurMagic(mg);
      if(!ours && entry != DEAL_ENTRY_IN)
        {
         // closing deals may carry the position magic or 0; check the position's entry deal
         long pid = HistoryDealGetInteger(d, DEAL_POSITION_ID);
         for(int j = 0; j < n; j++)
           {
            ulong e = HistoryDealGetTicket(j);
            if(HistoryDealGetInteger(e, DEAL_POSITION_ID) == pid && HistoryDealGetInteger(e, DEAL_ENTRY) == DEAL_ENTRY_IN)
              { ours = IsOurMagic(HistoryDealGetInteger(e, DEAL_MAGIC)); break; }
           }
        }
      if(!ours) continue;
      double pl = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION);
      s.pnlWeek += pl;
      if(t < daySrv) continue;
      s.pnlDay += pl;
      if(entry == DEAL_ENTRY_IN && sym == _Symbol)
        {
         if(mg == InpMagic) s.entriesA++;
         else               s.entriesB++;
        }
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
        {
         if(pl < 0) s.lossesInRow++;
         else       s.lossesInRow = 0;
        }
     }
  }

//+------------------------------------------------------------------+
//| News filter (economic calendar, live only)                       |
//+------------------------------------------------------------------+
bool NewsAround(const string cur, const datetime from, const datetime to)
  {
   if(cur == "" ) return false;
   MqlCalendarValue vals[];
   int n = CalendarValueHistory(vals, from, to, NULL, cur);
   for(int i = 0; i < n; i++)
     {
      MqlCalendarEvent ev;
      if(CalendarEventById(vals[i].event_id, ev) && ev.importance == CALENDAR_IMPORTANCE_HIGH)
        {
         gStatus = "Noticia: " + ev.name;
         return true;
        }
     }
   return false;
  }

bool NewsBlocked()
  {
   if(!InpNewsFilter || MQLInfoInteger(MQL_TESTER)) return false;
   datetime now  = TimeTradeServer();
   datetime from = now - InpNewsMinutes * 60;
   datetime to   = now + InpNewsMinutes * 60;
   string base   = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string quote  = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   if(NewsAround("USD", from, to)) return true;
   if(base != "USD" && base != "XAU" && NewsAround(base, from, to)) return true;
   if(quote != "USD" && NewsAround(quote, from, to)) return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Position sizing and order placement                              |
//+------------------------------------------------------------------+
double CalcLots(const double dist)
  {
   double risk = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0;
   double tv   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0) tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0 || ts <= 0 || dist <= 0) return 0;
   double perLot = dist / ts * tv;
   double lots   = risk / perLot;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots / step) * step;
   if(lots < mn)
     {
      PrintFormat("Operacion omitida: el lote minimo %.2f arriesgaria mas del %.2f%% (stop %.5f).", mn, InpRiskPct, dist);
      return 0;
     }
   lots = MathMin(lots, mx);
   int vd = (int)MathMax(0, MathCeil(-MathLog10(step)));
   return NormalizeDouble(lots, vd);
  }

bool OpenTrade(const int dir, double sl, const long magic, const string tag)
  {
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk)) return false;
   double price = (dir > 0) ? tk.ask : tk.bid;
   double dist  = (price - sl) * dir;
   if(dist <= 0)
     {
      PrintFormat("Senal %s omitida: el stop %.5f queda del lado equivocado del precio %.5f.", tag, sl, price);
      return false;
     }
   double stopLvl = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(dist < stopLvl)
     {
      PrintFormat("Senal %s omitida: stop demasiado cerca (%.5f < %.5f).", tag, dist, stopLvl);
      return false;
     }
   double tp   = price + dir * InpRR * dist;
   double lots = CalcLots(dist);
   if(lots <= 0) return false;
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
   trade.SetExpertMagicNumber(magic);
   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, price, sl, tp, "XEL-" + tag)
                       : trade.Sell(lots, _Symbol, price, sl, tp, "XEL-" + tag);
   PrintFormat("%s %s %.2f lotes a %.5f SL %.5f TP %.5f -> %s", tag, (dir > 0 ? "Compra" : "Venta"), lots, price, sl, tp,
               trade.ResultRetcodeDescription());
   return ok;
  }

//+------------------------------------------------------------------+
//| Asian range of the current UTC day                               |
//+------------------------------------------------------------------+
bool AsianRange(const datetime nowSrv, double &hi, double &lo)
  {
   int off = GmtOffset();
   long dayUTC = (long)DayStartUTC(nowSrv);
   datetime from = (datetime)(dayUTC + InpAsiaStartUTC * 3600 + off);
   datetime to   = (datetime)(dayUTC + InpAsiaEndUTC * 3600 + off - 1);
   MqlRates rr[];
   int n = CopyRates(_Symbol, InpTF, from, to, rr);
   if(n <= 0) return false;
   hi = -DBL_MAX; lo = DBL_MAX;
   for(int i = 0; i < n; i++)
     {
      hi = MathMax(hi, rr[i].high);
      lo = MathMin(lo, rr[i].low);
     }
   return (hi > lo);
  }

//+------------------------------------------------------------------+
//| Journal: CSV + Notion                                            |
//+------------------------------------------------------------------+
string AccountLabel()
  {
   if(MQLInfoInteger(MQL_TESTER)) return "Backtest";
   long m = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(m == ACCOUNT_TRADE_MODE_DEMO)    return "Demo";
   if(m == ACCOUNT_TRADE_MODE_CONTEST) return "Concurso";
   return "Real";
  }

string ReasonLabel(const long r)
  {
   if(r == DEAL_REASON_SL)     return "Stop";
   if(r == DEAL_REASON_TP)     return "Objetivo";
   if(r == DEAL_REASON_EXPERT) return "Cierre por hora";
   if(r == DEAL_REASON_SO)     return "Stop out";
   return "Manual";
  }

string JsonEsc(string s)
  {
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   return s;
  }

void WriteCSV(const string line)
  {
   if(!InpWriteCSV) return;
   string name = (MQLInfoInteger(MQL_TESTER) ? "backtest_" : "") + InpCSVName;
   int h = FileOpen(name, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("No pude abrir %s (error %d).", name, GetLastError());
      return;
     }
   if(FileSize(h) == 0)
      FileWriteString(h, "fecha_utc,cierre_utc,activo,direccion,estrategia,entrada,stop,salida,lotes,riesgo_usd,riesgo_pct,r,pnl,balance,cuenta,plan,notas\r\n");
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, line + "\r\n");
   FileClose(h);
  }

bool SendNotion(const string json)
  {
   if(!InpSendNotion || MQLInfoInteger(MQL_TESTER)) return false;
   if(InpNotionToken == "" || InpNotionDB == "")
     {
      Print("Notion: falta el token o el ID de la base de datos.");
      return false;
     }
   char data[], res[];
   string resHeaders;
   int len = StringToCharArray(json, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(len > 0) ArrayResize(data, len - 1);                 // drop the terminating zero
   string hdr = "Authorization: Bearer " + InpNotionToken + "\r\n" +
                "Notion-Version: 2022-06-28\r\n" +
                "Content-Type: application/json\r\n";
   ResetLastError();
   int code = WebRequest("POST", "https://api.notion.com/v1/pages", hdr, 8000, data, res, resHeaders);
   if(code == -1)
     {
      int e = GetLastError();
      if(e == 4014)
         Print("Notion: agrega https://api.notion.com en Herramientas > Opciones > Asesores Expertos > Permitir WebRequest.");
      else
         PrintFormat("Notion: error de WebRequest %d.", e);
      return false;
     }
   if(code != 200)
     {
      PrintFormat("Notion respondio %d: %s", code, CharArrayToString(res, 0, WHOLE_ARRAY, CP_UTF8));
      return false;
     }
   return true;
  }

string Num(const double v, const int digits) { return DoubleToString(v, digits); }

void LogClosedTrade(const ulong deal)
  {
   if(!HistoryDealSelect(deal)) return;
   string   sym     = HistoryDealGetString(deal, DEAL_SYMBOL);
   long     posId   = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   double   exitPx  = HistoryDealGetDouble(deal, DEAL_PRICE);
   datetime exitT   = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
   long     reason  = HistoryDealGetInteger(deal, DEAL_REASON);
   double   vol     = HistoryDealGetDouble(deal, DEAL_VOLUME);

   if(!HistorySelectByPosition(posId)) return;
   double   pl = 0, inPx = 0;
   datetime inT = 0;
   int      dir = 0;
   long     inMagic = -1;
   ulong    inOrder = 0;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      pl += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION);
      if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
        {
         inPx    = HistoryDealGetDouble(d, DEAL_PRICE);
         inT     = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
         dir     = (HistoryDealGetInteger(d, DEAL_TYPE) == DEAL_TYPE_BUY) ? 1 : -1;
         inMagic = HistoryDealGetInteger(d, DEAL_MAGIC);
         inOrder = (ulong)HistoryDealGetInteger(d, DEAL_ORDER);
        }
     }
   if(!IsOurMagic(inMagic) || dir == 0) return;

   double sl = HistoryOrderGetDouble(inOrder, ORDER_SL);
   int    dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0) tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double riskUsd = (sl > 0 && ts > 0) ? MathAbs(inPx - sl) / ts * tv * vol : 0;
   double r       = (riskUsd > 0) ? pl / riskUsd : 0;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double balBefore = balance - pl;
   double riskPct = (balBefore > 0) ? riskUsd / balBefore * 100.0 : 0;
   string strat   = (inMagic == InpMagic) ? "A" : "B";
   string why     = ReasonLabel(reason);
   bool   plan    = (why != "Manual");
   string acct    = AccountLabel();

   string line = IsoUTC(inT) + "," + IsoUTC(exitT) + "," + sym + "," + (dir > 0 ? "buy" : "sell") + "," + strat + "," +
                 Num(inPx, dg) + "," + Num(sl, dg) + "," + Num(exitPx, dg) + "," + Num(vol, 2) + "," +
                 Num(riskUsd, 2) + "," + Num(riskPct, 2) + "," + Num(r, 2) + "," + Num(pl, 2) + "," +
                 Num(balance, 2) + "," + acct + "," + (plan ? "si" : "no") + "," + why;
   WriteCSV(line);

   string title = sym + " " + (dir > 0 ? "Compra" : "Venta") + " " + strat + " #" + IntegerToString(posId);
   string json =
      "{\"parent\":{\"database_id\":\"" + JsonEsc(InpNotionDB) + "\"},\"properties\":{" +
      "\"Operacion\":{\"title\":[{\"text\":{\"content\":\"" + JsonEsc(title) + "\"}}]}," +
      "\"Fecha\":{\"date\":{\"start\":\"" + IsoUTC(inT) + "\",\"end\":\"" + IsoUTC(exitT) + "\"}}," +
      "\"Activo\":{\"select\":{\"name\":\"" + JsonEsc(sym) + "\"}}," +
      "\"Direccion\":{\"select\":{\"name\":\"" + (dir > 0 ? "Compra" : "Venta") + "\"}}," +
      "\"Estrategia\":{\"select\":{\"name\":\"" + strat + "\"}}," +
      "\"Cuenta\":{\"select\":{\"name\":\"" + acct + "\"}}," +
      "\"Motivo\":{\"select\":{\"name\":\"" + why + "\"}}," +
      "\"Entrada\":{\"number\":" + Num(inPx, dg) + "}," +
      "\"Stop\":{\"number\":" + Num(sl, dg) + "}," +
      "\"Salida\":{\"number\":" + Num(exitPx, dg) + "}," +
      "\"Lotes\":{\"number\":" + Num(vol, 2) + "}," +
      "\"Riesgo USD\":{\"number\":" + Num(riskUsd, 2) + "}," +
      "\"Riesgo %\":{\"number\":" + Num(riskPct, 2) + "}," +
      "\"R\":{\"number\":" + Num(r, 2) + "}," +
      "\"PL USD\":{\"number\":" + Num(pl, 2) + "}," +
      "\"Balance\":{\"number\":" + Num(balance, 2) + "}," +
      "\"Plan\":{\"checkbox\":" + (plan ? "true" : "false") + "}," +
      "\"Ganadora\":{\"checkbox\":" + (pl > 0 ? "true" : "false") + "}" +
      (InpNotionSummary != "" ? ",\"Resumen\":{\"relation\":[{\"id\":\"" + JsonEsc(InpNotionSummary) + "\"}]}" : "") +
      "}}";
   SendNotion(json);
   if(InpPushNotify && !MQLInfoInteger(MQL_TESTER))
      SendNotification(StringFormat("XEL %s %s %s: %+.2f USD (%+.2fR) - %s. Balance %.2f",
                                    sym, strat, (dir > 0 ? "Compra" : "Venta"), pl, r, why, balance));
  }

//+------------------------------------------------------------------+
//| Expert lifecycle                                                 |
//+------------------------------------------------------------------+
int OnInit()
  {
   hEmaF = iMA(_Symbol, InpTF, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaM = iMA(_Symbol, InpTF, InpEmaMid, 0, MODE_EMA, PRICE_CLOSE);
   hEmaS = iMA(_Symbol, InpTF, 200, 0, MODE_EMA, PRICE_CLOSE);
   hAtr  = iATR(_Symbol, InpTF, 14);
   if(hEmaF == INVALID_HANDLE || hEmaM == INVALID_HANDLE || hEmaS == INVALID_HANDLE || hAtr == INVALID_HANDLE)
     {
      Print("No pude crear los indicadores.");
      return INIT_FAILED;
     }
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(30);
   if(InpStrategy == XEL_STRAT_AB && AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("Aviso: la cuenta no es hedging. Con A + B solo se abrira una posicion por simbolo a la vez.");
   if(InpSendNotion && !MQLInfoInteger(MQL_TESTER) && (InpNotionToken == "" || InpNotionDB == ""))
      Print("Aviso: Notion activado pero falta el token o el ID de la base de datos.");
   PrintFormat("XauEurLab listo en %s %s. Desfase del servidor: GMT%+d.", _Symbol, EnumToString(InpTF), GmtOffset() / 3600);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(hEmaF);
   IndicatorRelease(hEmaM);
   IndicatorRelease(hEmaS);
   IndicatorRelease(hAtr);
   Comment("");
  }

void ShowPanel(const XelStats &s, const bool blocked)
  {
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)) return;
   string strat = (InpStrategy == XEL_STRAT_A ? "A" : InpStrategy == XEL_STRAT_B ? "B" : "A + B");
   Comment(StringFormat("XAU-EUR Lab  |  Estrategia %s  |  Servidor GMT%+d\n"
                        "Hoy: %+.2f  |  Semana: %+.2f  |  Stops seguidos: %d\n"
                        "Riesgo por operacion: %.2f%%  |  Estado: %s",
                        strat, GmtOffset() / 3600, s.pnlDay, s.pnlWeek, s.lossesInRow, InpRiskPct,
                        blocked ? gStatus : "operando"));
  }

void OnTick()
  {
   datetime now = TimeCurrent();
   double   h   = HourUTC(now);

   if(h >= InpCloseHourUTC)
      CloseOurPositions();

   datetime bt = iTime(_Symbol, InpTF, 0);
   if(bt == 0 || bt == gLastBar) return;
   gLastBar = bt;

   XelStats st;
   GetStats(st);

   // ----- risk gates -----
   bool   blocked  = false;
   double bal      = AccountInfoDouble(ACCOUNT_BALANCE);
   double flt      = FloatingPnl();
   double dayBase  = bal - st.pnlDay;
   double weekBase = bal - st.pnlWeek;
   gStatus = "";
   if(h >= InpCloseHourUTC)                                                  { blocked = true; gStatus = "fuera de horario"; }
   else if(dayBase > 0 && st.pnlDay + flt <= -InpMaxDailyLossPct / 100.0 * dayBase)   { blocked = true; gStatus = "limite diario alcanzado"; }
   else if(InpMaxLossesInRow > 0 && st.lossesInRow >= InpMaxLossesInRow)     { blocked = true; gStatus = "stops seguidos: pausa hasta manana"; }
   else if(weekBase > 0 && st.pnlWeek + flt <= -InpMaxWeeklyLossPct / 100.0 * weekBase) { blocked = true; gStatus = "limite semanal alcanzado"; }
   else if(InpMaxSpreadPoints > 0 && SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpreadPoints) { blocked = true; gStatus = "spread alto"; }
   else if(NewsBlocked())                                                    { blocked = true; }
   ShowPanel(st, blocked);
   if(blocked) return;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpTF, 1, 1, r) != 1) return;
   double c = r[0].close, o = r[0].open;
   double barH = HourUTC(r[0].time);
   double atr = Buf(hAtr, 1), ef = Buf(hEmaF, 1), em = Buf(hEmaM, 1), es = Buf(hEmaS, 1);
   if(atr == EMPTY_VALUE || ef == EMPTY_VALUE || em == EMPTY_VALUE || es == EMPTY_VALUE || atr <= 0) return;
   bool netting = (AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);

   // ----- Strategy A: Asian range breakout -----
   if((InpStrategy == XEL_STRAT_A || InpStrategy == XEL_STRAT_AB) && !HasPosition(InpMagic) && st.entriesA == 0 &&
      barH >= InpTradeStartUTC && barH < InpTradeEndUTC && !(netting && HasAnyPositionOnSymbol()))
     {
      double hi, lo;
      if(AsianRange(now, hi, lo) && (hi - lo) <= InpMaxRangeATR * atr)
        {
         int dir = 0;
         if(c > hi && (!InpTrendFilter || c > es))      dir = 1;
         else if(c < lo && (!InpTrendFilter || c < es)) dir = -1;
         if(dir != 0)
           {
            double sl;
            if(InpSLMode == XEL_SL_MID)           sl = (hi + lo) / 2.0;
            else if(InpSLMode == XEL_SL_OPPOSITE) sl = (dir > 0) ? lo : hi;
            else                                  sl = c - dir * InpAtrMult * atr;
            OpenTrade(dir, sl, InpMagic, "A");
           }
        }
     }

   // ----- Strategy B: EMA pullback -----
   if((InpStrategy == XEL_STRAT_B || InpStrategy == XEL_STRAT_AB) && !HasPosition(InpMagic + 1) &&
      st.entriesB < InpMaxTradesDayB && barH >= InpSessStartUTC && barH < InpSessEndUTC &&
      !(netting && HasAnyPositionOnSymbol()))
     {
      if(em > es && c > es && r[0].low <= ef && c > ef && c > o)
         OpenTrade(1, c - InpAtrMult * atr, InpMagic + 1, "B");
      else if(em < es && c < es && r[0].high >= ef && c < ef && c < o)
         OpenTrade(-1, c + InpAtrMult * atr, InpMagic + 1, "B");
     }
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;
   LogClosedTrade(trans.deal);
  }
//+------------------------------------------------------------------+
