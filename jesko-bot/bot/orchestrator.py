import logging
import time
from decimal import Decimal

from web3 import Web3

from .config import Config

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("jeskobot")

ERC20_ABI = [
    {
        "inputs": [],
        "name": "decimals",
        "outputs": [{"type": "uint8"}],
        "stateMutability": "view",
        "type": "function",
    }
]
CZ_ABI = ERC20_ABI + [
    {
        "inputs": [
            {"name": "token", "type": "address"},
            {"name": "amount", "type": "uint256"},
        ],
        "name": "flashFee",
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    }
]
AMM_ABI = [
    {
        "inputs": [],
        "name": "getReserves",
        "outputs": [{"type": "uint256"}, {"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    }
]
BORROWER_ABI = [
    {
        "inputs": [
            {"name": "mintAmount", "type": "uint256"},
            {"name": "loanAmount", "type": "uint256"},
            {"name": "deadline", "type": "uint256"},
            {"name": "maxWethIn", "type": "uint256"},
        ],
        "name": "executeCycle",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "owner",
        "outputs": [{"type": "address"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "paused",
        "outputs": [{"type": "bool"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "maxTradeSize",
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "minProfit",
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
]
QUOTER_V2_ABI = [
    {
        "inputs": [
            {
                "components": [
                    {"name": "tokenIn", "type": "address"},
                    {"name": "tokenOut", "type": "address"},
                    {"name": "amount", "type": "uint256"},
                    {"name": "fee", "type": "uint24"},
                    {"name": "sqrtPriceLimitX96", "type": "uint160"},
                ],
                "name": "params",
                "type": "tuple",
            }
        ],
        "name": "quoteExactOutputSingle",
        "outputs": [
            {"type": "uint256"},
            {"type": "uint160"},
            {"type": "uint32"},
            {"type": "uint256"},
        ],
        "stateMutability": "nonpayable",
        "type": "function",
    }
]
AAVE_ABI = [
    {
        "inputs": [],
        "name": "FLASHLOAN_PREMIUM_TOTAL",
        "outputs": [{"type": "uint128"}],
        "stateMutability": "view",
        "type": "function",
    }
]


def _to_units(value: Decimal, decimals: int) -> int:
    return int(value * (Decimal(10) ** decimals))


def _from_units(value: int, decimals: int) -> Decimal:
    return Decimal(value) / (Decimal(10) ** decimals)


class JeskoOrchestrator:
    def __init__(self):
        self.config = Config.from_env()
        self.w3 = Web3(
            Web3.HTTPProvider(
                self.config.rpc_url,
                request_kwargs={"timeout": 10},
            )
        )
        if not self.w3.is_connected():
            raise RuntimeError("Could not connect to the configured RPC")
        if self.w3.eth.chain_id != self.config.chain_id:
            raise RuntimeError(
                f"Wrong chain: expected {self.config.chain_id}, got {self.w3.eth.chain_id}"
            )

        self.account = self.w3.eth.account.from_key(self.config.private_key)
        self.addresses = {
            "cz": Web3.to_checksum_address(self.config.cz_token),
            "amm": Web3.to_checksum_address(self.config.private_amm),
            "borrower": Web3.to_checksum_address(self.config.house_borrower),
            "weth": Web3.to_checksum_address(self.config.weth),
            "aave": Web3.to_checksum_address(self.config.aave_pool),
            "quoter": Web3.to_checksum_address(self.config.uniswap_quoter),
        }
        for name, address in self.addresses.items():
            if not self.w3.eth.get_code(address):
                raise RuntimeError(f"No contract code at configured {name} address")

        self.cz = self.w3.eth.contract(address=self.addresses["cz"], abi=CZ_ABI)
        self.amm = self.w3.eth.contract(address=self.addresses["amm"], abi=AMM_ABI)
        self.borrower = self.w3.eth.contract(
            address=self.addresses["borrower"], abi=BORROWER_ABI
        )
        self.aave = self.w3.eth.contract(address=self.addresses["aave"], abi=AAVE_ABI)
        self.quoter = self.w3.eth.contract(
            address=self.addresses["quoter"], abi=QUOTER_V2_ABI
        )

        owner = self.borrower.functions.owner().call()
        if owner.lower() != self.account.address.lower():
            raise RuntimeError("Configured wallet is not the HouseBorrower owner")

        self.cz_decimals = self.cz.functions.decimals().call()
        self.weth_decimals = self.w3.eth.contract(
            address=self.addresses["weth"], abi=ERC20_ABI
        ).functions.decimals().call()
        self.trade_size = _to_units(self.config.trade_size_cz, self.cz_decimals)
        self.loan_amount = _to_units(self.config.loan_amount_weth, self.weth_decimals)
        self.min_profit = _to_units(self.config.min_profit_weth, self.weth_decimals)
        self.last_execution = 0.0

    def _quote_cycle(self) -> dict[str, int]:
        reserve_cz, reserve_weth = self.amm.functions.getReserves().call()
        if reserve_cz <= 0 or reserve_weth <= 0:
            raise RuntimeError("PrivateAMM has no liquidity")
        if self.trade_size > self.borrower.functions.maxTradeSize().call():
            raise RuntimeError("Configured CZ trade exceeds the contract limit")

        sale_weth = ((reserve_weth + self.loan_amount) * self.trade_size) // (
            reserve_cz + self.trade_size
        )
        if sale_weth <= 0:
            raise RuntimeError("PrivateAMM quote is zero")

        cz_fee = self.cz.functions.flashFee(self.addresses["cz"], self.trade_size).call()
        cz_debt = self.trade_size + cz_fee
        quote = self.quoter.functions.quoteExactOutputSingle(
            (
                self.addresses["weth"],
                self.addresses["cz"],
                cz_debt,
                self.config.uniswap_fee,
                0,
            )
        ).call()
        buyback_weth = int(quote[0])
        max_weth_in = (
            buyback_weth * (10_000 + self.config.slippage_bps) + 9_999
        ) // 10_000
        if max_weth_in > self.loan_amount + sale_weth:
            raise RuntimeError("Buyback cap exceeds this cycle's WETH proceeds")

        premium_bps = self.aave.functions.FLASHLOAN_PREMIUM_TOTAL().call()
        aave_premium = (self.loan_amount * premium_bps) // 10_000
        expected_profit = sale_weth - max_weth_in - aave_premium
        return {
            "sale_weth": sale_weth,
            "buyback_weth": buyback_weth,
            "max_weth_in": max_weth_in,
            "aave_premium": aave_premium,
            "expected_profit": expected_profit,
        }

    def _build_transaction(self, quote: dict[str, int]) -> tuple[dict, int] | None:
        current_min_profit = max(
            self.min_profit, self.borrower.functions.minProfit().call()
        )
        latest_block = self.w3.eth.get_block("latest")
        base_fee = latest_block.get("baseFeePerGas") or self.w3.eth.gas_price
        try:
            priority_fee = self.w3.eth.max_priority_fee
        except Exception:
            priority_fee = self.w3.to_wei("0.1", "gwei")
        max_fee = (base_fee * 2) + priority_fee
        max_fee_limit = int(
            self.config.max_gas_price_gwei * Decimal(1_000_000_000)
        )
        if max_fee > max_fee_limit:
            logger.info("Skipping: gas fee exceeds configured cap")
            return None

        deadline = int(time.time()) + 60
        function = self.borrower.functions.executeCycle(
            self.trade_size,
            self.loan_amount,
            deadline,
            quote["max_weth_in"],
        )
        tx = function.build_transaction(
            {
                "from": self.account.address,
                "nonce": self.w3.eth.get_transaction_count(
                    self.account.address, "pending"
                ),
                "chainId": self.config.chain_id,
                "maxFeePerGas": max_fee,
                "maxPriorityFeePerGas": priority_fee,
            }
        )
        gas_estimate = self.w3.eth.estimate_gas(tx)
        tx["gas"] = (gas_estimate * 120) // 100
        gas_cost = tx["gas"] * max_fee
        net_profit = quote["expected_profit"] - gas_cost
        if net_profit < current_min_profit:
            logger.info(
                "Skipping: estimated net profit %s WETH is below threshold",
                _from_units(net_profit, self.weth_decimals),
            )
            return None

        self.w3.eth.call(tx)
        return tx, net_profit

    def run_once(self) -> None:
        if self.borrower.functions.paused().call():
            logger.warning("Borrower is paused; skipping")
            return
        if time.monotonic() - self.last_execution < self.config.cooldown_seconds:
            logger.info("Cooldown active; skipping")
            return

        quote = self._quote_cycle()
        built = self._build_transaction(quote)
        if built is None:
            return
        tx, net_profit = built

        logger.info(
            "Opportunity: sell=%s WETH buyback=%s WETH net-after-gas=%s WETH",
            _from_units(quote["sale_weth"], self.weth_decimals),
            _from_units(quote["buyback_weth"], self.weth_decimals),
            _from_units(net_profit, self.weth_decimals),
        )
        if not self.config.live_trading:
            logger.info("Dry run only; set ENABLE_LIVE_TRADING=true to broadcast")
            return

        signed = self.account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        self.last_execution = time.monotonic()
        logger.info("Transaction sent: %s", tx_hash.hex())
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
        if receipt.status != 1:
            raise RuntimeError(f"Transaction reverted: {tx_hash.hex()}")
        logger.info("Cycle confirmed in block %s", receipt.blockNumber)

    def run(self) -> None:
        logger.info(
            "Jesko bot on Arbitrum One; live trading=%s; wallet=%s",
            self.config.live_trading,
            self.account.address,
        )
        while True:
            try:
                self.run_once()
            except Exception:
                logger.exception("Cycle check failed closed; no transaction sent")
            time.sleep(self.config.cycle_interval_seconds)


if __name__ == "__main__":
    JeskoOrchestrator().run()
