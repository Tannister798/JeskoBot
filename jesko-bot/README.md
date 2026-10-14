# JeskoBot

JeskoBot is an experimental WETH/USDC cross-venue arbitrage monitor for Arbitrum One. CZ is not part of the trading strategy.

## Strategy

The bot compares WETH-to-USDC-to-WETH routes across Uniswap V3 fee tiers and Sushi V2. It checks Aave V3 and Balancer Vault WETH liquidity, selecting the provider with the most available WETH that can fund the configured trade. The executor performs both swaps atomically, repays the selected lender, and transfers only profit above the starting WETH balance to its owner.

Before a transaction is sent, the bot accounts for the lender fee, quote slippage, gas cost, minimum-profit requirement, executor loan cap, and live contract state. It simulates the transaction. Live sending is disabled unless `ENABLE_LIVE_TRADING=true` is explicitly set.

## Current Market Read

The configured Arbitrum WETH/native-USDC pools exist, but the sampled Uniswap V3 round trips lost money before gas, and the Sushi V2 pool was shallow. No profitable route was observed. The bot should report no opportunity and send nothing until live quotes show a positive net return. Pool liquidity and prices change; do not treat this snapshot as a persistent market assessment.

## Setup

Install Foundry and Python 3.10+, then from this directory:

```sh
forge test
forge build
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Set a new, uncompromised wallet key. Deploy the executor with reviewed Arbitrum One addresses, then set `ARBITRAGE_EXECUTOR` in `.env`. Never commit `.env`.

```sh
forge script script/DeployWethUsdcArbitrage.s.sol:DeployWethUsdcArbitrage --rpc-url "$RPC_URL" --broadcast
python -m bot.orchestrator
```

The deployment script creates the executor only. It does not provide liquidity, fund the flash-loan providers, or guarantee an arbitrage opportunity. The bot checks chain ID, code at all configured addresses, executor ownership and immutable configuration, lender capacity, pool quotes, gas, and simulation; errors fail closed.

## Production Gate

The project has not been audited and is not approved for unattended mainnet trading. Keep live trading disabled until the deployed executor is independently reviewed, the route selection is validated against mainnet forks, slippage and gas limits are tested under adverse conditions, and a monitored operational key/pausing process is established. The old CZ, `PrivateAMM`, `SkewKeeper`, and `HouseBorrower` contracts and their deployment scripts are experimental legacy code, not used by the WETH/USDC bot.

See the [Foundry Book](https://book.getfoundry.sh/) for tool documentation.
