// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title PayeeRegistry — ERC-8004-flavored payee identity registry for Confirmation of Payee.
///
/// @notice No official ERC-8004 identity registry is deployed on the Aevum testnet:
/// the canonical ERC-8004 registry addresses used on other EVM chains
/// (0x8004A169FB4a3325136EB29fA0ceB6D2e539a432, 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63,
/// 0x8004Cb1BF31DAf7788926d9Ea82e8b26D1d2e51b) were probed via eth_getCode on chain 44005
/// on 2026-11-16 and all returned empty code. This contract therefore implements the same
/// identity semantics locally: a payee identity binds a display name + metadata hash to a
/// payout address, carries a verification flag, and supports Confirmation-of-Payee lookups
/// by payout address and by name.
///
/// Verification is performed by the registry owner (the verifying party — e.g. the payer
/// organisation that onboarded and checked the payee off-chain). Registration is open:
/// anyone may register a payout address once; the binding is immutable afterwards so a
/// verified name can never be silently re-pointed at a different address.
contract PayeeRegistry {
    struct Payee {
        address payoutAddress;
        string name;
        bytes32 metadataHash;
        bool verified;
        bool exists;
    }

    address public owner;
    uint256 public nextPayeeId = 1;

    mapping(uint256 => Payee) private _payees;
    mapping(address => uint256) private _idByPayout;
    mapping(bytes32 => uint256) private _idByNameHash;

    event PayeeRegistered(uint256 indexed payeeId, address indexed payoutAddress, string name, bytes32 metadataHash);
    event PayeeVerificationSet(uint256 indexed payeeId, bool verified);

    error NotOwner();
    error ZeroAddress();
    error EmptyName();
    error PayoutAlreadyRegistered(address payoutAddress);
    error NameAlreadyRegistered(string name);
    error PayeeNotFound(uint256 payeeId);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /// @notice Register a payee identity. One registration per payout address and per name.
    /// @param name Display name used for Confirmation-of-Payee (exact-match lookup).
    /// @param metadataHash Hash of off-chain metadata (KYC pack, website, IPFS doc, ...).
    /// @param payoutAddress Address that will receive payments for this payee.
    /// @return payeeId The new registry id (starts at 1).
    function registerPayee(string calldata name, bytes32 metadataHash, address payoutAddress)
        external
        returns (uint256 payeeId)
    {
        if (payoutAddress == address(0)) revert ZeroAddress();
        if (bytes(name).length == 0) revert EmptyName();
        if (_idByPayout[payoutAddress] != 0) revert PayoutAlreadyRegistered(payoutAddress);
        bytes32 nameHash = keccak256(abi.encodePacked(name));
        if (_idByNameHash[nameHash] != 0) revert NameAlreadyRegistered(name);

        payeeId = nextPayeeId++;
        _payees[payeeId] = Payee({
            payoutAddress: payoutAddress,
            name: name,
            metadataHash: metadataHash,
            verified: false,
            exists: true
        });
        _idByPayout[payoutAddress] = payeeId;
        _idByNameHash[nameHash] = payeeId;

        emit PayeeRegistered(payeeId, payoutAddress, name, metadataHash);
    }

    /// @notice Set or revoke the verification flag for a payee. Only the registry owner
    /// (the verifying party) may do this. Revoking verification immediately blocks all
    /// new payments to the payee via InvoiceBook.
    function setVerified(uint256 payeeId, bool verified) external onlyOwner {
        if (!_payees[payeeId].exists) revert PayeeNotFound(payeeId);
        _payees[payeeId].verified = verified;
        emit PayeeVerificationSet(payeeId, verified);
    }

    function getPayee(uint256 payeeId) external view returns (Payee memory) {
        if (!_payees[payeeId].exists) revert PayeeNotFound(payeeId);
        return _payees[payeeId];
    }

    function payeeExists(uint256 payeeId) external view returns (bool) {
        return _payees[payeeId].exists;
    }

    function isVerified(uint256 payeeId) external view returns (bool) {
        return _payees[payeeId].exists && _payees[payeeId].verified;
    }

    function payoutOf(uint256 payeeId) external view returns (address) {
        if (!_payees[payeeId].exists) revert PayeeNotFound(payeeId);
        return _payees[payeeId].payoutAddress;
    }

    function payeeIdByAddress(address payoutAddress) external view returns (uint256) {
        return _idByPayout[payoutAddress];
    }

    function payeeIdByName(string calldata name) external view returns (uint256) {
        return _idByNameHash[keccak256(abi.encodePacked(name))];
    }

    /// @notice Confirmation of Payee by address: returns the registered name and whether
    /// the identity is verified. A payer UI calls this before paying an address.
    function confirmPayee(address payoutAddress)
        external
        view
        returns (uint256 payeeId, string memory name, bool verified)
    {
        payeeId = _idByPayout[payoutAddress];
        if (payeeId == 0) return (0, "", false);
        Payee storage p = _payees[payeeId];
        return (payeeId, p.name, p.verified);
    }

    /// @notice Confirmation of Payee by name: returns the bound payout address and whether
    /// the identity is verified. Lets a payer check "the address I was given really is
    /// the Acme Studio from the registry".
    function confirmPayeeByName(string calldata name)
        external
        view
        returns (uint256 payeeId, address payoutAddress, bool verified)
    {
        payeeId = _idByNameHash[keccak256(abi.encodePacked(name))];
        if (payeeId == 0) return (0, address(0), false);
        Payee storage p = _payees[payeeId];
        return (payeeId, p.payoutAddress, p.verified);
    }
}
