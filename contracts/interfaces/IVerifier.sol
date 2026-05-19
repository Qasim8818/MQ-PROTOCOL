// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IVerifier
 * @notice Standard interface for FFLONK/Groth16 ZK proof verifiers
 */

interface IVerifier {
    /**
     * @notice Verify a ZK proof
     * @param a First part of proof (2 field elements)
     * @param b Second part of proof (2x2 field elements)
     * @param c Third part of proof (2 field elements)
     * @param pubInputs Public input array
     * @return True if proof is valid
     */
    function verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[] calldata pubInputs
    ) external view returns (bool);
}
