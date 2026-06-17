#!/usr/bin/env bash
# Polygon throughput benchmark runner.
#
# Establishes the maximum number of POL (native) and USDC (ERC-20) transfers
# that fit in a 160,000,000 gas block under ideal lab conditions.
#
# Usage:
#   ./bench.sh                 # run the local (mocked) benchmarks
#   POLYGON_RPC_URL=... ./bench.sh   # also validate against real USDC on Polygon
set -euo pipefail

cd "$(dirname "$0")"

# Install forge-std if it isn't vendored yet (lib/ is git-ignored).
if [ ! -d lib/forge-std ]; then
  echo ">> installing forge-std..."
  git clone --depth 1 https://github.com/foundry-rs/forge-std lib/forge-std
fi

echo ">> building..."
forge build >/dev/null

echo ">> running POL (native) throughput benchmark..."
forge test --match-contract NativeThroughput -vv

echo ">> running USDC (ERC-20) throughput benchmark..."
forge test --match-contract 'UsdcThroughput' -vv

# Real USDC on a Polygon fork. Defaults to dRPC's public endpoint; override with
# POLYGON_RPC_URL, or set RUN_FORK=0 to skip (the fork run takes ~1-2 minutes).
if [ "${RUN_FORK:-1}" = "1" ]; then
  export POLYGON_RPC_URL="${POLYGON_RPC_URL:-https://polygon.drpc.org}"
  echo ">> running real-USDC Polygon fork benchmark via ${POLYGON_RPC_URL}..."
  forge test --match-contract UsdcForkThroughput -vv
else
  echo ">> (RUN_FORK=0; skipping the real-USDC Polygon fork benchmark)"
fi
