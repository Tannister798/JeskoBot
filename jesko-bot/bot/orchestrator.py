import logging
import time

from web3 import Web3

from .config import Config

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("jeskobot")

HOUSE_BORROWER_ABI = [
    {
        "inputs": [
            {"name": "mintAmount", "type": "uint256"},
            {"name": "loanAmount", "type": "uint256"},
            {"name": "minUsdcOut", "type": "uint256"},
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
]

SKEW_KEEPER_ABI = [
    {
        "inputs": [],
        "name": "isSkewHealthy",
        "outputs": [{"type": "bool"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "getCurrentSkewBps",
        "outputs": [{"type": "int256"}],
        "stateMutability": "view",
        "type": "function",
    },
]


class JeskoOrchestrator:
    def __init__(self):
        self.config = Config.from_env()
        self.w3 = Web3(
            Web3.HTTPProvider(self.config.rpc_url, request_kwargs={"timeout": 20})
        )
        if not self.w3.is_connected():
            raise RuntimeError("RPC not connected")
        if self.w3.eth.chain_id != self.config.chain_id:
            raise RuntimeError(
                f"Wrong chain: expected {self.config.chain_id}, got {self.w3.eth.chain_id}"
            )

        self.account = self.w3.eth.account.from_key(self.config.private_key)

        self.borrower = self.w3.eth.contract(
            address=Web3.to_checksum_address(self.config.house_borrower),
            abi=HOUSE_BORROWER_ABI,
        )
        self.keeper = self.w3.eth.contract(
            address=Web3.to_checksum_address(self.config.skew_keeper),
            abi=SKEW_KEEPER_ABI,
        )

        for name, addr in {
            "HOUSE_BORROWER": self.config.house_borrower,
            "SKEW_KEEPER": self.config.skew_keeper,
            "PRIVATE_AMM": self.config.private_amm,
            "CZ_TOKEN": self.config.cz_token,
        }.items():
            if not self.w3.eth.get_code(Web3.to_checksum_address(addr)):
                raise RuntimeError(f"No code at {name}")

        owner = self.borrower.functions.owner().call()
        if owner.lower() != self.account.address.lower():
            raise RuntimeError("Wallet is not HouseBorrower owner")

        self.last_execution = 0.0
        logger.info("Jesko private-AMM orchestrator ready")
        logger.info("Wallet: %s", self.account.address)
        logger.info("Live trading: %s", self.config.live_trading)

    def try_cycle(self) -> None:
        if self.borrower.functions.paused().call():
            logger.info("Borrower paused — skip")
            return

        try:
            healthy = self.keeper.functions.isSkewHealthy().call()
            skew = self.keeper.functions.getCurrentSkewBps().call()
        except Exception as e:
            logger.warning("Skew read failed (need liquidity + price): %s", e)
            return

        logger.info("Skew bps: %s healthy=%s", skew, healthy)
        if not healthy:
            logger.info("Skew unhealthy — skip")
            return

        now = time.time()
        if now - self.last_execution < self.config.cooldown_seconds:
            logger.info("Cooldown active — skip")
            return

        deadline = int(time.time()) + 60
        tx = self.borrower.functions.executeCycle(
            self.config.mint_amount,
            self.config.loan_amount,
            self.config.min_usdc_out,
            deadline,
        ).build_transaction(
            {
                "from": self.account.address,
                "nonce": self.w3.eth.get_transaction_count(self.account.address),
                "chainId": self.config.chain_id,
            }
        )

        try:
            gas = self.w3.eth.estimate_gas(tx)
            tx["gas"] = int(gas * 1.2)
        except Exception as e:
            logger.error("Gas estimate / simulation failed: %s", e)
            return

        base = self.w3.eth.get_block("latest").get("baseFeePerGas") or self.w3.eth.gas_price
        tx["maxFeePerGas"] = int(base * 2)
        tx["maxPriorityFeePerGas"] = self.w3.to_wei("0.01", "gwei")

        if not self.config.live_trading:
            try:
                self.w3.eth.call(
                    {
                        "to": tx["to"],
                        "from": tx["from"],
                        "data": tx["data"],
                    }
                )
                logger.info(
                    "Dry-run OK | mint=%s loan=%s",
                    self.config.mint_amount,
                    self.config.loan_amount,
                )
            except Exception as e:
                logger.error("Dry-run revert: %s", e)
            return

        signed = self.account.sign_transaction(tx)
        raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction
        tx_hash = self.w3.eth.send_raw_transaction(raw)
        logger.info("Submitted: %s", tx_hash.hex())
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=180)
        logger.info("Status: %s gasUsed=%s", receipt.status, receipt.gasUsed)
        self.last_execution = time.time()

    def run(self) -> None:
        logger.info("Loop started")
        while True:
            try:
                self.try_cycle()
            except Exception as e:
                logger.exception("Cycle error: %s", e)
            time.sleep(self.config.cycle_interval_seconds)


if __name__ == "__main__":
    JeskoOrchestrator().run()