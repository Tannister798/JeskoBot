import os
from dotenv import load_dotenv

load_dotenv()

class Config:
    PRIVATE_KEY = os.getenv("PRIVATE_KEY")
    RPC_URL = os.getenv("RPC_URL", "https://sepolia-rollup.arbitrum.io/rpc")

    CZ_TOKEN = os.getenv("CZ_TOKEN")
    PRIVATE_AMM = os.getenv("PRIVATE_AMM")
    HOUSE_BORROWER = os.getenv("HOUSE_BORROWER")
    SKEW_KEEPER = os.getenv("SKEW_KEEPER")
    PRICE_FEED = os.getenv("PRICE_FEED")

    MIN_SKEW = 0.010
    MAX_SKEW = 0.020
    IDEAL_SKEW = 0.018

    MIN_PROFIT_USD = 30
    MAX_TRADE_SIZE_USD = 150_000
    DEFAULT_LOAN_RATIO = 0.65

    MAX_SLIPPAGE = 0.015
    COOLDOWN_SECONDS = 45
