# Aerodrome Auto-Balance

`AerodromeRebalancer` is a [**Gnosis Safe module**](https://docs.safe.global/advanced/smart-account-modules) for **Base**. It centers an **Aerodrome SlipStream** concentrated liquidity position on the pool's current tick by withdrawing liquidity, swapping as needed, minting a new position with the **same tick width**, and enforcing TWAP deviation, slippage, deadline, and LP-principal value-floor checks. `rebalance(deadline)` is callable by the Safe and Safe-allowlisted keepers; configuring the Safe, enabling the module, and setting strategy parameters stays with Safe owners.

For the bundled tick-spacing-10 deployment target, one-leg rebalance swaps route through Aerodrome's Universal Router using the pool-family selector for the WETH/cbBTC factory. The module transfers the exact input amount to the router for each swap, avoiding Permit2 and leaving no persistent Safe token approvals behind.

The bundled deploy script targets the **Base mainnet WETH/cbBTC** SlipStream **tick-spacing-10** pool and its gauge/router addresses wired in [`script/DeployAerodromeRebalancer.s.sol`](script/DeployAerodromeRebalancer.s.sol).

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`)
- Solidity **0.8.28** and **via IR** enabled (already set in `foundry.toml`)
- Optional: a Base mainnet RPC URL for deployment and fork tests

## Clone and install dependencies

This project uses Foundry remappings for `forge-std`, OpenZeppelin, and Safe contracts. If `lib/` is missing (it is listed in `.gitignore` in this repo), install dependencies from the repository root:

```bash
forge install foundry-rs/forge-std --no-commit
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge install safe-global/safe-smart-account --no-commit
```

Build:

```bash
forge build
```

## Environment variables

Copy the example env file and fill in values:

```bash
cp .env.example .env
```

| Variable | Purpose |
|----------|---------|
| `BASE_RPC_URL` | Base RPC (e.g. `https://mainnet.base.org` or your provider) |
| `BASESCAN_API_KEY` | Optional—verification / explorer tooling if you use it |
| `SAFE_ADDRESS` | The Gnosis Safe that will own positions and enable this module; read by [`DeployAerodromeRebalancer.s.sol`](script/DeployAerodromeRebalancer.s.sol) via `vm.envAddress` |
| `KEEPER_ADDRESSES` | Optional comma-separated keeper addresses to allowlist at deployment |

Never commit `.env`. With Foundry’s default behavior, **`forge script` loads `.env` from the repo root** when present, so `SAFE_ADDRESS` and `BASE_RPC_URL` are picked up automatically for the commands below—you can still override with `export` or inline flags.

**Do not store the deployer private key in `.env` for this workflow.** Supply it only through a CLI wallet flag (next section).

## Tests

Unit tests (mocks, no RPC):

```bash
forge test
```

Fork tests ([`test/AerodromeRebalancer.fork.t.sol`](test/AerodromeRebalancer.fork.t.sol)) exercise Base mainnet state. They **skip** if `BASE_RPC_URL` is unset or the fork fails:

```bash
export BASE_RPC_URL=https://mainnet.base.org
forge test --match-contract AerodromeRebalancerForkTest
```

## Deploy the module

From the repo root: put **`SAFE_ADDRESS`** (and usually **`BASE_RPC_URL`**) in `.env`—there is **no `DEPLOYER_PRIVATE_KEY` (or any deploy key) in `.env`** for this project. The deployer identity is passed only when you run `forge script`, via a wallet flag below.

Deployer **pays gas** and sends the contract creation transaction; the **module’s `SAFE` immutable** is set from `SAFE_ADDRESS`. The deploy account does not need to be a Safe signer, but it must be funded with Base ETH for `--broadcast`.

| Input | Where it comes from |
|-------|---------------------|
| `SAFE_ADDRESS` | `.env` (or shell), read inside the script |
| `KEEPER_ADDRESSES` | Optional `.env` or shell value; comma-separated addresses allowlisted as initial keepers in the constructor |
| `BASE_RPC_URL` | `.env` or `--rpc-url` |
| `BASESCAN_API_KEY` | `.env` or shell, used by Foundry when `--verify` is passed |
| Deployer signing key | **CLI only**—[`--private-key`](https://book.getfoundry.sh/reference/forge/forge-script#wallet-options), [`--keystore`](https://book.getfoundry.sh/reference/forge/forge-script#wallet-options), [`--ledger`](https://book.getfoundry.sh/reference/forge/forge-script#wallet-options), [`--interactive`](https://book.getfoundry.sh/reference/forge/forge-script#wallet-options), etc.—not from `.env` |

**Simulate locally** (dry run—no transactions sent on-chain). No wallet flags are required; Forge estimates gas only.

```bash
forge script script/DeployAerodromeRebalancer.s.sol:DeployAerodromeRebalancer \
  --rpc-url "$BASE_RPC_URL"
```

**Broadcast to Base** (deploy for real). **`--broadcast` requires a signer** (`--private-key`, keystore, hardware wallet, etc.). Typical pattern: define a **shell-only** variable for the session (not in `.env`), then pass it into Foundry:

```bash
# Use a throwaway shell variable; never commit this line or add it to `.env`.
DEPLOY_PK='<hex_private_key>'

forge script script/DeployAerodromeRebalancer.s.sol:DeployAerodromeRebalancer \
  --rpc-url "$BASE_RPC_URL" \
  --broadcast \
  --verify \
  --private-key "$DEPLOY_PK"
```

To pass initial keepers as a direct script parameter instead of `KEEPER_ADDRESSES`, call the overloaded script entrypoint:

```bash
forge script script/DeployAerodromeRebalancer.s.sol:DeployAerodromeRebalancer \
  --sig "run(address[])" \
  "[$KEEPER_1,$KEEPER_2]" \
  --rpc-url "$BASE_RPC_URL" \
  --broadcast \
  --verify \
  --private-key "$DEPLOY_PK"
```

The `--verify` flag uses the `base` explorer configuration in [`foundry.toml`](foundry.toml) and the `BASESCAN_API_KEY` environment variable. You can instead pass `--private-key <hex_private_key>` inline, or use `--keystore`, `--ledger`, `--interactive`, etc.—see [`forge script` wallet options](https://book.getfoundry.sh/reference/forge/forge-script#wallet-options). Raw keys can end up in **shell history** and process listings; keystores or hardware wallets are safer when you can use them.

On success, `forge script` prints the deployed contract address and writes run artifacts under `broadcast/` (ignored by git). The script also **logs** the module address, configured Safe, and initial keepers when `KEEPER_ADDRESSES` is set or direct keepers are passed.

### Enable on the Safe (required)

After deployment, **Safe owners** must:

1. **Enable the module** – e.g. `Safe.enableModule(<deployed AerodromeRebalancer address>)` via Safe UI or a transaction you craft.
2. **Register the position NFT** – the module tracks one staked SlipStream NFT at a time. From the Safe, call `setCurrentTokenId(tokenId)` on the deployed contract. Preconditions on-chain enforce that:
   - the NFT matches this pool’s `token0` / `token1` and tick spacing;
   - liquidity is non-zero;
   - the NFT is **staked in the gauge** for this Safe (`NotStaked` reverts otherwise).

Liquidity withdrawals and swaps are executed **through the Safe** via `execTransactionFromModuleReturnData`; the Safe must hold approvals as required by NPM, router, and gauge flows for your setup.

### Optional configuration (Safe-only calls)

Configurable via Safe-originated transactions on the module (see [`src/AerodromeRebalancer.sol`](src/AerodromeRebalancer.sol)):

- `setKeeper(keeper, allowed)` – allow bots or EOAs to call `rebalance(deadline)` (Safe can always call it). Initial keepers can also be configured at deploy time with `KEEPER_ADDRESSES`.
- `setTwapWindow`, `setMaxTickDeviation`, `setMaxSlippageBps`, `setMaxRebalanceLossBps`
- `pause` / `unpause`

Anyone can call **`previewRebalance()`** view to see whether `rebalance(deadline)` would succeed and why not. Keepers should pass a near-term deadline, for example `block.timestamp + 5 minutes`, so stale queued transactions fail instead of executing later.

### Other pools / networks

[`DeployAerodromeRebalancer.s.sol`](script/DeployAerodromeRebalancer.s.sol) is hard-coded for the Base WETH/cbBTC tick-spacing-10 pool, gauge, position manager, and Universal Router. Deploying against another SlipStream deployment requires deploying with your own constructor parameters (`pool`, `gauge`, `npm`, `swapRouter`, and risk parameters)—for example via a script you derive from that file or directly in Solidity. Always use a swap router from the same SlipStream deployment/factory as the target pool.

## Using this codebase in another Foundry project

Treat it as a normal dependency:

```bash
forge install <your-git-remote>/aerodrome-auto-balance --no-commit
```

Add remappings that match this repo’s `foundry.toml` (paths under `lib/aerodrome-auto-balance/...` depend on the install path), then import `AerodromeRebalancer` from the installed `src` path.

## License

SPDX-License-Identifier: MIT (see contract headers).
