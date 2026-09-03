// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
/**
 * @title Token
 * @dev Self-contained ERC20 implementation with custom 1% transaction fees
 *      (70% to owner / 30% burnt) plus a "spray" distribution mechanism.
 *      No external ERC20 library dependencies are required.
 */
contract Token is IERC20, Ownable, ReentrancyGuard {
    // ---- IERC20 state ----
    string private _name;
    string private _symbol;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ---- Fee customizations: 1% total fee, split 70/30 ----
    uint256 private constant FEE_DENOMINATOR = 100; // 0.1% increments
    uint256 private constant OWNER_FEE_SHARE = 70;   // 70% of fee to owner
    // Kept for backwards compatibility w/ original constant naming.
    uint256 private constant MAX_RECIPIENTS = 100;
    uint256 private constant MAX_MINT_PER_WINDOW = 1000;
    uint256 private constant BLOCKS_PER_WINDOW = 57600; // ~24 hours at ~1.5s/block

    // ---- Errors ----
    error NoRecipients();
    error TooManyRecipients();
    error InsufficientBalance(uint256 available, uint256 required);
    error ZeroAddress();
    error CannotSendToContract();
    error AmountTooLow();
    error MintRateExceeded(uint256 mintedThisWindow, uint256 maxAllowed, uint256 requestedAmount);
    error InsufficientAllowance(uint256 allowed, uint256 required);

    // Tracks the amount minted in the current block window
    uint256 private _mintedThisWindow;
    uint256 private _mintWindowStartBlock;

    // Exempt addresses from the transaction fee
    mapping(address => bool) public isFeeExempt;

    /**
     * @dev Constructor mints initial supply to the deployer.
     * @param _tokenName Token name
     * @param _tokenSymbol Token symbol
     * @param initialSupply Initial token supply
     */
    constructor(string memory _tokenName, string memory _tokenSymbol, uint256 initialSupply) Ownable(msg.sender) {
        _name = _tokenName;
        _symbol = _tokenSymbol;

        _mint(msg.sender, initialSupply);
        _mintWindowStartBlock = block.number;
        isFeeExempt[msg.sender] = true; // fee exempt the owner/deployer
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function allowance(address ownerAddr, address spender) external view override returns (uint256) {
        return _allowances[ownerAddr][spender];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        if (msg.sender == from) {
            // Caller is the token holder themselves, no allowance check needed
            _transfer(from, to, amount);
            return true;
        }
        uint256 currentAllowance = _allowances[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) revert InsufficientAllowance(currentAllowance, amount);
            _approve(from, msg.sender, currentAllowance - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    /**
     * @dev Evaluates the 1% fee for a transfer, returning the fee and the
     *      corresponding owner / burn shares.
     */
    function _calculateFee(uint256 amount) private pure returns (uint256 fee, uint256 ownerShare, uint256 burnShare) {
        fee = amount / FEE_DENOMINATOR;
        ownerShare = (fee * OWNER_FEE_SHARE) / FEE_DENOMINATOR;
        burnShare = fee - ownerShare;
    }

    /**
     * @dev Internal mint. Only callable from within the contract.
     */
    function _mint(address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    /**
     * @dev Internal burn. Only callable from within the contract.
     */
    function _burn(address from, uint256 amount) internal {
        if (amount > _balances[from]) revert InsufficientBalance(_balances[from], amount);
        _balances[from] -= amount;
        _totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function _approve(address ownerAddr, address spender, uint256 amount) internal {
        if (ownerAddr == address(0)) revert ZeroAddress();
        if (spender == address(0)) revert ZeroAddress();
        _allowances[ownerAddr][spender] = amount;
        emit Approval(ownerAddr, spender, amount);
    }

    /**
     * @dev Core transfer logic that applies the custom fee when neither party
     *      is exempt. Emits the fee portion as an owner reward and a burn.
     */
    function _transfer(address sender, address recipient, uint256 amount) internal {
        if (sender == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();

        if (amount > _balances[sender]) revert InsufficientBalance(_balances[sender], amount);

        _balances[sender] -= amount;

        bool applyFee = !isFeeExempt[sender] && !isFeeExempt[recipient];

        if (applyFee) {
            (uint256 fee, uint256 ownerShare, uint256 burnShare) = _calculateFee(amount);

            _balances[owner()] += ownerShare;
            emit Transfer(sender, owner(), ownerShare);

            _balances[address(0xdead)] += burnShare;
            _totalSupply -= burnShare;
            emit Transfer(sender, address(0), burnShare);

            _balances[recipient] += amount - fee;
            emit Transfer(sender, recipient, amount - fee);
        } else {
            _balances[recipient] += amount;
            emit Transfer(sender, recipient, amount);
        }
    }

    /**
     * @dev Mints new tokens. Only callable by the owner, with a rate limit
     *      of 1000 tokens per block window (~24 hours).
     */
    function mint(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountTooLow();

        _rollMintWindow();

        uint256 availableThisWindow = MAX_MINT_PER_WINDOW - _mintedThisWindow;
        if (amount > availableThisWindow) {
            revert MintRateExceeded(_mintedThisWindow, MAX_MINT_PER_WINDOW, amount);
        }

        _mint(to, amount);
        _mintedThisWindow += amount;
    }

    /**
     * @dev Internal helper to roll over the mint window if a new block window has begun.
     */
    function _rollMintWindow() private {
        if (block.number >= _mintWindowStartBlock + BLOCKS_PER_WINDOW) {
            _mintWindowStartBlock = block.number;
            _mintedThisWindow = 0;
        }
    }

    /**
     * @dev Burns tokens from a specified address.
     * @param from Address from which tokens will be burned
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 amount) external {
        if (from != msg.sender) {
            uint256 currentAllowance = _allowances[from][msg.sender];
            if (currentAllowance != type(uint256).max) {
                if (currentAllowance < amount) revert InsufficientAllowance(currentAllowance, amount);
                _approve(from, msg.sender, currentAllowance - amount);
            }
        }
        _burn(from, amount);
    }

    /**
     * @dev Sets whether an address is exempt from the transaction fee.
     *      Only callable by the owner.
     */
    function setFeeExempt(address account, bool exempt) external onlyOwner {
        isFeeExempt[account] = exempt;
    }

    /**
     * @dev Sprays a fixed amount of tokens to a list of recipient addresses.
     */
    function spray(address[] calldata recipients, uint256 amount) external nonReentrant {
        if (recipients.length == 0) revert NoRecipients();
        if (recipients.length > MAX_RECIPIENTS) revert TooManyRecipients();

        (uint256 feePerTransfer, , ) = _calculateFee(amount);
        uint256 totalDebit = (amount + feePerTransfer) * recipients.length;
        uint256 available = balanceOf(msg.sender);
        if (available < totalDebit) revert InsufficientBalance(available, totalDebit);

        // Temporarily exempt the sender to avoid nested fee application
        bool wasExempt = isFeeExempt[msg.sender];
        isFeeExempt[msg.sender] = true;

        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            if (recipient == address(0)) revert ZeroAddress();
            if (recipient == address(this)) revert CannotSendToContract();
            _transfer(msg.sender, recipient, amount);
        }

        isFeeExempt[msg.sender] = wasExempt;
    }

    /**
     * @dev Splits a total amount of tokens evenly among all recipients.
     */
    function spraySplit(address[] calldata recipients, uint256 totalAmount) external nonReentrant {
        if (recipients.length == 0) revert NoRecipients();
        if (recipients.length > MAX_RECIPIENTS) revert TooManyRecipients();

        uint256 perRecipient = totalAmount / recipients.length;
        if (perRecipient == 0) revert AmountTooLow();

        (uint256 feePerTransfer, , ) = _calculateFee(perRecipient);
        uint256 totalDebit = (perRecipient + feePerTransfer) * recipients.length;
        uint256 available = balanceOf(msg.sender);
        if (available < totalDebit) revert InsufficientBalance(available, totalDebit);

        // Temporarily exempt the sender to avoid nested fee application
        bool wasExempt = isFeeExempt[msg.sender];
        isFeeExempt[msg.sender] = true;

        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            if (recipient == address(0)) revert ZeroAddress();
            if (recipient == address(this)) revert CannotSendToContract();
            _transfer(msg.sender, recipient, perRecipient);
        }

        isFeeExempt[msg.sender] = wasExempt;
    }
}
