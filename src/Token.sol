// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SprayToken
 * @dev Standard ERC20 token with a special "spray" function that distributes
 *      tokens to a list of addresses (max 10 recipients per spray).
 */
contract Token is ERC20, Ownable {
    uint256 public constant MAX_RECIPIENTS = 10;

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
    function spray(address[] calldata recipients, uint256 amount) external onlyOwner {
        require(recipients.length > 0, "SprayToken: no recipients");
        require(recipients.length <= MAX_RECIPIENTS, "SprayToken: too many recipients (max 10)");

        uint256 totalCost = amount * recipients.length;
        require(balanceOf(msg.sender) >= totalCost, "SprayToken: insufficient balance");

        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            require(recipient != address(0), "SprayToken: zero address");
            require(recipient != address(this), "SprayToken: cannot send to contract itself");
            _transfer(msg.sender, recipient, amount);
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