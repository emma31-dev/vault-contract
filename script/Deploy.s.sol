// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Token} from "../src/Token.sol";
import {Vault} from "../src/Vault.sol";

/**
 * @title Deploy
 * @notice Deploys Token then Vault behind an ERC1967 proxy.
 *         Vault is upgradeable — the implementation is deployed first,
 *         then wrapped in a proxy that calls initialize() atomically.
 *
 * Usage
 * ─────
 * Local anvil:
 *   anvil                          # start a local node in another terminal
 *   forge script script/Deploy.s.sol:Deploy \
 *     --rpc-url http://127.0.0.1:8545 \
 *     --private-key <ANVIL_KEY> \
 *     --broadcast
 *
 * Testnet / mainnet (dry-run first, then add --broadcast):
 *   forge script script/Deploy.s.sol:Deploy \
 *     --rpc-url $RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY
 *
 * Environment variables (optional overrides):
 *   TOKEN_NAME        – defaults to "No Null State"
 *   TOKEN_SYMBOL      – defaults to "NNS"
 *   TOKEN_SUPPLY      – initial supply in whole tokens, defaults to 1_000_000
 *   VAULT_NAME        – defaults to "NNS Vault Share"
 *   VAULT_SYMBOL      – defaults to "NSHARE"
 */
contract Deploy is Script {
    // ── defaults ──────────────────────────────────────────────────────────
    string constant DEFAULT_TOKEN_NAME = "No Null State";
    string constant DEFAULT_TOKEN_SYMBOL = "NNS";
    uint256 constant DEFAULT_TOKEN_SUPPLY = 1_000_000; // whole tokens; scaled below
    string constant DEFAULT_VAULT_NAME = "NNS Vault Share";
    string constant DEFAULT_VAULT_SYMBOL = "NSHARE";

    // ── deployed addresses (set during run, useful for tests that inherit) ─
    Token public token;
    Vault public vault; // points to the proxy
    address public vaultImpl; // the bare implementation address

    function run() external {
        // ── resolve config ────────────────────────────────────────────────
        string memory tokenName = _envStringOr("TOKEN_NAME", DEFAULT_TOKEN_NAME);
        string memory tokenSymbol = _envStringOr("TOKEN_SYMBOL", DEFAULT_TOKEN_SYMBOL);
        uint256 tokenSupply = _envUintOr("TOKEN_SUPPLY", DEFAULT_TOKEN_SUPPLY) * 1e18;
        string memory vaultName = _envStringOr("VAULT_NAME", DEFAULT_VAULT_NAME);
        string memory vaultSymbol = _envStringOr("VAULT_SYMBOL", DEFAULT_VAULT_SYMBOL);

        // ── broadcast ─────────────────────────────────────────────────────
        vm.startBroadcast();

        // 1. Deploy Token
        token = new Token(tokenName, tokenSymbol, tokenSupply);
        console.log("Token deployed  :", address(token));
        console.log("  name          :", token.name());
        console.log("  symbol        :", token.symbol());
        console.log("  totalSupply   :", token.totalSupply());
        console.log("  owner         :", token.owner());

        // 2. Deploy Vault implementation (constructor disables initializers)
        Vault impl = new Vault();
        vaultImpl = address(impl);
        console.log("Vault impl      :", vaultImpl);

        // 3. Deploy ERC1967 proxy, calling initialize() atomically
        bytes memory initData = abi.encodeCall(Vault.initialize, (address(token), vaultName, vaultSymbol));
        ERC1967Proxy proxy = new ERC1967Proxy(vaultImpl, initData);
        vault = Vault(address(proxy));

        console.log("Vault proxy     :", address(vault));
        console.log("  name          :", vault.name());
        console.log("  symbol        :", vault.symbol());
        console.log("  asset         :", vault.asset());
        console.log("  owner         :", vault.owner());

        vm.stopBroadcast();

        // ── summary ───────────────────────────────────────────────────────
        console.log("---");
        console.log("Deployment complete.");
        console.log("  Token     :", address(token));
        console.log("  Vault impl:", vaultImpl);
        console.log("  Vault     :", address(vault));
    }

    // ── helpers ───────────────────────────────────────────────────────────

    /// @dev Returns the env var as a string, or `fallback` if not set / empty.
    function _envStringOr(string memory key, string memory fallback_) internal view returns (string memory) {
        try vm.envString(key) returns (string memory val) {
            if (bytes(val).length > 0) return val;
        } catch {}
        return fallback_;
    }

    /// @dev Returns the env var as a uint256, or `fallback` if not set.
    function _envUintOr(string memory key, uint256 fallback_) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 val) {
            return val;
        } catch {}
        return fallback_;
    }
}
