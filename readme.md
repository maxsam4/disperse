# disperse

_verb_ distribute erc-20 tokens to many addresses in just two transactions

## what's in this repo

- [wagmi-disperse](wagmi-disperse): 2025 rewrite that's currently deployed to https://disperse.app
- [riot-disperse](riot-disperse): original 2018 version preserved for historical purposes and referencing
- [brownie-disperse](brownie-disperse): 2018 contract and test scripts
- [throughput-benchmark](throughput-benchmark): Foundry benchmarks for max POL & USDC transfers per 160M-gas Polygon block
- [disperse.pdf](docs/disperse.pdf): 2018 paper and research

## interface

```
disperseEther(address[] recipients, uint256[] values)
disperseToken(IERC20 token, address[] recipients, uint256[] values)
disperseTokenSimple(IERC20 token, address[] recipients, uint256[] values)
```

## optimizations

`disperseToken` first transfers the tokens to the contract addresses using `transferFrom` and then uses `transfer` to distribute them.
this reduces gas costs by 1/3 as `transfer` updates state only twice (balances) without updating allowance as `transferFrom` does.

`disperseTokenSimple` uses `transferFrom` only, use it if you prefer the transfers to come from your address.

gas usage also depends on each recipient's balance, previous zero balance being the worst case.


## caveats

tokens with missing return values are not supported for simplicity's sake. read more about this problem [here](https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca).
