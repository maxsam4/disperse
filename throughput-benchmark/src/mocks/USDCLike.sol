// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title USDCLike
/// @notice A faithful-enough reimplementation of Circle's FiatTokenV2_2 transfer
///         path — the contract behind USDC on Polygon (both native USDC and the
///         bridged USDC.e). Compared to a minimal ERC-20, every transfer also:
///           * reads the global paused flag,
///           * reads the blacklist slot for `msg.sender`, `from` and `to`.
///         These extra cold/warm SLOADs are exactly what makes a real USDC
///         transfer cost more than the textbook ~35k, so benchmarking against
///         this contract yields numbers representative of mainnet USDC rather
///         than an idealized token.
///
///         The storage layout mirrors FiatToken: balances, allowances and the
///         blacklist live in their own mappings, so the warm/dirty-slot dynamics
///         we exploit in the "same recipient" benchmark behave like production.
contract USDCLike {
    string public constant name = "USD Coin";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;

    address public owner;
    bool public paused;

    mapping(address => uint256) internal balances;
    mapping(address => mapping(address => uint256)) internal allowed;
    mapping(address => bool) internal blacklisted;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error AccountBlacklisted();
    error ContractPaused();

    constructor() {
        owner = msg.sender;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier notBlacklisted(address account) {
        if (blacklisted[account]) revert AccountBlacklisted();
        _;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function allowance(address o, address spender) external view returns (uint256) {
        return allowed[o][spender];
    }

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount)
        external
        whenNotPaused
        notBlacklisted(msg.sender)
        notBlacklisted(spender)
        returns (bool)
    {
        allowed[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount)
        external
        whenNotPaused
        notBlacklisted(msg.sender)
        notBlacklisted(to)
        returns (bool)
    {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        external
        whenNotPaused
        notBlacklisted(msg.sender)
        notBlacklisted(from)
        notBlacklisted(to)
        returns (bool)
    {
        uint256 allowance_ = allowed[from][msg.sender];
        if (allowance_ != type(uint256).max) {
            allowed[from][msg.sender] = allowance_ - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balances[from] -= amount;
        unchecked {
            balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
