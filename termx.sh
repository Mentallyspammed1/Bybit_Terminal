#!/bin/bash

# --- Project Configuration ---
BASE_DIR="bybit_terminal_full" # Name of the project directory
declare -a DIRS=("core" "strategies" "indicators" "utils" "logs" "templates")
declare -a FILES=(
  "$BASE_DIR/__main__.py"
  "$BASE_DIR/config.py"
  "$BASE_DIR/enums.py"
  "$BASE_DIR/core/risk_manager.py"
  "$BASE_DIR/core/notifier.py"
  "$BASE_DIR/core/strategy_engine.py"
  "$BASE_DIR/indicators/fibonacci_pivot_points.py"
  "$BASE_DIR/indicators/rsi.py"
  "$BASE_DIR/indicators/atr.py"
  "$BASE_DIR/utils/data_feed.py"
  ".env"
  "requirements.txt"
)

# --- Neon Color Definitions ---
NEON_CYAN    = "\033[96m\033[1m"  # Bright Cyan
NEON_GREEN   = "\033[92m\033[1m"  # Bright Green
NEON_YELLOW  = "\033[93m\033[1m"  # Bright Yellow
NEON_RED     = "\033[91m\033[1m"  # Bright Red
NEON_MAGENTA = "\033[95m\033[1m"  # Bright Magenta
RESET_COLOR  = "\033[0m"            # Reset to default color

# --- Function to create directories ---
create_directories() {
    echo "${NEON_CYAN}🛠 Creating directory structure...${RESET_COLOR}"
    mkdir -p "$BASE_DIR" || { echo "${NEON_RED}❌ Failed to create base directory '$BASE_DIR'${RESET_COLOR}"; exit 1; }
    for dir in "${DIRS[@]}"; do
        mkdir -p "$BASE_DIR/$dir" || { echo "${NEON_RED}❌ Failed to create directory '$BASE_DIR/$dir'${RESET_COLOR}"; exit 1; }
        touch "$BASE_DIR/$dir/__init__.py" || { echo "${NEON_RED}❌ Failed to initialize package in '$BASE_DIR/$dir'${RESET_COLOR}"; exit 1; }
    done
    echo "${NEON_GREEN}✅ Directory structure created under '$BASE_DIR'${RESET_COLOR}"
}

# --- Function to create files with content ---
create_file() {
    local file_path=$1
    local content=$2

    echo "${NEON_CYAN}📄 Creating $file_path...${RESET_COLOR}"
    mkdir -p "$(dirname "$file_path")"
    {
        echo "$content"
    } > "$file_path"

    if [ $? -eq 0 ]; then
        echo "${NEON_GREEN}✅ Created $file_path${RESET_COLOR}"
    else
        echo "${NEON_RED}❌ Failed to create $file_path${RESET_COLOR}"
        exit 1
    fi
}

