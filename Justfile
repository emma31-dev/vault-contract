# Load .env automatically if it exists
set dotenv-load := true

# ── defaults ──────────────────────────────────────────────────────────────────
rpc_url    := env("RPC_URL",     "http://127.0.0.1:8545")
private_key := env("PRIVATE_KEY", "")

# ── help (default) ────────────────────────────────────────────────────────────
[private]
default:
    @just --list

# ── build ─────────────────────────────────────────────────────────────────────

# Compile all contracts
build:
    forge build

# ── test ──────────────────────────────────────────────────────────────────────

# Run full test suite
test:
    forge test -v

# Run only Token tests
test-token:
    forge test --match-path test/Token.t.sol -v

# Run only Vault tests
test-vault:
    forge test --match-path test/Vault.t.sol -v

# ── deploy ────────────────────────────────────────────────────────────────────

# Dry-run deployment (no broadcast, no on-chain state)
dry-run:
    forge script script/Deploy.s.sol:Deploy \
        --rpc-url "{{ rpc_url }}" \
        --private-key "{{ private_key }}"

# Deploy to local anvil node (http://127.0.0.1:8545)
deploy-local:
    forge script script/Deploy.s.sol:Deploy \
        --rpc-url "{{ rpc_url }}" \
        --private-key "{{ private_key }}" \
        --broadcast

# Deploy to a remote network and verify on Etherscan
# Requires ETHERSCAN_API_KEY in env
deploy:
    forge script script/Deploy.s.sol:Deploy \
        --rpc-url "{{ rpc_url }}" \
        --private-key "{{ private_key }}" \
        --broadcast \
        --verify

# ── local node ────────────────────────────────────────────────────────────────

# Start a local anvil node (runs in foreground — use a separate terminal)
anvil:
    anvil

# ── utilities ─────────────────────────────────────────────────────────────────

# Format all Solidity files
fmt:
    forge fmt

# Generate gas snapshots
snapshot:
    forge snapshot

# Clean build artifacts
clean:
    forge clean
