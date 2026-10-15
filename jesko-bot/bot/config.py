import os
from dataclasses import dataclass

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
    house_borrower: str
    skew_keeper: str
    private_amm: str
    cz_token: str
    weth: str
    usdc: str
    mint_amount: int
    loan_amount: int
    min_usdc_out: int
    cycle_interval_seconds: int
    cooldown_seconds: int
    live_trading: bool

    @classmethod
    def from_env(cls) -> "Config":
        private_key = _required("PRIVATE_KEY")
        if private_key.lower().startswith("your_") or private_key == "0x":
            raise ValueError("PRIVATE_KEY must be a real rotated key")

        cfg = cls(
            rpc_url=os.getenv("RPC_URL", "https://arb1.arbitrum.io/rpc").strip(),
            chain_id=int(os.getenv("CHAIN_ID", "42161")),
            private_key=private_key,
            house_borrower=_required("HOUSE_BORROWER"),
            skew_keeper=_required("SKEW_KEEPER"),
            private_amm=_required("PRIVATE_AMM"),
            cz_token=_required("CZ_TOKEN"),
            weth=_required("WETH"),
            usdc=_required("USDC"),
            mint_amount=int(os.getenv("MINT_AMOUNT", "1000000000000000000")),
            loan_amount=int(os.getenv("LOAN_AMOUNT", "10000000000000000")),
            min_usdc_out=int(os.getenv("MIN_USDC_OUT", "0")),
            cycle_interval_seconds=int(os.getenv("CYCLE_INTERVAL_SECONDS", "30")),
            cooldown_seconds=int(os.getenv("COOLDOWN_SECONDS", "45")),
            live_trading=os.getenv("ENABLE_LIVE_TRADING", "false").lower() == "true",
        )

        if cfg.chain_id != 42161:
            raise ValueError("This bot targets Arbitrum One (42161)")
        if cfg.mint_amount <= 0 or cfg.loan_amount <= 0:
            raise ValueError("MINT_AMOUNT and LOAN_AMOUNT must be positive")
        return cfg