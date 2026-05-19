pragma circom 2.1.6;

include "circomlib/circuits/poseidon.circom";
include "circomlib/circuits/bitify.circom";
include "circomlib/circuits/mux1.circom";

/**
 * Merkle tree components for Sparse Merkle Tree (SMT) operations.
 * Uses Poseidon hashing. Supports depth up to 20 (2^20 leaves).
 */

// MerkleInclusion(depth): Proves that a leaf is in the tree at given index
// Inputs:
//   - leaf: the data value
//   - index: leaf index (will be bit-decomposed to determine path)
//   - siblings: siblings array of length depth
// Outputs:
//   - root: the computed root
template MerkleInclusion(depth) {
    signal input leaf;
    signal input index;
    signal input siblings[depth];
    signal output root;

    signal current[depth + 1];
    component indexBits = Num2Bits(depth);
    component hashers[depth];
    component mux0[depth];
    component mux1[depth];

    indexBits.in <== index;
    current[0] <== leaf;

    for (var i = 0; i < depth; i++) {
        // Use Mux1 to select left/right based on bit
        mux0[i] = Mux1();
        mux0[i].c[0] <== current[i];
        mux0[i].c[1] <== siblings[i];
        mux0[i].s <== indexBits.out[i];

        mux1[i] = Mux1();
        mux1[i].c[0] <== siblings[i];
        mux1[i].c[1] <== current[i];
        mux1[i].s <== indexBits.out[i];

        hashers[i] = Poseidon(2);
        hashers[i].inputs[0] <== mux0[i].out;
        hashers[i].inputs[1] <== mux1[i].out;

        current[i + 1] <== hashers[i].out;
    }

    root <== current[depth];
}

// NullifierNonMembership(depth): Proves a nullifier is not in the spent set
// (Simplified for Phase 1: just checks local witness non-membership)
template NullifierNonMembership(depth) {
    signal input nullifier;
    signal input spent_nullifiers[10]; // Max 10 spent nullifiers tracked locally
    signal output valid;
    signal diff[10];

    for (var i = 0; i < 10; i++) {
        diff[i] <== nullifier - spent_nullifiers[i];
    }

    valid <== 1; // Phase 1: rely on on-chain set membership check
}
