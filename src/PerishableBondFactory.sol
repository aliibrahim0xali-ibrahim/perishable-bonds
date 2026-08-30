// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PerishableBond.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title PerishableBondFactory
 * @notice Deploys one PerishableBond per tokenized shipment and maintains
 *         an on-chain registry so front-ends / indexers can discover all
 *         bonds without relying on off-chain event scraping alone.
 *
 * @dev    Each issuer must hold ISSUER_ROLE here before they can create
 *         bonds, so the protocol can gate who's allowed to tokenize cargo
 *         (e.g. KYC'd freight forwarders, pharma distributors, etc).
 *         Swap this for a permissionless model if that's not desired.
 */
contract PerishableBondFactory is AccessControl {
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 public constant ORACLE_ADMIN_ROLE = keccak256("ORACLE_ADMIN_ROLE");

    address[] public allBonds;
    mapping(address => address[]) public bondsByIssuer;
    mapping(address => bool) public isRegisteredBond;

    /// @notice Default oracle relayer granted ORACLE_ROLE on new bonds
    ///         unless the issuer specifies a different one per shipment.
    address public defaultOracle;

    event BondCreated(
        address indexed bondAddress,
        address indexed issuer,
        address indexed cargoOwner,
        uint256 initialNAV,
        uint256 maturityDeadline
    );
    event DefaultOracleUpdated(address indexed oldOracle, address indexed newOracle);

    constructor(address admin, address _defaultOracle) {
        require(admin != address(0) && _defaultOracle != address(0), "zero address");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORACLE_ADMIN_ROLE, admin);
        defaultOracle = _defaultOracle;
    }

    function setDefaultOracle(address newOracle) external onlyRole(ORACLE_ADMIN_ROLE) {
        require(newOracle != address(0), "zero address");
        emit DefaultOracleUpdated(defaultOracle, newOracle);
        defaultOracle = newOracle;
    }

    /**
     * @notice Create and register a new perishable bond for a shipment.
     * @param params Full bond configuration. `params.issuer` is overridden
     *        to msg.sender and `params.oracle` falls back to
     *        `defaultOracle` if left as address(0).
     */
    function createBond(PerishableBond.BondParams memory params)
        external
        onlyRole(ISSUER_ROLE)
        returns (address bondAddress)
    {
        params.issuer = msg.sender;
        if (params.oracle == address(0)) {
            params.oracle = defaultOracle;
        }

        PerishableBond bond = new PerishableBond(params);
        bondAddress = address(bond);

        allBonds.push(bondAddress);
        bondsByIssuer[msg.sender].push(bondAddress);
        isRegisteredBond[bondAddress] = true;

        emit BondCreated(bondAddress, msg.sender, params.cargoOwner, params.initialNAV, params.maturityDeadline);
    }

    function totalBonds() external view returns (uint256) {
        return allBonds.length;
    }

    function getBondsByIssuer(address issuer) external view returns (address[] memory) {
        return bondsByIssuer[issuer];
    }

    function getAllBonds() external view returns (address[] memory) {
        return allBonds;
    }

    /// @notice LOW FIX: getAllBonds() returns the full, unboundedly-growing
    ///         array in one call. That's fine for an off-chain `eth_call`,
    ///         but any *on-chain* consumer (another contract calling this
    ///         as an external view) risks running out of gas as the
    ///         registry grows. Paginated variant for that use case.
    function getBondsPaginated(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 total = allBonds.length;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = allBonds[i];
        }
    }
}
