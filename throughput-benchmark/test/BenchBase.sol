// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";

/// @notice Shared methodology helpers for the throughput benchmarks.
///
/// Methodology
/// -----------
/// "Max transfers per block" is governed by the *marginal* gas of one more
/// transfer once a batch is already running, because at maximum throughput the
/// block is packed with as few (large) transactions as possible, so every fixed
/// cost (the 21,000 intrinsic, the function selector, the first cold SLOAD/CALL)
/// is amortized to ~0 across thousands of transfers.
///
/// We measure that marginal cost directly and robustly: run the same batch at
/// two sizes (N and 2N) and divide the *difference* in execution gas by N. The
/// difference cancels every fixed/one-off cost and isolates the steady-state,
/// fully-warm per-transfer gas — exactly the quantity that fills a block.
///
///   transfers_per_block ≈ (BLOCK_GAS_LIMIT - INTRINSIC) / marginal_gas
///
/// For paths whose calldata grows with the batch (the array variants) we add the
/// marginal calldata cost so the figure reflects real on-chain block accounting.
abstract contract BenchBase is Test {
    /// Polygon block gas target used for this study.
    uint256 internal constant BLOCK_GAS_LIMIT = 160_000_000;

    /// Intrinsic cost paid once per transaction.
    uint256 internal constant INTRINSIC = 21_000;

    /// Calldata pricing (post EIP-2028).
    uint256 internal constant CALLDATA_NONZERO = 16;
    uint256 internal constant CALLDATA_ZERO = 4;

    /// Sizes used for the two-point marginal measurement.
    uint256 internal constant N1 = 2_000;
    uint256 internal constant N2 = 4_000;

    struct Result {
        string label;
        uint256 marginalGas; // gas per additional transfer at steady state
        uint256 perBlock; // transfers that fit in BLOCK_GAS_LIMIT
    }

    Result[] internal results;

    function _record(string memory label, uint256 marginalGas) internal returns (uint256 perBlock) {
        perBlock = marginalGas == 0 ? 0 : (BLOCK_GAS_LIMIT - INTRINSIC) / marginalGas;
        results.push(Result({label: label, marginalGas: marginalGas, perBlock: perBlock}));
        console2.log("%s", label);
        console2.log("    gas / transfer : %s", marginalGas);
        console2.log("    transfers/block: %s", perBlock);
    }

    /// @dev ABI calldata cost of one extra recipient encoded as a 32-byte word
    ///      holding a 20-byte address (12 leading zero bytes + 20 nonzero bytes).
    ///      A conservative upper bound assuming all address bytes are nonzero.
    function _addressWordCalldata() internal pure returns (uint256) {
        return 12 * CALLDATA_ZERO + 20 * CALLDATA_NONZERO; // 368
    }

    function _printHeader(string memory title) internal pure {
        console2.log("");
        console2.log("==================================================================");
        console2.log(" %s", title);
        console2.log(" block gas limit: 160,000,000");
        console2.log("==================================================================");
    }
}
