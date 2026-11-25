// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TrustFlowAiScript} from "../script/TrustFlowAi.s.sol";
import {TrustFlowEscrow} from "../src/TrustFlowai.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract FeeOnTransferMockUSDC is MockUSDC {
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, _msgSender(), amount);
        _transfer(from, to, amount);
        _burn(to, amount / 100);
        return true;
    }
}

contract DrainingMockUSDC is MockUSDC {
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, _msgSender(), amount);
        _transfer(from, to, amount);
        _burn(to, balanceOf(to));
        return true;
    }
}

contract TrustFlowEscrowTest is Test {
    uint128 private constant TASK_AMOUNT = 1_000e6;
    uint256 private constant INITIAL_BALANCE = 10_000e6;
    uint16 private constant FEE_BPS = 500;

    MockUSDC private usdc;
    TrustFlowEscrow private trustFlow;

    address private customer = makeAddr("customer");
    address private provider = makeAddr("provider");
    address private resolver = makeAddr("resolver");
    address private treasury = makeAddr("treasury");

    uint256 private taskId;
    uint64 private workDeadline;

    function setUp() public {
        usdc = new MockUSDC();
        trustFlow = new TrustFlowEscrow(address(usdc), provider, resolver, treasury, FEE_BPS);

        usdc.mint(customer, INITIAL_BALANCE);
        workDeadline = uint64(block.timestamp + 1 days);

        vm.startPrank(customer);
        usdc.approve(address(trustFlow), TASK_AMOUNT);
        taskId = trustFlow.createTask(TASK_AMOUNT, keccak256("task brief"), workDeadline);
        trustFlow.fundTask(taskId);
        vm.stopPrank();
    }

    function testApproveTaskSplitsProviderPaymentAndFee() public {
        _submit();

        vm.prank(customer);
        trustFlow.approveTask(taskId);

        assertEq(trustFlow.claimable(provider), 950e6);
        assertEq(trustFlow.claimable(treasury), 50e6);

        vm.prank(provider);
        trustFlow.claim();
        vm.prank(treasury);
        trustFlow.claim();

        assertEq(usdc.balanceOf(provider), 950e6);
        assertEq(usdc.balanceOf(treasury), 50e6);
    }

    function testCustomerCanRequestOneRevisionAndApproveResubmission() public {
        _submit();

        vm.prank(customer);
        trustFlow.requestRevision(taskId, keccak256("revision reason"));
        vm.prank(provider);
        trustFlow.resubmitDeliverable(taskId, keccak256("updated work"), keccak256("new evidence"));
        vm.prank(customer);
        trustFlow.approveTask(taskId);

        assertEq(trustFlow.claimable(provider), 950e6);
        assertEq(trustFlow.claimable(treasury), 50e6);
    }

    function testResolverCanSplitDisputeSettlement() public {
        _submit();
        vm.prank(customer);
        trustFlow.openDispute(taskId, keccak256("reason"));

        vm.prank(resolver);
        trustFlow.resolveDispute(taskId, 400e6);

        assertEq(trustFlow.claimable(provider), 380e6);
        assertEq(trustFlow.claimable(treasury), 20e6);
        assertEq(trustFlow.claimable(customer), 600e6);
    }

    function testResolverCanRefundCustomerFromDispute() public {
        _submit();
        vm.prank(customer);
        trustFlow.openDispute(taskId, keccak256("reason"));

        vm.prank(resolver);
        trustFlow.resolveDispute(taskId, 0);

        assertEq(trustFlow.claimable(customer), TASK_AMOUNT);

        vm.prank(customer);
        trustFlow.claim();

        assertEq(usdc.balanceOf(customer), INITIAL_BALANCE);
    }

    function testCustomerCanClaimRefundAfterWorkDeadline() public {
        vm.warp(uint256(workDeadline) + 1);
        vm.prank(customer);
        trustFlow.claimWorkTimeoutRefund(taskId);

        assertEq(trustFlow.claimable(customer), TASK_AMOUNT);
    }

    function testReviewTimeoutPaysProviderAndTreasury() public {
        _submit();
        vm.warp(block.timestamp + trustFlow.REVIEW_PERIOD() + 1);

        trustFlow.finalizeReviewTimeout(taskId);

        assertEq(trustFlow.claimable(provider), 950e6);
        assertEq(trustFlow.claimable(treasury), 50e6);
    }

    function testDisputeTimeoutRefundsCustomer() public {
        _submit();
        vm.prank(customer);
        trustFlow.openDispute(taskId, keccak256("reason"));
        vm.warp(block.timestamp + trustFlow.DISPUTE_RESOLUTION_PERIOD() + 1);

        trustFlow.claimDisputeTimeoutRefund(taskId);

        assertEq(trustFlow.claimable(customer), TASK_AMOUNT);
    }

    function testCustomerCanCancelUnfundedTask() public {
        vm.prank(customer);
        uint256 unfundedTaskId = trustFlow.createTask(TASK_AMOUNT, keccak256("another brief"), workDeadline);

        vm.prank(customer);
        trustFlow.cancelUnfundedTask(unfundedTaskId);
    }

    function testOnlyConfiguredProviderCanSubmitDeliverable() public {
        vm.expectRevert(TrustFlowEscrow.Unauthorized.selector);
        vm.prank(customer);
        trustFlow.submitDeliverable(taskId, keccak256("deliverable"), keccak256("evidence"));
    }

    function testProviderCannotClaimBeforeCustomerApproval() public {
        _submit();
        assertEq(trustFlow.claimable(provider), 0);
    }

    function testOnlyResolverCanResolveDispute() public {
        _submit();
        vm.prank(customer);
        trustFlow.openDispute(taskId, keccak256("reason"));

        vm.expectRevert(TrustFlowEscrow.Unauthorized.selector);
        vm.prank(customer);
        trustFlow.resolveDispute(taskId, 0);
    }

    function testConstructorRejectsEachZeroAddress() public {
        vm.expectRevert(TrustFlowEscrow.ZeroAddress.selector);
        new TrustFlowEscrow(address(0), provider, resolver, treasury, FEE_BPS);

        vm.expectRevert(TrustFlowEscrow.ZeroAddress.selector);
        new TrustFlowEscrow(address(usdc), address(0), resolver, treasury, FEE_BPS);

        vm.expectRevert(TrustFlowEscrow.ZeroAddress.selector);
        new TrustFlowEscrow(address(usdc), provider, address(0), treasury, FEE_BPS);

        vm.expectRevert(TrustFlowEscrow.ZeroAddress.selector);
        new TrustFlowEscrow(address(usdc), provider, resolver, address(0), FEE_BPS);
    }

    function testConstructorRejectsFeeAboveMaximum() public {
        vm.expectRevert(TrustFlowEscrow.InvalidFee.selector);
        new TrustFlowEscrow(address(usdc), provider, resolver, treasury, 1_501);
    }

    function testConstructorRejectsAddressWithoutTokenCode() public {
        vm.expectRevert(TrustFlowEscrow.InvalidToken.selector);
        new TrustFlowEscrow(address(0x1234), provider, resolver, treasury, FEE_BPS);
    }

    function testCreateTaskRejectsZeroAmountAndHash() public {
        vm.startPrank(customer);

        vm.expectRevert(TrustFlowEscrow.InvalidAmount.selector);
        trustFlow.createTask(0, keccak256("brief"), workDeadline);

        vm.expectRevert(TrustFlowEscrow.InvalidHash.selector);
        trustFlow.createTask(TASK_AMOUNT, bytes32(0), workDeadline);

        vm.stopPrank();
    }

    function testCreateTaskRejectsExpiredAndOverlongDeadlines() public {
        vm.startPrank(customer);

        vm.expectRevert(TrustFlowEscrow.InvalidDeadline.selector);
        trustFlow.createTask(TASK_AMOUNT, keccak256("brief"), uint64(block.timestamp));

        vm.expectRevert(TrustFlowEscrow.InvalidDeadline.selector);
        trustFlow.createTask(TASK_AMOUNT, keccak256("brief"), uint64(block.timestamp + 31 days));

        vm.stopPrank();
    }

    function testCreateTaskIsBlockedWhilePaused() public {
        trustFlow.pause();

        vm.expectRevert();
        vm.prank(customer);
        trustFlow.createTask(TASK_AMOUNT, keccak256("brief"), workDeadline);
    }

    function testFundingRejectsUnknownTaskWrongCustomerWrongStatusAndExpiredDeadline() public {
        vm.expectRevert(TrustFlowEscrow.InvalidTask.selector);
        vm.prank(customer);
        trustFlow.fundTask(999);

        vm.expectRevert(TrustFlowEscrow.Unauthorized.selector);
        vm.prank(provider);
        trustFlow.fundTask(taskId);

        vm.expectRevert(TrustFlowEscrow.InvalidStatus.selector);
        vm.prank(customer);
        trustFlow.fundTask(taskId);

        uint256 unfundedTaskId = _createUnfundedTask();
        vm.warp(uint256(workDeadline) + 1);
        vm.expectRevert(TrustFlowEscrow.DeadlinePassed.selector);
        vm.prank(customer);
        trustFlow.fundTask(unfundedTaskId);
    }

    function testFundingRejectsFeeOnTransferToken() public {
        FeeOnTransferMockUSDC feeToken = new FeeOnTransferMockUSDC();
        TrustFlowEscrow feeTokenEscrow = new TrustFlowEscrow(address(feeToken), provider, resolver, treasury, FEE_BPS);
        feeToken.mint(customer, TASK_AMOUNT);

        vm.startPrank(customer);
        feeToken.approve(address(feeTokenEscrow), TASK_AMOUNT);
        uint256 feeTokenTask = feeTokenEscrow.createTask(TASK_AMOUNT, keccak256("brief"), workDeadline);
        vm.expectRevert(TrustFlowEscrow.IncorrectTokenReceived.selector);
        feeTokenEscrow.fundTask(feeTokenTask);
        vm.stopPrank();
    }

    function testFundingRejectsTokenThatReducesEscrowBalance() public {
        DrainingMockUSDC drainingToken = new DrainingMockUSDC();
        TrustFlowEscrow drainingEscrow =
            new TrustFlowEscrow(address(drainingToken), provider, resolver, treasury, FEE_BPS);
        drainingToken.mint(customer, TASK_AMOUNT);
        drainingToken.mint(address(drainingEscrow), 10);

        vm.startPrank(customer);
        drainingToken.approve(address(drainingEscrow), TASK_AMOUNT);
        uint256 drainingTask = drainingEscrow.createTask(TASK_AMOUNT, keccak256("brief"), workDeadline);
        vm.expectRevert(TrustFlowEscrow.IncorrectTokenReceived.selector);
        drainingEscrow.fundTask(drainingTask);
        vm.stopPrank();
    }

    function testSubmitDeliverableRejectsUnknownTaskInvalidStatusDeadlineAndEmptyHashes() public {
        vm.expectRevert(TrustFlowEscrow.InvalidTask.selector);
        vm.prank(provider);
        trustFlow.submitDeliverable(999, keccak256("work"), keccak256("evidence"));

        uint256 unfundedTaskId = _createUnfundedTask();
        vm.expectRevert(TrustFlowEscrow.InvalidStatus.selector);
        vm.prank(provider);
        trustFlow.submitDeliverable(unfundedTaskId, keccak256("work"), keccak256("evidence"));

        uint256 expiredTaskId = _createFundedTask();
        vm.warp(uint256(workDeadline) + 1);
        vm.expectRevert(TrustFlowEscrow.DeadlinePassed.selector);
        vm.prank(provider);
        trustFlow.submitDeliverable(expiredTaskId, keccak256("work"), keccak256("evidence"));

        vm.warp(block.timestamp - 1 days - 1);
        vm.expectRevert(TrustFlowEscrow.InvalidHash.selector);
        vm.prank(provider);
        trustFlow.submitDeliverable(taskId, bytes32(0), keccak256("evidence"));

        vm.expectRevert(TrustFlowEscrow.InvalidHash.selector);
        vm.prank(provider);
        trustFlow.submitDeliverable(taskId, keccak256("work"), bytes32(0));
    }

    function testRevisionRequestRejectsUnknownTaskWrongUserWrongStatusExpiredWindowAndEmptyReason() public {
        vm.expectRevert(TrustFlowEscrow.InvalidTask.selector);
        vm.prank(customer);
        trustFlow.requestRevision(999, keccak256("reason"));

        vm.expectRevert(TrustFlowEscrow.Unauthorized.selector);
        vm.prank(provider);
        trustFlow.requestRevision(taskId, keccak256("reason"));

        vm.expectRevert(TrustFlowEscrow.InvalidStatus.selector);
        vm.prank(customer);
        trustFlow.requestRevision(taskId, keccak256("reason"));

        _submit();
        vm.warp(block.timestamp + trustFlow.REVIEW_PERIOD() + 1);
        vm.expectRevert(TrustFlowEscrow.DeadlinePassed.selector);
        vm.prank(customer);
        trustFlow.requestRevision(taskId, keccak256("reason"));
    }

    function testRevisionRequestRejectsEmptyReasonAndSecondRevision() public {
        _submit();

        vm.expectRevert(TrustFlowEscrow.InvalidHash.selector);
        vm.prank(customer);
        trustFlow.requestRevision(taskId, bytes32(0));

        vm.prank(customer);
        trustFlow.requestRevision(taskId, keccak256("reason"));
        vm.prank(provider);
        trustFlow.resubmitDeliverable(taskId, keccak256("updated"), keccak256("evidence"));

        vm.expectRevert(TrustFlowEscrow.InvalidStatus.selector);
        vm.prank(customer);
        trustFlow.requestRevision(taskId, keccak256("another revision"));
    }

    function testResubmissionRejectsUnknownTaskUnauthorizedStatusDeadlineAndEmptyHashes() public {
        vm.expectRevert(TrustFlowEscrow.InvalidTask.selector);
        vm.prank(provider);
        trustFlow.resubmitDeliverable(999, keccak256("work"), keccak256("evidence"));

        _submit();
        vm.expectRevert(TrustFlowEscrow.InvalidStatus.selector);
        vm.prank(provider);
        trustFlow.resubmitDeliverable(taskId, keccak256("work"), keccak256("evidence"));

        vm.prank(customer);
        trustFlow.requestRevision(taskId, keccak256("reason"));

        vm.expectRevert(TrustFlowEscrow.Unauthorized.selector);
        vm.prank(customer);
        trustFlow.resubmitDeliverable(taskId, keccak256("work"), keccak256("evidence"));

        vm.warp(block.timestamp + trustFlow.REVISION_PERIOD() + 1);
        vm.expectRevert(TrustFlowEscrow.DeadlinePassed.selector);
        vm.prank(provider);
        trustFlow.resubmitDeliverable(taskId, keccak256("work"), keccak256("evidence"));
    }

    function testResubmissionRejectsEmptyDeliverableOrEvidenceHash() public {
        _submit();
        vm.prank(customer);
        trustFlow.requestRevision(taskId, keccak256("reason"));

        vm.expectRevert(TrustFlowEscrow.InvalidHash.selector);
        vm.prank(provider);
        trustFlow.resubmitDeliverable(taskId, bytes32(0), keccak256("evidence"));

        vm.expectRevert(TrustFlowEscrow.InvalidHash.selector);
        vm.prank(provider);
        trustFlow.resubmitDeliverable(taskId, keccak256("work"), bytes32(0));
    }

    function testApprovalRejectsUnknownTaskWrongUserInvalidStatusAndExpiredReview() public {
        vm.expectRevert(TrustFlowEscrow.InvalidTask.selector);
        vm.prank(customer);
        trustFlow.approveTask(999);

        vm.expectRevert(TrustFlowEscrow.Unauthorized.selector);
        vm.prank(provider);
        trustFlow.approveTask(taskId);

        vm.expectRevert(TrustFlowEscrow.InvalidStatus.selector);
        vm.prank(customer);
        trustFlow.approveTask(taskId);

        _submit();
        vm.warp(block.timestamp + trustFlow.REVIEW_PERIOD() + 1);
        vm.expectRevert(TrustFlowEscrow.DeadlinePassed.selector);
        vm.prank(customer);
        trustFlow.approveTask(taskId);
    }

    function testDisputeOpeningRejectsUnknownTaskWrongUserInvalidStatusAndExpiredReview() public {
        vm.expectRevert(TrustFlowEscrow.InvalidTask.selector);
        vm.prank(customer);
        trustFlow.openDispute(999, keccak256("reason"));

        vm.expectRevert(TrustFlowEscrow.Unauthorized.selector);
        vm.prank(provider);
        trustFlow.openDispute(taskId, keccak256("reason"));

        vm.expectRevert(TrustFlowEscrow.InvalidStatus.selector);
        vm.prank(customer);
        trustFlow.openDispute(taskId, keccak256("reason"));

        _submit();
        vm.warp(block.timestamp + trustFlow.REVIEW_PERIOD() + 1);
        vm.expectRevert(TrustFlowEscrow.DeadlinePassed.selector);
        vm.prank(customer);
        trustFlow.openDispute(taskId, keccak256("reason"));
    }

    function testDisputeOpeningRejectsEmptyReasonAndSupportsResubmittedWork() public {
        _submit();
        vm.expectRevert(TrustFlowEscrow.InvalidHash.selector);
        vm.prank(customer);
        trustFlow.openDispute(taskId, bytes32(0));

        vm.prank(customer);
        trustFlow.requestRevision(taskId, keccak256("revision"));
        vm.prank(provider);
        trustFlow.resubmitDeliverable(taskId, keccak256("updated"), keccak256("evidence"));
        vm.prank(customer);
        trustFlow.openDispute(taskId, keccak256("reason"));
    }

    function testDisputeResolutionRejectsUnknownTaskInvalidStatusClosedWindowAndExcessAmount() public {
        vm.expectRevert(TrustFlowEscrow.InvalidTask.selector);
        vm.prank(resolver);
        trustFlow.resolveDispute(999, 0);

        vm.expectRevert(TrustFlowEscrow.InvalidStatus.selector);
        vm.prank(resolver);
        trustFlow.resolveDispute(taskId, 0);

        _submit();
        vm.prank(customer);
        trustFlow.openDispute(taskId, keccak256("reason"));

        vm.expectRevert(TrustFlowEscrow.InsufficientEscrowAmount.selector);
        vm.prank(resolver);
        trustFlow.resolveDispute(taskId, TASK_AMOUNT + 1);

        vm.warp(block.timestamp + trustFlow.DISPUTE_RESOLUTION_PERIOD() + 1);
        vm.expectRevert(TrustFlowEscrow.DisputeWindowClosed.selector);
        vm.prank(resolver);
        trustFlow.resolveDispute(taskId, 0);
    }

    function testWorkTimeoutRefundRejectsUnknownTaskWrongUserAndUnexpiredTask() public {
        vm.expectRevert(TrustFlowEscrow.InvalidTask.selector);
        vm.prank(customer);
        trustFlow.claimWorkTimeoutRefund(999);

        vm.expectRevert(TrustFlowEscrow.Unauthorized.selector);
        vm.prank(provider);
        trustFlow.claimWorkTimeoutRefund(taskId);

        vm.expectRevert(TrustFlowEscrow.DeadlineNotPassed.selector);
        vm.prank(customer);
        trustFlow.claimWorkTimeoutRefund(taskId);
    }

    function testRevisionTimeoutRefundsCustomer() public {
        _submit();
        vm.prank(customer);
        trustFlow.requestRevision(taskId, keccak256("revision"));
        vm.warp(block.timestamp + trustFlow.REVISION_PERIOD() + 1);

        vm.prank(customer);
        trustFlow.claimWorkTimeoutRefund(taskId);

        assertEq(trustFlow.claimable(customer), TASK_AMOUNT);
    }

    function testReviewTimeoutRejectsUnknownTaskInvalidStatusAndEarlyFinalization() public {
        vm.expectRevert(TrustFlowEscrow.InvalidTask.selector);
        trustFlow.finalizeReviewTimeout(999);

        vm.expectRevert(TrustFlowEscrow.InvalidStatus.selector);
        trustFlow.finalizeReviewTimeout(taskId);

        _submit();
        vm.expectRevert(TrustFlowEscrow.DeadlineNotPassed.selector);
        trustFlow.finalizeReviewTimeout(taskId);
    }

    function testReviewTimeoutCanFinalizeResubmittedWork() public {
        _submit();
        vm.prank(customer);
        trustFlow.requestRevision(taskId, keccak256("revision"));
        vm.prank(provider);
        trustFlow.resubmitDeliverable(taskId, keccak256("updated"), keccak256("evidence"));
        vm.warp(block.timestamp + trustFlow.REVIEW_PERIOD() + 1);

        trustFlow.finalizeReviewTimeout(taskId);

        assertEq(trustFlow.claimable(provider), 950e6);
    }

    function testDisputeTimeoutRejectsUnknownTaskInvalidStatusAndEarlyClaim() public {
        vm.expectRevert(TrustFlowEscrow.InvalidTask.selector);
        trustFlow.claimDisputeTimeoutRefund(999);

        vm.expectRevert(TrustFlowEscrow.InvalidStatus.selector);
        trustFlow.claimDisputeTimeoutRefund(taskId);

        _submit();
        vm.prank(customer);
        trustFlow.openDispute(taskId, keccak256("reason"));

        vm.expectRevert(TrustFlowEscrow.DeadlineNotPassed.selector);
        trustFlow.claimDisputeTimeoutRefund(taskId);
    }

    function testUnfundedCancellationRejectsUnknownTaskWrongUserAndInvalidStatus() public {
        vm.expectRevert(TrustFlowEscrow.InvalidTask.selector);
        trustFlow.cancelUnfundedTask(999);

        vm.expectRevert(TrustFlowEscrow.Unauthorized.selector);
        vm.prank(provider);
        trustFlow.cancelUnfundedTask(taskId);

        vm.expectRevert(TrustFlowEscrow.InvalidStatus.selector);
        vm.prank(customer);
        trustFlow.cancelUnfundedTask(taskId);
    }

    function testClaimRejectsWhenNothingIsOwed() public {
        vm.expectRevert(TrustFlowEscrow.NothingToClaim.selector);
        trustFlow.claim();
    }

    function testOwnerCanPauseAndUnpauseAndNonOwnerCannot() public {
        vm.expectRevert();
        vm.prank(customer);
        trustFlow.pause();

        trustFlow.pause();
        assertTrue(trustFlow.paused());
        vm.expectRevert();
        vm.prank(customer);
        trustFlow.unpause();

        trustFlow.unpause();
        assertFalse(trustFlow.paused());
    }

    function testSettlementSkipsZeroProviderFeeAndRefundClaims() public {
        TrustFlowEscrow zeroFeeEscrow = new TrustFlowEscrow(address(usdc), provider, resolver, treasury, 0);

        vm.startPrank(customer);
        usdc.approve(address(zeroFeeEscrow), TASK_AMOUNT);
        uint256 zeroFeeTask = zeroFeeEscrow.createTask(TASK_AMOUNT, keccak256("zero fee task"), workDeadline);
        zeroFeeEscrow.fundTask(zeroFeeTask);
        vm.stopPrank();

        vm.prank(provider);
        zeroFeeEscrow.submitDeliverable(zeroFeeTask, keccak256("work"), keccak256("evidence"));
        vm.prank(customer);
        zeroFeeEscrow.approveTask(zeroFeeTask);

        assertEq(zeroFeeEscrow.claimable(provider), TASK_AMOUNT);
        assertEq(zeroFeeEscrow.claimable(treasury), 0);
        assertEq(zeroFeeEscrow.claimable(customer), 0);
    }

    function testZeroProviderGrossSkipsProviderAndFeeClaims() public {
        _submit();
        vm.prank(customer);
        trustFlow.openDispute(taskId, keccak256("reason"));
        vm.prank(resolver);
        trustFlow.resolveDispute(taskId, 0);

        assertEq(trustFlow.claimable(provider), 0);
        assertEq(trustFlow.claimable(treasury), 0);
        assertEq(trustFlow.claimable(customer), TASK_AMOUNT);
    }

    function testFrontendGettersReturnTaskDetailsAndHashes() public {
        (
            address storedCustomer,
            address storedProvider,
            uint128 amount,
            uint16 taskFeeBps,
            TrustFlowEscrow.Status status
        ) = trustFlow.getTaskCore(taskId);

        assertEq(storedCustomer, customer);
        assertEq(storedProvider, provider);
        assertEq(amount, TASK_AMOUNT);
        assertEq(taskFeeBps, FEE_BPS);
        assertEq(uint256(status), uint256(TrustFlowEscrow.Status.Funded));

        (bytes32 briefHash, bytes32 deliverableHash, bytes32 evidenceHash, bytes32 reasonHash) =
            trustFlow.getTaskHashes(taskId);
        assertEq(briefHash, keccak256("task brief"));
        assertEq(deliverableHash, bytes32(0));
        assertEq(evidenceHash, bytes32(0));
        assertEq(reasonHash, bytes32(0));

        _submit();
        vm.prank(customer);
        trustFlow.openDispute(taskId, keccak256("dispute reason"));

        (briefHash, deliverableHash, evidenceHash, reasonHash) = trustFlow.getTaskHashes(taskId);
        assertEq(briefHash, keccak256("task brief"));
        assertEq(deliverableHash, keccak256("deliverable"));
        assertEq(evidenceHash, keccak256("evidence"));
        assertEq(reasonHash, keccak256("dispute reason"));

        (,,,, status) = trustFlow.getTaskCore(taskId);
        assertEq(uint256(status), uint256(TrustFlowEscrow.Status.Disputed));
    }

    function testFrontendDeadlineGettersTrackTaskProgress() public {
        (uint64 createdAt, uint64 storedWorkDeadline, uint64 reviewDeadline) = trustFlow.getTaskDeadlines(taskId);
        assertEq(createdAt, uint64(block.timestamp));
        assertEq(storedWorkDeadline, workDeadline);
        assertEq(reviewDeadline, 0);

        (uint64 revisionDeadline, uint64 disputeDeadline) = trustFlow.getTaskResolutionInfo(taskId);
        assertEq(revisionDeadline, 0);
        assertEq(disputeDeadline, 0);

        _submit();
        (,, reviewDeadline) = trustFlow.getTaskDeadlines(taskId);
        assertEq(reviewDeadline, uint64(block.timestamp + trustFlow.REVIEW_PERIOD()));

        vm.prank(customer);
        trustFlow.requestRevision(taskId, keccak256("revision reason"));
        (revisionDeadline,) = trustFlow.getTaskResolutionInfo(taskId);
        assertEq(revisionDeadline, uint64(block.timestamp + trustFlow.REVISION_PERIOD()));

        vm.prank(provider);
        trustFlow.resubmitDeliverable(taskId, keccak256("updated work"), keccak256("updated evidence"));
        vm.prank(customer);
        trustFlow.openDispute(taskId, keccak256("dispute reason"));
        (, disputeDeadline) = trustFlow.getTaskResolutionInfo(taskId);
        assertEq(disputeDeadline, uint64(block.timestamp + trustFlow.DISPUTE_RESOLUTION_PERIOD()));
    }

    function testFrontendGettersRejectUnknownTask() public {
        vm.expectRevert(TrustFlowEscrow.InvalidTask.selector);
        trustFlow.getTaskCore(999);

        vm.expectRevert(TrustFlowEscrow.InvalidTask.selector);
        trustFlow.getTaskHashes(999);

        vm.expectRevert(TrustFlowEscrow.InvalidTask.selector);
        trustFlow.getTaskDeadlines(999);

        vm.expectRevert(TrustFlowEscrow.InvalidTask.selector);
        trustFlow.getTaskResolutionInfo(999);
    }

    function _createUnfundedTask() private returns (uint256 createdTaskId) {
        vm.prank(customer);
        createdTaskId = trustFlow.createTask(TASK_AMOUNT, keccak256("unfunded task"), workDeadline);
    }

    function _createFundedTask() private returns (uint256 fundedTaskId) {
        usdc.mint(customer, TASK_AMOUNT);
        vm.startPrank(customer);
        usdc.approve(address(trustFlow), TASK_AMOUNT);
        fundedTaskId = trustFlow.createTask(TASK_AMOUNT, keccak256("funded task"), workDeadline);
        trustFlow.fundTask(fundedTaskId);
        vm.stopPrank();
    }

    function _submit() private {
        vm.prank(provider);
        trustFlow.submitDeliverable(taskId, keccak256("deliverable"), keccak256("evidence"));
    }
}

contract TrustFlowAiScriptTest is Test {
    function testDeploymentScriptSuccessAndFeeValidation() public {
        MockUSDC testToken = new MockUSDC();

        vm.setEnv("FEE_BPS", "500");
        vm.setEnv("USDC_ADDRESS", vm.toString(address(testToken)));
        vm.setEnv("AGENT_WALLET", "0x0000000000000000000000000000000000000002");
        vm.setEnv("RESOLVER_ADDRESS", "0x0000000000000000000000000000000000000003");
        vm.setEnv("TREASURY_ADDRESS", "0x0000000000000000000000000000000000000004");
        assertEq(vm.envUint("FEE_BPS"), 500);

        TrustFlowAiScript deployScript = new TrustFlowAiScript();
        deployScript.run();

        TrustFlowEscrow deployed = deployScript.trustFlowEscrow();
        assertEq(deployed.feeBps(), 500);
        assertEq(deployed.agentWallet(), 0x0000000000000000000000000000000000000002);

        vm.setEnv("FEE_BPS", "1501");
        try deployScript.run() {
            fail("Deployment should reject a fee above the maximum");
        } catch Error(string memory reason) {
            assertEq(reason, "Fee exceeds maximum");
        }
    }
}