# --- Main Script Execution ---
main() {
    create_directories

    # --- Create __main__.py with Full Code ---
    create_file "$BASE_DIR/__main__.py" "$(cat << 'EOF'
#!/usr/bin/env python3
import os, time, hashlib, hmac, urllib.parse, json, threading, numpy as np, plotext as plt, smtplib, logging
from email.message import EmailMessage
import requests, pandas as pd, ccxt
from colorama import init, Fore, Style
from dotenv import load_dotenv
from datetime import datetime, timedelta
from indicators import FibonacciPivotPoints, RSI, ATR, atr
from enums import OrderType, OrderSide, AnalysisType
from core.risk_manager import RM
from core.notifier import NH
from core.strategy_engine import SE
from utils.data_feed import fetch_ohlcv_cyber

init(autoreset=True);load_dotenv()

# --- Neon Color Definitions ---
NEON_CYAN    = Fore.CYAN + Style.BRIGHT
NEON_GREEN   = Fore.GREEN + Style.BRIGHT
NEON_YELLOW  = Fore.YELLOW + Style.BRIGHT
NEON_RED     = Fore.RED + Style.BRIGHT
NEON_MAGENTA = Fore.MAGENTA + Style.BRIGHT
RESET_COLOR  = Fore.WHITE + Style.RESET_ALL

# --- Configuration Class ---
class Configuration:
    def __init__(self):
        self.api_key = os.getenv("BYBIT_API_KEY")
        self.api_secret = os.getenv("BYBIT_API_SECRET")
        self.trading_mode = os.getenv("TRADING_MODE", "paper").lower() # Default to paper trading
        self.email = {
            'server': os.getenv("EMAIL_SERVER"),
            'user': os.getenv("EMAIL_USER"),
            'password': os.getenv("EMAIL_PASSWORD"),
            'receiver': os.getenv("EMAIL_RECEIVER")
        }
        self.risk = {
            'max_per_trade': float(os.getenv("MAX_RISK_PER_TRADE", 0.02)), # Default 2%
            'max_leverage': int(os.getenv("MAX_LEVERAGE", 100)),            # Default 100x
            'daily_loss_limit': float(os.getenv("DAILY_LOSS_LIMIT", 0.1))   # Default 10% daily loss limit
        }
        self.strategy = { # Basic strategy config - can be expanded
            'default_strategy': os.getenv("DEFAULT_STRATEGY", "ema") # Example default strategy
        }

CONFIG = Configuration()

# --- Logging Setup ---
logging.basicConfig(filename='terminal_errors.log', level=logging.ERROR,
                    format='%(asctime)s - %(levelname)s - %(message)s')

class BTT:
    """Bybit Terminal Trader - Command-line interface for trading Bybit Futures."""
    def __init__(self):
        """Initializes BTT terminal."""
        self.exch = self._init_exch()
        self.rm = RM(CONFIG.risk)
        self.ntf = NH(CONFIG)
        self.se = SE()
        self.ao = {}
        self.mdc = {}
        self.fpp_indicator = FibonacciPivotPoints()

    def _init_exch(self) -> ccxt.Exchange:
        """Initializes CCXT Bybit exchange object."""
        if not CONFIG.api_key or not CONFIG.api_secret:
            raise ValueError("API keys missing from environment variables.")
        exchange_params = {
            'apiKey': CONFIG.api_key,
            'secret': CONFIG.api_secret,
            'options': {'defaultType': 'swap'},
            'enableRateLimit': True,
        }
        if CONFIG.trading_mode == "paper":
            exchange_params['testMode'] = True # Enable test mode for paper trading
        return ccxt.bybit(exchange_params)

    def execute_order(self, order_type: OrderType, symbol: str, side: OrderSide, amount: float, price: float = None, params: dict = None):
        """Executes a trading order on Bybit."""
        try:
            op = {'symbol': symbol, 'type': order_type.value, 'side': side.value, 'amount': amount, 'params': params or {}}
            if order_type == OrderType.LIMIT:
                op['price'] = price

            if CONFIG.trading_mode == "live":
                if not self.exch.testMode: # Double check we are not in test mode for live trading
                    order = self.exch.create_order(**op)
                    self.ao[order['id']] = order
                    msg = f"Live Order executed: {order['id']} - {op}"
                    print(NEON_GREEN + msg)
                    self.ntf.send_alert(msg)
                    return order
                else:
                    msg = NEON_RED + "Attempted LIVE order in test mode! Check TRADING_MODE config."
                    print(msg)
                    self.ntf.send_alert(msg)
                    return None
            else: # Paper or Backtest mode
                order = self.exch.create_order(**op) # Still creates "simulated" order in testMode=True
                self.ao[order['id']] = order
                msg = f"Paper Order simulated: {op}"
                print(NEON_CYAN + msg)
                self.ntf.send_alert(msg) # Still send paper trade alerts if emails configured
                return order

        except ccxt.NetworkError as e:
            error_msg = f"Network error encountered: {str(e)}"
            print(NEON_RED + error_msg)
            self.ntf.send_alert(error_msg)
            logging.error(error_msg)
            return None
        except ccxt.ExchangeError as e:
            error_msg = f"Exchange error encountered: {str(e)}"
            print(NEON_RED + error_msg)
            self.ntf.send_alert(error_msg)
            logging.error(error_msg)
            return None
        except Exception as e:
            error_msg = f"Unexpected error during order execution: {str(e)}"
            print(NEON_RED + error_msg)
            self.ntf.send_alert(error_msg)
            logging.error(error_msg)
            return None

    def cond_order(self):
        """Handles conditional order placement with neon prompts."""
        print(NEON_CYAN + "\\nConditional Order Types:")
        print(f"1. {NEON_YELLOW}Stop-Limit")
        print(f"2. {NEON_YELLOW}Trailing Stop")
        print(f"3. {NEON_YELLOW}OCO (Simulated)") # OCO is simulated
        choice = input(NEON_YELLOW + "Select type: ")

        symbol = input(NEON_YELLOW + "Symbol: ").upper()
        side_str = input(NEON_YELLOW + "Side (buy/sell): ").lower()
        try:
            side = OrderSide(side_str)
        except ValueError:
            print(NEON_RED + "Invalid order side.  Must be 'buy' or 'sell'.")
            return

        try:
            amount = float(input(NEON_YELLOW + "Quantity: "))
        except ValueError:
            print(NEON_RED + "Invalid quantity.")
            return

        if choice == '1':
            stop_price = self._validate_float_input(NEON_YELLOW + "Stop Price: ", "Stop Price")
            if stop_price is None: return
            limit_price = self._validate_float_input(NEON_YELLOW + "Limit Price: ", "Limit Price")
            if limit_price is None: return
            self._sl(symbol, side, amount, stop_price, limit_price)
        elif choice == '2':
            trail_value = self._validate_float_input(NEON_YELLOW + "Trailing Value ($): ", "Trailing Value")
            if trail_value is None: return
            self._ts(symbol, side, amount, trail_value)
        elif choice == '3':
            price1 = self._validate_float_input(NEON_YELLOW + "Price 1 (e.g., Take Profit Limit): ", "Price 1")
            if price1 is None: return
            price2 = self._validate_float_input(NEON_YELLOW + "Price 2 (e.g., Stop-Loss Limit): ", "Price 2")
            if price2 is None: return
            self._oco(symbol, side, amount, price1, price2)
        else:
            print(NEON_RED + Style.BRIGHT + "Invalid choice for conditional order type.")

    def _validate_float_input(self, prompt, input_name):
        """Validates float input with neon prompts."""
        while True:
            try:
                value_str = input(prompt)
                if not value_str: # Allow empty input to be treated as None or default if needed later
                    return None
                return float(value_str)
            except ValueError:
                print(NEON_RED + f"Invalid input for {input_name}. Please enter a valid number.")

    def _sl(self, symbol: str, side: OrderSide, amount: float, stop: float, limit: float):
        """Places a stop-limit order."""
        params = {'stopPx': stop, 'basePrice': limit,  'triggerType': 'lastPrice'} # Bybit params
        try:
            order = self.execute_order(symbol=symbol, type=OrderType.LIMIT, side=side, amount=amount, price=limit, params=params)
            if order:
                print(NEON_GREEN + f"Stop-limit placed: {order['id']}")
        except Exception as e:
            print(NEON_RED + f"Error placing stop-limit order: {e}")
            logging.error(f"Stop-limit order placement error: {e}")

    def _ts(self, symbol: str, side: OrderSide, amount: float, trail_value: float):
        """Places a trailing stop order."""
        params = {'trailingStop': str(trail_value)}  # Bybit requires string for trailing stop
        try:
            order = self.execute_order(symbol=symbol, type=OrderType.MARKET, side=side, amount=amount, params=params) #Market for TS
            if order:
                print(NEON_GREEN + f"Trailing stop placed: {order['id']}")
        except Exception as e:
            print(NEON_RED + f"Error placing trailing stop: {e}")
            logging.error(f"Trailing stop order placement error: {e}")

    def _oco(self, symbol: str, side: OrderSide, amount: float, price1: float, price2: float):
        """Places a simulated OCO order (One-Cancels-Other).

        Note: Bybit does not natively support OCO for futures. This is a client-side simulation.
        It places two separate limit orders and relies on client-side logic to cancel the second
        order if the first one fills.  This example is simplified and may not be robust in all scenarios.
        """
        if CONFIG.trading_mode == "live":
            print(NEON_YELLOW + "OCO orders are SIMULATED in this terminal and are NOT recommended for live trading due to lack of server-side cancellation. Use at your own risk.")

        try:
            # Place the first order (e.g., Take Profit Limit)
            order1_params = {'stopLoss': None, 'takeProfit': price1} # Example attaching TP to order1
            order1 = self.execute_order(symbol=symbol, type=OrderType.LIMIT, side=side, amount=amount, price=price1, params=order1_params)
            if order1:
                print(NEON_GREEN + f"OCO Order 1 (Take Profit) placed: {order1['id']}")

                # Place the second order (e.g., Stop-Loss Limit) - Opposite side
                opposite_side = OrderSide.SELL if side == OrderSide.BUY else OrderSide.BUY
                order2_params = {'stopLoss': price2, 'takeProfit': None} # Example attaching SL to order2
                order2 = self.execute_order(symbol=symbol, type=OrderType.STOP_LIMIT, side=opposite_side, amount=amount, price=price2, params=order2_params) #STOP_LIMIT for SL
                if order2:
                    print(NEON_GREEN + f"OCO Order 2 (Stop-Loss) placed: {order2['id']}")
                    print(NEON_YELLOW + "OCO Simulation: Client-side OCO simulation is basic. Robust OCO requires server-side order management and real-time monitoring which is NOT implemented here.")
                else:
                    if order1: # Attempt to cancel order1 if order2 fails - basic cleanup
                        self.exch.cancel_order(order1['id'], symbol)
                        print(NEON_YELLOW + f"OCO setup incomplete. Order 1 ({order1['id']}) cancelled due to Order 2 placement failure.")
                    print(NEON_RED + "Failed to place OCO Order 2 (Stop-Loss). OCO setup incomplete.")
            else:
                print(NEON_RED + "Failed to place OCO Order 1 (Take Profit). OCO setup incomplete.")

        except Exception as e:
            print(NEON_RED + f"Error placing OCO orders: {e}")
            logging.error(f"OCO order placement error: {e}")

    def chart_adv(self, symbol: str, timeframe: str = '1h', periods: int = 100):
        """Displays an advanced price chart with optional RSI overlay."""
        try:
            ohlcv = self.exch.fetch_ohlcv(symbol, timeframe, limit=periods)
            closes = [x[4] for x in ohlcv]
            plt.clear_figure()
            plt.plot(closes, color='cyan') # Base price in cyan
            plt.title(NEON_CYAN + f"{symbol} Price Chart ({timeframe})", color='white') # Neon title
            plt.xlabel("Time", color='white')
            plt.ylabel("Price", color='white')
            plt.tick_color('white') # White tick marks
            plt.show()

            overlay_rsi = input(NEON_YELLOW + "Overlay RSI? (y/n): ").lower()
            if overlay_rsi == 'y':
                self._chart_rsi(closes, symbol, timeframe)
        except ccxt.NetworkError as e:
            print(NEON_RED + f"Network error fetching chart data: {e}")
            logging.error(f"Network error fetching chart data: {e}")
        except ccxt.ExchangeError as e:
            print(NEON_RED + f"Bybit Exchange Error fetching chart data: {e}")
            logging.error(f"Bybit Exchange Error fetching chart data: {e}")
        except Exception as e:
            print(NEON_RED + f"Error displaying chart: {e}")
            logging.error(f"General error displaying chart: {e}")

    def _chart_rsi(self, closes: list, symbol, timeframe):
        """Overlays RSI on the existing chart."""
        rsi_indicator = RSI()
        rsi_vals = rsi_indicator.calculate(pd.Series(closes), period=14)
        plt.plot(rsi_vals, color='magenta') # RSI in magenta
        plt.ylim(0, 100)
        plt.hline(70, color='red', linestyle='dashed') # Overbought line
        plt.hline(30, color='green', linestyle='dashed') # Oversold line
        plt.title(NEON_CYAN + f"RSI Overlay for {symbol} ({timeframe})", color='white')
        plt.xlabel("Time", color='white')
        plt.ylabel("RSI Value", color='white')
        plt.tick_color('white')
        plt.show()

    def backtest(self):
        """Initiates and displays backtesting results with neon output."""
        symbol = input(NEON_YELLOW + "Symbol: ").upper()
        timeframe = input(NEON_YELLOW + "Timeframe (1h/4h/1d): ")
        strategy_name = input(NEON_YELLOW + "Strategy (ema/macd): ").lower()

        try:
            data = self.exch.fetch_ohlcv(symbol, timeframe, limit=1000)
            if not data:
                print(NEON_RED + "No data available for backtesting.")
                return

            df = pd.DataFrame(data, columns=['timestamp', 'open', 'high', 'low', 'close', 'volume'])
            df['timestamp'] = pd.to_datetime(df['timestamp'], unit='ms')
            df.set_index('timestamp', inplace=True)
            bt_res = self.se.run_backtest(df, strategy_name)

            print(NEON_CYAN + f"\\n--- Backtest Results ({strategy_name.upper()}):")
            print(f"{RESET_COLOR}Total Return: {NEON_GREEN}{bt_res['tot_ret_perc']:.2f}%{RESET_COLOR}") # Green for profit
            print(f"{RESET_COLOR}Max Drawdown: {NEON_RED}{bt_res['max_dd_perc']:.2f}%{RESET_COLOR}")   # Red for drawdown

            plot_cumulative_returns = input(NEON_YELLOW + "Plot cumulative returns? (y/n): ").lower()
            if plot_cumulative_returns == 'y':
                plt.clear_figure()
                plt.plot(bt_res['cum_rets'].fillna(1), color='yellow') # Yellow for cumulative returns
                plt.title(NEON_CYAN + f"{strategy_name.upper()} Strategy Cumulative Returns for {symbol}", color='white')
                plt.xlabel("Date", color='white')
                plt.ylabel("Cumulative Returns", color='white')
                plt.tick_color('white')
                plt.show()

        except ccxt.ExchangeError as e:
            print(NEON_RED + f"Bybit Exchange Error during backtest: {e}")
            logging.error(f"Bybit Exchange Error during backtest: {e}")
        except ValueError as e:
            print(NEON_RED + str(e))
            logging.error(f"Value Error during backtest: {e}")
        except Exception as e:
            print(NEON_RED + f"Backtest Error: {e}")
            logging.error(f"General Backtest Error: {e}")
    def disp_adv_menu(self):
        """Displays the advanced features menu."""
        while True:
            os.system('clear')
            print(NEON_CYAN + Style.BRIGHT + """\n╔═══════════════════════════════╗\n║      ADVANCED FEATURES        ║\n╠═══════════════════════════════╣\n║ 1. Algorithmic Trading        ║\n║ 2. Risk Management Tools      ║\n║ 3. Market Analysis Suite      ║\n║ 4. Notification Setup         ║
║ 5. Back to Main Menu          ║\n╚═══════════════════════════════╝\n""")
            choice = input(Fore.YELLOW + "Select feature (1-5): ")
            if choice == '1':
                self.disp_algo_menu()
            elif choice == '2':
                self.disp_rm_menu()
            elif choice == '3':
                self.disp_ma_menu()
            elif choice == '4':
                self.disp_notif_menu()
            elif choice == '5':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 5.")
                time.sleep(1.5)

    def disp_rm_menu(self):
        """Displays the risk management tools menu."""
        while True:
            os.system('clear')
            print(Fore.CYAN + Style.BRIGHT + """\n╔═══════════════════════════════╗\n║    RISK MANAGEMENT TOOLS      ║\n╠═══════════════════════════════╣\n║ 1. Margin Calculator          ║\n║ 2. Set Max Risk Percentage    ║
║ 3. Set Leverage Configuration ║
║ 4. Back to Advanced Features  ║\n╚═══════════════════════════════╝\n""")
            choice = input(Fore.YELLOW + "Select tool (1-4): ")
            if choice == '1':
                self.margin_calc()
            elif choice == '3':
                self.set_lev_menu()
            elif choice == '4':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 4.")
                time.sleep(1.5)

    def disp_algo_menu(self):
        """Displays the algorithmic trading menu."""
        while True:
            os.system('clear')
            print(Fore.CYAN + Style.BRIGHT + """\n╔═══════════════════════════════╗\n║    ALGORITHMIC TRADING        ║\n╠═══════════════════════════════╣\n║ 1. Run Strategy Backtest      ║
║ 2. Live Strategy Exec (WIP)   ║
║ 3. Strategy Config (WIP)    ║
║ 4. Back to Advanced Features  ║\n╚═══════════════════════════════╝\n""")
            choice = input(Fore.YELLOW + "Select action (1-4): ")
            if choice == '1':
                self.backtest()
            elif choice == '4':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 4.")
                time.sleep(1.5)

    def config_strategy_menu(self):
        """Allows configuration of trading strategies (WIP)."""
        while True:
            os.system('clear')
            print(Fore.CYAN + Style.BRIGHT + """\n╔═══════════════════════════════╗\n║      STRATEGY CONFIGURATION   ║
╠═══════════════════════════════╣
║ 1. Select Default Strategy    ║
║ 2. View Current Strategy      ║
║ 3. Back to Algo Trading Menu  ║\n╚═══════════════════════════════╝\n""")
            choice = input(Fore.YELLOW + "Select action (1-3): ")
            if choice == '1':
                self._set_default_strategy()
            elif choice == '2':
                print(Fore.CYAN + f"\\nCurrent Default Strategy: {NEON_YELLOW}{self.current_strategy}{RESET_COLOR}")
                input(Fore.YELLOW + Style.BRIGHT + "Press Enter to continue...")
            elif choice == '3':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 3.")
                time.sleep(1.5)

    def _set_default_strategy(self):
        """Sets the default trading strategy."""
        strategy_name = input(Fore.YELLOW + "Enter strategy name (ema/macd): ").lower()
        if strategy_name in ['ema', 'macd']:
            self.current_strategy = strategy_name
            CONFIG.strategy['default_strategy'] = strategy_name #Update config as well for persistence
            print(NEON_GREEN + f"Default strategy set to: {NEON_YELLOW}{strategy_name}{RESET_COLOR}")
        else:
            print(Fore.RED + f"Strategy '{strategy_name}' not supported.")
        input(Fore.YELLOW + Style.BRIGHT + "Press Enter to continue...")


    def disp_ma_menu(self):
        """Displays the market analysis suite menu."""
        while True:
            os.system('clear')
            print(Fore.CYAN + Style.BRIGHT + """\n╔═══════════════════════════════╗\n║    MARKET ANALYSIS SUITE      ║
╠═══════════════════════════════╣
║ 1. Adv Chart                 ║
║ 2. Mkt Sentiment              ║
║ 3. Funding Rate               ║
║ 4. RSI Analyze                ║
║ 5. ATR Analyze                ║
║ 6. MACD Analyze     (WIP)     ║
║ 7. FPP Analyze                ║
║ 8. BB Analyze       (WIP)     ║
║ 9. Back to Adv Feat           ║\n╚═══════════════════════════════╝\n""")
            choice = input(Fore.YELLOW + "Select analysis (1-8): ")
            if choice == '1':
                symbol = input(Fore.YELLOW + "Enter symbol: ").upper()
                timeframe = input(Fore.YELLOW + "Enter timeframe: ").lower()
                self.chart_adv(symbol, timeframe)
            elif choice == '2':
                sentiment = get_msentiment()
                print(Fore.CYAN + "\\nMarket Sentiment (Fear/Greed Index):")
                print(Fore.WHITE + f"{sentiment}")
                input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter...")
            elif choice == '3':
                symbol = input(Fore.YELLOW + "Enter symbol: ").upper()
                self.fetch_frate(symbol)
            elif choice == '4':
                self._analyze_indicator(RSI, "RSI")
            elif choice == '5':
                self._analyze_indicator(ATR, "ATR")
            elif choice == '6':
                print(NEON_YELLOW + "MACD Analysis - Work in Progress") #WIP message
                time.sleep(1) # Short pause for WIP message
                # self._analyze_indicator(MACD, "MACD") # MACD Indicator - Not implemented yet
            elif choice == '7':
                self.analyze_fpp_menu()
            elif choice == '8':
                print(NEON_YELLOW + "Bollinger Bands Analysis - Work in Progress") #WIP message
                time.sleep(1) # Short pause for WIP message
                # self._analyze_indicator(BollingerBands, "Bollinger Bands") # BB - Not implemented
            elif choice == '9':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 8.")
                time.sleep(1.5)

    def disp_notif_menu(self):
        """Displays the notification setup menu with neon styling."""
        while True:
            os.system('clear')
            print(NEON_CYAN + """\n╔═══════════════════════════════╗\n║    NOTIFICATION SETUP         ║\n╠═══════════════════════════════╣\n║ 1. Set Price Alert            ║
║ 2. Cfg Email Alerts           ║
║ 3. Back to Adv Feat           ║\n╚═══════════════════════════════╝\n""")
            choice = input(Fore.YELLOW + "Select action (1-3): ")
            if choice == '1':
                symbol = input(Fore.YELLOW + "Symbol for alert: ").upper()
                price = float(input(Fore.YELLOW + "Target price: "))
                self.ntf.price_alert(symbol, price)
                print(Fore.GREEN + f"Price alert set for {symbol} at {price}.")
                input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter...")
            elif choice == '2':
                self.cfg_email_menu()
            elif choice == '3':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 3.")
                time.sleep(1.5)

    def cfg_email_menu(self):
        """Configures email alert settings."""
        print(Fore.CYAN + Style.BRIGHT + "\\n--- Configure Email Alerts ---")
        server = input(Fore.YELLOW + "SMTP Server (e.g., smtp.gmail.com): ")
        user = input(Fore.YELLOW + "Email User: ")
        password = input(Fore.YELLOW + "Email Pass: ")
        smtp_details = {'server': server, 'user': user, 'password': password}
        self.ntf.cfg_email(smtp_details)
        input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter...")

    def margin_calc(self):
        """Calculates margin requirements for a trade."""
        os.system('clear')
        print(Fore.CYAN + Style.BRIGHT + "╔══════════════════════════════════╗\n║        MARGIN CALCULATOR         ║\n╚══════════════════════════════════╝")
        account_balance = float(input(Fore.YELLOW + "Account Balance (USDT): "))
        leverage = int(input(Fore.YELLOW + "Leverage (e.g., 10x): "))
        risk_percentage = float(input(Fore.YELLOW + "Risk % per trade: "))
        entry_price = float(input(Fore.YELLOW + "Entry Price: "))
        stop_loss_price = float(input(Fore.YELLOW + "Stop Loss Price: "))

        self.rm.set_lev(leverage)
        position_size = self.rm.pos_size(entry_price, stop_loss_price, account_balance)
        print(Fore.CYAN + "\\n--- Position Calculation ---")
        print(Fore.WHITE + f"Position Size (Contracts): {Fore.GREEN}{position_size}")
        risk_amount = account_balance * risk_percentage / 100
        print(Fore.WHITE + f"Risk Amount (USDT): ${Fore.YELLOW}{risk_amount:.2f}")
        print(Fore.WHITE + f"Leverage Used: {Fore.MAGENTA}{leverage}x")
        input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter...")

    def set_lev_menu(self):
        """Sets the leverage configuration through user input."""
        leverage = int(input(Fore.YELLOW + "Set Leverage (1-100): "))
        self.rm.set_lev(leverage)
        print(Fore.GREEN + f"Leverage set to {self.rm.leverage}x")
        input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter...")

    def fetch_frate(self, symbol: str):
        """Fetches and displays the funding rate for a given symbol."""
        if not self.exch:
            print(Fore.RED + Style.BRIGHT + "CCXT exchange object not initialized.")
            return None

        try:
            funding_rate_data = self.exch.fetch_funding_rate(symbol)
            if funding_rate_data and 'fundingRate' in funding_rate_data:
                os.system('clear')
                print(Fore.CYAN + Style.BRIGHT + "╔════════════FUNDING RATE═════════════╗")
                rate_percentage = float(funding_rate_data['fundingRate']) * 100
                print(Fore.WHITE + Style.BRIGHT + f"\\nCurrent funding rate for {Fore.GREEN}{symbol}{Fore.WHITE}: {Fore.GREEN}{rate_percentage:.4f}%")

                if rate_percentage > 0:
                    rate_color = Fore.GREEN
                    direction = "Positive"
                elif rate_percentage < 0:
                    rate_color = Fore.RED
                    direction = "Negative"
                else:
                    rate_color = Fore.YELLOW
                    direction = "Neutral"

                print(Fore.WHITE + Style.BRIGHT + f"Funding Rate is: {rate_color}{direction}{Fore.WHITE}")
                return funding_rate_data['fundingRate']
            else:
                print(Fore.RED + Style.BRIGHT + f"Could not fetch funding rate for {symbol}")
                return None

        except ccxt.ExchangeError as e:
            print(Fore.RED + Style.BRIGHT + f"Bybit Exchange Error fetching funding rate: {e}")
            logging.error(f"Bybit Exchange Error fetching funding rate: {e}")
        except Exception as e:
            print(Fore.RED + Style.BRIGHT + f"Error fetching funding rate: {e}")
            logging.error(f"General error fetching funding rate: {e}")
        finally:
            input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter...")

    def analyze_fpp_menu(self):
        """Analyzes and displays Fibonacci Pivot Points based on user input."""
        symbol = input(Fore.YELLOW + "Enter Futures symbol for FPP analysis (e.g., BTCUSDT): ").upper()
        timeframe = input(Fore.YELLOW + "Enter timeframe for FPP (e.g., 1d): ").lower()

        try:
            bars = self.exch.fetch_ohlcv(symbol, timeframe, limit=2)
            if not bars or len(bars) < 2:
                print(Fore.RED + Style.BRIGHT + f"Could not fetch enough OHLCV data for {symbol} in {timeframe}")
                return

            df = pd.DataFrame(bars, columns=['timestamp', 'open', 'high', 'low', 'close', 'volume'])
            current_price = self.exch.fetch_ticker(symbol)['last']
            fpp_df = self.fpp_indicator.calculate(df)
            signals = self.fpp_indicator.generate_trading_signals(df, current_price)

            os.system('clear')
            print(Fore.CYAN + Style.BRIGHT + f"╔══════FIBONACCI PIVOT POINTS ({symbol} - {timeframe})══════╗")
            print(Fore.WHITE + Style.BRIGHT + "\\nFibonacci Pivot Levels:")
            for level in self.fpp_indicator.level_names:
                price = fpp_df.iloc[0][level]
                signal_name = self.fpp_indicator.level_names[level]
                print(f"{Fore.WHITE}{signal_name}: {Fore.GREEN}{price:.4f}")

            if signals:
                print(Fore.WHITE + Style.BRIGHT + "\\nTrading Signals:")
                for signal in signals:
                    print(signal)
            else:
                print(Fore.YELLOW + "\\nNo strong signals at this time.")

        except ccxt.ExchangeError as e:
            print(Fore.RED + Style.BRIGHT + f"Bybit Exchange Error during FPP analysis: {e}")
            logging.error(f"Bybit Exchange Error during FPP analysis: {e}")
        except Exception as e:
            print(Fore.RED + Style.BRIGHT + f"Error analyzing Fibonacci Pivot Points: {e}")
            logging.error(f"General error analyzing Fibonacci Pivot Points: {e}")
        finally:
            input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter to continue...")

    def disp_mkt_menu(self):
        """Displays the market data menu with neon styling."""
        while True:
            os.system('clear')
            print(NEON_CYAN + """
╔════════════MARKET DATA═════════════╗
║         (Using CCXT)             ║
╚═══════════════════════════════╝
Choose data:
1. Symbol Price
2. Order Book
3. Symbols List
4. RSI
5. ATR
6. FPP
7. Adv Chart
8. Mkt Sentiment
9. Funding Rate
10. Back to Main Menu\n""")
            choice = input(Fore.YELLOW + "Select data (1-10): ")
            if choice == '1':
                symbol = input(Fore.YELLOW + "Futures symbol (e.g., BTCUSDT): ").upper()
                self.fetch_sym_price(symbol)
            elif choice == '2':
                symbol = input(Fore.YELLOW + "Futures symbol (e.g., BTCUSDT): ").upper()
                self.get_ob(symbol)
            elif choice == '3':
                self.list_syms()
            elif choice == '4':
                symbol = input(Fore.YELLOW + "Futures symbol: ").upper()
                timeframe = input(Fore.YELLOW + "Timeframe (e.g., 1h): ").lower()
                self.disp_rsi(symbol, timeframe)
            elif choice == '5':
                symbol = input(Fore.YELLOW + "Futures symbol: ").upper()
                timeframe = input(Fore.YELLOW + "Timeframe (e.g., 1h): ").lower()
                period = int(input(Fore.YELLOW + "ATR Period (e.g., 14): ") or 14)
                self.disp_atr(symbol, timeframe, period)
            elif choice == '6':
                symbol = input(Fore.YELLOW + "Futures symbol: ").upper()
                timeframe = input(Fore.YELLOW + "Timeframe for FPP (e.g., 1d): ").lower()
                self.disp_fpp(symbol, timeframe)
            elif choice == '7':
                symbol = input(Fore.YELLOW + "Futures symbol: ").upper()
                timeframe = input(Fore.YELLOW + "Timeframe (e.g., 1h): ").lower()
                self.chart_adv(symbol, timeframe)
            elif choice == '8':
                sentiment = get_msentiment()
                print(Fore.CYAN + "\\nMarket Sentiment (Fear/Greed Index):")
                print(Fore.WHITE + f"{sentiment}")
                input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter...")
            elif choice == '9':
                symbol = input(Fore.YELLOW + "Enter symbol: ").upper()
                self.fetch_frate(symbol)
            elif choice == '10':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 10.")
                time.sleep(1.5)

    def disp_fpp(self, symbol: str, timeframe: str):
        """Displays Fibonacci Pivot Points in a formatted output."""
        try:
            bars = self.exch.fetch_ohlcv(symbol, timeframe, limit=2)
            if not bars or len(bars) < 2:
                print(Fore.RED + Style.BRIGHT + f"Could not fetch enough OHLCV data for {symbol} in {timeframe}")
                return

            df = pd.DataFrame(bars, columns=['timestamp', 'open', 'high', 'low', 'close', 'volume'])
            df['timestamp'] = pd.to_datetime(df['timestamp'], unit='ms') # Convert to datetime object
            df.set_index('timestamp', inplace=True) # set index to timestamp
            current_price = self.exch.fetch_ticker(symbol)['last']
            fpp_df = self.fpp_indicator.calculate(df)
            signals = self.fpp_indicator.generate_trading_signals(df, current_price)

            os.system('clear')
            print(Fore.CYAN + Style.BRIGHT + f"╔══════FIBONACCI PIVOT POINTS ({symbol} - {timeframe})══════╗")
            print(Fore.WHITE + Style.BRIGHT + "\\nFibonacci Pivot Levels:")
            for level in self.fpp_indicator.level_names:
                price = fpp_df.iloc[0][level]
                signal_name = self.fpp_indicator.level_names[level]
                print(f"{Fore.WHITE}{signal_name}: {Fore.GREEN}{price:.4f}")

            if signals:
                print(Fore.WHITE + Style.BRIGHT + "\\nTrading Signals:")
                for signal in signals:
                    print(signal)
            else:
                print(Fore.YELLOW + "\\nNo strong signals at this time.")

        except ccxt.ExchangeError as e:
            print(Fore.RED + Style.BRIGHT + f"Bybit Exchange Error during FPP display: {e}")
            logging.error(f"Bybit Exchange Error during FPP display: {e}")
        except Exception as e:
            print(Fore.RED + Style.BRIGHT + f"Error displaying Fibonacci Pivot Points: {e}")
            logging.error(f"General error displaying Fibonacci Pivot Points: {e}")
        finally:
            input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter to continue...")

    def disp_trade_menu(self):
        """Displays the trading actions menu."""
        while True:
            os.system('clear')
            print(Fore.CYAN + Style.BRIGHT + """\n╔════════════TRADE ACTIONS════════════╗\n║      (Using Direct Requests)      ║\n╚═══════════════════════════════╝\nChoose action:\n1. Market Order\n2. Limit Order\n3. Cond Order\n4. Cancel Order\n8. Back to Main Menu\n""")
            choice = input(Fore.YELLOW + "Select action (1-8): ")
            if choice == '1':
                self.place_mkt_order()
            elif choice == '2':
                self.place_lmt_order()
            elif choice == '3':
                self.cond_order()
            elif choice == '4':
                self.cancel_order_menu()
            elif choice == '8':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 8.")
                time.sleep(1.5)

    def cancel_order_menu(self):
        """Handles order cancellation based on user input."""
        order_id_to_cancel = input(Fore.YELLOW + "Enter Order ID to Cancel: ")
        symbol_for_cancel = input(Fore.YELLOW + "Enter Symbol for Order Cancellation: ").upper()
        confirmation = input(Fore.YELLOW + Style.BRIGHT + f"Confirm cancel order {order_id_to_cancel} for {symbol_for_cancel}? (y/n): ").lower()
        if confirmation == 'y':
            try:
                result = self.exch.cancel_order(order_id_to_cancel, symbol=symbol_for_cancel)
                print(Fore.GREEN + f"Order {order_id_to_cancel} cancelled successfully.")
                self.ntf.send_alert(f"Order {order_id_to_cancel} cancelled.")
            except ccxt.OrderNotFound as e:
                print(Fore.RED + Style.BRIGHT + f"Order not found: {e}")
                logging.error(f"Order not found during cancellation: {e}")
            except ccxt.ExchangeError as e:
                print(Fore.RED + Style.BRIGHT + f"Bybit Exchange Error during order cancellation: {e}")
                logging.error(f"Bybit Exchange Error during order cancellation: {e}")
            except Exception as e:
                print(Fore.RED + Style.BRIGHT + f"Error cancelling order: {e}")
                logging.error(f"General error during order cancellation: {e}")
        else:
            print(Fore.YELLOW + "Order cancellation aborted by user.")
        input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter to continue...")

    def disp_acc_menu(self):
        """Displays the account operations menu."""
        while True:
            os.system('clear')
            print(Fore.CYAN + Style.BRIGHT + """\n╔════════════ACCOUNT OPS═════════════╗\n║     (Using CCXT & Pandas)        ║\n╚═══════════════════════════════╝\nChoose action:\n1. View Balance\n2. View Order History\n3. Margin Calculator\n4. View Open Orders\n6. Back to Main Menu\n""")
            choice = input(Fore.YELLOW + "Select action (1-6): ")
            if choice == '1':
                self.view_bal()
            elif choice == '2':
                self.view_ord_hist()
            elif choice == '3':
                self.margin_calc()
            elif choice == '4':
                self.view_open_orders()
            elif choice == '6':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 6.")
                time.sleep(1.5)

    def view_open_orders(self):
        """Displays current open orders for a specified symbol."""
        symbol = input(Fore.YELLOW + "Enter Futures symbol to view open orders (e.g., BTCUSDT, leave blank for all): ").upper()
        try:
            if symbol:
                open_orders = self.exch.fetch_open_orders(symbol=symbol)
            else:
                open_orders = self.exch.fetch_open_orders()
            if open_orders:
                os.system('clear')
                print(Fore.CYAN + Style.BRIGHT + f"╔══════════OPEN ORDERS ({symbol if symbol else 'ALL SYMBOLS'})══════════╗")
                df_orders = pd.DataFrame(open_orders, columns=['id', 'datetime', 'type', 'side', 'price', 'amount', 'status', 'symbol'])
                df_orders['datetime'] = pd.to_datetime(df_orders['datetime']).dt.strftime('%Y-%m-%d %H:%M:%S')
                print(Fore.WHITE + Style.BRIGHT + "\\nOpen Orders:")
                print(Fore.GREEN + df_orders[['datetime', 'symbol', 'type', 'side', 'price', 'amount', 'status']].to_string(index=False))
            else:
                print(Fore.YELLOW + "No open orders found.")
        except ccxt.ExchangeError as e:
            print(Fore.RED + Style.BRIGHT + f"Bybit Err fetch open orders: {e}")
            logging.error(f"Bybit Exchange Error fetching open orders: {e}")
        except Exception as e:
            print(Fore.RED + Style.BRIGHT + f"Err view open orders: {e}")
            logging.error(f"General error viewing open orders: {e}")
        finally:
            input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter...")


    def disp_main_menu(self):
        """Displays the main menu of the terminal."""
        os.system('clear')
        print(Fore.CYAN + Style.BRIGHT + """\n╔══════════════════════════════════╗\n║   Bybit Futures Terminal v1.1    ║\n║  Enhanced Version - Pyrrmethus Edit   ║\n║       Powered by Pyrrmethus       ║\n╚══════════════════════════════════╝\nChoose a category:\n1. Account Operations\n2. Market Data\n3. Trading Actions\n4. Advanced Features\n5. Display API Keys (Debug)\n6. Exit\n""")
        return input(Fore.YELLOW + Style.BRIGHT + "Enter choice (1-6): ")

    def handle_acc_menu(self):
        """Handles actions within the account operations menu."""
        while True:
            choice_acc = self.disp_acc_menu()
            if choice_acc == '1':
                self.view_bal()
            elif choice_acc == '2':
                self.view_ord_hist()
            elif choice_acc == '3':
                self.margin_calc()
            elif choice_acc == '4':
                self.view_open_orders()
            elif choice_acc == '6':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 6.")

    def handle_mkt_menu(self):
        """Handles actions within the market data menu."""
        while True:
            choice_mkt = self.disp_mkt_menu()
            if choice_mkt == '1':
                symbol = input(Fore.YELLOW + "Futures symbol (e.g., BTCUSDT): ").upper()
                self.fetch_sym_price(symbol)
            elif choice_mkt == '2':
                symbol = input(Fore.YELLOW + "Futures symbol (e.g., BTCUSDT): ").upper()
                self.get_ob(symbol)
            elif choice_mkt == '3':
                self.list_syms()
            elif choice_mkt == '4':
                symbol = input(Fore.YELLOW + "Futures symbol: ").upper()
                timeframe = input(Fore.YELLOW + "Timeframe (e.g., 1h): ").lower()
                self.disp_rsi(symbol, timeframe)
            elif choice_mkt == '5':
                symbol = input(Fore.YELLOW + "Futures symbol: ").upper()
                timeframe = input(Fore.YELLOW + "Timeframe (e.g., 1h): ").lower()
                period = int(input(Fore.YELLOW + "ATR Period (e.g., 14): ") or 14)
                self.disp_atr(symbol, timeframe, period)
            elif choice_mkt == '6':
                symbol = input(Fore.YELLOW + "Futures symbol: ").upper()
                timeframe = input(Fore.YELLOW + "Timeframe for FPP (e.g., 1d): ").lower()
                self.disp_fpp(symbol, timeframe)
            elif choice_mkt == '7':
                symbol = input(Fore.YELLOW + "Futures symbol: ").upper()
                timeframe = input(Fore.YELLOW + "Timeframe (e.g., 1h): ").lower()
                self.chart_adv(symbol, timeframe)
            elif choice_mkt == '8':
                sentiment = get_msentiment()
                print(Fore.CYAN + "\\nMarket Sentiment (Fear/Greed Index):")
                print(Fore.WHITE + f"{sentiment}")
                input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter...")
            elif choice_mkt == '9':
                symbol = input(Fore.YELLOW + "Enter symbol: ").upper()
                self.fetch_frate(symbol)
            elif choice_mkt == '10':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 10.")

    def handle_trade_menu(self):
        """Handles actions within the trading actions menu."""
        if CONFIG.api_key and CONFIG.api_secret:
            while True:
                choice_trade = self.disp_trade_menu()
                if choice_trade == '1':
                    self.place_mkt_order()
                elif choice_trade == '2':
                    self.place_lmt_order()
                elif choice_trade == '3':
                    self.cond_order()
                elif choice_trade == '4':
                    self.cancel_order_menu()
                elif choice_trade == '8':
                    break
                else:
                    print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 8.")
        else:
            print(Fore.RED + Style.BRIGHT + "Trading actions disabled: API keys missing.")
            input(Fore.YELLOW + Style.BRIGHT + "Press Enter...")

    def main(self):
        """Main loop of the terminal application."""
        while True:
            main_choice = self.disp_main_menu()
            if main_choice == '1':
                self.handle_acc_menu()
            elif main_choice == '2':
                self.handle_mkt_menu()
            elif main_choice == '3':
                self.handle_trade_menu()
            elif main_choice == '4':
                self.disp_adv_menu()
            elif main_choice == '5':
                self.debug_apikeys()
            elif main_choice == '6':
                print(Fore.MAGENTA + Style.BRIGHT + "Exiting terminal.")
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 6.")
                time.sleep(1.5)
        print(Fore.CYAN + Style.BRIGHT + "Terminal closed.")

    def disp_adv_menu(self):
        """Displays the advanced features menu with neon styling."""
        while True:
            os.system('clear')
            print(NEON_CYAN + """
╔═══════════════════════════════╗
║      ADVANCED FEATURES        ║
╠═══════════════════════════════╣
║ 1. Algorithmic Trading        ║
║ 2. Risk Management Tools      ║
║ 3. Market Analysis Suite      ║
║ 4. Notification Setup         ║
║ 5. Back to Main Menu          ║
╚═══════════════════════════════╝
            """)
            choice = input(Fore.YELLOW + "Select feature (1-5): ")
            if choice == '1':
                self.disp_algo_menu()
            elif choice == '2':
                self.disp_rm_menu()
            elif choice == '3':
                self.disp_ma_menu()
            elif choice == '4':
                self.disp_notif_menu()
            elif choice == '5':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 5.")
                time.sleep(1.5)

    def disp_rm_menu(self):
        """Displays the risk management tools menu with neon styling."""
        while True:
            os.system('clear')
            print(Fore.CYAN + Style.BRIGHT + """\n╔═══════════════════════════════╗\n║    RISK MANAGEMENT TOOLS      ║
╠═══════════════════════════════╣
║ 1. Margin Calculator          ║
║ 2. Set Max Risk Percentage    ║
║ 3. Set Leverage Configuration ║
║ 4. Back to Advanced Features  ║\n╚═══════════════════════════════╝\n""")
            choice = input(Fore.YELLOW + "Select tool (1-4): ")
            if choice == '1':
                self.margin_calc()
            elif choice == '3':
                self.set_lev_menu()
            elif choice == '4':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 4.")
                time.sleep(1.5)

    def disp_algo_menu(self):
        """Displays the algorithmic trading menu with neon styling."""
        while True:
            os.system('clear')
            print(Fore.CYAN + Style.BRIGHT + """\n╔═══════════════════════════════╗\n║    ALGORITHMIC TRADING        ║
╠═══════════════════════════════╣
║ 1. Run Strategy Backtest      ║
║ 2. Live Strategy Exec (WIP)   ║
║ 3. Strategy Config (WIP)    ║
║ 4. Back to Advanced Features  ║\n╚═══════════════════════════════╝\n""")
            choice = input(Fore.YELLOW + "Select action (1-4): ")
            if choice == '1':
                self.backtest()
            elif choice == '3':
                self.config_strategy_menu() # New strategy config menu
            elif choice == '4':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 4.")
                time.sleep(1.5)

    def config_strategy_menu(self):
        """Allows configuration of trading strategies (WIP)."""
        while True:
            os.system('clear')
            print(Fore.CYAN + Style.BRIGHT + """\n╔═══════════════════════════════╗\n║      STRATEGY CONFIGURATION   ║
╠═══════════════════════════════╣
║ 1. Select Default Strategy    ║
║ 2. View Current Strategy      ║
║ 3. Back to Algo Trading Menu  ║\n╚═══════════════════════════════╝\n""")
            choice = input(Fore.YELLOW + "Select action (1-3): ")
            if choice == '1':
                self._set_default_strategy()
            elif choice == '2':
                print(Fore.CYAN + f"\\nCurrent Default Strategy: {NEON_YELLOW}{self.current_strategy}{RESET_COLOR}")
                input(Fore.YELLOW + Style.BRIGHT + "Press Enter to continue...")
            elif choice == '3':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 3.")
                time.sleep(1.5)

    def _set_default_strategy(self):
        """Sets the default trading strategy."""
        strategy_name = input(Fore.YELLOW + "Enter strategy name (ema/macd): ").lower()
        if strategy_name in ['ema', 'macd']:
            self.current_strategy = strategy_name
            CONFIG.strategy['default_strategy'] = strategy_name #Update config as well for persistence
            print(NEON_GREEN + f"Default strategy set to: {NEON_YELLOW}{strategy_name}{RESET_COLOR}")
        else:
            print(Fore.RED + f"Strategy '{strategy_name}' not supported.")
        input(Fore.YELLOW + Style.BRIGHT + "Press Enter to continue...")


    def disp_ma_menu(self):
        """Displays the market analysis menu with neon styling."""
        while True:
            os.system('clear')
            print(NEON_CYAN + """
╔═══════════════════════════════╗
║    MARKET ANALYSIS SUITE      ║
╠═══════════════════════════════╣
║ 1. Adv Chart                 ║
║ 2. Mkt Sentiment              ║
║ 3. Funding Rate               ║
║ 4. RSI Analyze                ║
║ 5. ATR Analyze                ║
║ 6. MACD Analyze     (WIP)     ║
║ 7. FPP Analyze                ║
║ 8. BB Analyze       (WIP)     ║
║ 9. Back to Adv Feat           ║\n╚═══════════════════════════════╝\n""")
            choice = input(Fore.YELLOW + "Select analysis (1-9): ")
            if choice == '1':
                symbol = input(Fore.YELLOW + "Enter symbol: ").upper()
                timeframe = input(Fore.YELLOW + "Enter timeframe: ").lower()
                self.chart_adv(symbol, timeframe)
            elif choice == '2':
                sentiment = get_msentiment()
                print(Fore.CYAN + "\\nMarket Sentiment (Fear/Greed Index):")
                print(Fore.WHITE + f"{sentiment}")
                input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter...")
            elif choice == '3':
                symbol = input(Fore.YELLOW + "Enter symbol: ").upper()
                self.fetch_frate(symbol)
            elif choice == '4':
                self._analyze_indicator(RSI, "RSI")
            elif choice == '5':
                self._analyze_indicator(ATR, "ATR")
            elif choice == '6':
                print(NEON_YELLOW + "MACD Analysis - Work in Progress") #WIP message
                time.sleep(1) # Short pause for WIP message
                # self._analyze_indicator(MACD, "MACD") # MACD Indicator - Not implemented yet
            elif choice == '7':
                self.analyze_fpp_menu()
            elif choice == '8':
                print(NEON_YELLOW + "Bollinger Bands Analysis - Work in Progress") #WIP message
                time.sleep(1) # Short pause for WIP message
                # self._analyze_indicator(BollingerBands, "Bollinger Bands") # BB - Not implemented
            elif choice == '9':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 9.")
                time.sleep(1.5)

    def disp_notif_menu(self):
        """Displays the notification setup menu with neon styling."""
        while True:
            os.system('clear')
            print(NEON_CYAN + """\n╔═══════════════════════════════╗\n║    NOTIFICATION SETUP         ║\n╠═══════════════════════════════╣\n║ 1. Set Price Alert            ║
║ 2. Cfg Email Alerts           ║
║ 3. Back to Adv Feat           ║\n╚═══════════════════════════════╝\n""")
            choice = input(Fore.YELLOW + "Select action (1-3): ")
            if choice == '1':
                symbol = input(Fore.YELLOW + "Symbol for alert: ").upper()
                price = float(input(Fore.YELLOW + "Target price: "))
                self.ntf.price_alert(symbol, price)
                print(Fore.GREEN + f"Price alert set for {symbol} at {price}.")
                input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter...")
            elif choice == '2':
                self.cfg_email_menu()
            elif choice == '3':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 3.")
                time.sleep(1.5)

    def cfg_email_menu(self):
        """Configures email alert settings with neon prompts."""
        print(Fore.CYAN + Style.BRIGHT + "\\n--- Configure Email Alerts ---")
        server = input(Fore.YELLOW + "SMTP Server (e.g., smtp.gmail.com): ")
        user = input(Fore.YELLOW + "Email User: ")
        password = input(Fore.YELLOW + "Email Pass: ")
        receiver = input(Fore.YELLOW + "Receiver Email: ")
        smtp_details = {'server': server, 'user': user, 'password': password, 'receiver': receiver} # Include receiver
        self.ntf.cfg_email(smtp_details)
        input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter...")

    def margin_calc(self):
        """Calculates margin requirements with neon display."""
        os.system('clear')
        print(Fore.CYAN + Style.BRIGHT + "╔══════════════════════════════════╗\n║        MARGIN CALCULATOR         ║\n╚══════════════════════════════════╝")
        account_balance = float(input(Fore.YELLOW + "Account Balance (USDT): "))
        leverage = int(input(Fore.YELLOW + "Leverage (e.g., 10x): "))
        risk_percentage = float(input(Fore.YELLOW + "Risk % per trade: "))
        entry_price = float(input(Fore.YELLOW + "Entry Price: "))
        stop_loss_price = float(input(Fore.YELLOW + "Stop Loss Price: "))

        self.rm.set_lev(leverage)
        position_size = self.rm.pos_size(entry_price, stop_loss_price, account_balance)
        print(Fore.CYAN + "\\n--- Position Calculation ---")
        print(Fore.WHITE + f"Position Size (Contracts): {Fore.GREEN}{position_size}")
        risk_amount = account_balance * risk_percentage / 100
        print(Fore.WHITE + f"Risk Amount (USDT): ${Fore.YELLOW}{risk_amount:.2f}")
        print(Fore.WHITE + f"Leverage Used: {Fore.MAGENTA}{leverage}x")
        input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter...")

    def set_lev_menu(self):
        """Sets the leverage configuration through user input."""
        leverage = int(input(Fore.YELLOW + "Set Leverage (1-100): "))
        self.rm.set_lev(leverage)
        print(Fore.GREEN + f"Leverage set to {self.rm.leverage}x")
        input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter...")

    def fetch_frate(self, symbol: str):
        """Fetches and displays the funding rate for a given symbol."""
        if not self.exch:
            print(Fore.RED + Style.BRIGHT + "CCXT exchange object not initialized.")
            return None

        try:
            funding_rate_data = self.exch.fetch_funding_rate(symbol)
            if funding_rate_data and 'fundingRate' in funding_rate_data:
                os.system('clear')
                print(Fore.CYAN + Style.BRIGHT + "╔════════════FUNDING RATE═════════════╗")
                rate_percentage = float(funding_rate_data['fundingRate']) * 100
                print(Fore.WHITE + Style.BRIGHT + f"\\nCurrent funding rate for {Fore.GREEN}{symbol}{Fore.WHITE}: {Fore.GREEN}{rate_percentage:.4f}%")

                if rate_percentage > 0:
                    rate_color = Fore.GREEN
                    direction = "Positive"
                elif rate_percentage < 0:
                    rate_color = Fore.RED
                    direction = "Negative"
                else:
                    rate_color = Fore.YELLOW
                    direction = "Neutral"

                print(Fore.WHITE + Style.BRIGHT + f"Funding Rate is: {rate_color}{direction}{Fore.WHITE}")
                return funding_rate_data['fundingRate']
            else:
                print(Fore.RED + Style.BRIGHT + f"Could not fetch funding rate for {symbol}")
                return None

        except ccxt.ExchangeError as e:
            print(Fore.RED + Style.BRIGHT + f"Bybit Exchange Error fetching funding rate: {e}")
            logging.error(f"Bybit Exchange Error fetching funding rate: {e}")
        except Exception as e:
            print(Fore.RED + Style.BRIGHT + f"Error fetching funding rate: {e}")
            logging.error(f"General error fetching funding rate: {e}")
        finally:
            input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter...")

    def analyze_fpp_menu(self):
        """Analyzes and displays Fibonacci Pivot Points based on user input."""
        symbol = input(Fore.YELLOW + "Enter Futures symbol for FPP analysis (e.g., BTCUSDT): ").upper()
        timeframe = input(Fore.YELLOW + "Enter timeframe for FPP (e.g., 1d): ").lower()

        try:
            bars = self.exch.fetch_ohlcv(symbol, timeframe, limit=2)
            if not bars or len(bars) < 2:
                print(Fore.RED + Style.BRIGHT + f"Could not fetch enough OHLCV data for {symbol} in {timeframe}")
                return

            df = pd.DataFrame(bars, columns=['timestamp', 'open', 'high', 'low', 'close', 'volume'])
            current_price = self.exch.fetch_ticker(symbol)['last']
            fpp_df = self.fpp_indicator.calculate(df)
            signals = self.fpp_indicator.generate_trading_signals(df, current_price)

            os.system('clear')
            print(Fore.CYAN + Style.BRIGHT + f"╔══════FIBONACCI PIVOT POINTS ({symbol} - {timeframe})══════╗")
            print(Fore.WHITE + Style.BRIGHT + "\\nFibonacci Pivot Levels:")
            for level in self.fpp_indicator.level_names:
                price = fpp_df.iloc[0][level]
                signal_name = self.fpp_indicator.level_names[level]
                print(f"{Fore.WHITE}{signal_name}: {Fore.GREEN}{price:.4f}")

            if signals:
                print(Fore.WHITE + Style.BRIGHT + "\\nTrading Signals:")
                for signal in signals:
                    print(signal)
            else:
                print(Fore.YELLOW + "\\nNo strong signals at this time.")

        except ccxt.ExchangeError as e:
            print(Fore.RED + Style.BRIGHT + f"Bybit Exchange Error during FPP analysis: {e}")
            logging.error(f"Bybit Exchange Error during FPP analysis: {e}")
        except Exception as e:
            print(Fore.RED + Style.BRIGHT + f"Error analyzing Fibonacci Pivot Points: {e}")
            logging.error(f"General error analyzing Fibonacci Pivot Points: {e}")
        finally:
            input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter to continue...")

    def get_msentiment(self):
        """Fetches market sentiment (Fear & Greed Index) from alternative.me API."""
        url = "https://api.alternative.me/fng/?limit=1&format=json"
        try:
            response = requests.get(url)
            response.raise_for_status()
            data = response.json()
            value = data['data'][0]['value']
            classification = data['data'][0]['value_classification']
            return f"Fear & Greed Index: {value} ({classification})"
        except requests.exceptions.RequestException as e:
            logging.error(f"Error fetching market sentiment: {e}")
            return "Could not retrieve market sentiment."
        except (KeyError, IndexError, json.JSONDecodeError) as e:
            logging.error(f"Error processing market sentiment data: {e}")
            return "Could not process market sentiment data."

    def disp_mkt_menu(self):
        """Displays the market data menu."""
        while True:
            os.system('clear')
            print(Fore.CYAN + Style.BRIGHT + """\n╔════════════MARKET DATA═════════════╗\n║         (Using CCXT)             ║\n╚═══════════════════════════════╝\nChoose data:\n1. Symbol Price\n2. Order Book\n3. Symbols List\n4. RSI\n5. ATR\n6. FPP\n7. Adv Chart\n8. Mkt Sentiment\n9. Funding Rate\n10. Back to Main Menu\n""")
            choice = input(Fore.YELLOW + "Select data (1-10): ")
            if choice == '1':
                symbol = input(Fore.YELLOW + "Futures symbol (e.g., BTCUSDT): ").upper()
                self.fetch_sym_price(symbol)
            elif choice == '2':
                symbol = input(Fore.YELLOW + "Futures symbol (e.g., BTCUSDT): ").upper()
                self.get_ob(symbol)
            elif choice == '3':
                self.list_syms()
            elif choice == '4':
                symbol = input(Fore.YELLOW + "Futures symbol: ").upper()
                timeframe = input(Fore.YELLOW + "Timeframe (e.g., 1h): ").lower()
                self.disp_rsi(symbol, timeframe)
            elif choice == '5':
                symbol = input(Fore.YELLOW + "Futures symbol: ").upper()
                timeframe = input(Fore.YELLOW + "Timeframe (e.g., 1h): ").lower()
                period = int(input(Fore.YELLOW + "ATR Period (e.g., 14): ") or 14)
                self.disp_atr(symbol, timeframe, period)
            elif choice == '6':
                symbol = input(Fore.YELLOW + "Futures symbol: ").upper()
                timeframe = input(Fore.YELLOW + "Timeframe for FPP (e.g., 1d): ").lower()
                self.disp_fpp(symbol, timeframe)
            elif choice == '7':
                symbol = input(Fore.YELLOW + "Futures symbol: ").upper()
                timeframe = input(Fore.YELLOW + "Timeframe (e.g., 1h): ").lower()
                self.chart_adv(symbol, timeframe)
            elif choice == '8':
                sentiment = get_msentiment()
                print(Fore.CYAN + "\\nMarket Sentiment (Fear/Greed Index):")
                print(Fore.WHITE + f"{sentiment}")
                input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter...")
            elif choice == '9':
                symbol = input(Fore.YELLOW + "Enter symbol: ").upper()
                self.fetch_frate(symbol)
            elif choice == '10':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 10.")
                time.sleep(1.5)

    def disp_acc_menu(self):
        """Displays the account operations menu."""
        while True:
            os.system('clear')
            print(Fore.CYAN + Style.BRIGHT + """\n╔════════════ACCOUNT OPS═════════════╗\n║     (Using CCXT & Pandas)        ║\n╚═══════════════════════════════╝\nChoose action:\n1. View Balance\n2. View Order History\n3. Margin Calculator\n4. View Open Orders\n6. Back to Main Menu\n""")
            choice = input(Fore.YELLOW + "Select action (1-6): ")
            if choice == '1':
                self.view_bal()
            elif choice == '2':
                self.view_ord_hist()
            elif choice_acc == '3':
                self.margin_calc()
            elif choice_acc == '4':
                self.view_open_orders()
            elif choice_acc == '6':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 6.")

    def handle_acc_menu(self):
        """Handles actions within the account operations menu."""
        while True:
            choice_acc = self.disp_acc_menu()
            if choice_acc == '1':
                self.view_bal()
            elif choice_acc == '2':
                self.view_ord_hist()
            elif choice_acc == '3':
                self.margin_calc()
            elif choice_acc == '4':
                self.view_open_orders()
            elif choice_acc == '6':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 6.")

    def handle_mkt_menu(self):
        """Handles actions within the market data menu."""
        while True:
            choice_mkt = self.disp_mkt_menu()
            if choice_mkt == '1':
                symbol = input(Fore.YELLOW + "Futures symbol (e.g., BTCUSDT): ").upper()
                self.fetch_sym_price(symbol)
            elif choice_mkt == '2':
                symbol = input(Fore.YELLOW + "Futures symbol (e.g., BTCUSDT): ").upper()
                self.get_ob(symbol)
            elif choice_mkt == '3':
                self.list_syms()
            elif choice_mkt == '4':
                symbol = input(Fore.YELLOW + "Futures symbol: ").upper()
                timeframe = input(Fore.YELLOW + "Timeframe (e.g., 1h): ").lower()
                self.disp_rsi(symbol, timeframe)
            elif choice_mkt == '5':
                symbol = input(Fore.YELLOW + "Futures symbol: ").upper()
                timeframe = input(Fore.YELLOW + "Timeframe (e.g., 1h): ").lower()
                period = int(input(Fore.YELLOW + "ATR Period (e.g., 14): ") or 14)
                self.disp_atr(symbol, timeframe, period)
            elif choice_mkt == '6':
                symbol = input(Fore.YELLOW + "Futures symbol: ").upper()
                timeframe = input(Fore.YELLOW + "Timeframe for FPP (e.g., 1d): ").lower()
                self.disp_fpp(symbol, timeframe)
            elif choice_mkt == '7':
                symbol = input(Fore.YELLOW + "Futures symbol: ").upper()
                timeframe = input(Fore.YELLOW + "Timeframe (e.g., 1h): ").lower()
                self.chart_adv(symbol, timeframe)
            elif choice_mkt == '8':
                sentiment = get_msentiment()
                print(Fore.CYAN + "\\nMarket Sentiment (Fear/Greed Index):")
                print(Fore.WHITE + f"{sentiment}")
                input(Fore.YELLOW + Style.BRIGHT + "\\nPress Enter...")
            elif choice_mkt == '9':
                symbol = input(Fore.YELLOW + "Enter symbol: ").upper()
                self.fetch_frate(symbol)
            elif choice_mkt == '10':
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 10.")

    def handle_trade_menu(self):
        """Handles actions within the trading actions menu."""
        if CONFIG.api_key and CONFIG.api_secret:
            while True:
                choice_trade = self.disp_trade_menu()
                if choice_trade == '1':
                    self.place_mkt_order()
                elif choice_trade == '2':
                    self.place_lmt_order()
                elif choice_trade == '3':
                    self.cond_order()
                elif choice_trade == '4':
                    self.cancel_order_menu()
                elif choice_trade == '8':
                    break
                else:
                    print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 8.")
        else:
            print(Fore.RED + Style.BRIGHT + "Trading actions disabled: API keys missing.")
            input(Fore.YELLOW + Style.BRIGHT + "Press Enter...")

    def main(self):
        """Main loop of the terminal application."""
        while True:
            main_choice = self.disp_main_menu()
            if main_choice == '1':
                self.handle_acc_menu()
            elif main_choice == '2':
                self.handle_mkt_menu()
            elif main_choice == '3':
                self.handle_trade_menu()
            elif main_choice == '4':
                self.disp_adv_menu()
            elif main_choice == '5':
                self.debug_apikeys()
            elif main_choice == '6':
                print(Fore.MAGENTA + Style.BRIGHT + "Exiting terminal.")
                break
            else:
                print(Fore.RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 6.")
                time.sleep(1.5)
        print(Fore.CYAN + Style.BRIGHT + "Terminal closed.")

    def run(self):
        """Runs the main terminal loop."""
        self.main()

if __name__ == "__main__":
    terminal = BTT()
    terminal.run()
EOM
)"

    # --- Create config.py with Full Code ---
    create_file "$BASE_DIR/config.py" "$(cat << 'EOF'
import os
from enum import Enum
from pydantic import BaseSettings

class TradingMode(str, Enum):
    LIVE = "live"
    PAPER = "paper"
    BACKTEST = "backtest"

class Config(BaseSettings):
    api_key: str = os.getenv("BYBIT_API_KEY")
    api_secret: str = os.getenv("BYBIT_API_SECRET")
    trading_mode: TradingMode = TradingMode(os.getenv("TRADING_MODE", "paper"))
    risk_params: dict = {
        'max_per_trade': float(os.getenv("MAX_RISK_PER_TRADE", 0.02)),
        'max_leverage': int(os.getenv("MAX_LEVERAGE", 100)),
        'daily_loss_limit': float(os.getenv("DAILY_LOSS_LIMIT", 0.1))
    }
    email_config: dict = {
        'server': os.getenv("EMAIL_SERVER"),
        'user': os.getenv("EMAIL_USER"),
        'password': os.getenv("EMAIL_PASSWORD"),
        'receiver': os.getenv("EMAIL_RECEIVER")
    }
    strategy_config: dict = {
        'default_strategy': os.getenv("DEFAULT_STRATEGY", "ema")
    }


    class Config:
        env_file = ".env"

CONFIG = Config()
EOF
)"

    # --- Create enums.py with Full Code ---
    create_file "$BASE_DIR/enums.py" "$(cat << 'EOF'
