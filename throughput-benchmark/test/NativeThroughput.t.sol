// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BenchBase} from "./BenchBase.sol";
import {console2} from "forge-std/Test.sol";
import {BatchTransfer} from "../src/BatchTransfer.sol";

/// @notice Max POL (native) transfers in a 160M gas block.
///
/// Optimization ladder (each rung strictly faster than the last):
///   0. naive EOA -> fresh empty account  (real-world airdrop worst case)
///   1. naive EOA -> existing account     (no 25k new-account charge)
///   2. batched -> many fresh accounts    (amortize 21k, but pay 25k each)
///   3. batched -> many warm pre-funded accounts
///   4. batched -> single hot pre-funded recipient  (LAB MAXIMUM)
///
/// The irreducible floor for a value-bearing CALL to an EOA is ~6,700 gas:
/// 9,000 CallValueTransferGas minus the 2,300 stipend that is forwarded to the
/// callee and refunded to the caller when (as for a plain EOA) it goes unused,
/// plus the 100 gas warm-access charge. There is no native opcode that moves
/// value for less.
contract NativeThroughput is BenchBase {
    BatchTransfer internal batch;
    uint256 internal constant VALUE = 1; // 1 wei: minimum nonzero transfer

    address payable internal hot = payable(address(uint160(0xA0701)));

    function setUp() public {
        batch = new BatchTransfer();
        // Fund the contract generously for the largest batch we run.
        vm.deal(address(batch), 1_000 ether);
        // The hot recipient is pre-funded so it is never an "empty" account.
        vm.deal(hot, 1 ether);
    }

    // --- helpers -------------------------------------------------------------

    function _measureSame(uint256 count) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        batch.disperseEtherSame(hot, VALUE, count);
        used = g0 - gasleft();
    }

    uint256 internal saltNonce;

    function _measureManyFresh(uint256 count) internal returns (uint256 used) {
        uint256 salt = ++saltNonce;
        address[] memory r = new address[](count);
        for (uint256 i; i < count; ++i) {
            r[i] = address(uint160(uint256(keccak256(abi.encode("fresh", salt, i)))));
        }
        uint256 g0 = gasleft();
        batch.disperseEtherEqual(r, VALUE);
        used = g0 - gasleft();
    }

    /// @dev Distinct recipients that already exist on-chain (pre-funded, so the
    ///      account is non-empty). Each is still cold-accessed once (2,600) but
    ///      pays no 25,000 new-account charge — the realistic "pay existing
    ///      holders" case.
    function _measureManyPrefunded(uint256 count) internal returns (uint256 used) {
        uint256 salt = ++saltNonce;
        address[] memory r = new address[](count);
        for (uint256 i; i < count; ++i) {
            address a = address(uint160(uint256(keccak256(abi.encode("prefunded", salt, i)))));
            r[i] = a;
            vm.deal(a, 1 ether); // pre-existing balance => non-empty account
        }
        uint256 g0 = gasleft();
        batch.disperseEtherEqual(r, VALUE);
        used = g0 - gasleft();
    }

    // --- benchmark -----------------------------------------------------------

    function test_NativeThroughput() public {
        _printHeader("MAX POL (NATIVE) TRANSFERS PER BLOCK");

        // Rung 0 & 1: standalone transfers are constant-cost, computed directly.
        // EIP-2929/2200: plain value send is 21,000; +25,000 if the recipient
        // account is empty (new-account creation).
        _record("0. naive EOA -> fresh empty account", INTRINSIC + 25_000);
        _record("1. naive EOA -> existing account", INTRINSIC);

        // Rung 2: batched to distinct, fresh (empty) recipients — every transfer
        // pays cold access (2,600) + new-account creation (25,000).
        // gasleft() captures execution only; the array paths also pay calldata
        // for one address word per recipient, charged before execution.
        uint256 freshMarginal = (_measureManyFresh(N2) - _measureManyFresh(N1)) / N1;
        _record("2. batched -> many fresh empty accounts", freshMarginal + _addressWordCalldata());

        // Rung 3: batched to distinct recipients that ALREADY EXIST (pre-funded,
        // non-empty). Cold access is still paid per recipient, but the 25,000
        // new-account charge is gone. This is the realistic "pay existing
        // holders" figure — measured, not extrapolated.
        uint256 prefundedMarginal = (_measureManyPrefunded(N2) - _measureManyPrefunded(N1)) / N1;
        _record("3. batched -> many distinct pre-existing accounts", prefundedMarginal + _addressWordCalldata());

        // Rung 4: the lab maximum. Same hot recipient, constant calldata.
        uint256 s1 = _measureSame(N1);
        uint256 s2 = _measureSame(N2);
        uint256 sameMarginal = (s2 - s1) / N1;
        uint256 maxPerBlock = _record("4. batched -> single hot recipient (MAX)", sameMarginal);

        console2.log("");
        console2.log(">>> HEADLINE: max POL transfers in a 160M block = %s", maxPerBlock);

        // Sanity: each rung should beat the previous one.
        assertLt(sameMarginal, prefundedMarginal, "same-recipient should beat distinct pre-existing");
        assertLt(prefundedMarginal, freshMarginal, "pre-existing should beat fresh accounts");
        assertLt(prefundedMarginal, INTRINSIC, "batching should beat naive");
        // Floor check: a value transfer to an EOA cannot cost less than ~6,700
        // gas (9,000 CallValueTransferGas - 2,300 refunded stipend + warm CALL).
        assertGe(sameMarginal, 6_500, "cannot beat CallValueTransferGas floor");
        assertLt(sameMarginal, 9_000, "stipend refund should bring us below 9,000");
    }
}
