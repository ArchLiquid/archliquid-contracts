# ArchLiquid Contracts

Composed deployment and cross-module integration workspace for ArchLiquid.

> **Status:** Live on Robinhood Chain testnet. Testnet assets have no monetary
> value. Review the contract, network, and transaction details before signing.

## Module releases

First-party contracts are imported from seven public modules at exact commits.
[`modules.lock.json`](modules.lock.json) records the complete commit and compiler
configuration used by this workspace.

| Module | Contracts | Pinned commit |
|---|---|---|
| [Core](https://github.com/ArchLiquid/archliquid-core) | Treasury, stock registry, constrained stock execution, exchange interfaces, and shared math | [`b1f0bec`](https://github.com/ArchLiquid/archliquid-core/commit/b1f0bec05bdee32cdcb3dfa74310f2f5476760be) |
| [Lockers](https://github.com/ArchLiquid/archliquid-lockers) | Canonical Uniswap V2 LP locks and dedicated Uniswap V3/V4 position locks | [`f47efd0`](https://github.com/ArchLiquid/archliquid-lockers/commit/f47efd092c263d1d185a777079413119b546b4ac) |
| [Token](https://github.com/ArchLiquid/archliquid-token) | Fixed-supply distribution token, one-time deferred market wiring, and token factory | [`e2413e9`](https://github.com/ArchLiquid/archliquid-token/commit/e2413e9e1fdc86d93cf4544b2e7fa6adcd9976f1) |
| [Launchpad](https://github.com/ArchLiquid/archliquid-launchpad) | V3/V4 launches, AMM adapters, and immutable V4 user-liquidity provisioning | [`9941b1c`](https://github.com/ArchLiquid/archliquid-launchpad/commit/9941b1ceae0ee33700dec01fe5abc2817a772c5a) |
| [Vesting](https://github.com/ArchLiquid/archliquid-vesting) | Immutable cliff and linear-release schedules | [`88c3f26`](https://github.com/ArchLiquid/archliquid-vesting/commit/88c3f26a0a58faa40010e7b6c320322078658194) |
| [Staking](https://github.com/ArchLiquid/archliquid-staking) | Factory-created staking pools with funded rewards | [`8933871`](https://github.com/ArchLiquid/archliquid-staking/commit/8933871b5c4b9b8bf6fa742e8d3494645b3842ab) |
| [Lending](https://github.com/ArchLiquid/archliquid-lending) | Timestamp-native collateralized ERC-20 markets, burn-before-list activation, bounded Chainlink liquidation pricing, and flash loans | [`5e3272d`](https://github.com/ArchLiquid/archliquid-lending/commit/5e3272d0bdf0299199cf288a24dcb5d39fa9f9ab) |

This repository contains deployment composition, cross-module tests, common
test doubles, and network manifests. It does not maintain a second copy of the
first-party contracts.

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

The default build uses Solidity 0.8.30, Cancun EVM, optimizer enabled with 200
runs, and IR compilation. The exact settings are recorded in
[`modules.lock.json`](modules.lock.json).

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

[`ArchMinedV4UserLiquidityFork.t.sol`](test/ArchMinedV4UserLiquidityFork.t.sol)
reconciles the exact active V4 user-liquidity contracts against the signed
release manifest. It verifies immutable dependencies, frozen launch bindings,
the atomic canary positions, custody, and zero-residue guarantees.

```bash
forge test --match-contract ArchIntegrationTest -vv
forge test --match-contract ArchSafetyEdgeCasesTest -vv
forge test --match-contract ArchMinedV4UserLiquidityForkTest \
  --fork-url https://rpc.testnet.chain.robinhood.com -vv
```

The local composed suite also compiles the current V3 and V4 launch modules.
Fork checks return early unless their respective RPC environment variable is
present, so the explicit commands below are required for live-chain coverage.

## Robinhood mainnet fork checks

Robinhood production token bytecode uses Cancun opcodes, so the opt-in local
fork runs with an explicit Cancun EVM target:

```bash
RH_MAINNET_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
forge test --match-contract RobinhoodMainnetForkTest \
  --evm-version cancun -vv
```

The eight checks validate the configured V3 periphery, the seven-field
SwapRouter02 call, constrained WETH execution, a WETH/USDG/AAPL route, V3 pool
creation plus position minting, the live V2 WETH/USDG pair, canonical V2 LP
custody, and the V4 periphery with a currently live position. Foundry executes
them against a local fork; the command does not broadcast a mainnet
transaction.

The V4 testnet suite records the expected manager code hashes, confirms that
the official mainnet V2 addresses have no testnet code, and exercises the
dedicated V4 locker against a compatible live position:

```bash
RH_TESTNET_RPC_URL=https://rpc.testnet.chain.robinhood.com \
forge test --match-contract RobinhoodTestnetV4ForkTest \
  --evm-version cancun -vv
```

The V4 PositionManager used by the testnet release differs from Robinhood
mainnet bytecode. Its exact address and runtime code hash are pinned in the
signed module manifest.

## Deploy the protocol composition

[`DeployProtocol.s.sol`](script/DeployProtocol.s.sol) deploys the treasury,
V2/V3/V4 lockers, vesting service, stock registry and constrained executor,
token factory, launchpad, and staking factory. It requires:

- `PRIVATE_KEY`
- `PROTOCOL_MULTISIG`
- `KEEPER`
- `V2_FACTORY`
- `V3_NFPM`
- `V3_SWAP_ROUTER`
- `V4_POSITION_MANAGER`
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

The deployer temporarily wires the V3 locker and stock registry, then starts
two-step ownership transfers for all three lockers and the registry to
`PROTOCOL_MULTISIG`. After deployment, the multisig must accept those
transfers and approve each supported stock token.

Lending deployment is provided by
[`archliquid-lending/script/DeployLending.s.sol`](https://github.com/ArchLiquid/archliquid-lending/blob/main/script/DeployLending.s.sol).
Markets must configure both oracle freshness windows, permanently burn the
minimum activation seed, and set finite supply and borrow caps before enabling
collateral. The lending module guide documents the required ordering.

Never commit a private key or API key. Use a secure signer and secret manager
for any live deployment.

## Self-contained testnet deployment

[`DeployTestnet.s.sol`](script/DeployTestnet.s.sol) creates a complete stack
with mock WETH, V2/V3/V4 infrastructure, discoverable liquidity positions,
stock/USDG tokens, price feeds, and two lending markets. It is intended for
valueless testnet testing, not production use.

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

[`deployments/robinhood-testnet.source-inventory.json`](deployments/robinhood-testnet.source-inventory.json)
lists the additional exact-address contracts that belong to the same source
publication gate, including superseded implementations retained for historical
inspection.

Release `robinhood-testnet-2026-08-14-r8` keeps the r7 lending proxy, oracle,
rate model, and cToken market addresses while upgrading only the Comptroller
implementation:

| Lending component | Address |
|---|---|
| Comptroller proxy | `0x2534E25536d31730db6C8fd16060898f9B3275B6` |
| Comptroller implementation | `0x0bcc334C558556740BcF33b10c4DCa621b84C795` |
| Price oracle | `0x787eD40B4c4c195C4C76558C8865A13722A99eC9` |
| Per-second rate model | `0x6cdc22E79b0fbB5280bbC9AbCDe1Ce93bA955433` |
| arUSDG | `0x9797bd68F8F80EAD20f679263fA4e33051F5E8Fa` |
| arNVDAx | `0x943132B8Bf830b7Fbf89E7eB23B2075140663dd4` |

Earlier V2 testnet launch releases are retired and are not part of the current
supported release surface. Their immutable on-chain contracts and already
published source remain inspectable through Sourcify.

[`deployments/robinhood-testnet-v4-user-liquidity.json`](deployments/robinhood-testnet-v4-user-liquidity.json)
records the additive V4 user-liquidity release and its atomic two-position
canary. All seven creation and runtime bytecodes are exact-verified on
Sourcify, and the live manifest is bound to the authorized release signer by
[`deployments/robinhood-testnet-v4-user-liquidity.approval.json`](deployments/robinhood-testnet-v4-user-liquidity.approval.json).
The exact publication evidence is retained in
[`docs/audit-evidence/robinhood-testnet-v4-user-liquidity-r1-sourcify.json`](docs/audit-evidence/robinhood-testnet-v4-user-liquidity-r1-sourcify.json).

| V4 user-liquidity component | Address |
|---|---|
| V4 liquidity adapter | `0x7694D631107fea145d872A6003f40a2021F99343` |
| V4 user-liquidity provisioner | `0xba8cB9EE1Ea1126535C22d13805ec5cC22613775` |
| Token factory | `0x897cd8ac993184d6dd3B549A5FbEc04f697C107c` |
| Presale deployer | `0x873d07CD525F447BaC22607c6f535347e354f333` |
| Bonding-curve deployer | `0x62FF5dB0062c39B6bc555CD745b1B4E1729f361F` |
| Launchpad | `0x45f7497ff12De39924905d9820A2E1CC60707302` |
| Token deployment library | `0xaeea5fFc86f98E9023D1e1C9a0EFFc9ce973CEC4` |

The live-fork reconciliation suite is:

```bash
forge test --match-contract ArchMinedV4UserLiquidityForkTest \
  --fork-url https://rpc.testnet.chain.robinhood.com -vv
```

[`deployments/robinhood-testnet-uniswap-v3-release.json`](deployments/robinhood-testnet-uniswap-v3-release.json)
records the canonical-bytecode Uniswap V3 testnet stack and six funded
stock/WETH pools. All 12 stack contracts are publicly source-verified on
Sourcify and visible in Robinhood Blockscout. Independent release evidence
proves exact pinned-package creation and runtime bytecode parity for every
address. Sourcify classifies two contracts as `exact_match` and ten as
`match`; both classifications are verified, while `exact_match` additionally
reproduces compiler auxdata byte-for-byte.

| Canonical V3 component | Address |
|---|---|
| Factory | `0xe138C58a8f5FB97A52bf17966Ad1c68bD4B52979` |
| Position manager | `0xD1e800aD30B2249977921ce5aFb8d69f773590Ec` |
| Quoter V2 | `0xF209bBacF31420D668d092614168318AF65A657b` |
| SwapRouter02 | `0xF3545700dbc70B8b3962FAf08039BdA2664b71C9` |

The source-publication evidence is retained in
[`docs/audit-evidence/robinhood-testnet-canonical-uniswap-v3-r1-source-publication.json`](docs/audit-evidence/robinhood-testnet-canonical-uniswap-v3-r1-source-publication.json).

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
