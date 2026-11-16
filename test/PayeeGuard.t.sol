// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PayeeRegistry} from "../src/PayeeRegistry.sol";
import {InvoiceBook} from "../src/InvoiceBook.sol";
import {AgentMandate} from "../src/AgentMandate.sol";
import {MockUSD8} from "./MockUSD8.sol";

// Minimal Foundry cheatcode interface (keeps the repo free of external test deps).
interface Vm {
    function prank(address) external;
    function warp(uint256) external;
    function expectRevert() external;
    function expectRevert(bytes calldata) external;
}

contract PayeeGuardTest {
    Vm internal vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address internal PAYER = address(0x1001);
    address internal PAYEE = address(0x1002);
    address internal AGENT = address(0x1003);
    address internal STRANGER = address(0x1004);

    uint256 internal constant TUSD = 1e6;

    MockUSD8 internal token;
    PayeeRegistry internal registry;
    InvoiceBook internal book;
    AgentMandate internal mandate;

    uint256 internal acmeId; // verified payee used by most tests

    function setUp() public {
        token = new MockUSD8();
        registry = new PayeeRegistry(); // owner = this test contract
        book = new InvoiceBook(address(registry), address(token));
        mandate = new AgentMandate();
        book.setMandateContract(address(mandate));

        token.mint(PAYER, 10_000 * TUSD);

        acmeId = registry.registerPayee("Acme Studio", keccak256("acme-metadata"), PAYEE);
        registry.setVerified(acmeId, true);
    }

    // ---------- helpers ----------

    function _invoice(uint256 payeeId, uint256 amount, string memory ref) internal returns (uint256 id) {
        vm.prank(PAYER);
        id = book.createInvoice(payeeId, amount, ref, 0, bytes32(0));
    }

    function _mandate(uint256 cap, uint256 budget, uint256 expiry) internal returns (uint256 id) {
        vm.prank(PAYER);
        id = mandate.grantMandate(AGENT, cap, budget, expiry, address(book), false, new uint256[](0));
    }

    function _approve(uint256 amount) internal {
        vm.prank(PAYER);
        token.approve(address(book), amount);
    }

    function _future() internal view returns (uint256) {
        return block.timestamp + 7 days;
    }

    // ---------- tests ----------

    function testHappyPathAgentPaysInvoice() public {
        uint256 inv = _invoice(acmeId, 120 * TUSD, "INV-0142");
        uint256 mid = _mandate(150 * TUSD, 500 * TUSD, _future());
        _approve(500 * TUSD);

        uint256 payeeBefore = token.balanceOf(PAYEE);
        vm.prank(AGENT);
        mandate.payInvoice(mid, inv);

        InvoiceBook.Invoice memory got = book.getInvoice(inv);
        assert(got.status == InvoiceBook.Status.Paid);
        assert(got.executor == AGENT);
        assert(token.balanceOf(PAYEE) == payeeBefore + 120 * TUSD);
        assert(mandate.getMandate(mid).spent == 120 * TUSD);
    }

    function testDirectPayHappyPath() public {
        uint256 inv = _invoice(acmeId, 120 * TUSD, "INV-0142");
        _approve(500 * TUSD);

        vm.prank(PAYER);
        book.payInvoice(inv);

        InvoiceBook.Invoice memory got = book.getInvoice(inv);
        assert(got.status == InvoiceBook.Status.Paid);
        assert(got.executor == PAYER);
        assert(token.balanceOf(PAYEE) == 120 * TUSD);
    }

    function testDoublePayBlocked() public {
        uint256 inv = _invoice(acmeId, 120 * TUSD, "INV-0142");
        uint256 mid = _mandate(150 * TUSD, 500 * TUSD, _future());
        _approve(500 * TUSD);

        vm.prank(AGENT);
        mandate.payInvoice(mid, inv);

        vm.prank(AGENT);
        vm.expectRevert();
        mandate.payInvoice(mid, inv);

        vm.prank(PAYER);
        vm.expectRevert();
        book.payInvoice(inv);
    }

    function testUnverifiedPayeeBlocked() public {
        uint256 unverifiedId = registry.registerPayee("Ghost Studio", keccak256("ghost"), STRANGER);
        uint256 inv = _invoice(unverifiedId, 50 * TUSD, "INV-666");
        uint256 mid = _mandate(150 * TUSD, 500 * TUSD, _future());
        _approve(500 * TUSD);

        vm.prank(AGENT);
        vm.expectRevert(); // PayeeNotVerified from the book
        mandate.payInvoice(mid, inv);

        vm.prank(PAYER);
        vm.expectRevert(); // PayeeNotVerified on the direct path too
        book.payInvoice(inv);

        assert(book.getInvoice(inv).status == InvoiceBook.Status.Issued);
        assert(mandate.getMandate(mid).spent == 0);
    }

    function testOverCapBlocked() public {
        uint256 inv = _invoice(acmeId, 200 * TUSD, "INV-200");
        uint256 mid = _mandate(150 * TUSD, 500 * TUSD, _future());
        _approve(500 * TUSD);

        vm.prank(AGENT);
        vm.expectRevert(); // OverCap
        mandate.payInvoice(mid, inv);

        assert(book.getInvoice(inv).status == InvoiceBook.Status.Issued);
        assert(mandate.getMandate(mid).spent == 0);
    }

    function testBudgetExhaustion() public {
        uint256 inv1 = _invoice(acmeId, 300 * TUSD, "INV-A");
        uint256 inv2 = _invoice(acmeId, 300 * TUSD, "INV-B");
        uint256 mid = _mandate(400 * TUSD, 500 * TUSD, _future());
        _approve(500 * TUSD);

        vm.prank(AGENT);
        mandate.payInvoice(mid, inv1);
        assert(mandate.getMandate(mid).spent == 300 * TUSD);

        vm.prank(AGENT);
        vm.expectRevert(); // BudgetExceeded: 300 + 300 > 500
        mandate.payInvoice(mid, inv2);

        assert(book.getInvoice(inv2).status == InvoiceBook.Status.Issued);
    }

    function testExpiredMandate() public {
        uint256 inv = _invoice(acmeId, 120 * TUSD, "INV-0142");
        uint256 mid = _mandate(150 * TUSD, 500 * TUSD, block.timestamp + 1 days);
        _approve(500 * TUSD);

        vm.warp(block.timestamp + 2 days);
        vm.prank(AGENT);
        vm.expectRevert(); // MandateExpired
        mandate.payInvoice(mid, inv);
    }

    function testRevokedMandatePaymentFails() public {
        uint256 inv = _invoice(acmeId, 120 * TUSD, "INV-0142");
        uint256 mid = _mandate(150 * TUSD, 500 * TUSD, _future());
        _approve(500 * TUSD);

        vm.prank(PAYER);
        mandate.revokeMandate(mid);

        vm.prank(AGENT);
        vm.expectRevert(); // MandateRevokedError
        mandate.payInvoice(mid, inv);

        assert(book.getInvoice(inv).status == InvoiceBook.Status.Issued);
    }

    function testCancelInvoiceBlocksPayment() public {
        uint256 inv = _invoice(acmeId, 120 * TUSD, "INV-0142");
        uint256 mid = _mandate(150 * TUSD, 500 * TUSD, _future());
        _approve(500 * TUSD);

        vm.prank(STRANGER);
        vm.expectRevert(); // NotPayer
        book.cancelInvoice(inv);

        vm.prank(PAYER);
        book.cancelInvoice(inv);
        assert(book.getInvoice(inv).status == InvoiceBook.Status.Cancelled);

        vm.prank(AGENT);
        vm.expectRevert(); // InvoiceNotIssued
        mandate.payInvoice(mid, inv);
    }

    function testAllowlistBlocksUnlistedPayee() public {
        uint256 inv = _invoice(acmeId, 120 * TUSD, "INV-0142");
        vm.prank(PAYER);
        uint256 mid = mandate.grantMandate(AGENT, 150 * TUSD, 500 * TUSD, _future(), address(book), true, new uint256[](0));
        _approve(500 * TUSD);

        vm.prank(AGENT);
        vm.expectRevert(); // PayeeNotAllowed
        mandate.payInvoice(mid, inv);

        vm.prank(PAYER);
        mandate.allowPayee(mid, acmeId);

        vm.prank(AGENT);
        mandate.payInvoice(mid, inv);
        assert(book.getInvoice(inv).status == InvoiceBook.Status.Paid);
    }

    function testNonAgentCannotUseMandate() public {
        uint256 inv = _invoice(acmeId, 120 * TUSD, "INV-0142");
        uint256 mid = _mandate(150 * TUSD, 500 * TUSD, _future());
        _approve(500 * TUSD);

        vm.prank(STRANGER);
        vm.expectRevert(); // NotMandateAgent
        mandate.payInvoice(mid, inv);
    }

    function testConfirmationOfPayeeLookups() public {
        (uint256 idByAddr, string memory name, bool verified) = registry.confirmPayee(PAYEE);
        assert(idByAddr == acmeId);
        assert(keccak256(bytes(name)) == keccak256(bytes("Acme Studio")));
        assert(verified);

        (uint256 idByName, address payout, bool verifiedByName) = registry.confirmPayeeByName("Acme Studio");
        assert(idByName == acmeId);
        assert(payout == PAYEE);
        assert(verifiedByName);

        // Revoking verification is reflected immediately in CoP lookups.
        registry.setVerified(acmeId, false);
        (, , bool verifiedAfter) = registry.confirmPayee(PAYEE);
        assert(!verifiedAfter);
    }
}
