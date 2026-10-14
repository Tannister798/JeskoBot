import os
from dotenv import load_dotenv

load_dotenv()

class Config:
    # Wallet & Network
    PRIVATE_KEY = os.getenv("PRIVATE_KEY")
    RPC_URL = os.getenv("RPC_URL", "https://arb1.arbitrum.io/rpc")

    # Contract addresses (fill after deployment)
    CZ_TOKEN = os.getenv("CZ_TOKEN")
    PRIVATE_AMM = os.getenv("PRIVATE_AMM")
    HOUSE_BORROWER = os.getenv("HOUSE_BORROWER")
    SKEW_KEEPER = os.getenv("SKEW_KEEPER")
    PRICE_FEED = os.getenv("PRICE_FEED")

    # Strategy parameters
    MIN_SKEW = 0.010          # 1.0%
    MAX_SKEW = 0.020          # 2.0%
    IDEAL_SKEW = 0.018        # 1.8%

    MIN_PROFIT_USD = 30
    MAX_TRADE_SIZE_USD = 150_000
    DEFAULT_LOAN_RATIO = 0.65

    # Safety
    MAX_SLIPPAGE = 0.015
    COOLDOWN_SECONDS = 45
