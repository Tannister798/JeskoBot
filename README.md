# JeskoBot

The canonical Solidity contracts, bot, and environment template are in [jesko-bot/README.md](jesko-bot/README.md). The repo-root `bot/`, `script/`, and `.env.example` are legacy snapshots; do not use them for mainnet trading or deployment.

Target network: Arbitrum One (`42161`). The bot scans WETH/USDC routes across Uniswap V3 and Sushi V2 and selects between Aave and Balancer by available WETH liquidity. It defaults to dry-run and will not submit a transaction unless a simulated route clears gas, slippage, and profit limits. No profitable route was found in the latest on-chain check. The project has not been audited and is not approved for live trading until deployment, fork-testing, liquidity monitoring, and independent security review are complete.
