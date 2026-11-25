// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// OpenZeppelin Contracts v5
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TrustFlowEscrow is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --------------------------------------------------
    // CONSTANTS
    // --------------------------------------------------

    uint256 public constant MAX_FEE_BPS = 1_500;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    uint256 public constant MAX_WORK_DURATION = 30 days;
    uint256 public constant REVIEW_PERIOD = 2 days;
    uint256 public constant REVISION_PERIOD = 2 days;
    uint256 public constant DISPUTE_RESOLUTION_PERIOD = 7 days;

    // --------------------------------------------------
    // STATE
    // --------------------------------------------------

    IERC20 public immutable usdc;
    address public immutable agentWallet;
    address public immutable resolver;
    address public immutable treasury;
    uint16 public immutable feeBps;

    uint256 public nextTaskId = 1;

    enum Status {
        None,
        Created,
        Funded,
        Submitted,
        RevisionRequested,
        Resubmitted,
        Disputed,
        Completed,
        Resolved,
        Refunded,
        Cancelled
    }

    struct Task {
        address customer;
        address provider;
        uint128 amount;
        uint16 taskFeeBps;

        bytes32 briefHash;
        bytes32 deliverableHash;
        bytes32 evidenceHash;
        bytes32 disputeReasonHash;

        uint64 createdAt;
        uint64 workDeadline;
        uint64 reviewDeadline;
        uint64 revisionDeadline;
        uint64 disputeResolutionDeadline;

        Status status;
    }

    mapping(uint256 => Task) private tasks;

    mapping(address => uint256) public claimable;

    // --------------------------------------------------
    // ERRORS
    // --------------------------------------------------

    error ZeroAddress();
    error InvalidToken();
    error InvalidAmount();
    error InvalidFee();
    error InvalidHash();
    error InvalidDeadline();
    error InvalidTask();
    error Unauthorized();
    error InvalidStatus();
    error DeadlinePassed();
    error DeadlineNotPassed();
    error IncorrectTokenReceived();
    error InsufficientEscrowAmount();
    error NothingToClaim();
    error DisputeWindowClosed();

    // --------------------------------------------------
    // EVENTS
    // --------------------------------------------------

    event TaskCreated(
        uint256 indexed taskId, address indexed customer, address indexed provider, uint256 amount, bytes32 briefHash
    );

    event TaskFunded(uint256 indexed taskId, address indexed customer, uint256 amount);

    event DeliverableSubmitted(uint256 indexed taskId, bytes32 deliverableHash, bytes32 evidenceHash, bool isRevision);

    event RevisionRequested(uint256 indexed taskId, bytes32 reasonHash, uint64 revisionDeadline);

    event DisputeOpened(uint256 indexed taskId, bytes32 reasonHash, uint64 resolutionDeadline);

    event TaskSettled(
        uint256 indexed taskId,
        Status finalStatus,
        uint256 providerGross,
        uint256 providerNet,
        uint256 platformFee,
        uint256 customerRefund
    );

    event RefundIssued(uint256 indexed taskId, uint256 amount);
    event FundsClaimed(address indexed account, uint256 amount);

    // --------------------------------------------------
    // CONSTRUCTOR
    // --------------------------------------------------

    constructor(address _usdc, address _agentWallet, address _resolver, address _treasury, uint16 _feeBps)
        Ownable(msg.sender)
    {
        if (_usdc == address(0) || _agentWallet == address(0) || _resolver == address(0) || _treasury == address(0)) {
            revert ZeroAddress();
        }

        // Ensure USDC address contains contract code.
        if (_usdc.code.length == 0) revert InvalidToken();

        if (_feeBps > MAX_FEE_BPS) revert InvalidFee();

        usdc = IERC20(_usdc);
        agentWallet = _agentWallet;
        resolver = _resolver;
        treasury = _treasury;
        feeBps = _feeBps;
    }

    // --------------------------------------------------
    // TASK CREATION
    // --------------------------------------------------

    function createTask(uint128 _amount, bytes32 _briefHash, uint64 _workDeadline)
        external
        whenNotPaused
        returns (uint256 taskId)
    {
        if (_amount == 0) revert InvalidAmount();
        if (_briefHash == bytes32(0)) revert InvalidHash();

        if (_workDeadline <= block.timestamp || _workDeadline > block.timestamp + MAX_WORK_DURATION) {
            revert InvalidDeadline();
        }

        taskId = nextTaskId++;

        Task storage task = tasks[taskId];

        task.customer = msg.sender;
        task.provider = agentWallet;
        task.amount = _amount;
        task.taskFeeBps = feeBps;
        task.briefHash = _briefHash;
        task.createdAt = uint64(block.timestamp);
        task.workDeadline = _workDeadline;
        task.status = Status.Created;

        emit TaskCreated(taskId, msg.sender, agentWallet, _amount, _briefHash);
    }

    // --------------------------------------------------
    // FUND TASK
    // --------------------------------------------------

    function fundTask(uint256 _taskId) external whenNotPaused nonReentrant {
        Task storage task = tasks[_taskId];

        if (task.customer == address(0)) revert InvalidTask();
        if (msg.sender != task.customer) revert Unauthorized();
        if (task.status != Status.Created) revert InvalidStatus();
        if (block.timestamp > task.workDeadline) revert DeadlinePassed();

        uint256 balanceBefore = usdc.balanceOf(address(this));

        usdc.safeTransferFrom(msg.sender, address(this), task.amount);

        uint256 balanceAfter = usdc.balanceOf(address(this));

        if (balanceAfter < balanceBefore || balanceAfter - balanceBefore != task.amount) {
            revert IncorrectTokenReceived();
        }

        task.status = Status.Funded;

        emit TaskFunded(_taskId, msg.sender, task.amount);
    }

    // --------------------------------------------------
    // SUBMIT DELIVERABLE
    // --------------------------------------------------

    function submitDeliverable(uint256 _taskId, bytes32 _deliverableHash, bytes32 _evidenceHash) external {
        Task storage task = tasks[_taskId];

        if (task.customer == address(0)) revert InvalidTask();
        if (msg.sender != task.provider) revert Unauthorized();
        if (task.status != Status.Funded) revert InvalidStatus();
        if (block.timestamp > task.workDeadline) revert DeadlinePassed();

        if (_deliverableHash == bytes32(0) || _evidenceHash == bytes32(0)) {
            revert InvalidHash();
        }

        task.deliverableHash = _deliverableHash;
        task.evidenceHash = _evidenceHash;
        task.reviewDeadline = uint64(block.timestamp + REVIEW_PERIOD);
        task.status = Status.Submitted;

        emit DeliverableSubmitted(_taskId, _deliverableHash, _evidenceHash, false);
    }

    // --------------------------------------------------
    // REQUEST ONE REVISION
    // --------------------------------------------------

    function requestRevision(uint256 _taskId, bytes32 _reasonHash) external {
        Task storage task = tasks[_taskId];

        if (task.customer == address(0)) revert InvalidTask();
        if (msg.sender != task.customer) revert Unauthorized();

        if (task.status != Status.Submitted) revert InvalidStatus();
        if (block.timestamp > task.reviewDeadline) revert DeadlinePassed();
        if (_reasonHash == bytes32(0)) revert InvalidHash();

        task.revisionDeadline = uint64(block.timestamp + REVISION_PERIOD);
        task.status = Status.RevisionRequested;

        emit RevisionRequested(_taskId, _reasonHash, task.revisionDeadline);
    }

    // --------------------------------------------------
    // RESUBMIT DELIVERABLE
    // --------------------------------------------------

    function resubmitDeliverable(uint256 _taskId, bytes32 _deliverableHash, bytes32 _evidenceHash) external {
        Task storage task = tasks[_taskId];

        if (task.customer == address(0)) revert InvalidTask();
        if (msg.sender != task.provider) revert Unauthorized();
        if (task.status != Status.RevisionRequested) revert InvalidStatus();

        if (block.timestamp > task.revisionDeadline) {
            revert DeadlinePassed();
        }

        if (_deliverableHash == bytes32(0) || _evidenceHash == bytes32(0)) {
            revert InvalidHash();
        }

        task.deliverableHash = _deliverableHash;
        task.evidenceHash = _evidenceHash;
        task.reviewDeadline = uint64(block.timestamp + REVIEW_PERIOD);
        task.status = Status.Resubmitted;

        emit DeliverableSubmitted(_taskId, _deliverableHash, _evidenceHash, true);
    }

    // --------------------------------------------------
    // CUSTOMER APPROVAL
    // --------------------------------------------------

    function approveTask(uint256 _taskId) external {
        Task storage task = tasks[_taskId];

        if (task.customer == address(0)) revert InvalidTask();
        if (msg.sender != task.customer) revert Unauthorized();

        if (task.status != Status.Submitted && task.status != Status.Resubmitted) {
            revert InvalidStatus();
        }

        if (block.timestamp > task.reviewDeadline) {
            revert DeadlinePassed();
        }

        _settle(_taskId, task.amount, Status.Completed);
    }

    // --------------------------------------------------
    // OPEN DISPUTE
    // --------------------------------------------------

    function openDispute(uint256 _taskId, bytes32 _reasonHash) external {
        Task storage task = tasks[_taskId];

        if (task.customer == address(0)) revert InvalidTask();
        if (msg.sender != task.customer) revert Unauthorized();

        if (task.status != Status.Submitted && task.status != Status.Resubmitted) {
            revert InvalidStatus();
        }

        if (block.timestamp > task.reviewDeadline) {
            revert DeadlinePassed();
        }

        if (_reasonHash == bytes32(0)) revert InvalidHash();

        task.disputeReasonHash = _reasonHash;
        task.disputeResolutionDeadline = uint64(block.timestamp + DISPUTE_RESOLUTION_PERIOD);

        task.status = Status.Disputed;

        emit DisputeOpened(_taskId, _reasonHash, task.disputeResolutionDeadline);
    }

    // --------------------------------------------------
    // RESOLVE DISPUTE
    // --------------------------------------------------

    function resolveDispute(uint256 _taskId, uint128 _providerGross) external {
        Task storage task = tasks[_taskId];

        if (task.customer == address(0)) revert InvalidTask();
        if (msg.sender != resolver) revert Unauthorized();
        if (task.status != Status.Disputed) revert InvalidStatus();

        if (block.timestamp > task.disputeResolutionDeadline) {
            revert DisputeWindowClosed();
        }

        if (_providerGross > task.amount) {
            revert InsufficientEscrowAmount();
        }

        _settle(_taskId, _providerGross, Status.Resolved);
    }

    // --------------------------------------------------
    // TIMEOUT AND CANCELLATION
    // --------------------------------------------------

    function claimWorkTimeoutRefund(uint256 _taskId) external {
        Task storage task = tasks[_taskId];

        if (task.customer == address(0)) revert InvalidTask();
        if (msg.sender != task.customer) revert Unauthorized();

        bool workExpired = task.status == Status.Funded && block.timestamp > task.workDeadline;

        bool revisionExpired = task.status == Status.RevisionRequested && block.timestamp > task.revisionDeadline;

        if (!workExpired && !revisionExpired) {
            revert DeadlineNotPassed();
        }

        task.status = Status.Refunded;
        claimable[task.customer] += task.amount;

        emit RefundIssued(_taskId, task.amount);
    }

    function finalizeReviewTimeout(uint256 _taskId) external {
        Task storage task = tasks[_taskId];

        if (task.customer == address(0)) revert InvalidTask();

        if (task.status != Status.Submitted && task.status != Status.Resubmitted) {
            revert InvalidStatus();
        }

        if (block.timestamp <= task.reviewDeadline) {
            revert DeadlineNotPassed();
        }

        _settle(_taskId, task.amount, Status.Completed);
    }

    function claimDisputeTimeoutRefund(uint256 _taskId) external {
        Task storage task = tasks[_taskId];

        if (task.customer == address(0)) revert InvalidTask();
        if (task.status != Status.Disputed) revert InvalidStatus();

        if (block.timestamp <= task.disputeResolutionDeadline) {
            revert DeadlineNotPassed();
        }

        task.status = Status.Refunded;
        claimable[task.customer] += task.amount;

        emit RefundIssued(_taskId, task.amount);
    }

    function cancelUnfundedTask(uint256 _taskId) external {
        Task storage task = tasks[_taskId];

        if (task.customer == address(0)) revert InvalidTask();
        if (msg.sender != task.customer) revert Unauthorized();
        if (task.status != Status.Created) revert InvalidStatus();

        task.status = Status.Cancelled;
    }

    // --------------------------------------------------
    // INTERNAL SETTLEMENT
    // --------------------------------------------------

    function _settle(uint256 _taskId, uint256 _providerGross, Status _finalStatus) internal {
        Task storage task = tasks[_taskId];

        uint256 platformFee = (_providerGross * task.taskFeeBps) / BPS_DENOMINATOR;

        uint256 providerNet = _providerGross - platformFee;
        uint256 customerRefund = task.amount - _providerGross;

        task.status = _finalStatus;

        if (providerNet > 0) {
            claimable[task.provider] += providerNet;
        }

        if (platformFee > 0) {
            claimable[treasury] += platformFee;
        }

        if (customerRefund > 0) {
            claimable[task.customer] += customerRefund;
        }

        emit TaskSettled(_taskId, _finalStatus, _providerGross, providerNet, platformFee, customerRefund);
    }

    // --------------------------------------------------
    // CLAIM FUNDS
    // --------------------------------------------------

    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];

        if (amount == 0) revert NothingToClaim();

        claimable[msg.sender] = 0;

        usdc.safeTransfer(msg.sender, amount);

        emit FundsClaimed(msg.sender, amount);
    }

    // --------------------------------------------------
    // EMERGENCY PAUSE
    // --------------------------------------------------

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --------------------------------------------------
    // FRONTEND GETTERS
    // --------------------------------------------------

    function getTaskCore(uint256 _taskId)
        external
        view
        returns (address customer, address provider, uint128 amount, uint16 taskFeeBps, Status status)
    {
        Task storage task = tasks[_taskId];

        if (task.customer == address(0)) revert InvalidTask();

        return (task.customer, task.provider, task.amount, task.taskFeeBps, task.status);
    }

    function getTaskHashes(uint256 _taskId)
        external
        view
        returns (bytes32 briefHash, bytes32 deliverableHash, bytes32 evidenceHash, bytes32 disputeReasonHash)
    {
        Task storage task = tasks[_taskId];

        if (task.customer == address(0)) revert InvalidTask();

        return (task.briefHash, task.deliverableHash, task.evidenceHash, task.disputeReasonHash);
    }

    function getTaskDeadlines(uint256 _taskId)
        external
        view
        returns (uint64 createdAt, uint64 workDeadline, uint64 reviewDeadline)
    {
        Task storage task = tasks[_taskId];

        if (task.customer == address(0)) revert InvalidTask();

        return (task.createdAt, task.workDeadline, task.reviewDeadline);
    }

    function getTaskResolutionInfo(uint256 _taskId)
        external
        view
        returns (uint64 revisionDeadline, uint64 disputeResolutionDeadline)
    {
        Task storage task = tasks[_taskId];

        if (task.customer == address(0)) revert InvalidTask();

        return (task.revisionDeadline, task.disputeResolutionDeadline);
    }
}
