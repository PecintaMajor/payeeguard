// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "./IERC20.sol";
import {PayeeRegistry} from "./PayeeRegistry.sol";

/// @title InvoiceBook — tUSD8 invoice lifecycle with Confirmation-of-Payee payment guards.
/// @notice Invoices are created against a registered payee, then paid exactly once.
/// Payment pulls tUSD8 from the invoice's payer via transferFrom and sends it directly
/// to the payee's registry-bound payout address. Payment is only possible while the
/// payee is VERIFIED in the PayeeRegistry — this is the Confirmation-of-Payee guard.
/// Payments happen either directly by the payer (payInvoice) or through the authorised
/// AgentMandate contract (payInvoiceOnBehalf), never by anyone else.
contract InvoiceBook {
    enum Status {
        Issued,
        Paid,
        Cancelled
    }

    struct Invoice {
        uint256 payeeId;
        address payer;
        uint256 amount; // tUSD8 atomic units (6 decimals)
        string invoiceRef; // e.g. "INV-0142"
        uint256 dueDate; // unix timestamp; 0 = due immediately
        bytes32 memoHash;
        Status status;
        uint256 paidAt;
        address executor; // who executed the payment (payer or agent)
    }

    IERC20 public immutable token;
    PayeeRegistry public immutable registry;

    address public owner;
    /// @notice The only contract allowed to call payInvoiceOnBehalf (the AgentMandate).
    address public mandateContract;

    uint256 public nextInvoiceId = 1;
    mapping(uint256 => Invoice) private _invoices;

    event InvoiceCreated(
        uint256 indexed invoiceId, uint256 indexed payeeId, address indexed payer, uint256 amount, string invoiceRef, uint256 dueDate
    );
    event InvoicePaid(
        uint256 indexed invoiceId, uint256 indexed payeeId, address payer, address payoutAddress, uint256 amount, address executor
    );
    event InvoiceCancelled(uint256 indexed invoiceId);
    event MandateContractSet(address indexed mandateContract);

    error NotOwner();
    error NotPayer();
    error NotMandateContract();
    error PayeeNotRegistered(uint256 payeeId);
    error PayeeNotVerified(uint256 payeeId);
    error InvalidAmount();
    error InvoiceNotFound(uint256 invoiceId);
    error InvoiceNotIssued(uint256 invoiceId, Status status);
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address registry_, address token_) {
        owner = msg.sender;
        registry = PayeeRegistry(registry_);
        token = IERC20(token_);
    }

    /// @notice Wire the AgentMandate contract (one-time setup by the book owner).
    function setMandateContract(address mandateContract_) external onlyOwner {
        mandateContract = mandateContract_;
        emit MandateContractSet(mandateContract_);
    }

    /// @notice Create an invoice payable to a registered payee. The creator becomes the
    /// payer. The payee does NOT need to be verified at creation time — verification is
    /// enforced at payment time, so an invoice to a not-yet-verified payee simply cannot
    /// be paid until verification lands (the agent runner holds it and reports why).
    function createInvoice(uint256 payeeId, uint256 amount, string calldata invoiceRef, uint256 dueDate, bytes32 memoHash)
        external
        returns (uint256 invoiceId)
    {
        if (!registry.payeeExists(payeeId)) revert PayeeNotRegistered(payeeId);
        if (amount == 0) revert InvalidAmount();

        invoiceId = nextInvoiceId++;
        _invoices[invoiceId] = Invoice({
            payeeId: payeeId,
            payer: msg.sender,
            amount: amount,
            invoiceRef: invoiceRef,
            dueDate: dueDate,
            memoHash: memoHash,
            status: Status.Issued,
            paidAt: 0,
            executor: address(0)
        });

        emit InvoiceCreated(invoiceId, payeeId, msg.sender, amount, invoiceRef, dueDate);
    }

    /// @notice Cancel an open invoice. Only the payer, only while Issued.
    function cancelInvoice(uint256 invoiceId) external {
        Invoice storage inv = _mustExist(invoiceId);
        if (msg.sender != inv.payer) revert NotPayer();
        if (inv.status != Status.Issued) revert InvoiceNotIssued(invoiceId, inv.status);
        inv.status = Status.Cancelled;
        emit InvoiceCancelled(invoiceId);
    }

    /// @notice Pay an invoice directly as its payer.
    function payInvoice(uint256 invoiceId) external {
        Invoice storage inv = _mustExist(invoiceId);
        if (msg.sender != inv.payer) revert NotPayer();
        _pay(invoiceId, inv, msg.sender);
    }

    /// @notice Pay an invoice with funds from `payer`, executed by `executor` (the agent).
    /// Only callable by the authorised AgentMandate contract, which enforces the mandate
    /// scope (cap, budget, expiry, revocation, allowlist) atomically in the same
    /// transaction before calling this.
    function payInvoiceOnBehalf(uint256 invoiceId, address payer, address executor) external {
        if (msg.sender != mandateContract) revert NotMandateContract();
        Invoice storage inv = _mustExist(invoiceId);
        if (inv.payer != payer) revert NotPayer();
        _pay(invoiceId, inv, executor);
    }

    function _pay(uint256 invoiceId, Invoice storage inv, address executor) internal {
        if (inv.status != Status.Issued) revert InvoiceNotIssued(invoiceId, inv.status);
        if (!registry.isVerified(inv.payeeId)) revert PayeeNotVerified(inv.payeeId);
        address payout = registry.payoutOf(inv.payeeId);

        // Effects before interaction (anti-double-pay): mark Paid first.
        inv.status = Status.Paid;
        inv.paidAt = block.timestamp;
        inv.executor = executor;

        bool ok = token.transferFrom(inv.payer, payout, inv.amount);
        if (!ok) revert TransferFailed();

        emit InvoicePaid(invoiceId, inv.payeeId, inv.payer, payout, inv.amount, executor);
    }

    function _mustExist(uint256 invoiceId) internal view returns (Invoice storage inv) {
        inv = _invoices[invoiceId];
        if (inv.payer == address(0)) revert InvoiceNotFound(invoiceId);
    }

    function getInvoice(uint256 invoiceId) external view returns (Invoice memory) {
        if (_invoices[invoiceId].payer == address(0)) revert InvoiceNotFound(invoiceId);
        return _invoices[invoiceId];
    }

    function invoiceCount() external view returns (uint256) {
        return nextInvoiceId - 1;
    }
}
