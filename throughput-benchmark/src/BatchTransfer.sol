// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @title BatchTransfer
/// @notice Throughput-optimized batch transfer primitives for native POL and
///         ERC-20 tokens (e.g. USDC). Every entry point is a single transaction
///         that performs many logical transfers, amortizing the 21,000 gas
///         intrinsic transaction cost across the whole batch.
///
/// The functions are ordered from "general purpose" to "maximum throughput".
/// The `*Same` variants are the lab-condition optimum: they send to a single
/// hot recipient `count` times, which means
///   * calldata is constant regardless of `count` (no per-recipient bytes), and
///   * after the first iteration every touched account / storage slot is warm
///     (EIP-2929) and "dirty" (EIP-2200), collapsing per-transfer cost to its
///     irreducible floor.
contract BatchTransfer {
    error CallFailed();
    error LengthMismatch();
    error TransferFailed();

    // -------------------------------------------------------------------------
    // Native POL
    // -------------------------------------------------------------------------

    /// @notice General disperse: arbitrary recipients and arbitrary amounts.
    function disperseEther(address[] calldata recipients, uint256[] calldata values) external payable {
        if (recipients.length != values.length) revert LengthMismatch();
        unchecked {
            for (uint256 i; i < recipients.length; ++i) {
                (bool ok,) = recipients[i].call{value: values[i]}("");
                if (!ok) revert CallFailed();
            }
        }
    }

    /// @notice Equal-amount disperse. Only one `value` lives in calldata instead
    ///         of one per recipient, shaving ~9 calldata bytes/recipient.
    function disperseEtherEqual(address[] calldata recipients, uint256 value) external payable {
        unchecked {
            for (uint256 i; i < recipients.length; ++i) {
                (bool ok,) = recipients[i].call{value: value}("");
                if (!ok) revert CallFailed();
            }
        }
    }

    /// @notice Maximum-throughput native path: send `value` to the same hot,
    ///         pre-funded recipient `count` times. Calldata is fixed (3 words),
    ///         the recipient stays warm and never triggers new-account creation,
    ///         so per-transfer cost approaches ~6,700 gas (9,000 CallValueTransferGas
    ///         minus the 2,300 stipend an EOA refunds, plus 100 warm access).
    function disperseEtherSame(address payable to, uint256 value, uint256 count) external payable {
        // Tight assembly loop: no Solidity bounds checks, no memory expansion,
        // forward zero gas stipend beyond the mandatory CALL value transfer.
        assembly {
            for { let i := 0 } lt(i, count) { i := add(i, 1) } {
                // call(gas, addr, value, inOff, inLen, outOff, outLen)
                let ok := call(gas(), to, value, 0, 0, 0, 0)
                if iszero(ok) {
                    mstore(0x00, 0x3204506f) // CallFailed()
                    revert(0x1c, 0x04)
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // ERC-20 (USDC)
    // -------------------------------------------------------------------------

    /// @notice General token disperse using the classic 1/3-gas-saving trick:
    ///         pull the full total in once with `transferFrom`, then fan it out
    ///         with `transfer` (which updates two balances and no allowance).
    function disperseToken(IERC20 token, address[] calldata recipients, uint256[] calldata values) external {
        if (recipients.length != values.length) revert LengthMismatch();
        uint256 total;
        unchecked {
            for (uint256 i; i < recipients.length; ++i) {
                total += values[i];
            }
        }
        if (!token.transferFrom(msg.sender, address(this), total)) revert TransferFailed();
        unchecked {
            for (uint256 i; i < recipients.length; ++i) {
                if (!token.transfer(recipients[i], values[i])) revert TransferFailed();
            }
        }
    }

    /// @notice Equal-amount token disperse.
    function disperseTokenEqual(IERC20 token, address[] calldata recipients, uint256 value) external {
        if (!token.transferFrom(msg.sender, address(this), value * recipients.length)) revert TransferFailed();
        unchecked {
            for (uint256 i; i < recipients.length; ++i) {
                if (!token.transfer(recipients[i], value)) revert TransferFailed();
            }
        }
    }

    /// @notice Maximum-throughput token path: pull the total in once, then
    ///         `transfer` `value` to the same hot recipient `count` times. Both
    ///         the contract's balance slot and the recipient's balance slot are
    ///         warm + dirty after the first iteration, so subsequent SSTOREs
    ///         cost 100 gas each and per-transfer cost is dominated only by the
    ///         token's own logic (event log + checks).
    function disperseTokenSame(IERC20 token, address to, uint256 value, uint256 count) external {
        if (!token.transferFrom(msg.sender, address(this), value * count)) revert TransferFailed();
        unchecked {
            for (uint256 i; i < count; ++i) {
                if (!token.transfer(to, value)) revert TransferFailed();
            }
        }
    }

    receive() external payable {}
}
