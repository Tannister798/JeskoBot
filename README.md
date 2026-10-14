# JeskoBot

The canonical Solidity contracts, bot, and environment template are in [jesko-bot/README.md](jesko-bot/README.md). The repo-root `bot/`, `script/`, and `.env.example` are legacy snapshots; do not use them for mainnet trading or deployment.

Target network: Arbitrum One (`42161`). The bot defaults to dry-run and requires an initialized, funded Uniswap V3 WETH/CZ pool before it can quote a route. The project has not been audited and must not be treated as production-safe until the deployment, liquidity, fork-test, and security-review requirements in the project README are complete.
