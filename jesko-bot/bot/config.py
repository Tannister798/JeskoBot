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
    executor: str
    weth: str
    usdc: str
    aave_pool: str
    aave_atoken: str
    balancer_vault: str
    uniswap_quoter: str
    sushi_router: str
    trade_amount_weth: Decimal
    min_profit_weth: Decimal
    slippage_bps: int
    max_gas_price_gwei: Decimal
    cycle_interval_seconds: int
    cooldown_seconds: int
    live_trading: bool

    @classmethod
    def from_env(cls) -> "Config":
        private_key = _required("PRIVATE_KEY")
        if private_key.lower().startswith("your_") or private_key.lower() == "0x":
            raise ValueError("PRIVATE_KEY must be set to a rotated key")

        config = cls(
            rpc_url=os.getenv("RPC_URL", "https://arb1.arbitrum.io/rpc").strip(),
            chain_id=int(os.getenv("CHAIN_ID", "42161")),
            private_key=private_key,
            executor=_required("ARBITRAGE_EXECUTOR"),
            weth=_required("WETH"),
            usdc=_required("USDC"),
            aave_pool=_required("AAVE_POOL"),
            aave_atoken=_required("AAVE_ATOKEN"),
            balancer_vault=_required("BALANCER_VAULT"),
            uniswap_quoter=_required("UNISWAP_V3_QUOTER"),
            sushi_router=_required("SUSHI_V2_ROUTER"),
            trade_amount_weth=Decimal(_required("TRADE_AMOUNT_WETH")),
            min_profit_weth=Decimal(os.getenv("MIN_PROFIT_WETH", "0.01")),
            slippage_bps=int(os.getenv("MAX_SLIPPAGE_BPS", "50")),
            max_gas_price_gwei=Decimal(os.getenv("MAX_GAS_PRICE_GWEI", "2")),
            cycle_interval_seconds=int(os.getenv("CYCLE_INTERVAL_SECONDS", "25")),
            cooldown_seconds=int(os.getenv("COOLDOWN_SECONDS", "45")),
            live_trading=os.getenv("ENABLE_LIVE_TRADING", "false").lower() == "true",
        )

        if config.chain_id != 42161:
            raise ValueError("This bot only supports Arbitrum One (chain ID 42161)")
        if not config.rpc_url.startswith(("http://", "https://")):
            raise ValueError("RPC_URL must be an HTTP(S) endpoint")
        if config.trade_amount_weth <= 0 or config.min_profit_weth < 0:
            raise ValueError("Trade amount must be positive and minimum profit non-negative")
        if not 0 <= config.slippage_bps <= 500:
            raise ValueError("MAX_SLIPPAGE_BPS must be between 0 and 500")
        if config.max_gas_price_gwei <= 0:
            raise ValueError("MAX_GAS_PRICE_GWEI must be positive")
        if config.cycle_interval_seconds <= 0 or config.cooldown_seconds < 0:
            raise ValueError("Polling interval must be positive and cooldown non-negative")
        return config
