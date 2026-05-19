import { expect } from "chai";
import { commitOrder, computeDepositLeaf, normalizePrice, Order } from "../../sdk/src/crypto";
import { SparseMerkleTree } from "../../sdk/src/smt";

describe("SDK Helpers", function () {
  it("normalizes prices correctly when output decimals are lower than input decimals", function () {
    expect(normalizePrice(1n, 18, 6)).to.equal(10n ** 30n);
    expect(normalizePrice(1n, 6, 18)).to.equal(10n ** 6n);
  });

  it("builds a non-zero empty SMT root and verifies generated proofs", function () {
    const tree = new SparseMerkleTree();
    expect(tree.root()).to.not.equal(0n);

    tree.insert(7, 123n);
    const proof = tree.generateProof(7);
    expect(tree.verify(proof)).to.equal(true);
  });

  it("hashes address-based orders and deposit leaves without bigint address coercion", function () {
    const order: Order = {
      price: 2n * (10n ** 18n),
      quantity: 5n,
      side: 1n,
      salt: 99n,
      tokenIn: "0x0000000000000000000000000000000000000001",
      tokenOut: "0x0000000000000000000000000000000000000002",
      deadline: 1234n,
      owner: "0x0000000000000000000000000000000000000003",
    };

    expect(commitOrder(order)).to.be.a("bigint");
    expect(
      computeDepositLeaf(
        "0x0000000000000000000000000000000000000003",
        "0x0000000000000000000000000000000000000001",
        10n
      )
    ).to.be.a("bigint");
  });
});
