pragma circom 2.1.6;

include "circomlib/circuits/poseidon.circom";
include "circomlib/circuits/comparators.circom";
include "./lib/comparators_safe.circom";

/**
 * MatchProof Circuit (Bug Fixes #2, #4, #5)
 * Proves that two orders (buy and sell) are compatible without revealing individual prices.
 * 
 * Public Inputs:
 *   [0] = buyCommitment
 *   [1] = sellCommitment
 *   [2] = settledPrice
 *   [3] = settledQty
 *   [4] = buyNullifier
 *   [5] = sellNullifier
 *   [6] = matcherAddress
 *   [7] = protocolFeeBps
 * 
 * Private Inputs (Buy side):
 *   buyPrice, buyQuantity, buySide, buySalt, buyTokenIn, buyTokenOut, buyDeadline, buyOwner, buySpendingKey
 * 
 * Private Inputs (Sell side):
 *   sellPrice, sellQuantity, sellSide, sellSalt, sellTokenIn, sellTokenOut, sellDeadline, sellOwner, sellSpendingKey
 */

template MatchProof() {
    // Public inputs
    signal input buyCommitment;
    signal input sellCommitment;
    signal input settledPrice;
    signal input settledQty;
    signal input buyNullifier;
    signal input sellNullifier;
    signal input matcherAddress;
    signal input protocolFeeBps;
    
    // Private inputs (buy order)
    signal input buyPrice;
    signal input buyQuantity;
    signal input buySide; // Must be 1 (buy)
    signal input buySalt;
    signal input buyTokenIn;
    signal input buyTokenOut;
    signal input buyDeadline;
    signal input buyOwner;
    signal input buySpendingKey;
    
    // Private inputs (sell order)
    signal input sellPrice;
    signal input sellQuantity;
    signal input sellSide; // Must be 0 (sell)
    signal input sellSalt;
    signal input sellTokenIn;
    signal input sellTokenOut;
    signal input sellDeadline;
    signal input sellOwner;
    signal input sellSpendingKey;
    
    component buyCommitmentHash = Poseidon(8);
    buyCommitmentHash.inputs[0] <== buyPrice;
    buyCommitmentHash.inputs[1] <== buyQuantity;
    buyCommitmentHash.inputs[2] <== buySide;
    buyCommitmentHash.inputs[3] <== buySalt;
    buyCommitmentHash.inputs[4] <== buyTokenIn;
    buyCommitmentHash.inputs[5] <== buyTokenOut;
    buyCommitmentHash.inputs[6] <== buyDeadline;
    buyCommitmentHash.inputs[7] <== buyOwner;
    buyCommitment === buyCommitmentHash.out;

    component sellCommitmentHash = Poseidon(8);
    sellCommitmentHash.inputs[0] <== sellPrice;
    sellCommitmentHash.inputs[1] <== sellQuantity;
    sellCommitmentHash.inputs[2] <== sellSide;
    sellCommitmentHash.inputs[3] <== sellSalt;
    sellCommitmentHash.inputs[4] <== sellTokenIn;
    sellCommitmentHash.inputs[5] <== sellTokenOut;
    sellCommitmentHash.inputs[6] <== sellDeadline;
    sellCommitmentHash.inputs[7] <== sellOwner;
    sellCommitment === sellCommitmentHash.out;

    component buyNullifierHash = Poseidon(2);
    buyNullifierHash.inputs[0] <== buySpendingKey;
    buyNullifierHash.inputs[1] <== buyCommitment;
    buyNullifier === buyNullifierHash.out;

    component sellNullifierHash = Poseidon(2);
    sellNullifierHash.inputs[0] <== sellSpendingKey;
    sellNullifierHash.inputs[1] <== sellCommitment;
    sellNullifier === sellNullifierHash.out;
    
    // ===== Side Verification =====
    buySide === 1;  // Buy order
    sellSide === 0; // Sell order
    
    // ===== Token Pair Verification (Bug Fix #5) =====
    // buyTokenIn must equal sellTokenOut (buyer receives what seller is selling)
    // buyTokenOut must equal sellTokenIn (buyer is selling what seller receives)
    buyTokenIn === sellTokenOut;
    buyTokenOut === sellTokenIn;
    
    // ===== Price Compatibility Check (Bug Fix #2) =====
    // Buy price >= settled price >= Sell price
    // Using 256-bit safe comparisons
    
    component buyPriceGteSettled = SafeGreaterEqThan(252);
    buyPriceGteSettled.a <== buyPrice;
    buyPriceGteSettled.b <== settledPrice;
    buyPriceGteSettled.out === 1;

    component settledPriceGteSell = SafeGreaterEqThan(252);
    settledPriceGteSell.a <== settledPrice;
    settledPriceGteSell.b <== sellPrice;
    settledPriceGteSell.out === 1;

    component settledQtyMin = Min(252);
    settledQtyMin.a <== buyQuantity;
    settledQtyMin.b <== sellQuantity;
    settledQty === settledQtyMin.out;

    component buyPriceIsZero = IsZero();
    component sellPriceIsZero = IsZero();
    component settledPriceIsZero = IsZero();
    component settledQtyIsZero = IsZero();
    component buyQuantityIsZero = IsZero();
    component sellQuantityIsZero = IsZero();
    component feeMaxCheck = SafeGreaterEqThan(14);

    buyPriceIsZero.in <== buyPrice;
    sellPriceIsZero.in <== sellPrice;
    settledPriceIsZero.in <== settledPrice;
    settledQtyIsZero.in <== settledQty;
    buyQuantityIsZero.in <== buyQuantity;
    sellQuantityIsZero.in <== sellQuantity;

    buyPriceIsZero.out === 0;
    sellPriceIsZero.out === 0;
    settledPriceIsZero.out === 0;
    settledQtyIsZero.out === 0;
    buyQuantityIsZero.out === 0;
    sellQuantityIsZero.out === 0;

    feeMaxCheck.a <== 10000;
    feeMaxCheck.b <== protocolFeeBps;
    feeMaxCheck.out === 1;
}

component main { 
    public [buyCommitment, sellCommitment, settledPrice, settledQty, buyNullifier, sellNullifier, matcherAddress, protocolFeeBps]
} = MatchProof();