from enum import Enum

class OrderType(Enum):
    MARKET = 'market'
    LIMIT = 'limit'
    STOP = 'stop'
    OCO = 'oco'

class OrderSide(Enum):
    BUY = 'buy'
    SELL = 'sell'

class AnalysisType(Enum):
    RSI = 'rsi'
    ATR = 'atr'
    FPP = 'fpp'
    MACD = 'macd'
    BB = 'bb'
EOF
)"

    # --- Create core/risk_manager.py with Full Code ---
    create_file "$BASE_DIR/core/risk_manager.py" "$(cat << 'EOF'
from colorama import Fore, Style

NEON_GREEN   = Fore.GREEN + Style.BRIGHT

# --- Risk Manager ---
class RM:
    def __init__(self, config):
        self.config = config
        self.leverage = 1 # default

    def set_lev(self, leverage: int):
        self.leverage = min(leverage, self.config['max_leverage'])
        print(NEON_GREEN + f"Leverage set to {self.leverage}x")

    def pos_size(self, entry_price, stop_loss_price, account_balance):
        risk_amount = account_balance * self.config['max_per_trade']
        risk_per_contract = abs(entry_price - stop_loss_price)
        if risk_per_contract == 0:
            return 0  # Avoid division by zero
        return (risk_amount / risk_per_contract) * self.leverage

    def calc_margin(self, position_size, entry_price, leverage):
        """Calculates initial margin needed for a position."""
        if leverage == 0:
            return 0
        return (position_size * entry_price) / leverage
