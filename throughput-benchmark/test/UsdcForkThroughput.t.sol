// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BenchBase} from "./BenchBase.sol";
import {console2} from "forge-std/Test.sol";
import {BatchTransfer, IERC20} from "../src/BatchTransfer.sol";

interface IUSDC is IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice Validates the USDC throughput numbers against the REAL FiatToken
///         bytecode deployed on Polygon, by forking mainnet.
///
/// This test self-skips unless `POLYGON_RPC_URL` is set, e.g.:
///   POLYGON_RPC_URL=https://polygon.drpc.org forge test --match-contract Fork -vv
///
/// Native Circle USDC on Polygon PoS: 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359
contract UsdcForkThroughput is BenchBase {
    address internal constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;

    // Distinct-recipient runs deal() per address against the live fork, which is
    // slower than the constant-calldata same-recipient run, so use smaller sizes.
    uint256 internal constant DN1 = 500;
    uint256 internal constant DN2 = 1_000;

    BatchTransfer internal batch;
    IUSDC internal usdc;
    address internal hot = address(uint160(0xC0FFEE));

    bool internal active;
    uint256 internal saltNonce;

    function setUp() public {
        string memory rpc = vm.envOr("POLYGON_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // not configured -> skip
        vm.createSelectFork(rpc);

        usdc = IUSDC(USDC);
        batch = new BatchTransfer();

        try this.fund() {
            active = true;
        } catch {
            active = false;
        }
    }

    /// @dev External so deal()/approve() can be wrapped in try/catch; some token
    ///      storage layouts defeat foundry's automatic slot detection.
    function fund() external {
        deal(USDC, address(this), 1e15); // 1e9 USDC
        deal(USDC, hot, 1e6); // seed the hot recipient
        require(usdc.balanceOf(address(this)) >= 1e15, "deal failed");
        usdc.approve(address(batch), type(uint256).max);
    }

    function _sameUsdc(uint256 count) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        batch.disperseTokenSame(IERC20(USDC), hot, 1, count);
        used = g0 - gasleft();
    }

    /// @dev Distinct recipients that already hold real USDC (nonzero->nonzero).
    function _preexistingUsdc(uint256 count) internal returns (uint256 used) {
        uint256 salt = ++saltNonce;
        address[] memory r = new address[](count);
        for (uint256 i; i < count; ++i) {
            address a = address(uint160(uint256(keccak256(abi.encode("fork-pe", salt, i)))));
            r[i] = a;
            deal(USDC, a, 1e6); // pre-existing balance
        }
        uint256 g0 = gasleft();
        batch.disperseTokenEqual(IERC20(USDC), r, 1);
        used = g0 - gasleft();
    }

    function test_RealUsdcThroughput() public {
        if (!active) {
            console2.log("POLYGON_RPC_URL not set (or deal failed) -> skipping real USDC fork benchmark");
            vm.skip(true);
            return;
        }

        _printHeader("MAX REAL USDC TRANSFERS PER BLOCK (POLYGON FORK)");

        // Distinct recipients that already hold USDC (realistic "pay holders").
        uint256 preMarginal = (_preexistingUsdc(DN2) - _preexistingUsdc(DN1)) / (DN2 - DN1);
        _record("Real USDC -> many distinct pre-existing holders", preMarginal + _addressWordCalldata());

        // Same hot recipient (lab maximum).
        uint256 sameMarginal = (_sameUsdc(N2) - _sameUsdc(N1)) / N1;
        uint256 max = _record("Real USDC -> single hot recipient (MAX)", sameMarginal);

        console2.log("");
        console2.log(">>> HEADLINE: max REAL USDC transfers in a 160M block = %s", max);

        assertLt(sameMarginal, preMarginal, "hot recipient should beat distinct pre-existing");
    }
}
