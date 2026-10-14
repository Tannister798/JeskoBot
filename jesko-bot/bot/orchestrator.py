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
    },
    {
        "inputs": [{"name": "account", "type": "address"}],
        "name": "balanceOf",
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
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
BALANCER_VAULT_ABI = [
    {
        "inputs": [],
        "name": "getProtocolFeesCollector",
        "outputs": [{"type": "address"}],
        "stateMutability": "view",
        "type": "function",
    }
]
BALANCER_FEES_ABI = [
    {
        "inputs": [],
        "name": "getFlashLoanFeePercentage",
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    }
]
UNISWAP_QUOTER_ABI = [
    {
        "inputs": [
            {
                "components": [
                    {"name": "tokenIn", "type": "address"},
                    {"name": "tokenOut", "type": "address"},
                    {"name": "amountIn", "type": "uint256"},
                    {"name": "fee", "type": "uint24"},
                    {"name": "sqrtPriceLimitX96", "type": "uint160"},
                ],
                "name": "params",
                "type": "tuple",
            }
        ],
        "name": "quoteExactInputSingle",
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
SUSHI_ROUTER_ABI = [
    {
        "inputs": [
            {"name": "amountIn", "type": "uint256"},
            {"name": "path", "type": "address[]"},
        ],
        "name": "getAmountsOut",
        "outputs": [{"name": "amounts", "type": "uint256[]"}],
        "stateMutability": "view",
        "type": "function",
    }
]
EXECUTOR_ABI = [
    {
        "inputs": [
            {"name": "lender", "type": "uint8"},
            {"name": "loanAmount", "type": "uint256"},
            {"name": "buyVenue", "type": "uint8"},
            {"name": "sellVenue", "type": "uint8"},
            {"name": "buyFee", "type": "uint24"},
            {"name": "sellFee", "type": "uint24"},
            {"name": "minUsdcOut", "type": "uint256"},
            {"name": "minWethOut", "type": "uint256"},
            {"name": "minProfit", "type": "uint256"},
            {"name": "deadline", "type": "uint256"},
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
        "name": "maxLoanAmount",
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "weth",
        "outputs": [{"type": "address"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "usdc",
        "outputs": [{"type": "address"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "aavePool",
        "outputs": [{"type": "address"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "balancerVault",
        "outputs": [{"type": "address"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "uniswapRouter",
        "outputs": [{"type": "address"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "sushiRouter",
        "outputs": [{"type": "address"}],
        "stateMutability": "view",
        "type": "function",
    },
]

UNISWAP_FEES = (100, 500, 3000, 10_000)
UNISWAP_V3 = 0
SUSHI_V2 = 1
AAVE = 0
BALANCER = 1


def to_units(value: Decimal, decimals: int) -> int:
    return int(value * (Decimal(10) ** decimals))


def from_units(value: int, decimals: int) -> Decimal:
    return Decimal(value) / (Decimal(10) ** decimals)


class JeskoOrchestrator:
    def __init__(self):
        self.config = Config.from_env()
        self.w3 = Web3(
            Web3.HTTPProvider(self.config.rpc_url, request_kwargs={"timeout": 10})
        )
        if not self.w3.is_connected():
            raise RuntimeError("Could not connect to configured RPC")
        if self.w3.eth.chain_id != self.config.chain_id:
            raise RuntimeError(
                f"Wrong chain: expected {self.config.chain_id}, got {self.w3.eth.chain_id}"
            )

        self.account = self.w3.eth.account.from_key(self.config.private_key)
        self.addresses = {
            "executor": Web3.to_checksum_address(self.config.executor),
            "weth": Web3.to_checksum_address(self.config.weth),
            "usdc": Web3.to_checksum_address(self.config.usdc),
            "aave": Web3.to_checksum_address(self.config.aave_pool),
            "aToken": Web3.to_checksum_address(self.config.aave_atoken),
            "balancer": Web3.to_checksum_address(self.config.balancer_vault),
            "quoter": Web3.to_checksum_address(self.config.uniswap_quoter),
            "sushi": Web3.to_checksum_address(self.config.sushi_router),
        }
        for name, address in self.addresses.items():
            if not self.w3.eth.get_code(address):
                raise RuntimeError(f"No deployed code at configured {name} address")

        self.weth = self.w3.eth.contract(address=self.addresses["weth"], abi=ERC20_ABI)
        self.usdc = self.w3.eth.contract(address=self.addresses["usdc"], abi=ERC20_ABI)
        self.executor = self.w3.eth.contract(
            address=self.addresses["executor"], abi=EXECUTOR_ABI
        )
        self.aave = self.w3.eth.contract(address=self.addresses["aave"], abi=AAVE_ABI)
        self.balancer = self.w3.eth.contract(
            address=self.addresses["balancer"], abi=BALANCER_VAULT_ABI
        )
        self.quoter = self.w3.eth.contract(
            address=self.addresses["quoter"], abi=UNISWAP_QUOTER_ABI
        )
        self.sushi = self.w3.eth.contract(
            address=self.addresses["sushi"], abi=SUSHI_ROUTER_ABI
        )

        self._verify_deployment()
        self.weth_decimals = self.weth.functions.decimals().call()
        self.usdc_decimals = self.usdc.functions.decimals().call()
        self.loan_amount = to_units(self.config.trade_amount_weth, self.weth_decimals)
        self.minimum_profit = to_units(self.config.min_profit_weth, self.weth_decimals)
        self.last_execution = 0.0

    def _verify_deployment(self) -> None:
        expected = {
            "weth": self.addresses["weth"],
            "usdc": self.addresses["usdc"],
            "aavePool": self.addresses["aave"],
            "balancerVault": self.addresses["balancer"],
            "uniswapRouter": "0xE592427A0AEce92De3Edee1F18E0157C05861564",
            "sushiRouter": self.addresses["sushi"],
        }
        for getter, address in expected.items():
            deployed = self.executor.functions[getter]().call()
            if deployed.lower() != address.lower():
                raise RuntimeError(f"Executor {getter} does not match configuration")

        owner = self.executor.functions.owner().call()
        if owner.lower() != self.account.address.lower():
            raise RuntimeError("Configured wallet is not the executor owner")

    def _best_lender(self) -> tuple[int, int, int] | None:
        available_aave = self.weth.functions.balanceOf(self.addresses["aToken"]).call()
        available_balancer = self.weth.functions.balanceOf(self.addresses["balancer"]).call()
        candidates = []

        if available_aave >= self.loan_amount:
            premium_bps = self.aave.functions.FLASHLOAN_PREMIUM_TOTAL().call()
            fee = (self.loan_amount * premium_bps) // 10_000
            candidates.append((AAVE, available_aave, fee))
        if available_balancer >= self.loan_amount:
            fee_collector = self.balancer.functions.getProtocolFeesCollector().call()
            fees = self.w3.eth.contract(address=fee_collector, abi=BALANCER_FEES_ABI)
            fee_percentage = fees.functions.getFlashLoanFeePercentage().call()
            fee = (self.loan_amount * fee_percentage) // 10**18
            candidates.append((BALANCER, available_balancer, fee))

        if not candidates:
            return None
        return max(candidates, key=lambda candidate: candidate[1])

    def _quote(self, venue: int, token_in: str, token_out: str, amount_in: int, fee: int) -> int:
        if venue == UNISWAP_V3:
            result = self.quoter.functions.quoteExactInputSingle(
                (token_in, token_out, amount_in, fee, 0)
            ).call()
            return int(result[0])
        path = [token_in, token_out]
        amounts = self.sushi.functions.getAmountsOut(amount_in, path).call()
        return int(amounts[-1])

    def _venue_options(self) -> list[tuple[int, int]]:
        options = [(UNISWAP_V3, fee) for fee in UNISWAP_FEES]
        options.append((SUSHI_V2, 0))
        return options

    def _best_route(self, lender_fee: int) -> dict | None:
        best = None
        options = self._venue_options()
        slippage_factor = 10_000 - self.config.slippage_bps

        for buy_venue, buy_fee in options:
            try:
                usdc_quote = self._quote(
                    buy_venue,
                    self.addresses["weth"],
                    self.addresses["usdc"],
                    self.loan_amount,
                    buy_fee,
                )
            except Exception:
                continue
            if usdc_quote <= 0:
                continue

            min_usdc_out = (usdc_quote * slippage_factor) // 10_000
            for sell_venue, sell_fee in options:
                if buy_venue == sell_venue:
                    continue
                try:
                    weth_quote = self._quote(
                        sell_venue,
                        self.addresses["usdc"],
                        self.addresses["weth"],
                        min_usdc_out,
                        sell_fee,
                    )
                except Exception:
                    continue
                min_weth_out = (weth_quote * slippage_factor) // 10_000
                gross_profit = min_weth_out - self.loan_amount - lender_fee
                if best is None or gross_profit > best["gross_profit"]:
                    best = {
                        "buy_venue": buy_venue,
                        "sell_venue": sell_venue,
                        "buy_fee": buy_fee,
                        "sell_fee": sell_fee,
                        "usdc_quote": usdc_quote,
                        "weth_quote": weth_quote,
                        "min_usdc_out": min_usdc_out,
                        "min_weth_out": min_weth_out,
                        "gross_profit": gross_profit,
                    }
        return best

    def _build_candidate(self, lender: int, lender_fee: int, route: dict) -> dict | None:
        latest_block = self.w3.eth.get_block("latest")
        base_fee = latest_block.get("baseFeePerGas") or self.w3.eth.gas_price
        try:
            priority_fee = self.w3.eth.max_priority_fee
        except Exception:
            priority_fee = self.w3.to_wei("0.1", "gwei")

        max_fee = (base_fee * 2) + priority_fee
        max_fee_limit = int(self.config.max_gas_price_gwei * Decimal(1_000_000_000))
        if max_fee > max_fee_limit:
            logger.info("Skipping: gas price is above the configured cap")
            return None

        deadline = int(time.time()) + 45
        minimum_profit = self.minimum_profit
        arguments = (
            lender,
            self.loan_amount,
            route["buy_venue"],
            route["sell_venue"],
            route["buy_fee"],
            route["sell_fee"],
            route["min_usdc_out"],
            route["min_weth_out"],
            minimum_profit,
            deadline,
        )
        tx = self.executor.functions.executeCycle(*arguments).build_transaction(
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
        try:
            gas_estimate = self.w3.eth.estimate_gas(tx)
            tx["gas"] = (gas_estimate * 120) // 100
            gas_cost = tx["gas"] * max_fee
            required_profit = self.minimum_profit + gas_cost
            tx["data"] = self.executor.functions.executeCycle(
                lender,
                self.loan_amount,
                route["buy_venue"],
                route["sell_venue"],
                route["buy_fee"],
                route["sell_fee"],
                route["min_usdc_out"],
                route["min_weth_out"],
                required_profit,
                deadline,
            )._encode_transaction_data()
            net_profit = route["gross_profit"] - gas_cost
            if net_profit < self.minimum_profit:
                return None
            self.w3.eth.call(tx)
        except Exception as error:
            logger.debug("Candidate simulation rejected: %s", error)
            return None

        return {
            "tx": tx,
            "net_profit": net_profit,
            "route": route,
            "lender": lender,
        }

    def run_once(self) -> None:
        if self.executor.functions.paused().call():
            logger.warning("Executor is paused")
            return
        if self.loan_amount > self.executor.functions.maxLoanAmount().call():
            logger.error("Configured trade exceeds the executor loan cap")
            return
        if time.monotonic() - self.last_execution < self.config.cooldown_seconds:
            logger.info("Cooldown active")
            return

        lender_choice = self._best_lender()
        if lender_choice is None:
            logger.info("No flash-loan provider has enough WETH liquidity")
            return
        lender, available_liquidity, lender_fee = lender_choice
        route = self._best_route(lender_fee)
        if route is None:
            logger.info("No cross-venue WETH/USDC route is available")
            return
        candidate = self._build_candidate(lender, lender_fee, route)
        if candidate is None:
            logger.info("Best route does not clear profit, gas, or simulation checks")
            return

        logger.info(
            "Opportunity lender=%s available=%s WETH buy=%s/%s sell=%s/%s net=%s WETH",
            "Aave" if lender == AAVE else "Balancer",
            from_units(available_liquidity, self.weth_decimals),
            "Uniswap V3" if route["buy_venue"] == UNISWAP_V3 else "Sushi V2",
            route["buy_fee"],
            "Uniswap V3" if route["sell_venue"] == UNISWAP_V3 else "Sushi V2",
            route["sell_fee"],
            from_units(candidate["net_profit"], self.weth_decimals),
        )
        if not self.config.live_trading:
            logger.info("Dry run only; set ENABLE_LIVE_TRADING=true to broadcast")
            return

        signed = self.account.sign_transaction(candidate["tx"])
        tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        self.last_execution = time.monotonic()
        logger.info("Transaction sent: %s", tx_hash.hex())
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
        if receipt.status != 1:
            raise RuntimeError(f"Transaction reverted: {tx_hash.hex()}")
        logger.info("Confirmed in block %s", receipt.blockNumber)

    def run(self) -> None:
        logger.info(
            "WETH/USDC arbitrage monitor on Arbitrum One; live=%s; wallet=%s",
            self.config.live_trading,
            self.account.address,
        )
        while True:
            try:
                self.run_once()
            except Exception:
                logger.exception("Cycle evaluation failed closed; no transaction sent")
            time.sleep(self.config.cycle_interval_seconds)


if __name__ == "__main__":
    JeskoOrchestrator().run()