EOF
)"

    # --- Create core/notifier.py with Full Code ---
    create_file "$BASE_DIR/core/notifier.py" "$(cat << 'EOF'
import smtplib
from email.message import EmailMessage
from queue import Queue
import threading
import logging
from colorama import Fore, Style

NEON_CYAN    = Fore.CYAN + Style.BRIGHT
NEON_GREEN   = Fore.GREEN + Style.BRIGHT
NEON_YELLOW  = Fore.YELLOW + Style.BRIGHT
NEON_RED     = Fore.RED + Style.BRIGHT

# --- Notifier Handler ---
class NH:
    def __init__(self, config):
        self.config = config.email_config
        self.queue = Queue()
        threading.Thread(target=self.process_queue, daemon=True).start()
        self.email_alerts_enabled = all(config.email_config.values()) # Enable emails only if all config is present

    def send_alert(self, message):
        if self.email_alerts_enabled:
            self.queue.put(message)
        else:
            print(NEON_YELLOW + "Email alerts are not configured, displaying alert in terminal:")
            print(NEON_CYAN + message)

    def process_queue(self):
        while True:
            msg = self.queue.get()
            try:
                with smtplib.SMTP_SSL(self.config['server'], 465) as server:
                    server.login(self.config['user'], self.config['password'])
                    email_msg = EmailMessage()
                    email_msg.set_content(msg)
                    email_msg['Subject'] = 'BTT Alert'
                    email_msg['From'] = self.config['user']
                    email_msg['To'] = self.config['receiver']
                    server.send_message(email_msg)
                print(NEON_GREEN + "Email alert sent successfully.")
            except Exception as e:
                print(NEON_RED + f"Failed to send email alert: {str(e)}")
                logging.exception("Email sending failed")

    def cfg_email(self, smtp_details: dict):
        """Configures email alert settings."""
        self.config.update(smtp_details)
        self.email_alerts_enabled = all(self.config.values())
        if self.email_alerts_enabled:
            print(NEON_GREEN + "Email alerts enabled.")
        else:
            print(NEON_YELLOW + "Email alerts configuration incomplete. Email alerts disabled.")

    def price_alert(self, symbol, price):
        """Placeholder for price alerts - needs robust implementation (e.g., background thread)."""
        print(f"{NEON_CYAN}Price alert set for {symbol} at {price}. (Currently simulated)")
        # TODO:  Replace with actual price monitoring and alerting.
