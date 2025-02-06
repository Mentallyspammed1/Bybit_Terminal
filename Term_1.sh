#!/bin/bash

# --- Project Configuration ---
BASE_DIR="bybit_terminal_full"
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
    mkdir -p "$BASE_DIR" || { echo "${NEON_RED}❌ Failed to create base directory '$BASE_DIR'"; exit 1; }
    for dir in "${DIRS[@]}"; do
        mkdir -p "$BASE_DIR/$dir" || { echo "${NEON_RED}❌ Failed to create directory '$BASE_DIR/$dir'"; exit 1; }
        touch "$BASE_DIR/$dir/__init__.py" || { echo "${NEON_RED}❌ Failed to initialize package in '$BASE_DIR/$dir'"; exit 1; }
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

    # --- Create __main__.py ---
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

# --- Neon Color Definitions --- (Redundant, but keep for completeness)
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
            choice = input(NEON_YELLOW + "Select feature (1-5): ")
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
                print(NEON_RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 5.")
                time.sleep(1.5)

    def disp_rm_menu(self):
        """Displays the risk management tools menu with neon styling."""
        while True:
            os.system('clear')
            print(NEON_CYAN + """
╔═══════════════════════════════╗
║    RISK MANAGEMENT TOOLS      ║
╠═══════════════════════════════╣
║ 1. Margin Calculator          ║
║ 2. Set Max Risk Percentage    ║
║ 3. Set Leverage Configuration ║
║ 4. Back to Advanced Features  ║
╚═══════════════════════════════╝
            """)
            choice = input(NEON_YELLOW + "Select tool (1-4): ")
            if choice == '1':
                self.margin_calc()
            elif choice == '3':
                self.set_lev_menu()
            elif choice == '4':
                break
            else:
                print(NEON_RED + Style.BRIGHT + "Invalid choice. Please select a number from 1 to 4.")
                time.sleep(1.5)

    def disp_algo_menu(self):
        """Displays the algorithmic trading menu with neon styling."""
 
