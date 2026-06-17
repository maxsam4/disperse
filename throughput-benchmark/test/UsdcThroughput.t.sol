// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BenchBase} from "./BenchBase.sol";
import {console2} from "forge-std/Test.sol";
import {BatchTransfer, IERC20} from "../src/BatchTransfer.sol";
import {MinimalERC20} from "../src/mocks/MinimalERC20.sol";
import {USDCLike} from "../src/mocks/USDCLike.sol";

/// @notice Max USDC (ERC-20) transfers in a 160M gas block.
///
/// Unlike native POL, the cost is dominated by storage writes, not value
/// transfer. The tricks that matter:
///   * batching (amortize the 21k intrinsic),
///   * the disperse "pull-once then fan-out" pattern (transferFrom once, then
///     transfer — no per-recipient allowance SSTORE),
///   * sending to recipients that already hold a balance, so each balance slot
///     is a nonzero->nonzero update (~5k) instead of a zero->nonzero one (~20k),
///   * sending to the SAME hot recipient, so after the first iteration both the
///     sender (contract) and recipient balance slots are warm AND dirty, making
///     every subsequent SSTORE 100 gas — leaving only the Transfer event and
///     the token's own checks as marginal cost.
///
/// We benchmark against two tokens:
///   * MinimalERC20 — theoretical ERC-20 floor,
///   * USDCLike     — Circle FiatToken-style (paused + 3x blacklist SLOADs),
///     representative of real USDC on Polygon.
contract UsdcThroughput is BenchBase {
    BatchTransfer internal batch;
    MinimalERC20 internal min;
    USDCLike internal usdc;

    address internal funder = address(this);
    address internal hot = address(uint160(0xC0FFEE));

    function setUp() public {
        batch = new BatchTransfer();
        min = new MinimalERC20();
        usdc = new USDCLike();

        // Mint plenty to this contract (the funder/sender) and approve the batch.
        min.mint(address(this), 1e30);
        usdc.mint(address(this), 1e30);
        min.approve(address(batch), type(uint256).max);
        usdc.approve(address(batch), type(uint256).max);

        // Pre-seed the hot recipient so its balance slot starts nonzero.
        min.mint(hot, 1e6);
        usdc.mint(hot, 1e6);
    }

    // --- helpers -------------------------------------------------------------

    function _sameMinimal(uint256 count) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        batch.disperseTokenSame(IERC20(address(min)), hot, 1, count);
        used = g0 - gasleft();
    }

    function _sameUsdc(uint256 count) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        batch.disperseTokenSame(IERC20(address(usdc)), hot, 1, count);
        used = g0 - gasleft();
    }

    uint256 internal saltNonce;

    function _manyFreshUsdc(uint256 count) internal returns (uint256 used) {
        uint256 salt = ++saltNonce;
        address[] memory r = new address[](count);
        for (uint256 i; i < count; ++i) {
            r[i] = address(uint160(uint256(keccak256(abi.encode(salt, i)))));
        }
        uint256 g0 = gasleft();
        batch.disperseTokenEqual(IERC20(address(usdc)), r, 1);
        used = g0 - gasleft();
    }

    function _marginal(function(uint256) internal returns (uint256) f) internal returns (uint256) {
        uint256 m1 = f(N1);
        uint256 m2 = f(N2);
        return (m2 - m1) / N1;
    }

    // --- benchmark -----------------------------------------------------------

    function test_UsdcThroughput() public {
        _printHeader("MAX USDC (ERC-20) TRANSFERS PER BLOCK");

        // Realistic batched airdrop: distinct fresh recipients (zero->nonzero),
        // FiatToken-style token. This is the honest "real airdrop" figure.
        uint256 usdcFreshMarginal = _marginal(_manyFreshUsdc);
        _record("USDC, batched -> many fresh recipients", usdcFreshMarginal + _addressWordCalldata());

        // Same hot recipient, FiatToken-style token (warm + dirty slots).
        uint256 usdcSameMarginal = _marginal(_sameUsdc);
        uint256 usdcMax = _record("USDC, batched -> single hot recipient (MAX)", usdcSameMarginal);

        // Same hot recipient, minimal ERC-20 (theoretical floor).
        uint256 minSameMarginal = _marginal(_sameMinimal);
        uint256 minMax = _record("Minimal ERC-20, single hot recipient (FLOOR)", minSameMarginal);

        console2.log("");
        console2.log(">>> HEADLINE: max USDC transfers in a 160M block = %s", usdcMax);
        console2.log(">>> Theoretical ERC-20 floor in a 160M block      = %s", minMax);

        // Each optimization should help; USDC's extra checks make it pricier
        // than the minimal floor.
        assertLt(usdcSameMarginal, usdcFreshMarginal, "hot recipient should beat fresh");
        assertGt(usdcSameMarginal, minSameMarginal, "USDC checks cost more than minimal");
    }
}
