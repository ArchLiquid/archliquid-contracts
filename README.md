# ArchLiquid Contracts

Composed deployment and cross-module integration workspace for ArchLiquid.

> **Status:** Testnet preview. The ArchLiquid contracts have not been audited
> by an external security firm. Review the source, module pins, deployment
> configuration, and test results before interacting with any deployment.

## Module releases

Production contracts are imported from seven public modules at exact commits.
[`modules.lock.json`](modules.lock.json) records the complete commit and compiler
configuration used by this workspace.

| Module | Contracts | Pinned commit |
|---|---|---|
| [Core](https://github.com/ArchLiquid/archliquid-core) | Treasury, stock registry, constrained stock execution, exchange interfaces, and shared math | [`b1f0bec`](https://github.com/ArchLiquid/archliquid-core/commit/b1f0bec05bdee32cdcb3dfa74310f2f5476760be) |
| [Lockers](https://github.com/ArchLiquid/archliquid-lockers) | ERC-20 liquidity locks and Uniswap V3 position locks | [`a91771c`](https://github.com/ArchLiquid/archliquid-lockers/commit/a91771ca0ff37598fe79e4a01d214459bfeddb20) |
| [Token](https://github.com/ArchLiquid/archliquid-token) | Fixed-supply distribution token and token factory | [`b5cd812`](https://github.com/ArchLiquid/archliquid-token/commit/b5cd8124c39a2e46bee19f74ea8f735178a0276b) |
| [Launchpad](https://github.com/ArchLiquid/archliquid-launchpad) | Fixed-price presales, bonding curves, and launch deployers | [`73d280a`](https://github.com/ArchLiquid/archliquid-launchpad/commit/73d280aeda488ee0f9d3e4bc78f4ba78c75d2085) |
| [Vesting](https://github.com/ArchLiquid/archliquid-vesting) | Immutable cliff and linear-release schedules | [`88c3f26`](https://github.com/ArchLiquid/archliquid-vesting/commit/88c3f26a0a58faa40010e7b6c320322078658194) |
| [Staking](https://github.com/ArchLiquid/archliquid-staking) | Factory-created staking pools with funded rewards | [`8933871`](https://github.com/ArchLiquid/archliquid-staking/commit/8933871b5c4b9b8bf6fa742e8d3494645b3842ab) |
| [Lending](https://github.com/ArchLiquid/archliquid-lending) | Collateralized ERC-20 markets, Chainlink pricing, and flash loans | [`53cfa0a`](https://github.com/ArchLiquid/archliquid-lending/commit/53cfa0a1340984c6e4eee4cdd462dc140ba66410) |

This repository contains deployment composition, cross-module tests, common
test doubles, and network manifests. It does not maintain a second copy of the
production contracts.

## Dependency graph

```text
core ──> lockers ──> token ──> launchpad
  └───────────────> token ────────┘
  └───────────────────────────────┘

vesting      staking      lending
    \            |            /
     \-----------+-----------/
                 v
       composed deployment and tests
```

The integration workspace imports every module through the explicit remappings
in [`foundry.toml`](foundry.toml). No module imports this repository.

## Install and build

Clone the repository, initialize the seven direct modules and shared Foundry
dependencies, then initialize Compound inside the Lending module. Every path is
fixed to the commit recorded in `modules.lock.json`.

```bash
git clone https://github.com/ArchLiquid/archliquid-contracts.git
cd archliquid-contracts

git submodule update --init \
  lib/core lib/lockers lib/token lib/launchpad \
  lib/vesting lib/staking lib/lending \
  lib/forge-std lib/openzeppelin-contracts

git -C lib/lending submodule update --init lib/compound-protocol

forge build
forge test
forge build --sizes
```

The composed workspace does not require each module's standalone development
submodules, so a recursive checkout is unnecessary.

The default build uses Solidity 0.8.30, Paris EVM, optimizer enabled with 200
runs, and IR compilation. Paris remains the default because Robinhood Chain
testnet requires bytecode without Cancun-only opcodes.

## Integration tests

[`ArchIntegration.t.sol`](test/ArchIntegration.t.sol) composes the pinned
modules and checks:

- token creation, stock distribution, holder claims, and collateralized
  borrowing in one ecosystem flow;
- flat fees reaching the treasury;
- lending-market listing and oracle pricing; and
- a presale from creation through contribution, finalization, liquidity, and
  contributor claim.

[`ArchSafetyEdgeCases.t.sol`](test/ArchSafetyEdgeCases.t.sol) covers composed
configuration and solvency boundaries that span module ownership.

```bash
forge test --match-contract ArchIntegrationTest -vv
forge test --match-contract ArchSafetyEdgeCasesTest -vv
```

The local composed suite contains six executing tests. Five additional
Robinhood mainnet-fork checks are opt-in and return early unless
`RH_MAINNET_RPC_URL` is present.

## Robinhood mainnet fork checks

Robinhood production token bytecode uses Cancun opcodes, so the opt-in local
fork runs with an explicit Cancun EVM target:

```bash
RH_MAINNET_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
forge test --match-contract RobinhoodMainnetForkTest \
  --evm-version cancun -vv
```

The five checks validate the configured V3 periphery, the seven-field
SwapRouter02 call, constrained WETH execution, a WETH/USDG/AAPL route, and V3
pool creation plus position minting. Foundry executes them against a local fork;
the command does not broadcast a mainnet transaction.

## Deploy the protocol composition

[`DeployProtocol.s.sol`](script/DeployProtocol.s.sol) deploys the treasury, V3
locker, vesting service, stock registry and constrained executor, token factory,
launchpad, and staking factory. It requires:

- `PRIVATE_KEY`
- `PROTOCOL_MULTISIG`
- `KEEPER`
- `V3_NFPM`
- `V3_SWAP_ROUTER`
- `WETH`
- `STOCK_SWAP_AGGREGATOR`

Run the script without `--broadcast` first, inspect the complete simulation,
and independently verify every supplied address on the target chain.

```bash
forge script script/DeployProtocol.s.sol:DeployProtocol \
  --rpc-url <rpc-url>

forge script script/DeployProtocol.s.sol:DeployProtocol \
  --rpc-url <rpc-url> \
  --broadcast
```

The deployer temporarily wires the locker and stock registry, then starts their
two-step transfers to `PROTOCOL_MULTISIG`. After deployment, the multisig must
accept both ownership transfers and approve each supported stock token.

Lending deployment is provided by
[`archliquid-lending/script/DeployLending.s.sol`](https://github.com/ArchLiquid/archliquid-lending/blob/main/script/DeployLending.s.sol).

Never commit a private key or API key. Use a secure signer and secret manager
for any live deployment.

## Self-contained testnet deployment

[`DeployTestnet.s.sol`](script/DeployTestnet.s.sol) creates a complete stack with
mock WETH, V3 infrastructure, stock/USDG tokens, price feeds, and two lending
markets. It is intended for valueless testnet testing, not production use.

```bash
PRIVATE_KEY=<testnet-key> forge script \
  script/DeployTestnet.s.sol:DeployTestnet \
  --rpc-url robinhood_testnet
```

Creation fees can be overridden with `LOCKER_FEE`, `VESTING_FEE`,
`FACTORY_FEE`, `LISTING_FEE`, and `STAKING_FEE`. The defaults are the immutable
values declared by the deployment script.

The follow-up scripts exercise deployed flows:

```bash
forge script script/TestnetFlywheelCreate.s.sol:TestnetFlywheelCreate \
  --rpc-url robinhood_testnet

PROBE_TOKEN=<created-token> forge script \
  script/TestnetFlywheelFollowup.s.sol:TestnetFlywheelFollowup \
  --rpc-url robinhood_testnet

forge script script/TestnetProbe.s.sol:TestnetProbe \
  --rpc-url robinhood_testnet

forge script script/TestnetPresaleProbe.s.sol:TestnetPresaleProbe \
  --rpc-url robinhood_testnet
```

Add `--broadcast` only after a successful simulation and explicit review of the
target network, signer, fees, balances, and addresses.

## Published testnet manifest

[`deployments/robinhood-testnet.json`](deployments/robinhood-testnet.json)
records the Robinhood Chain testnet release, roles, deployed addresses, fee and
risk settings, markets, oracle feeds, and the block used for the recorded state
checks. It describes a valueless mock testnet deployment and must not be treated
as a mainnet address list.

[`deployments/robinhood-testnet.approval.json`](deployments/robinhood-testnet.approval.json)
contains the release identifier, canonical manifest digest, signer, and EIP-191
signature for that exact manifest. Changing the manifest invalidates the
approval and requires a new signature from the declared release approver.

## Updating a module

When a module changes, update all three references together:

1. the module's Git submodule commit;
2. its full commit in `modules.lock.json`; and
3. the module table in this README.

Then run the composed build, tests, and size report. If an API, invariant,
deployment value, or security assumption changed, update the affected module
guide and this integration guide in the same change.

## Security

Read [SECURITY.md](SECURITY.md) before reporting a vulnerability. Use GitHub's
private vulnerability reporting flow; do not publish exploit details in an
issue.

## License

Copyright (c) 2026 ArchLiquid. This repository is public source, not open
source. No permission to use, copy, modify, compile, deploy, or distribute the
first-party materials is granted without prior written approval. See
[LICENSE](LICENSE). Files marked `LicenseRef-ArchLiquid-Proprietary` are
governed by that license. Compound-derived and third-party files retain their
respective license identifiers and terms.
