// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IVerifier.sol";

/**
 * @title MockVerifier
 * @notice Test-only verifier that deterministically accepts or rejects proofs.
 */
contract MockVerifier is IVerifier {
    bool private immutable _result;

    constructor(bool result_) {
        _result = result_;
    }

    function verifyProof(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[] calldata
    ) external view returns (bool) {
        return _result;
    }
}
