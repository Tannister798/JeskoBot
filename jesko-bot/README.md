# JeskoBot

JeskoBot is an experimental CZ/WETH arbitrage system for Arbitrum One. The on-chain borrower flash-mints CZ, temporarily adds Aave-borrowed WETH to `PrivateAMM`, sells CZ there, then buys back the CZ debt through a Uniswap V3 WETH/CZ exact-output swap. It repays both lenders and transfers only the cycle's net WETH profit to the owner.

## Route

- Sell venue: the project-owned `PrivateAMM` CZ/WETH pair.
- Buyback venue: Uniswap V3 WETH/CZ at the 1% fee tier (`10000`).
- The bot quotes the exact CZ repayment amount, includes the Aave flash-loan premium and estimated gas, checks a minimum-profit threshold, and simulates the transaction before broadcast.
- The bot is dry-run-only unless `ENABLE_LIVE_TRADING=true` is explicitly set.

The target Uniswap pool does not ship with this repository. CZ must be deployed on Arbitrum One and the WETH/CZ pool must be created and funded with enough liquidity before quotes or trades can succeed. The 1% tier is a starting choice for a volatile project token, not a claim that it currently has the best liquidity. Reassess pool depth and slippage after liquidity is established.

## Setup

Install Foundry and Python 3.10+, then from this directory:

```sh
forge install
forge test
forge build
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Set a newly generated wallet key and fill `CZ_TOKEN`, `PRIVATE_AMM`, and `HOUSE_BORROWER` only after deploying and verifying those contracts. Never commit `.env`. The example points to Arbitrum One (chain ID `42161`) and uses the canonical WETH, Aave V3 pool, Uniswap V3 router, and QuoterV2 addresses.

Run the monitor in dry-run mode first:

```sh
python -m bot.orchestrator
```

The monitor checks the chain ID, contract bytecode, borrower owner, pause state, trade-size cap, pool reserves, exact-output quote, Aave premium, gas cap, and simulated transaction. Missing contracts, missing pool liquidity, stale/invalid quotes, or failed simulation stop that cycle without sending a transaction.

## Deployment And Safety

`script/Deploy.s.sol` creates a mock price feed and is testnet-only; it explicitly rejects Arbitrum One. `script/DeployBorrower.s.sol` deploys a borrower against addresses supplied through the environment. It does not deploy CZ, create the Uniswap pool, or add liquidity.

This code has not been audited and is not ready for unattended mainnet trading. Before enabling live trading, deploy the production token/pools, verify the deployed bytecode and ownership, fork-test against Arbitrum One state, set conservative on-chain limits, and obtain an independent smart-contract/security review. The existing `SkewKeeper` and mock-feed path are not part of the production quote path.

See the [Foundry Book](https://book.getfoundry.sh/) for tool documentation.
