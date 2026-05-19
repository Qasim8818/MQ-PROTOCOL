pragma circom 2.1.6;

include "circomlib/circuits/comparators.circom";
include "circomlib/circuits/bitify.circom";

/**
 * Safe range-checked comparison operators.
 * Prevents field-element wraparound by enforcing that inputs fit in specified bit range.
 * All outputs are 0 or 1.
 */

// SafeGreaterEqThan(bits): Outputs 1 if a >= b, 0 otherwise
// Both a and b must fit in 'bits' bits. Prevents wraparound attacks.
template SafeGreaterEqThan(bits) {
    signal input a;
    signal input b;
    signal output out;

    component aBits = Num2Bits(bits);
    component bBits = Num2Bits(bits);
    component ge = GreaterEqThan(bits);

    aBits.in <== a;
    bBits.in <== b;
    ge.in[0] <== a;
    ge.in[1] <== b;

    out <== ge.out;
}

// SafeLessThan(bits): Outputs 1 if a < b, 0 otherwise
template SafeLessThan(bits) {
    signal input a;
    signal input b;
    signal output out;

    component aBits = Num2Bits(bits);
    component bBits = Num2Bits(bits);
    component lt = LessThan(bits);

    aBits.in <== a;
    bBits.in <== b;
    lt.in[0] <== a;
    lt.in[1] <== b;

    out <== lt.out;
}

// Min(bits): Outputs min(a, b)
template Min(bits) {
    signal input a;
    signal input b;
    signal output out;

    component lt = SafeLessThan(bits);
    lt.a <== a;
    lt.b <== b;

    out <== a * lt.out + b * (1 - lt.out);
}
