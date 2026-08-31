// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SprayToken
 * @dev Standard ERC20 token with a special "spray" function that distributes
 *      tokens to a list of addresses (max 100 recipients per spray).
 *      Includes a mint rate limit: the owner can mint a maximum of 1000 tokens
 *      per 57600 blocks (approximately 24 hours, assuming ~1.5 second block time).
 */
contract Token is ERC20, Ownable, ReentrancyGuard {
    uint256 private constant MAX_RECIPIENTS = 100;
    uint256 private constant MAX_MINT_PER_WINDOW = 1000;
    uint256 private constant BLOCKS_PER_WINDOW = 57600; // ~24 hours at ~1.5s/block

    error NoRecipients();
    error TooManyRecipients();
    error InsufficientBalance(uint256 available, uint256 required);
    error ZeroAddress();
    error CannotSendToContract();
    error AmountTooLow();
    error MintRateExceeded(uint256 mintedThisWindow, uint256 maxAllowed, uint256 requestedAmount);

    // Tracks the amount minted in the current block window
    uint256 private _mintedThisWindow;
    uint256 private _mintWindowStartBlock;

    /**
     * @dev Constructor mints initial supply to the deployer.
     * @param _name Token name
     * @param _symbol Token symbol
     * @param initialSupply Initial token supply
     */
    constructor(string memory _name, string memory _symbol, uint256 initialSupply)
        ERC20(_name, _symbol)
        Ownable(msg.sender)
    {
        _mint(msg.sender, initialSupply);
        _mintWindowStartBlock = block.number;
    }

    /**
     * @dev Mints new tokens. Only callable by the owner, with a rate limit
     *      of 1000 tokens per block window (~24 hours).
     * @param to Address to receive the minted tokens
     * @param amount Amount of tokens to mint
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
     * @dev Burns tokens from a specified address
     * @param from Address from which tokens will be burned
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    /**
     * @dev Sprays a fixed amount of tokens to a list of recipient addresses.
     * @param recipients List of addresses to receive tokens (max 100)
     * @param amount Amount of tokens to send to each recipient
     */
    function spray(address[] calldata recipients, uint256 amount) external nonReentrant {
        if (recipients.length == 0) revert NoRecipients();
        if (recipients.length > MAX_RECIPIENTS) revert TooManyRecipients();

        uint256 totalCost = amount * recipients.length;
        uint256 available = balanceOf(msg.sender);
        if (available < totalCost) revert InsufficientBalance(available, totalCost);

        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            if (recipient == address(0)) revert ZeroAddress();
            if (recipient == address(this)) revert CannotSendToContract();
            _transfer(msg.sender, recipient, amount);
        }
    }

    /**
     * @dev Splits a total amount of tokens evenly among all recipients.
     * @param recipients List of addresses to receive tokens (max 100)
     * @param totalAmount Total amount of tokens to distribute among all recipients
     */
    function spraySplit(address[] calldata recipients, uint256 totalAmount) external nonReentrant {
        if (recipients.length == 0) revert NoRecipients();
        if (recipients.length > MAX_RECIPIENTS) revert TooManyRecipients();

        uint256 perRecipient = totalAmount / recipients.length;
        if (perRecipient == 0) revert AmountTooLow();

        uint256 actualTotal = perRecipient * recipients.length;
        uint256 available = balanceOf(msg.sender);
        if (available < actualTotal) revert InsufficientBalance(available, actualTotal);

        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            if (recipient == address(0)) revert ZeroAddress();
            if (recipient == address(this)) revert CannotSendToContract();
            _transfer(msg.sender, recipient, perRecipient);
        }
    }

    /**
     * @dev Sends a tip of tokens to the contract owner.
     * @param amount Amount of tokens to tip the owner
     */
    function tip(uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountTooLow();
        transfer(owner(), amount);
    }
}
