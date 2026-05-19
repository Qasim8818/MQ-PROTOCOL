pragma circom 2.1.6;

include "circomlib/circuits/poseidon.circom";

/**
 * CancelProof Circuit (Bug Fix #4)
 * Proves ownership of an order (can cancel it) without revealing the order details.
 * 
 * Public Inputs:
 *   [0] = nullifier
 * 
 * Private Inputs:
 *   spendingKey, commitment
 */

template CancelProof() {
    signal input nullifier;
    signal input spendingKey;
    signal input commitment;

    component nullifierHash = Poseidon(2);
    nullifierHash.inputs[0] <== spendingKey;
    nullifierHash.inputs[1] <== commitment;
    nullifier === nullifierHash.out;
}

component main { public [nullifier] } = CancelProof();
