# Polygon throughput benchmark

How many transfers fit in a single **160,000,000 gas** Polygon block?

This suite answers that for two assets, and pushes the number as high as
ideal lab conditions allow:

- **POL** — native value transfers
- **USDC** — ERC-20 transfers (benchmarked against a Circle FiatToken-style
  contract and, optionally, the real USDC bytecode on a Polygon fork)

## Headline results

Measured with `forge 1.7.x`, EVM `cancun`, `via_ir`, `optimizer_runs = 1e6`.
Run `./bench.sh` to reproduce.

| Asset | Strategy | Gas / transfer | **Transfers / 160M block** |
|-------|----------|---------------:|---------------------------:|
| POL   | naive EOA→fresh account (real-world airdrop floor) | 46,000 | 3,477 |
| POL   | naive EOA→existing account | 21,000 | 7,618 |
| POL   | batched → many fresh accounts | 35,077 | 4,560 |
| POL   | batched → many **distinct pre-existing** accounts | 7,740 | 20,669 |
| **POL** | **batched → single hot recipient (LAB MAX)** | **6,873** | **≈ 23,276** |
| USDC (mock) | batched → many fresh recipients (real airdrop) | 28,601 | 5,593 |
| USDC (mock) | batched → many **distinct pre-existing** holders | 6,924 | 23,104 |
| **USDC (mock)** | **batched → single hot recipient (LAB MAX)** | **3,885** | **≈ 41,178** |
| ERC-20 | minimal token, single hot recipient (theoretical floor) | 3,333 | ≈ 47,998 |

### Real USDC on a Polygon fork

Validated against Circle's actual FiatToken bytecode at
`0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359`, forked via dRPC
(`POLYGON_RPC_URL=https://polygon.drpc.org`):

| Asset | Strategy | Gas / transfer | **Transfers / 160M block** |
|-------|----------|---------------:|---------------------------:|
| **Real USDC** | batched → many **distinct pre-existing** holders | 6,759 | **≈ 23,669** |
| **Real USDC** | batched → single hot recipient (LAB MAX) | 5,890 | **≈ 27,161** |

Real USDC costs ~2,000 gas more per transfer than the minimal FiatToken mock:
its transparent-proxy `delegatecall`, packed `balanceAndBlacklistStates`
storage, and pause/blacklist SLOADs are all paid on every transfer.

> Note the counter-intuitive result: under lab conditions a **USDC transfer is
> cheaper than a POL transfer** (mock USDC, at least). A native value send is
> bounded below by the 9,000 gas `CallValueTransferGas` (≈6,700 net after the
> 2,300 stipend an EOA refunds), whereas an ERC-20 transfer to a warm,
> already-dirtied balance slot is just two 100-gas SSTOREs plus the `Transfer`
> event — no value-transfer charge at all. Real USDC (~5,890) lands close to
> native POL (~6,873) once its proxy/check overhead is included.

## Why these numbers — the optimization ladder

At maximum throughput the block is packed with as few, as large, transactions
as possible. Every **fixed** cost (the 21,000 intrinsic, the function selector,
the first cold access) is amortized to ~0, so what governs the count is the
**marginal** gas of one more transfer. Every trick below attacks a marginal cost:

1. **Batching.** One contract call performs thousands of transfers, so the
   21,000-gas intrinsic transaction cost is paid once instead of per transfer.
2. **Hot / warm addresses (EIP-2929).** A touched address costs 100 gas to
   access again instead of 2,600 cold. Reusing addresses keeps them warm.
3. **Same recipient.** Sending to one address `count` times means it is touched
   cold exactly once; every later transfer is warm. For ERC-20 it also keeps
   both balance slots **dirty**, collapsing each subsequent SSTORE to 100 gas
   (EIP-2200). And the calldata is constant — no per-recipient bytes at all.
4. **Pre-funded recipients.** A recipient that already holds a balance avoids
   native new-account creation (`CallNewAccountGas`, 25,000) and the ERC-20
   zero→nonzero SSTORE (≈20,000 vs ≈5,000 for nonzero→nonzero).
5. **Pull-once / fan-out (the classic disperse trick).** For tokens, pull the
   full total in with one `transferFrom`, then distribute with `transfer`s that
   touch only balances — no per-recipient allowance write.
6. **Calldata minimization.** Equal-amount variants put one `value` in calldata
   instead of one per recipient; the same-recipient path encodes a `count`
   instead of an address list, eliminating the 16-gas-per-nonzero-byte cost.
7. **Tight assembly loop.** The native max path loops in assembly with no
   Solidity bounds checks and no memory expansion.

The irreducible floors this exposes:

- **POL:** ~6,700 gas — there is no native opcode that moves value cheaper than
  `CallValueTransferGas` minus the refunded stipend.
- **ERC-20:** ~3,300 gas — two warm/dirty balance SSTOREs + one `Transfer` log;
  real USDC sits above this because of its paused-flag and 3× blacklist SLOADs.

## Methodology

`test/BenchBase.sol` measures the **marginal** cost directly and robustly: it
runs each batch at two sizes (`N` and `2N`) and divides the *difference* in
execution gas by `N`. Differencing cancels every fixed/one-off cost and yields
the steady-state, fully-warm per-transfer gas — exactly the quantity that fills
a block. Then:

```
transfers_per_block ≈ (160,000,000 - 21,000) / marginal_gas
```

For array-based paths the marginal calldata cost (a 32-byte word per recipient)
is added so the figure reflects real on-chain block accounting.

## Layout

```
src/BatchTransfer.sol        optimized batch primitives (native + ERC-20, incl. assembly max paths)
src/mocks/MinimalERC20.sol   cheapest compliant ERC-20 — the throughput ceiling
src/mocks/USDCLike.sol       Circle FiatToken-style token — representative of real USDC
test/NativeThroughput.t.sol  POL benchmark (optimization ladder)
test/UsdcThroughput.t.sol    USDC benchmark (optimization ladder)
test/UsdcForkThroughput.t.sol real USDC on a Polygon fork (opt-in via POLYGON_RPC_URL)
test/BenchBase.sol           shared measurement methodology
script/Report.s.sol          one-shot consolidated report
bench.sh                     runner
```

## Running

```bash
# from this directory
./bench.sh

# or directly
forge test -vv

# validate against the real USDC contract on Polygon (dRPC public endpoint)
POLYGON_RPC_URL=https://polygon.drpc.org forge test --match-contract Fork -vv
```

Foundry is required (`curl -L https://foundry.paradigm.xyz | bash && foundryup`).
`forge-std` is fetched automatically by `bench.sh` (or `forge install`).

## Caveats — lab vs. reality

These are **ceiling** numbers under ideal conditions, useful for capacity
planning and for understanding where gas goes. A production airdrop will be
slower because recipients are distinct and mostly fresh (cold access + account
creation / zero→nonzero SSTORE), which is why the "many fresh recipients" rows
are included as the realistic figures. Real USDC also carries blacklist and
pause checks. Network-level limits (calldata propagation, mempool, block-time)
are out of scope; this measures pure EVM gas.
