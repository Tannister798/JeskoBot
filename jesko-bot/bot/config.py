import os
from dotenv import load_dotenv
import os
from dataclasses import dataclass
from decimal import Decimal

from dotenv import load_dotenv

load_dotenv()


def _required(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise ValueError(f"{name} must be configured")
    return value


@dataclass(frozen=True)
class Config:
    rpc_url: str
    chain_id: int
    private_key: str
    cz_token: str
    private_amm: str
    house_borrower: str
    weth: str
    aave_pool: str
    uniswap_quoter: str
    uniswap_fee: int
    trade_size_cz: Decimal
    loan_amount_weth: Decimal
    min_profit_weth: Decimal
    slippage_bps: int
    max_gas_price_gwei: Decimal
    cycle_interval_seconds: int
    cooldown_seconds: int
    live_trading: bool

    @classmethod
    def from_env(cls) -> "Config":
        private_key = _required("PRIVATE_KEY")
        if private_key.lower() in {"your_private_key_here", "0x"}:
            raise ValueError("PRIVATE_KEY must be a real, rotated key")

        config = cls(
            rpc_url=os.getenv("RPC_URL", "https://arb1.arbitrum.io/rpc").strip(),
            chain_id=int(os.getenv("CHAIN_ID", "42161")),
            private_key=private_key,
            cz_token=_required("CZ_TOKEN"),
            private_amm=_required("PRIVATE_AMM"),
            house_borrower=_required("HOUSE_BORROWER"),
            weth=_required("WETH"),
            aave_pool=_required("AAVE_POOL"),
            uniswap_quoter=_required("UNISWAP_V3_QUOTER"),
            uniswap_fee=int(os.getenv("UNISWAP_V3_FEE", "10000")),
            trade_size_cz=Decimal(_required("TRADE_SIZE_CZ")),
            loan_amount_weth=Decimal(_required("LOAN_AMOUNT_WETH")),
            min_profit_weth=Decimal(os.getenv("MIN_PROFIT_WETH", "0.01")),
            slippage_bps=int(os.getenv("MAX_SLIPPAGE_BPS", "50")),
            max_gas_price_gwei=Decimal(os.getenv("MAX_GAS_PRICE_GWEI", "2")),
            cycle_interval_seconds=int(os.getenv("CYCLE_INTERVAL_SECONDS", "25")),
            cooldown_seconds=int(os.getenv("COOLDOWN_SECONDS", "45")),
            live_trading=os.getenv("ENABLE_LIVE_TRADING", "false").lower() == "true",
        )

        if config.chain_id != 42161:
            raise ValueError("This bot is configured for Arbitrum One (chain ID 42161)")
        if not config.rpc_url.startswith(("http://", "https://")):
            raise ValueError("RPC_URL must be an HTTP(S) endpoint")
        if config.trade_size_cz <= 0 or config.loan_amount_weth <= 0:
            raise ValueError("Trade size and WETH loan amount must be positive")
        if config.min_profit_weth < 0:
            raise ValueError("MIN_PROFIT_WETH cannot be negative")
        if config.max_gas_price_gwei <= 0:
            raise ValueError("MAX_GAS_PRICE_GWEI must be positive")
        if not 0 <= config.slippage_bps <= 500:
            raise ValueError("MAX_SLIPPAGE_BPS must be between 0 and 500")
        if config.uniswap_fee not in {100, 500, 3000, 10000}:
            raise ValueError("UNISWAP_V3_FEE must be an enabled V3 fee tier")
        if config.cycle_interval_seconds <= 0 or config.cooldown_seconds < 0:
            raise ValueError("Polling interval must be positive and cooldown non-negative")
        return config
