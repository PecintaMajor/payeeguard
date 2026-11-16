// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {InvoiceBook} from "./InvoiceBook.sol";

/// @title AgentMandate — scoped, revocable payment authority for an AI/agent payer.
/// @notice The innovation core of PayeeGuard. A payer (owner) grants an agent address a
/// mandate bounded by: a per-payment cap, a total budget, an expiry timestamp, exactly
/// one allowed InvoiceBook, and an optional payee allowlist. The agent can then pay
/// invoices from that book with the owner's funds — every check is enforced atomically
/// on-chain inside the payment transaction itself, so an agent (or a compromised agent
/// key) can never exceed the mandate. The owner can revoke instantly; revocation blocks
/// all further agent payments from that block on.
///
/// The owner must separately approve the InvoiceBook contract to spend tUSD8 up to the
/// budget (standard ERC-20 allowance) — the mandate is the policy layer on top.
contract AgentMandate {
    struct Mandate {
        address owner;
        address agent;
        uint256 perPaymentCap; // tUSD8 atomic units
        uint256 totalBudget; // tUSD8 atomic units
        uint256 spent;
        uint256 expiry; // unix timestamp; payments require block.timestamp < expiry
        address invoiceBook;
        bool allowlistEnabled;
        bool revoked;
        bool exists;
    }

    uint256 public nextMandateId = 1;
    mapping(uint256 => Mandate) private _mandates;
    mapping(uint256 => mapping(uint256 => bool)) private _allowedPayee; // mandateId => payeeId => allowed

    event MandateGranted(
        uint256 indexed mandateId,
        address indexed owner,
        address indexed agent,
        uint256 perPaymentCap,
        uint256 totalBudget,
        uint256 expiry,
        address invoiceBook,
        bool allowlistEnabled
    );
    event MandateRevoked(uint256 indexed mandateId);
    event AgentPayment(uint256 indexed mandateId, uint256 indexed invoiceId, address indexed agent, uint256 amount);

    error MandateNotFound(uint256 mandateId);
    error NotMandateOwner();
    error NotMandateAgent();
    error MandateRevokedError(uint256 mandateId);
    error MandateExpired(uint256 mandateId, uint256 expiry);
    error ZeroAddress();
    error InvalidLimits();
    error WrongInvoiceBook(address invoiceBook);
    error InvoicePayerMismatch();
    error OverCap(uint256 amount, uint256 cap);
    error BudgetExceeded(uint256 amount, uint256 remaining);
    error PayeeNotAllowed(uint256 payeeId);

    /// @notice Grant a mandate. `payeeIds` optionally seeds the payee allowlist; pass an
    /// empty array and `allowlistEnabled = false` to allow any verified payee.
    function grantMandate(
        address agent,
        uint256 perPaymentCap,
        uint256 totalBudget,
        uint256 expiry,
        address invoiceBook,
        bool allowlistEnabled,
        uint256[] calldata payeeIds
    ) external returns (uint256 mandateId) {
        if (agent == address(0) || invoiceBook == address(0)) revert ZeroAddress();
        if (perPaymentCap == 0 || totalBudget == 0 || expiry <= block.timestamp) revert InvalidLimits();

        mandateId = nextMandateId++;
        _mandates[mandateId] = Mandate({
            owner: msg.sender,
            agent: agent,
            perPaymentCap: perPaymentCap,
            totalBudget: totalBudget,
            spent: 0,
            expiry: expiry,
            invoiceBook: invoiceBook,
            allowlistEnabled: allowlistEnabled,
            revoked: false,
            exists: true
        });
        for (uint256 i = 0; i < payeeIds.length; i++) {
            _allowedPayee[mandateId][payeeIds[i]] = true;
        }

        emit MandateGranted(mandateId, msg.sender, agent, perPaymentCap, totalBudget, expiry, invoiceBook, allowlistEnabled);
    }

    /// @notice Revoke a mandate instantly. Only the mandate owner. All later agent
    /// payments under this mandate revert.
    function revokeMandate(uint256 mandateId) external {
        Mandate storage m = _mustExist(mandateId);
        if (msg.sender != m.owner) revert NotMandateOwner();
        m.revoked = true;
        emit MandateRevoked(mandateId);
    }

    /// @notice Add a payee to a mandate's allowlist (owner only).
    function allowPayee(uint256 mandateId, uint256 payeeId) external {
        Mandate storage m = _mustExist(mandateId);
        if (msg.sender != m.owner) revert NotMandateOwner();
        _allowedPayee[mandateId][payeeId] = true;
    }

    /// @notice Execute a payment under a mandate. Called by the agent. All mandate checks
    /// run first; the book then enforces its own guards (invoice Issued, payee verified)
    /// and pulls the funds from the owner — atomically: any failure reverts everything,
    /// including the budget accounting below.
    function payInvoice(uint256 mandateId, uint256 invoiceId) external {
        Mandate storage m = _mustExist(mandateId);
        if (msg.sender != m.agent) revert NotMandateAgent();
        if (m.revoked) revert MandateRevokedError(mandateId);
        if (block.timestamp >= m.expiry) revert MandateExpired(mandateId, m.expiry);

        InvoiceBook book = InvoiceBook(m.invoiceBook);
        InvoiceBook.Invoice memory inv = book.getInvoice(invoiceId);
        if (inv.payer != m.owner) revert InvoicePayerMismatch();
        if (inv.amount > m.perPaymentCap) revert OverCap(inv.amount, m.perPaymentCap);
        uint256 remaining = m.totalBudget - m.spent;
        if (inv.amount > remaining) revert BudgetExceeded(inv.amount, remaining);
        if (m.allowlistEnabled && !_allowedPayee[mandateId][inv.payeeId]) revert PayeeNotAllowed(inv.payeeId);

        // Effects before interaction; a revert in the book call rolls this back too.
        m.spent += inv.amount;

        book.payInvoiceOnBehalf(invoiceId, m.owner, msg.sender);

        emit AgentPayment(mandateId, invoiceId, msg.sender, inv.amount);
    }

    function getMandate(uint256 mandateId) external view returns (Mandate memory) {
        if (!_mandates[mandateId].exists) revert MandateNotFound(mandateId);
        return _mandates[mandateId];
    }

    function isPayeeAllowed(uint256 mandateId, uint256 payeeId) external view returns (bool) {
        return _allowedPayee[mandateId][payeeId];
    }

    function _mustExist(uint256 mandateId) internal view returns (Mandate storage m) {
        m = _mandates[mandateId];
        if (!m.exists) revert MandateNotFound(mandateId);
    }
}