EOF
)"

    # --- Create core/strategy_engine.py with Full Code ---
    create_file "$BASE_DIR/core/strategy_engine.py" "$(cat << 'EOF'
import numpy as np
import pandas as pd

# --- Strategy Engine ---
class SE:
    def __init__(self):
        pass

    def run_backtest(self, df, strategy_name):
        if strategy_name == 'ema':
            return self._ema_strategy(df)
        elif strategy_name == 'macd':
            return self._macd_strategy(df)
        else:
            raise ValueError(f"Unsupported strategy: {strategy_name}")

    def _ema_strategy(self, df):
        df['ema_fast'] = df['close'].ewm(span=12, adjust=False).mean()
        df['ema_slow'] = df['close'].ewm(span=26, adjust=False).mean()
        df['signal'] = np.where(df['ema_fast'] > df['ema_slow'], 1, -1)
        df['returns'] = df['close'].pct_change()
        df['strategy_returns'] = df['signal'].shift(1) * df['returns']
        bt_res = {
            'tot_ret_perc': df['strategy_returns'].sum() * 100,
            'max_dd_perc': (df['strategy_returns'].cumsum() -
                            df['strategy_returns'].cumsum().cummax()).min() * 100,
            'cum_rets': (1 + df['strategy_returns']).cumprod(),
        }
        return bt_res

    def _macd_strategy(self, df):
        df['ema_short'] = df['close'].ewm(span=12, adjust=False).mean()
        df['ema_long'] = df['close'].ewm(span=26, adjust=False).mean()
        df['macd'] = df['ema_short'] - df['ema_long']
        df['signal_line'] = df['macd'].ewm(span=9, adjust=False).mean()
        df['histogram'] = df['macd'] - df['signal_line']
        df['signal'] = np.where(df['macd'] > df['signal_line'], 1, -1) # Simple MACD cross
        df['returns'] = df['close'].pct_change()
        df['strategy_returns'] = df['signal'].shift(1) * df['returns']
        bt_res = {
            'tot_ret_perc': df['strategy_returns'].sum() * 100,
            'max_dd_perc': (df['strategy_returns'].cumsum() -
                            df['strategy_returns'].cumsum().cummax()).min() * 100,
            'cum_rets': (1 + df['strategy_returns']).cumprod(),
        }
        return bt_res
