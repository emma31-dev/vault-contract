# Vault Contract

An ERC-20 token with a 1% transfer fee and an ERC-4626 upgradeable vault built on top of it.

## Contracts

### Token (`NNS`)
A self-contained ERC-20 with:
- **1% transfer fee:** 70% to the owner, 30% permanently burned
- **Fee exemptions:** owner-controlled per-address exemption list and a global kill-switch (`setFees`)
- **Rate-limited minting:** max 1,000 tokens per 24-hour block window (~57,600 blocks)
- **`spray` / `spraySplit`:** batch-distribute tokens to up to 100 recipients in a single transaction
- `increaseAllowance` / `decreaseAllowance` for safe allowance management

### Vault (`NSHARE`)
An upgradeable ERC-4626 vault (behind an ERC-1967 proxy) that accepts `NNS` as the underlying asset:
- Block-based reward accrual (`~7.716e15` shares per block)
- `claimRewards()` mints accrued reward shares directly to the depositor
- Owner-controlled `mint()` with a rate limit of 1,000e18 shares per day

---

## Deployments — Polygon Mainnet

| Contract | Address |
|---|---|
| Token (`NNS`) | [`0x34ced970f392852ad92A3Cb729B7e1f7e96a4Ca2`](https://polygonscan.com/address/0x34ced970f392852ad92A3Cb729B7e1f7e96a4Ca2) |
| Vault proxy (`NSHARE`) | [`0xcEc82EFeB7049c0Db621221Fe2c2B8Bf9B645001`](https://polygonscan.com/address/0xcEc82EFeB7049c0Db621221Fe2c2B8Bf9B645001) |
| Vault implementation | [`0x77fd0E4Cfe6E95F0F8fc014E0a501f93DA096B08`](https://polygonscan.com/address/0x77fd0E4Cfe6E95F0F8fc014E0a501f93DA096B08) |

---

## Issues & Contributions

Found a bug or want to request a feature? [Open an issue](../../issues/new) in this repository.

Please include:
- A clear description of the problem or request
- Steps to reproduce (for bugs)
- Relevant contract addresses or transaction hashes if applicable

---

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [just](https://just.systems/man/en/packages.html) (Optional)

### Setup

```shell
git clone https://github.com/emma31-dev/vault-contract.git
cd vault-contract
cp .env.example .env   # fill in PRIVATE_KEY and RPC_URL
forge install
```

### Build

```shell
just build
# or
forge build
```

### Test

```shell
just test              # full suite
just test-token        # Token tests only
just test-vault        # Vault tests only
```

### Deploy

```shell
# local anvil
just anvil             # separate terminal
just deploy-local

# remote network (reads RPC_URL and PRIVATE_KEY from .env)
just deploy

# dry-run (no broadcast)
just dry-run
```

### Other

```shell
just fmt               # format Solidity
just snapshot          # gas snapshots
just clean             # remove build artifacts
```

---

Built with [Foundry](https://book.getfoundry.sh/).
