import time
import os
from web3 import Web3
from dotenv import load_dotenv
from config import Config

load_dotenv()

SKEW_KEEPER_ABI = [
    {
        "inputs": [],
        "name": "getCurrentSkewBps",
        "outputs": [{"name": "", "type": "int256"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "isSkewHealthy",
        "outputs": [{"name": "", "type": "bool"}],
        "stateMutability": "view",
        "type": "function"
    }
]

HOUSE_BORROWER_ABI = [
    {
        "inputs": [
            {"name": "mintAmount", "type": "uint256"},
            {"name": "loanAmount", "type": "uint256"},
            {"name": "deadline", "type": "uint256"}
        ],
        "name": "executeCycle",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function"
    }
]


class JeskoOrchestrator:
    def __init__(self):
        self.config = Config()
        self.w3 = Web3(Web3.HTTPProvider(self.config.RPC_URL))

        if not self.w3.is_connected():
            raise Exception("Failed to connect to RPC")

        print("Connected to chain ID:", self.w3.eth.chain_id)

        self.account = None
        if self.config.PRIVATE_KEY:
            self.account = self.w3.eth.account.from_key(self.config.PRIVATE_KEY)
            print("Wallet loaded:", self.account.address)

        self.last_execution = 0

        self.keeper = None
        self.borrower = None

        if self.config.SKEW_KEEPER:
            self.keeper = self.w3.eth.contract(
                address=Web3.to_checksum_address(self.config.SKEW_KEEPER),
                abi=SKEW_KEEPER_ABI
            )

        if self.config.HOUSE_BORROWER:
            self.borrower = self.w3.eth.contract(
                address=Web3.to_checksum_address(self.config.HOUSE_BORROWER),
                abi=HOUSE_BORROWER_ABI
            )

    def get_current_skew(self) -> float:
        if not self.keeper:
            print("No SkewKeeper address - using fallback 1.7%")
            return 0.017

        try:
            skew_bps = self.keeper.functions.getCurrentSkewBps().call()
            return skew_bps / 10000.0
        except Exception as e:
            print("Error reading skew:", str(e))
            return 0.0

    def is_healthy(self) -> bool:
        if not self.keeper:
            return True
        try:
            return self.keeper.functions.isSkewHealthy().call()
        except:
            return False

    def choose_parameters(self, current_skew: float):
        if current_skew < self.config.MIN_SKEW:
            print("Skew too low — skipping")
            return None
        if current_skew > self.config.MAX_SKEW:
            print("Skew too high — waiting for rebalance")
            return None

        size_factor = (current_skew - self.config.MIN_SKEW) / (self.config.MAX_SKEW - self.config.MIN_SKEW)
        mint_size_usd = 30_000 + (size_factor * (self.config.MAX_TRADE_SIZE_USD - 30_000))
        loan_size_usd = mint_size_usd * self.config.DEFAULT_LOAN_RATIO

        return {
            "mint_size_usd": 50,
            "loan_size_usd": 30,
            "skew": current_skew
        }

    def should_execute(self, params) -> bool:
        if params is None:
            return False
        if time.time() - self.last_execution < self.config.COOLDOWN_SECONDS:
            print("Cooldown active")
            return False
        return True

    def execute_cycle(self, params):
        print("\n=== Executing Cycle ===")
        print(f"Skew:        {params['skew']*100:.2f}%")
        print(f"Mint Size:   ${params['mint_size_usd']:,.0f}")
        print(f"Loan Size:   ${params['loan_size_usd']:,.0f}")

        if not self.borrower or not self.account:
            print("→ Dry-run mode (missing borrower or private key)")
            self.last_execution = time.time()
            print("=======================\n")
            return

        mint_amount = int(params["mint_size_usd"] * 1e18)
        loan_amount = int(params["loan_size_usd"] * 1e18)
        deadline = int(time.time()) + 600

        try:
            nonce = self.w3.eth.get_transaction_count(self.account.address)
            tx = self.borrower.functions.executeCycle(
                mint_amount,
                loan_amount,
                deadline
            ).build_transaction({
                "from": self.account.address,
                "nonce": nonce,
                "gas": 1_200_000,
                "maxFeePerGas": self.w3.to_wei("0.8", "gwei"),
                "maxPriorityFeePerGas": self.w3.to_wei("0.5", "gwei"),
                "chainId": self.w3.eth.chain_id,
            })

            signed = self.account.sign_transaction(tx)
            tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)
            print(f"→ Transaction sent: {tx_hash.hex()}")

            receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
            print(f"→ Status: {'Success' if receipt.status == 1 else 'Failed'}")
            self.last_execution = time.time()

        except Exception as e:
            print("→ Execution failed:", str(e))

        print("=======================\n")

    def run(self):
        print("Jesko Orchestrator started...")
        print(f"Target skew range: {self.config.MIN_SKEW*100:.1f}% – {self.config.MAX_SKEW*100:.1f}%")
        print(f"SkewKeeper loaded: {bool(self.keeper)}")
        print(f"HouseBorrower loaded: {bool(self.borrower)}")
        print(f"Wallet loaded: {bool(self.account)}")
        print("-" * 50)

        while True:
            try:
                current_skew = self.get_current_skew()
                print(f"Current skew: {current_skew*100:.2f}%")

                params = self.choose_parameters(current_skew)

                if self.should_execute(params):
                    self.execute_cycle(params)
                else:
                    print("No execution this round")

                time.sleep(25)

            except Exception as e:
                print("Error:", str(e))
                time.sleep(15)


if __name__ == "__main__":
    bot = JeskoOrchestrator()
    bot.run()
