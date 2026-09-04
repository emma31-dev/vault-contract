// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Token.sol";

contract TokenTest is Test {
    Token public token;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);
    address carol = address(0xCAF3);
    address owner;

    uint256 constant INITIAL_SUPPLY    = 1_000_000e18;
    uint256 constant FEE_DENOMINATOR   = 100;
    uint256 constant OWNER_FEE_SHARE   = 70;
    uint256 constant BLOCKS_PER_WINDOW = 57_600;
    uint256 constant MAX_MINT          = 1_000; // raw tokens, no decimals
    uint256 constant MAX_RECIPIENTS    = 100;

    // ---- helpers --------------------------------------------------------

    /// @dev Mirror of Token._calculateFee for assertion math.
    function _fee(uint256 amount)
        internal
        pure
        returns (uint256 fee, uint256 ownerShare, uint256 burnShare)
    {
        fee = amount / FEE_DENOMINATOR;
        ownerShare = (fee * OWNER_FEE_SHARE) / 100;
        burnShare  = fee - ownerShare;
    }

    // ---- setup ----------------------------------------------------------

    function setUp() public {
        owner = address(this);
        uint256 gasStart = gasleft();
        token = new Token("No Null State", "NNS", INITIAL_SUPPLY);
        emit log_named_uint("gasUsed_setUp_constructor", gasStart - gasleft());
    }

    // ---- baseline -------------------------------------------------------

    function test_noOp() public {}

    // ====================================================================
    // CONSTRUCTOR
    // ====================================================================

    function test_constructor_metadata() public view {
        assertEq(token.name(),     "No Null State");
        assertEq(token.symbol(),   "NNS");
        assertEq(token.decimals(), 18);
    }

    function test_constructor_initialSupplyMintedToDeployer() public view {
        assertEq(token.totalSupply(),    INITIAL_SUPPLY);
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY);
    }

    function test_constructor_deployerIsFeeExempt() public view {
        assertTrue(token.isFeeExempt(owner));
    }

    function test_constructor_ownerIsDeployer() public view {
        assertEq(token.owner(), owner);
    }

    // ====================================================================
    // ERC-20 BASICS
    // ====================================================================

    function test_transfer_basic() public {
        uint256 amount = 100e18;
        // owner is fee-exempt → recipient gets the full amount
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY - amount);
    }

    function test_approve_and_allowance() public {
        token.approve(alice, 500e18);
        assertEq(token.allowance(owner, alice), 500e18);
    }

    function test_transferFrom_decreasesAllowance() public {
        uint256 amount = 50e18;
        token.transfer(alice, 200e18);

        vm.prank(alice);
        token.approve(bob, amount);

        vm.prank(bob);
        token.transferFrom(alice, carol, amount);

        // alice→carol: neither is fee-exempt
        (, uint256 ownerShare,) = _fee(amount);
        assertEq(token.allowance(alice, bob), 0, "allowance fully consumed");
        // owner balance grew by the fee share
        assertGe(token.balanceOf(owner), INITIAL_SUPPLY - 200e18 + ownerShare);
    }

    function test_transferFrom_callerIsHolder_skipsAllowanceCheck() public {
        // New behaviour: if msg.sender == from, no allowance needed
        token.transfer(alice, 200e18);

        vm.prank(alice);
        token.transferFrom(alice, bob, 100e18);

        // alice is not exempt, bob is not exempt → fee applied
        (uint256 fee,,) = _fee(100e18);
        assertEq(token.balanceOf(bob), 100e18 - fee);
        assertEq(token.allowance(alice, alice), 0, "no allowance was set or consumed");
    }

    function test_transferFrom_infiniteAllowance_notDecremented() public {
        token.transfer(alice, 200e18);

        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, carol, 50e18);

        assertEq(token.allowance(alice, bob), type(uint256).max, "infinite allowance should not decrease");
    }

    function test_transfer_revertsOnInsufficientBalance() public {
        vm.prank(alice); // alice has 0 tokens
        vm.expectRevert(abi.encodeWithSelector(Token.InsufficientBalance.selector, 0, 1e18));
        token.transfer(bob, 1e18);
    }

    function test_transfer_revertsOnZeroAddressRecipient() public {
        vm.expectRevert(Token.ZeroAddress.selector);
        token.transfer(address(0), 1e18);
    }

    function test_transferFrom_revertsOnInsufficientAllowance() public {
        token.transfer(alice, 100e18);

        vm.prank(alice);
        token.approve(bob, 10e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Token.InsufficientAllowance.selector, 10e18, 50e18));
        token.transferFrom(alice, carol, 50e18);
    }

    // ====================================================================
    // FEE MECHANICS
    // ====================================================================

    function test_fee_appliedWhenNeitherPartyExempt() public {
        uint256 amount = 1_000e18;
        token.transfer(alice, amount); // owner→alice: owner exempt, no fee

        uint256 ownerBalBefore    = token.balanceOf(owner);
        uint256 totalSupplyBefore = token.totalSupply();

        vm.prank(alice);
        token.transfer(bob, amount);

        (uint256 fee, uint256 ownerShare, uint256 burnShare) = _fee(amount);

        assertEq(token.balanceOf(bob),   amount - fee,             "bob receives amount minus fee");
        assertEq(token.balanceOf(alice), 0,                         "alice fully spent");
        assertEq(token.balanceOf(owner), ownerBalBefore + ownerShare, "owner gets fee share");
        assertEq(token.totalSupply(),    totalSupplyBefore - burnShare, "burn reduces total supply");
    }

    function test_fee_notAppliedWhenSenderExempt() public {
        uint256 amount = 1_000e18;
        uint256 supplyBefore = token.totalSupply();

        token.transfer(alice, amount); // owner is exempt

        assertEq(token.balanceOf(alice), amount, "alice gets full amount");
        assertEq(token.totalSupply(), supplyBefore, "no supply change when sender exempt");
    }

    function test_fee_notAppliedWhenRecipientExempt() public {
        token.transfer(alice, 2_000e18);
        token.setFeeExempt(bob, true);

        uint256 aliceBal     = token.balanceOf(alice);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        token.transfer(bob, 1_000e18);

        assertEq(token.balanceOf(bob),   1_000e18,          "bob gets full amount when recipient exempt");
        assertEq(token.balanceOf(alice), aliceBal - 1_000e18);
        assertEq(token.totalSupply(),    supplyBefore,       "no burn when recipient exempt");
    }

    function test_fee_ownerShareAndBurnShareCorrect() public {
        uint256 amount = 10_000e18;
        token.transfer(alice, amount); // no fee (owner exempt)

        uint256 ownerBalBefore = token.balanceOf(owner);
        uint256 supplyBefore   = token.totalSupply();

        vm.prank(alice);
        token.transfer(bob, amount);

        (uint256 fee, uint256 ownerShare, uint256 burnShare) = _fee(amount);

        assertEq(fee,       100e18, "1% of 10_000e18");
        assertEq(ownerShare, 70e18, "70% of fee");
        assertEq(burnShare,  30e18, "30% of fee");

        assertEq(token.balanceOf(owner), ownerBalBefore + ownerShare);
        assertEq(token.totalSupply(),    supplyBefore   - burnShare);
        assertEq(token.balanceOf(bob),   amount - fee);
    }

    function testFuzz_fee_mathInvariant(uint256 amount) public {
        amount = bound(amount, 100, 1_000_000e18);
        token.transfer(alice, amount); // owner exempt, no fee on this leg

        uint256 ownerBalBefore = token.balanceOf(owner);
        uint256 supplyBefore   = token.totalSupply();

        vm.prank(alice);
        token.transfer(bob, amount);

        (uint256 fee, uint256 ownerShare, uint256 burnShare) = _fee(amount);

        assertEq(token.balanceOf(bob),   amount - fee);
        assertEq(token.balanceOf(owner), ownerBalBefore + ownerShare);
        assertEq(token.totalSupply(),    supplyBefore   - burnShare);
        // Conservation: recipient received + fee charged == original amount
        assertEq(token.balanceOf(bob) + fee, amount);
    }

    // ====================================================================
    // MINT
    // ====================================================================

    function test_mint_ownerCanMintWithinWindow() public {
        uint256 amount       = 500;
        uint256 supplyBefore = token.totalSupply();

        token.mint(alice, amount);

        assertEq(token.totalSupply(),    supplyBefore + amount);
        assertEq(token.balanceOf(alice), amount);
    }

    function test_mint_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.mint(alice, 100);
    }

    function test_mint_revertsOnZeroAddress() public {
        vm.expectRevert(Token.ZeroAddress.selector);
        token.mint(address(0), 100);
    }

    function test_mint_revertsOnZeroAmount() public {
        vm.expectRevert(Token.AmountTooLow.selector);
        token.mint(alice, 0);
    }

    function test_mint_revertsWhenWindowExceeded() public {
        token.mint(alice, MAX_MINT); // exhaust window

        vm.expectRevert(
            abi.encodeWithSelector(Token.MintRateExceeded.selector, MAX_MINT, MAX_MINT, 1)
        );
        token.mint(alice, 1);
    }

    function test_mint_windowResetsAfterBlocksPassed() public {
        token.mint(alice, MAX_MINT);

        vm.roll(block.number + BLOCKS_PER_WINDOW);

        token.mint(alice, MAX_MINT);
        assertEq(token.balanceOf(alice), MAX_MINT * 2);
    }

    function test_mint_partialWindowAllowance() public {
        token.mint(alice, 600);

        // 400 remaining — 401 should revert
        vm.expectRevert(
            abi.encodeWithSelector(Token.MintRateExceeded.selector, 600, MAX_MINT, 401)
        );
        token.mint(alice, 401);

        // exactly 400 should succeed
        token.mint(alice, 400);
        assertEq(token.balanceOf(alice), 1_000);
    }

    function test_mint_windowRollsExactlyAtBoundary() public {
        token.mint(alice, MAX_MINT);

        // one block before boundary — still the same window
        vm.roll(block.number + BLOCKS_PER_WINDOW - 1);
        vm.expectRevert();
        token.mint(alice, 1);

        // exactly at boundary — new window
        vm.roll(block.number + 1);
        token.mint(alice, 1);
        assertEq(token.balanceOf(alice), MAX_MINT + 1);
    }

    // ====================================================================
    // BURN
    // ====================================================================

    function test_burn_selfBurn() public {
        token.transfer(alice, 1_000e18);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        token.burn(alice, 500e18);

        assertEq(token.balanceOf(alice), 500e18);
        assertEq(token.totalSupply(),    supplyBefore - 500e18);
    }

    function test_burn_selfBurn_owner() public {
        uint256 supplyBefore = token.totalSupply();

        token.burn(owner, 1_000e18);

        assertEq(token.balanceOf(owner), INITIAL_SUPPLY - 1_000e18);
        assertEq(token.totalSupply(),    supplyBefore - 1_000e18);
    }

    function test_burn_approvedSpenderCanBurn() public {
        token.transfer(alice, 1_000e18);

        vm.prank(alice);
        token.approve(bob, 500e18);

        vm.prank(bob);
        token.burn(alice, 500e18);

        assertEq(token.balanceOf(alice),      500e18);
        assertEq(token.allowance(alice, bob), 0, "allowance consumed");
    }

    function test_burn_approvedSpenderInfiniteAllowanceNotDecremented() public {
        token.transfer(alice, 1_000e18);

        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.burn(alice, 500e18);

        assertEq(token.allowance(alice, bob), type(uint256).max, "infinite allowance unchanged");
    }

    function test_burn_ownerBurnsOtherAccount_requiresAllowance() public {
        // After the refactor, burn() only bypasses the allowance check when
        // from == msg.sender.  The owner has no special bypass anymore;
        // burning another address's tokens requires an explicit allowance.
        token.transfer(alice, 1_000e18);

        vm.expectRevert(
            abi.encodeWithSelector(Token.InsufficientAllowance.selector, 0, 500e18)
        );
        token.burn(alice, 500e18); // called by owner, but no allowance set
    }

    function test_burn_revertsWithInsufficientBalance() public {
        token.transfer(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Token.InsufficientBalance.selector, 100e18, 200e18));
        token.burn(alice, 200e18);
    }

    function test_burn_revertsWithInsufficientAllowance() public {
        token.transfer(alice, 1_000e18);

        vm.prank(alice);
        token.approve(bob, 10e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Token.InsufficientAllowance.selector, 10e18, 500e18));
        token.burn(alice, 500e18);
    }

    function test_burn_unapprovedThirdPartyReverts() public {
        token.transfer(alice, 1_000e18);

        vm.prank(carol); // carol has no allowance
        vm.expectRevert(abi.encodeWithSelector(Token.InsufficientAllowance.selector, 0, 100e18));
        token.burn(alice, 100e18);
    }

    // ====================================================================
    // SET FEE EXEMPT
    // ====================================================================

    function test_setFeeExempt_ownerCanExempt() public {
        assertFalse(token.isFeeExempt(alice));
        token.setFeeExempt(alice, true);
        assertTrue(token.isFeeExempt(alice));
    }

    function test_setFeeExempt_ownerCanRevoke() public {
        token.setFeeExempt(alice, true);
        token.setFeeExempt(alice, false);
        assertFalse(token.isFeeExempt(alice));
    }

    function test_setFeeExempt_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setFeeExempt(bob, true);
    }

    // ====================================================================
    // SET FEES (global kill-switch)
    // ====================================================================

    function test_setFees_ownerCanDisableFees() public {
        assertTrue(token.feesEnabled());
        token.setFees(false);
        assertFalse(token.feesEnabled());
    }

    function test_setFees_ownerCanReEnableFees() public {
        token.setFees(false);
        token.setFees(true);
        assertTrue(token.feesEnabled());
    }

    function test_setFees_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setFees(false);
    }

    function test_setFees_disabledMeansNoFeeOnAnyTransfer() public {
        token.setFees(false);
        uint256 amount = 1_000e18;
        token.transfer(alice, amount); // owner→alice, no fee anyway

        uint256 supplyBefore = token.totalSupply();
        uint256 ownerBal     = token.balanceOf(owner);

        vm.prank(alice);
        token.transfer(bob, amount); // fees disabled globally

        assertEq(token.balanceOf(bob),   amount, "bob gets full amount when fees disabled");
        assertEq(token.balanceOf(owner), ownerBal, "owner gets no fee share");
        assertEq(token.totalSupply(),    supplyBefore, "no burn when fees disabled");
    }

    function test_setFees_reenablingRestoresFeeOnTransfer() public {
        token.setFees(false);
        token.setFees(true);

        uint256 amount = 1_000e18;
        token.transfer(alice, amount);

        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        token.transfer(bob, amount);

        (uint256 fee,,uint256 burnShare) = _fee(amount);
        assertEq(token.balanceOf(bob), amount - fee, "fee applied after re-enable");
        assertEq(token.totalSupply(),  supplyBefore - burnShare);
    }

    // ====================================================================
    // INCREASE / DECREASE ALLOWANCE
    // ====================================================================

    function test_increaseAllowance_addsToExisting() public {
        token.approve(alice, 100e18);
        token.increaseAllowance(alice, 50e18);
        assertEq(token.allowance(owner, alice), 150e18);
    }

    function test_increaseAllowance_fromZero() public {
        token.increaseAllowance(alice, 200e18);
        assertEq(token.allowance(owner, alice), 200e18);
    }

    function test_increaseAllowance_revertsOnZeroAddress() public {
        vm.expectRevert(Token.ZeroAddress.selector);
        token.increaseAllowance(address(0), 100e18);
    }

    function test_decreaseAllowance_subtractsFromExisting() public {
        token.approve(alice, 200e18);
        token.decreaseAllowance(alice, 50e18);
        assertEq(token.allowance(owner, alice), 150e18);
    }

    function test_decreaseAllowance_toZero() public {
        token.approve(alice, 100e18);
        token.decreaseAllowance(alice, 100e18);
        assertEq(token.allowance(owner, alice), 0);
    }

    function test_decreaseAllowance_revertsOnUnderflow() public {
        token.approve(alice, 50e18);
        vm.expectRevert(Token.AllowanceUnderflow.selector);
        token.decreaseAllowance(alice, 100e18);
    }

    function test_decreaseAllowance_revertsOnZeroAddress() public {
        vm.expectRevert(Token.ZeroAddress.selector);
        token.decreaseAllowance(address(0), 50e18);
    }

    // ====================================================================
    // SPRAY
    // ====================================================================

    function test_spray_basic() public {
        uint256 amount = 100e18;
        address[] memory recipients = new address[](3);
        recipients[0] = alice;
        recipients[1] = bob;
        recipients[2] = carol;

        // owner is fee-exempt; each recipient gets exactly `amount`
        token.spray(recipients, amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(bob),   amount);
        assertEq(token.balanceOf(carol), amount);
    }

    function test_spray_senderExemptedDuringLoop_recipientsGetFullAmount() public {
        // spray() computes: totalDebit = (amount + fee) * count  (non-exempt sender)
        // The loop sends totalDebit/count = (amount + fee) per recipient.
        // Sender is exempted during the loop, so the full (amount + fee) lands with
        // each recipient and alice is left with exactly 0 (fully debited).
        uint256 amount = 100e18;
        uint256 count  = 3;

        (uint256 feePerTransfer,,) = _fee(amount);
        uint256 totalDebit       = (amount + feePerTransfer) * count;
        uint256 perRecipientGets = amount + feePerTransfer; // what each recipient actually receives

        token.transfer(alice, totalDebit); // fund exactly totalDebit
        assertEq(token.balanceOf(alice), totalDebit);

        address[] memory recipients = new address[](count);
        recipients[0] = address(0xDEEE1);
        recipients[1] = address(0xDEEE2);
        recipients[2] = address(0xDEEE3);

        vm.prank(alice);
        token.spray(recipients, amount);

        assertEq(token.balanceOf(alice), 0, "alice fully debited (totalDebit spent)");
        for (uint256 i = 0; i < count; i++) {
            assertEq(
                token.balanceOf(recipients[i]),
                perRecipientGets,
                "each recipient gets amount + fee (totalDebit/count, sender was exempt)"
            );
        }
    }

    function test_spray_revertsOnNoRecipients() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(Token.NoRecipients.selector);
        token.spray(empty, 100e18);
    }

    function test_spray_revertsOnTooManyRecipients() public {
        address[] memory recipients = new address[](MAX_RECIPIENTS + 1);
        for (uint256 i = 0; i < recipients.length; i++) {
            recipients[i] = address(uint160(i + 1));
        }
        vm.expectRevert(Token.TooManyRecipients.selector);
        token.spray(recipients, 1e18);
    }

    function test_spray_revertsOnZeroAddressInList() public {
        token.transfer(alice, 10_000e18);

        address[] memory recipients = new address[](2);
        recipients[0] = bob;
        recipients[1] = address(0);

        vm.prank(alice);
        vm.expectRevert(Token.ZeroAddress.selector);
        token.spray(recipients, 10e18);
    }

    function test_spray_revertsOnContractAddressInList() public {
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = address(token);

        vm.expectRevert(Token.CannotSendToContract.selector);
        token.spray(recipients, 10e18);
    }

    function test_spray_revertsOnInsufficientBalance() public {
        address[] memory recipients = new address[](1);
        recipients[0] = alice;

        vm.prank(bob); // bob has 0 tokens
        vm.expectRevert();
        token.spray(recipients, 1e18);
    }

    function test_spray_preservesSenderExemptionStatus() public {
        token.transfer(alice, 100_000e18);
        assertFalse(token.isFeeExempt(alice));

        address[] memory recipients = new address[](1);
        recipients[0] = bob;

        vm.prank(alice);
        token.spray(recipients, 10e18);

        assertFalse(token.isFeeExempt(alice), "alice exemption status must be restored");
    }

    function test_spray_preservesAlreadyExemptSender() public {
        // If sender was already exempt before spray, they should remain exempt after
        token.setFeeExempt(alice, true);
        token.transfer(alice, 100_000e18);

        address[] memory recipients = new address[](1);
        recipients[0] = bob;

        vm.prank(alice);
        token.spray(recipients, 10e18);

        assertTrue(token.isFeeExempt(alice), "pre-existing exemption should be preserved");
    }

    function test_spray_maxRecipients() public {
        uint256 amount = 1e18;
        // spray pre-check uses (amount + fee) * count to verify balance,
        // but actual debit is amount * count (sender is exempted during loop).
        // Fund with the pre-check figure to avoid InsufficientBalance revert.
        (uint256 feePerTransfer,,) = _fee(amount);
        uint256 totalNeeded = (amount + feePerTransfer) * MAX_RECIPIENTS;

        token.transfer(alice, totalNeeded);

        address[] memory recipients = new address[](MAX_RECIPIENTS);
        for (uint256 i = 0; i < MAX_RECIPIENTS; i++) {
            recipients[i] = address(uint160(0x1000 + i));
        }

        vm.prank(alice);
        token.spray(recipients, amount); // must not revert
    }

    // ====================================================================
    // SPRAY SPLIT
    // ====================================================================

    function test_spraySplit_basic() public {
        uint256 totalAmount = 300e18;
        address[] memory recipients = new address[](3);
        recipients[0] = alice;
        recipients[1] = bob;
        recipients[2] = carol;

        // owner is exempt; each recipient gets exactly perRecipient
        token.spraySplit(recipients, totalAmount);

        uint256 perRecipient = totalAmount / 3;
        assertEq(token.balanceOf(alice), perRecipient);
        assertEq(token.balanceOf(bob),   perRecipient);
        assertEq(token.balanceOf(carol), perRecipient);
    }

    function test_spraySplit_senderExemptedDuringLoop() public {
        // spraySplit() computes: totalDebit = (perRecipient + fee) * count (non-exempt sender)
        // The loop sends totalDebit/count = (perRecipient + fee) per recipient.
        // Sender is exempted, so full (perRecipient + fee) lands with each recipient
        // and alice is fully debited (balance → 0).
        uint256 totalAmount  = 300e18;
        uint256 count        = 3;
        uint256 perRecipient = totalAmount / count; // 100e18

        (uint256 feePerTransfer,,) = _fee(perRecipient);
        uint256 totalDebit       = (perRecipient + feePerTransfer) * count;
        uint256 perRecipientGets = perRecipient + feePerTransfer;

        token.transfer(alice, totalDebit); // fund exactly totalDebit
        assertEq(token.balanceOf(alice), totalDebit);

        address[] memory recipients = new address[](count);
        recipients[0] = address(0xEEEE1);
        recipients[1] = address(0xEEEE2);
        recipients[2] = address(0xEEEE3);

        vm.prank(alice);
        token.spraySplit(recipients, totalAmount);

        assertEq(token.balanceOf(alice), 0, "alice fully debited (totalDebit spent)");
        for (uint256 i = 0; i < count; i++) {
            assertEq(
                token.balanceOf(recipients[i]),
                perRecipientGets,
                "each recipient gets perRecipient + fee (totalDebit/count, sender was exempt)"
            );
        }
    }

    function test_spraySplit_revertsOnNoRecipients() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(Token.NoRecipients.selector);
        token.spraySplit(empty, 100e18);
    }

    function test_spraySplit_revertsOnTooManyRecipients() public {
        address[] memory recipients = new address[](MAX_RECIPIENTS + 1);
        for (uint256 i = 0; i < recipients.length; i++) {
            recipients[i] = address(uint160(i + 1));
        }
        vm.expectRevert(Token.TooManyRecipients.selector);
        token.spraySplit(recipients, 1e18);
    }

    function test_spraySplit_revertsWhenPerRecipientIsZero() public {
        // 1 wei split across 2 → 0 per recipient
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        vm.expectRevert(Token.AmountTooLow.selector);
        token.spraySplit(recipients, 1);
    }

    function test_spraySplit_revertsOnZeroAddressInList() public {
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = address(0);

        vm.expectRevert(Token.ZeroAddress.selector);
        token.spraySplit(recipients, 200e18);
    }

    function test_spraySplit_revertsOnContractAddressInList() public {
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = address(token);

        vm.expectRevert(Token.CannotSendToContract.selector);
        token.spraySplit(recipients, 200e18);
    }

    function test_spraySplit_revertsOnInsufficientBalance() public {
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;

        vm.prank(carol); // carol has 0 tokens
        vm.expectRevert();
        token.spraySplit(recipients, 100e18);
    }

    function test_spraySplit_preservesSenderExemptionStatus() public {
        token.transfer(alice, 100_000e18);
        assertFalse(token.isFeeExempt(alice));

        address[] memory recipients = new address[](2);
        recipients[0] = bob;
        recipients[1] = carol;

        vm.prank(alice);
        token.spraySplit(recipients, 20e18);

        assertFalse(token.isFeeExempt(alice), "alice exemption must be restored after spraySplit");
    }

    function test_spraySplit_truncationHandled() public {
        // 10e18 / 3 → 3.33...e18 truncated to 3333333333333333333
        // Remaining dust stays with the sender (not distributed)
        uint256 totalAmount = 10e18;
        uint256 count       = 3;

        address[] memory recipients = new address[](count);
        recipients[0] = alice;
        recipients[1] = bob;
        recipients[2] = carol;

        token.spraySplit(recipients, totalAmount);

        uint256 perRecipient = totalAmount / count;
        assertEq(token.balanceOf(alice), perRecipient);
        assertEq(token.balanceOf(bob),   perRecipient);
        assertEq(token.balanceOf(carol), perRecipient);
    }

    // ====================================================================
    // FUZZ
    // ====================================================================

    function testFuzz_transferPreservesTotalSupplyWhenExempt(uint256 amount) public {
        amount = bound(amount, 1, INITIAL_SUPPLY);
        uint256 supplyBefore = token.totalSupply();

        token.transfer(alice, amount); // owner is exempt

        assertEq(token.totalSupply(), supplyBefore, "total supply unchanged when sender exempt");
    }

    function testFuzz_burnReducesSupply(uint256 amount) public {
        amount = bound(amount, 1, INITIAL_SUPPLY);
        uint256 supplyBefore = token.totalSupply();

        token.burn(owner, amount); // self-burn, no allowance needed

        assertEq(token.totalSupply(), supplyBefore - amount);
    }

    function testFuzz_mintRateRespected(uint256 amount) public {
        amount = bound(amount, 1, MAX_MINT);
        uint256 supplyBefore = token.totalSupply();

        token.mint(alice, amount);

        assertEq(token.totalSupply(),    supplyBefore + amount);
        assertEq(token.balanceOf(alice), amount);
    }

    function testFuzz_fee_conservationInvariant(uint256 amount) public {
        amount = bound(amount, FEE_DENOMINATOR, 1_000_000e18);
        token.transfer(alice, amount); // owner exempt leg

        uint256 supplyBefore   = token.totalSupply();
        uint256 ownerBalBefore = token.balanceOf(owner);

        vm.prank(alice);
        token.transfer(bob, amount);

        (uint256 fee, uint256 ownerShare, uint256 burnShare) = _fee(amount);

        // bob received the net amount
        assertEq(token.balanceOf(bob), amount - fee);
        // owner received its share
        assertEq(token.balanceOf(owner), ownerBalBefore + ownerShare);
        // supply reduced by burn share only
        assertEq(token.totalSupply(), supplyBefore - burnShare);
        // no tokens created or lost beyond the burn
        assertEq(token.balanceOf(bob) + ownerShare + burnShare, amount);
    }

    function testFuzz_sprayEqualDistribution(uint8 recipientCount, uint256 amount) public {
        recipientCount = uint8(bound(recipientCount, 1, MAX_RECIPIENTS));
        amount = bound(amount, 100e18, 10_000e18);

        // spray pre-check: requires (amount + fee) * count balance
        (uint256 feePerTransfer,,) = _fee(amount);
        uint256 totalNeeded = (amount + feePerTransfer) * recipientCount;
        vm.assume(totalNeeded <= INITIAL_SUPPLY / 2);

        address[] memory recipients = new address[](recipientCount);
        for (uint256 i = 0; i < recipientCount; i++) {
            recipients[i] = address(uint160(0x5000 + i));
        }

        // owner is already fee-exempt; sender exemption during loop means each
        // recipient gets the full `amount` regardless
        token.spray(recipients, amount);

        for (uint256 i = 0; i < recipientCount; i++) {
            assertEq(token.balanceOf(recipients[i]), amount, "each recipient gets exact amount");
        }
    }
}
