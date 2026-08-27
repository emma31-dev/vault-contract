// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IERC4626 is IERC20 {
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    function asset() external view returns (address assetTokenAddress);
    function totalAssets() external view returns (uint256 totalManagedAssets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function maxMint(address receiver) external view returns (uint256 maxShares);
    function previewMint(uint256 shares) external view returns (uint256 assets);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function maxWithdraw(address owner) external view returns (uint256 maxAssets);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function maxRedeem(address owner) external view returns (uint256 maxShares);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

contract Vault is IERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable override asset;
    uint256 private _totalShares;
    mapping(address => uint256) private _shares;
    mapping(address => mapping(address => uint256)) private _allowances;

    uint8 private _decimals;
    string private _name;
    string private _symbol;

    constructor(address _asset, string memory _name_, string memory _symbol_) Ownable(msg.sender) {
        asset = _asset;
        _name = _name_;
        _symbol = _symbol_;
        _decimals = IERC20Metadata(_asset).decimals();
    }

    // ==================== ERC20 Interface ====================

    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public view returns (uint8) { return _decimals; }

    function totalSupply() public view override returns (uint256) { return _totalShares; }
    function balanceOf(address owner) public view override returns (uint256) { return _shares[owner]; }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override nonReentrant returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override nonReentrant returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        require(allowed >= amount, "ERC20: transfer amount exceeds allowance");
        if (allowed != type(uint256).max) {
            _allowances[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(_shares[from] >= amount, "ERC20: transfer amount exceeds balance");
        _shares[from] -= amount;
        _shares[to] += amount;
        emit Transfer(from, to, amount);
    }

    // ==================== ERC4626 Core ====================

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 supply = _totalShares;
        return supply == 0 ? assets : assets * supply / totalAssets();
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 supply = _totalShares;
        return supply == 0 ? shares : shares * totalAssets() / supply;
    }

    function maxDeposit(address) public pure override returns (uint256) { return type(uint256).max; }
    function maxMint(address) public pure override returns (uint256) { return type(uint256).max; }
    function maxWithdraw(address owner) public view override returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }
    function maxRedeem(address owner) public view override returns (uint256) {
        return balanceOf(owner);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 supply = _totalShares;
        return supply == 0 ? shares : shares * totalAssets() / supply;
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 supply = _totalShares;
        return supply == 0 ? assets : assets * supply / totalAssets();
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return convertToAssets(shares);
    }

    function deposit(uint256 assets, address receiver) external override nonReentrant returns (uint256 shares) {
        require(assets > 0, "ZERO_ASSETS");
        shares = previewDeposit(assets);
        _deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    function mint(uint256 shares, address receiver) external override nonReentrant returns (uint256 assets) {
        require(shares > 0, "ZERO_SHARES");
        assets = previewMint(shares);
        _deposit(msg.sender, receiver, assets, shares);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external override nonReentrant returns (uint256 shares) {
        require(assets > 0, "ZERO_ASSETS");
        shares = previewWithdraw(assets);
        _withdraw(owner, receiver, owner, assets, shares);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external override nonReentrant returns (uint256 assets) {
        require(shares > 0, "ZERO_SHARES");
        assets = previewRedeem(shares);
        _withdraw(owner, receiver, owner, assets, shares);
        return assets;
    }

    // ==================== Internal ====================

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal {
        require(shares > 0, "ZERO_SHARES_MINTED");
        IERC20(asset).safeTransferFrom(caller, address(this), assets);
        _shares[receiver] += shares;
        _totalShares += shares;
        emit Deposit(caller, receiver, assets, shares);
        emit Transfer(address(0), receiver, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal {
        require(_shares[owner] >= shares, "INSUFFICIENT_BALANCE");
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        _shares[owner] -= shares;
        _totalShares -= shares;
        emit Withdraw(caller, receiver, owner, assets, shares);
        emit Transfer(owner, address(0), shares);
        IERC20(asset).safeTransfer(receiver, assets);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 allowed = _allowances[owner][spender];
        require(allowed >= amount, "ERC20: insufficient allowance");
        if (allowed != type(uint256).max) {
            _allowances[owner][spender] = allowed - amount;
        }
    }

    // Required by IERC20 interface
    function _mint(address, uint256) internal pure { revert("NOT_IMPLEMENTED"); }
    function _burn(address, uint256) internal pure { revert("NOT_IMPLEMENTED"); }
}
