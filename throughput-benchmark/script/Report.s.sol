// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {BatchTransfer, IERC20} from "../src/BatchTransfer.sol";
import {MinimalERC20} from "../src/mocks/MinimalERC20.sol";
import {USDCLike} from "../src/mocks/USDCLike.sol";

/// @notice One-shot consolidated throughput report for the headline figures.
///         Run with:  forge script script/Report.s.sol
///
/// Reports the lab-maximum transfers/block for POL and USDC plus the ERC-20
/// theoretical floor, using the same two-point marginal methodology as the test
/// suite.
contract Report is Script {
    uint256 internal constant BLOCK_GAS_LIMIT = 160_000_000;
    uint256 internal constant INTRINSIC = 21_000;
    uint256 internal constant N1 = 2_000;
    uint256 internal constant N2 = 4_000;

    BatchTransfer internal batch;
    MinimalERC20 internal min;
    USDCLike internal usdc;
    address internal hot = address(uint160(0xC0FFEE));
    address internal funder = address(uint160(0xF00D));

    function run() external {
        batch = new BatchTransfer();
        min = new MinimalERC20();
        usdc = new USDCLike();

        vm.deal(address(batch), 1_000 ether);
        vm.deal(hot, 1 ether);

        // Mint to a dedicated funder EOA and approve/transfer as that account
        // (script contracts must not rely on address(this)).
        min.mint(funder, 1e30);
        usdc.mint(funder, 1e30);
        min.mint(hot, 1e6);
        usdc.mint(hot, 1e6);
        vm.startPrank(funder);
        min.approve(address(batch), type(uint256).max);
        usdc.approve(address(batch), type(uint256).max);

        uint256 pol = _perBlock(_nativeMarginal());
        uint256 usd = _perBlock(_tokenMarginal(IERC20(address(usdc))));
        uint256 floor = _perBlock(_tokenMarginal(IERC20(address(min))));
        vm.stopPrank();

        console2.log("==================================================================");
        console2.log(" POLYGON THROUGHPUT (160,000,000 gas block, ideal lab conditions)");
        console2.log("==================================================================");
        console2.log(" max POL transfers / block      : %s", pol);
        console2.log(" max USDC transfers / block      : %s", usd);
        console2.log(" ERC-20 theoretical floor / block: %s", floor);
        console2.log("==================================================================");
    }

    function _perBlock(uint256 marginal) internal pure returns (uint256) {
        return marginal == 0 ? 0 : (BLOCK_GAS_LIMIT - INTRINSIC) / marginal;
    }

    function _nativeMarginal() internal returns (uint256) {
        uint256 g1 = gasleft();
        batch.disperseEtherSame(payable(hot), 1, N1);
        uint256 u1 = g1 - gasleft();
        uint256 g2 = gasleft();
        batch.disperseEtherSame(payable(hot), 1, N2);
        uint256 u2 = g2 - gasleft();
        return (u2 - u1) / N1;
    }

    function _tokenMarginal(IERC20 token) internal returns (uint256) {
        uint256 g1 = gasleft();
        batch.disperseTokenSame(token, hot, 1, N1);
        uint256 u1 = g1 - gasleft();
        uint256 g2 = gasleft();
        batch.disperseTokenSame(token, hot, 1, N2);
        uint256 u2 = g2 - gasleft();
        return (u2 - u1) / N1;
    }
}