EOF
)"

    # --- Create indicators/fibonacci_pivot_points.py with Full Code ---
    create_file "$BASE_DIR/indicators/fibonacci_pivot_points.py" "$(cat << 'EOF'
import pandas as pd
from colorama import Fore, Style

NEON_GREEN   = Fore.GREEN + Style.BRIGHT
NEON_RED     = Fore.RED + Style.BRIGHT
NEON_YELLOW  = Fore.YELLOW + Style.BRIGHT

# --- Indicator Classes (in indicators.py, if separate file) ---
class FibonacciPivotPoints:
    def __init__(self, config=None): # Added config for consistency, though not used
        self.level_names = {
            "Pivot": "Pivot Point",
            "R1": "Resistance 1",
            "R2": "Resistance 2",
            "R3": "Resistance 3",
            "S1": "Support 1",
            "S2": "Support 2",
            "S3": "Support 3",
        }

    def calculate(self, df):
        """Calculates Fibonacci Pivot Points and levels."""
        high = df['high'].iloc[-1]
        low = df['low'].iloc[-1]
        close = df['close'].iloc[-1]

        pivot = (high + low + close) / 3
        r1 = (2 * pivot) - low
        r2 = pivot + (high - low)
        r3 = high + 2 * (pivot - low)
        s1 = (2 * pivot) - high
        s2 = pivot - (high - low)
        s3 = low - 2 * (high - pivot)

        return pd.DataFrame([{
            "Pivot": pivot, "R1": r1, "R2": r2, "R3": r3,
            "S1": s1, "S2": s2, "S3": s3
        }])

    def generate_trading_signals(self, df, current_price):
        """Generates trading signals based on FPP levels."""
        fpp_levels = self.calculate(df).iloc[0]
        signals = []

        if current_price > fpp_levels['R1']:
            signals.append(f"{NEON_GREEN}Price ({current_price:.2f}) above R1 ({fpp_levels['R1']:.2f}) - Consider selling near R2.")
        elif current_price < fpp_levels['S1']:
            signals.append(f"{NEON_RED}Price ({current_price:.2f}) below S1 ({fpp_levels['S1']:.2f}) - Consider buying near S2.")
        elif fpp_levels['Pivot'] < current_price < fpp_levels['R1']:
            signals.append(f"{NEON_YELLOW}Price between Pivot and R1. Monitor for breakouts.")
        elif fpp_levels['S1'] < current_price < fpp_levels['Pivot']:
            signals.append(f"{NEON_YELLOW}Price between S1 and Pivot. Monitor for breakouts.")

        return signals
EOF
)"

    echo -e "\n🚀 Full Terminal Setup Complete!"
    echo "🔧 Next steps:"
    echo "1. Configure your .env file with your API credentials, email settings, and trading preferences."
    echo "2. Install dependencies: ${NEON_GREEN}pip install -r requirements.txt${RESET_COLOR}"
    echo "3. Run the terminal: ${NEON_GREEN}python -m ${BASE_DIR/__/.}__main__.py${RESET_COLOR}"
    echo -e "\n${NEON_YELLOW}Important:${RESET_COLOR} Review and understand the code before live trading. Start with paper trading mode first!"
}

# --- Execute main function ---
main
