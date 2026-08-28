// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SprayToken
 * @dev Standard ERC20 token with a special "spray" function that distributes
 *      tokens to a list of addresses (max 10 recipients per spray).
 */
contract Token is ERC20, Ownable, ReentrancyGuard {
    uint256 public constant MAX_RECIPIENTS = 10;

    error NoRecipients();
    error TooManyRecipients();
    error InsufficientBalance(uint256 available, uint256 required);
    error ZeroAddress();
    error CannotSendToContract();
    error AmountTooLow();

    /**
     * @dev Constructor mints initial supply to the deployer.
     * @param name Token name
     * @param symbol Token symbol
     * @param initialSupply Initial token supply
     */
    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply
    ) ERC20(name, symbol) Ownable(msg.sender) {
        _mint(msg.sender, initialSupply);
    }

    /**
     * @dev Sprays a fixed amount of tokens to a list of recipient addresses.
     * @param recipients List of addresses to receive tokens (max 10)
     * @param amount Amount of tokens to send to each recipient
     */
    function spray(address[] calldata recipients, uint256 amount) external onlyOwner nonReentrant {
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
     * @param recipients List of addresses to receive tokens (max 10)
     * @param totalAmount Total amount of tokens to distribute among all recipients
     */
    function spraySplit(address[] calldata recipients, uint256 totalAmount) external onlyOwner nonReentrant {
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
     * @dev Override to prevent burning tokens.
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        super._update(from, to, value);
    }
}