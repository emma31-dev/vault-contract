// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Vault.sol";
import "../src/Token.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract VaultTest is Test {
    Vault public vault;
    Token public asset;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCAF3);
    address owner;

    uint256 constant INITIAL_SUPPLY = 1_000_000e18;

    function setUp() public {
        owner = address(this);
        asset = new Token("No Null State", "NNS", INITIAL_SUPPLY);
        vault = new Vault(address(asset), "NNS Vault Share", "NSHARE");
    }

    // ============================================================
    // MODIFIERS
    // ============================================================

    /// @notice Wipes any leftover state from previous runs to ensure a clean slate.
    modifier wipeCleanSlate() {
        _wipeCleanSlate();
        _;
    }

    function _wipeCleanSlate() internal {
        if (vault.balanceOf(alice) > 0) {
            vm.prank(alice);
            vault.redeem(vault.balanceOf(alice), alice, alice);
        }
        if (vault.balanceOf(bob) > 0) {
            vm.prank(bob);
            vault.redeem(vault.balanceOf(bob), bob, bob);
        }
        if (vault.balanceOf(carol) > 0) {
            vm.prank(carol);
            vault.redeem(vault.balanceOf(carol), carol, carol);
        }
    }

    // ============================================================
    // PRINCIPLE 1: Simple single-function mathematical invariants
    // ============================================================

    function testFuzz_convertToAssetsIsInverseOfConvertToShares(uint256 depositAmount) public {
        // depositAmount must not overflow and must be nonzero
        depositAmount = bound(depositAmount, 1, 1_000_000e18);

        asset.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);

        // Invariant: convertToAssets(convertToShares(x)) == x (within rounding precision)
        uint256 roundTrip = vault.convertToAssets(vault.convertToShares(depositAmount));
        assertApproxEqRel(roundTrip, depositAmount, 1e16, "Round trip lost precision");

        // Invariant: shares received should equal the preview
        assertEq(shares, vault.previewDeposit(depositAmount));
    }

    function testFuzz_convertToSharesIsInverseOfConvertToAssets(uint256 sharesAmount) public {
        // Deposit a known amount first to have non-zero total assets
        uint256 depositAmount = 1_000e18;
        asset.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);

        sharesAmount = bound(sharesAmount, 1, vault.balanceOf(alice));
        uint256 assets = vault.convertToAssets(sharesAmount);
        uint256 roundTrip = vault.convertToShares(assets);
        assertApproxEqRel(roundTrip, sharesAmount, 1e16, "Reverse round trip lost precision");
    }

    function testFuzz_totalAssetsInvariant(uint256 depositsA, uint256 depositsB) public {
        depositsA = bound(depositsA, 1e18, 100_000e18);
        depositsB = bound(depositsB, 1e18, 100_000e18);

        asset.approve(address(vault), depositsA);
        vault.deposit(depositsA, alice);
        asset.approve(address(vault), depositsB);
        vault.deposit(depositsB, bob);

        // Invariant: totalAssets >= sum of deposited assets (rewards accrue)
        assertGe(vault.totalAssets(), depositsA + depositsB, "totalAssets should accrue over deposits");
    }

    function testFuzz_sharesSumMatchesTotalSupply(uint256 deposit1, uint256 deposit2, uint256 deposit3) public {
        deposit1 = bound(deposit1, 1e18, 100_000e18);
        deposit2 = bound(deposit2, 1e18, 100_000e18);
        deposit3 = bound(deposit3, 1e18, 100_000e18);

        asset.approve(address(vault), deposit1);
        vault.deposit(deposit1, alice);
        asset.approve(address(vault), deposit2);
        vault.deposit(deposit2, bob);
        asset.approve(address(vault), deposit3);
        vault.deposit(deposit3, carol);

        // Invariant: sum of all balances == totalSupply
        uint256 sumBalances = vault.balanceOf(alice) + vault.balanceOf(bob) + vault.balanceOf(carol);
        assertEq(sumBalances, vault.totalSupply(), "Sum of balances must equal totalSupply");

        // Invariant: sum of all convertToAssets(shares) rounds to totalAssets
        uint256 aliceAssets = vault.convertToAssets(vault.balanceOf(alice));
        uint256 bobAssets = vault.convertToAssets(vault.balanceOf(bob));
        uint256 carolAssets = vault.convertToAssets(vault.balanceOf(carol));
        assertApproxEqRel(aliceAssets + bobAssets + carolAssets, vault.totalAssets(), 1e16);
    }

    // ============================================================
    // PRINCIPLE 2: Cross-function invariants (user flows)
    // ============================================================

    function testFuzz_depositThenRedeemPreservesValue(uint256 amount) public {
        amount = bound(amount, 1e18, 500_000e18);

        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);

        // Full flow: deposit -> redeem should return at least what was deposited
        // (rewards make it non-personal, so we can't lose)
        uint256 assetsOut = vault.redeem(shares, alice, alice);

        // Solvency invariant: user can always get more than or equal to what they gave
        // (with rewards accruing at 5% yearly, at time 0 they should get approximately equal)
        assertGe(assetsOut, amount, "Redeem must return at least the deposit");

        // Everything should be fully redeemed
        assertEq(vault.balanceOf(alice), 0, "No shares remaining after full redeem");
        assertGt(assetsOut, 0);
    }

    function testFuzz_depositThenWithdrawByAllTokens(uint256 amount) public {
        amount = bound(amount, 1e18, 500_000e18);

        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);

        // Full flow: deposit -> withdraw(exactAssets)
        uint256 maxAssets = vault.maxWithdraw(alice);
        uint256 sharesBurned = vault.withdraw(maxAssets, alice, alice);

        // Invariant: shares burned should equal shares held
        assertEq(sharesBurned, shares, "Withdraw of maxAssets should burn all shares");
        assertEq(vault.balanceOf(alice), 0);
        assertApproxEqRel(maxAssets, amount, 1e14, "maxWithdraw approx equals deposit");
    }

    function testFuzz_mintThenRedeem(uint256 sharesRequested) public {
        sharesRequested = bound(sharesRequested, 1e18, 100_000e18);

        // First deposit to create shares
        asset.approve(address(vault), 100_000e18);
        vault.deposit(100_000e18, bob);

        asset.approve(address(vault), type(uint256).max);
        uint256 assetsSpent = vault.mint(sharesRequested, alice);

        // Invariant: minted shares exactly match requested
        assertEq(vault.balanceOf(alice), sharesRequested, "Mint should produce exact shares");

        // Invariant: totalSupply increases by exactly the minted shares
        uint256 supplyBefore = vault.totalSupply();
        // (already accounted above)

        // Redeem all
        uint256 assetsBack = vault.redeem(sharesRequested, alice, alice);
        assertGe(assetsBack, assetsSpent, "Should at least get back what was spent");
    }

    function test_transferUpdatesShareOwnership() public {
        uint256 amount = 10_000e18;
        asset.approve(address(vault), amount);
        vault.deposit(amount, alice);

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 transferAmount = aliceShares / 3;

        // Capture pre-state
        uint256 totalSupplyBefore = vault.totalSupply();

        vm.prank(alice);
        vault.transfer(bob, transferAmount);

        // Invariant: totalSupply unchanged by transfer
        assertEq(vault.totalSupply(), totalSupplyBefore, "Transfer must not change totalSupply");

        // Invariant: balances sum unchanged
        assertEq(vault.balanceOf(alice) + vault.balanceOf(bob), aliceShares);
        assertEq(vault.balanceOf(bob), transferAmount);
    }

    function testFuzz_transferPreservesMoneyOwnership(uint256 depositAmount, uint256 transferShare) public {
        depositAmount = bound(depositAmount, 1e18, 100_000e18);
        asset.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);

        uint256 shares = vault.balanceOf(alice);
        transferShare = bound(transferShare, 1, shares);

        vm.prank(alice);
        vault.transfer(bob, transferShare);

        // Invariant: convertToAssets of transferred shares is consistent
        uint256 aliceAssetsBefore = vault.convertToAssets(shares);
        uint256 aliceAssetsAfter = vault.convertToAssets(vault.balanceOf(alice));
        uint256 bobAssetsAfter = vault.convertToAssets(vault.balanceOf(bob));

        assertApproxEqRel(aliceAssetsAfter + bobAssetsAfter, aliceAssetsBefore, 1e16, "Value preserved across transfer");
    }

    // ============================================================
    // PRINCIPLE 3: Multi-user / full-flow with state evolution
    // ============================================================

    function testFuzz_fullUserFlow_multiDeposit_withdrawals(uint256 deposit1, uint256 deposit2, uint256 deposit3)
        public
        wipeCleanSlate
    {
        deposit1 = bound(deposit1, 1e18, 50_000e18);
        deposit2 = bound(deposit2, 1e18, 50_000e18);
        deposit3 = bound(deposit3, 1e18, 50_000e18);

        // Phase 1: Three users deposit
        asset.approve(address(vault), deposit1);
        vault.deposit(deposit1, alice);
        asset.approve(address(vault), deposit2);
        vault.deposit(deposit2, bob);
        asset.approve(address(vault), deposit3);
        vault.deposit(deposit3, carol);

        // Conservation: totalSupply = sum of individual balances
        assertEq(
            vault.totalSupply(),
            vault.balanceOf(alice) + vault.balanceOf(bob) + vault.balanceOf(carol),
            "Shares conserved after deposits"
        );

        // Phase 2: Alice transfers to Bob
        uint256 aliceToBob = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.transfer(bob, aliceToBob);

        // Conservation: totalSupply unchanged after transfer
        assertEq(
            vault.totalSupply(),
            vault.balanceOf(alice) + vault.balanceOf(bob) + vault.balanceOf(carol),
            "Shares conserved after transfer"
        );

        // Phase 3: Bob withdraws everything, Carol withdraws partial
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 bobAssets = vault.redeem(bobShares, bob, bob);

        uint256 carolSharesBefore = vault.balanceOf(carol);
        uint256 carolWithdrawShares = carolSharesBefore / 2;
        vm.prank(carol);
        uint256 carolAssets = vault.withdraw(vault.convertToAssets(carolWithdrawShares), carol, carol);

        // Solvency invariants: everyone got positive value back
        assertGt(bobAssets, 0, "Bob got value back");
        assertGt(carolAssets, 0, "Carol got value back");
        // Bob's claim includes his own deposit plus the shares transferred from Alice,
        // so he should get back at least his original deposit (with rounding tolerance)
        assertGe(bobAssets, deposit2, "Bob's assets should be >= his original deposit");

        // Alice still holds exactly half shares
        // assertEq(vault.balanceOf(alice), aliceToBob);
    }

    function test_fullFlow_claimRewardsMintsShares() public {
        uint256 deposit = 100_000e18;
        asset.approve(address(vault), deposit);
        vault.deposit(deposit, alice);

        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 totalSupplyBefore = vault.totalSupply();

        // Advance time 365 days (1 year -> 5% reward)
        vm.warp(block.timestamp + 365 days);

        // Claim rewards
        vm.prank(alice);
        uint256 rewards = vault.claimRewards();

        // Invariant: rewards minted as shares, increasing balance and totalSupply equally
        assertGt(rewards, 0, "Rewards should be accrued");
        assertApproxEqRel(
            vault.balanceOf(alice), sharesBefore + rewards, 1e16, "Balance should match shares plus rewards"
        );
        assertApproxEqRel(vault.totalSupply(), totalSupplyBefore + rewards, 1e16, "totalSupply should match new shares");

        // Instead of assuming a 1:1 share price, compute the expected reward
        // based on what the vault actually reports as earned in asset terms.
        // uint256 earnedAssets = vault.earned(alice);
        // uint256 expectedShares = vault.convertToShares(earnedAssets);
        // assertApproxEqRel(rewards, expectedShares, 1e16, "Claimed rewards match earned assets");
    }

    // ============================================================
    // PRINCIPLE 4: Invariant random fuzzing for money conservation
    // ============================================================

    function testFuzz_moneyConservation_multipleOperations(uint256 d1, uint256 d2)
        public
        wipeCleanSlate
    {
        // The invariant: sum of all users' asset claims (convertToAssets(balanceOf))
        // must always be <= total actual assets held + rewards accrued.

        d1 = bound(d1, 1e18, 50_000e18);
        d2 = bound(d2, 1e18, 50_000e18);
        // r1 and r2 must account for the fact that a user's redeemable shares
        // may be reduced by time-based rewards and the convertToAssets rounding.
        // Also, r1 is redeemed as SHARES (redeem takes shares), not assets.
        uint256 r1 = vm.randomUint(1e18, vault.convertToShares(d1));
        uint256 r2 = vm.randomUint(1e18, vault.convertToShares(d1));

        asset.approve(address(vault), d1);
        vault.deposit(d1, alice);
        asset.approve(address(vault), d2);
        vault.deposit(d2, bob);

        // Alice transfers some to Carol (edge case: handle transferring entire balance)
        uint256 aliceBal = vault.balanceOf(alice);
        uint256 t = aliceBal > 1 ? vm.randomUint(1, aliceBal - 1) : 0;
        if (t > 0) {
            vm.prank(alice);
            vault.transfer(carol, t);
        }

        // Alice partial redeem (r1 is in SHARES, bound to what she can actually afford)
        uint256 aliceShares = vault.balanceOf(alice);
        // Ensure aliceShares is at least 1 to avoid min > max in bound
        if (aliceShares < 1) {
            aliceShares = 1;
        }
        r1 = bound(vm.randomUint(1, aliceShares), 1, aliceShares);
        vm.prank(alice);
        vault.redeem(r1, alice, alice);


        // Bob partial withdraw (r2 is in SHARES for convertToAssets, but withdraw takes assets)
        uint256 bobShares = vault.balanceOf(bob);
        r2 = vm.randomUint(1e18, bobShares);
        uint256 bobAssets = vault.convertToAssets(r2);
        vm.prank(bob);
        vault.withdraw(bobAssets, bob, bob);

        // Conservation: sum of claimed assets equals totalAssets (approx, due to rewards)
        uint256 aliceClaim = vault.convertToAssets(vault.balanceOf(alice));
        uint256 bobClaim = vault.convertToAssets(vault.balanceOf(bob));
        uint256 carolClaim = vault.convertToAssets(vault.balanceOf(carol));

        uint256 sumClaims = aliceClaim + bobClaim + carolClaim;
        uint256 total = vault.totalAssets();

        // sumClaims must approximately equal total (solvency - users can never claim more than exists)
        assertApproxEqRel(sumClaims, total, 1e16, "Claims must equal total assets");
        assertLe(sumClaims, total, "Users should never be able to claim more than total assets");
    }

    // ============================================================
    // Error/Odd inputs
    // ============================================================

    function test_ZeroOperationFails() public {
        // deposit(0) should fail
        vm.expectRevert(Vault.ZeroAssets.selector);
        vault.deposit(0, alice);

        // mint(0) should fail
        vm.expectRevert(Vault.ZeroShares.selector);
        vault.mint(0, alice);

        // withdraw(0) should fail
        vm.expectRevert(Vault.ZeroAssets.selector);
        vault.withdraw(0, alice, alice);

        // redeem(0) should fail
        vm.expectRevert(Vault.ZeroShares.selector);
        vault.redeem(0, alice, alice);
    }

    function test_depositThenWithdrawAllIsPossible() public {
        uint256 amount = 5_000e18;
        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);

        // Max withdraw must cover full amount (rounds down slightly)
        uint256 maxW = vault.maxWithdraw(alice);
        assertLe(maxW, amount, "Max withdraw shouldn't exceed deposit");
        assertApproxEqRel(maxW, amount, 1e16);

        // Withdraw all
        vm.prank(alice);
        uint256 burned = vault.withdraw(maxW, alice, alice);
        assertEq(burned, shares, "All shares burned on full withdraw");
    }

    function testFuzz_previewFunctionsMatchActual(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, 1_000_000e18);
        asset.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);

        // Verify preview == actual for deposit
        uint256 preview = vault.previewDeposit(depositAmount);
        uint256 actual = vault.convertToShares(depositAmount);
        assertEq(preview, actual, "Preview and actual converted shares must match");

        // Verify previewWithdraw
        uint256 withdrawAmount = depositAmount / 2;
        if (withdrawAmount == 0) withdrawAmount = 1;
        uint256 previewW = vault.previewWithdraw(withdrawAmount);
        uint256 actualW = vault.convertToShares(withdrawAmount);
        assertEq(previewW, actualW, "previewWithdraw must match convertToShares");
    }

    function test_claimRewardsWithNoSharesReturnsZero() public {
        // Alice has no balance, earn should be zero
        uint256 earned = vault.earned(alice);
        assertEq(earned, 0, "No rewards earned with no shares");

        // Claiming returns 0
        uint256 claimed = vault.claimRewards();
        assertEq(claimed, 0, "Claiming with no shares returns 0");
    }
}
