pragma circom 2.1.6;

include "circomlib/circuits/poseidon.circom";
include "circomlib/circuits/comparators.circom";
include "./lib/merkle.circom";
include "./lib/comparators_safe.circom";

/**
 * OrderValidity Circuit (Bug Fix #1, #4)
 * Proves:
 *   1. Commitment hash is valid (Poseidon8 of order fields + salt)
 *   2. Nullifier derives correctly from spendingKey and commitment
 *   3. Quantity >= minQuantity
 *   4. Price > 0, side ∈ {0, 1}
 *   5. User has sufficient deposit (solvency check via Merkle proof)
 * 
 * Public Inputs:
 *   [0] = commitment
 *   [1] = nullifier
 *   [2] = minQuantity
 *   [3] = depositRoot
 * 
 * Private Inputs:
 *   price, quantity, side, salt, tokenIn, tokenOut, deadline, owner (order fields)
 *   spendingKey, depositAmount, depositMerkleIndex, depositSiblings[] (solvency)
 */

template OrderValidity() {
    // Public inputs
    signal input commitment;
    signal input nullifier;
    signal input minQuantity;
    signal input depositRoot;
    
    // Private inputs (order fields)
    signal input price;
    signal input quantity;
    signal input side;
    signal input salt;
    signal input tokenIn;
    signal input tokenOut;
    signal input deadline;
    signal input owner;
    
    // Solvency proof inputs
    signal input spendingKey;
    signal input depositAmount;
    signal input depositMerkleIndex;
    signal input depositSiblings[20];
    
    component commitmentHash = Poseidon(8);
    commitmentHash.inputs[0] <== price;
    commitmentHash.inputs[1] <== quantity;
    commitmentHash.inputs[2] <== side;
    commitmentHash.inputs[3] <== salt;
    commitmentHash.inputs[4] <== tokenIn;
    commitmentHash.inputs[5] <== tokenOut;
    commitmentHash.inputs[6] <== deadline;
    commitmentHash.inputs[7] <== owner;
    commitment === commitmentHash.out;

    component nullifierHash = Poseidon(2);
    nullifierHash.inputs[0] <== spendingKey;
    nullifierHash.inputs[1] <== commitment;
    nullifier === nullifierHash.out;

    component minQuantityCheck = SafeGreaterEqThan(252);
    minQuantityCheck.a <== quantity;
    minQuantityCheck.b <== minQuantity;
    minQuantityCheck.out === 1;

    component priceIsZero = IsZero();
    priceIsZero.in <== price;
    priceIsZero.out === 0;
    side * (side - 1) === 0; // side is 0 or 1

    signal depositLeaf;
    component depositLeafHash = Poseidon(3);
    depositLeafHash.inputs[0] <== owner;
    depositLeafHash.inputs[1] <== tokenIn;
    depositLeafHash.inputs[2] <== depositAmount;
    depositLeaf <== depositLeafHash.out;

    component inclusion = MerkleInclusion(20);
    inclusion.leaf <== depositLeaf;
    inclusion.index <== depositMerkleIndex;
    for (var i = 0; i < 20; i++) {
        inclusion.siblings[i] <== depositSiblings[i];
    }
    depositRoot === inclusion.root;

    component solvencyCheck = SafeGreaterEqThan(252);
    solvencyCheck.a <== depositAmount;
    solvencyCheck.b <== quantity;
    solvencyCheck.out === 1;
}

component main { public [commitment, nullifier, minQuantity, depositRoot] } = OrderValidity();
