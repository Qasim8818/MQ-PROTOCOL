const { expect } = require("chai");
const snarkjs = require("snarkjs");
const fs = require("fs");
const path = require("path");
const { poseidon2, poseidon8 } = require("poseidon-lite");

describe("MatchProof Circuit", function () {
  this.timeout(600_000);

  let artifacts;

  before(function () {
    const buildDir = path.join(__dirname, "../../circuits/build");
    artifacts = {
      wasm: path.join(buildDir, "match_proof_js", "match_proof.wasm"),
      zkey: path.join(buildDir, "match_proof_final.zkey"),
      vk: path.join(buildDir, "match_proof_vk.json"),
    };

    if (!fs.existsSync(artifacts.wasm) || !fs.existsSync(artifacts.zkey) || !fs.existsSync(artifacts.vk)) {
      this.skip();
    }
  });

  function buildInputs(overrides = {}) {
    const base = {
      buyPrice: 1950n * (10n ** 18n),
      buyQuantity: 100n,
      buySide: 1n,
      buySalt: 123456789n,
      buyTokenIn: 11n,
      buyTokenOut: 22n,
      buyDeadline: 100n,
      buyOwner: 1001n,
      buySpendingKey: 555n,

      sellPrice: 1900n * (10n ** 18n),
      sellQuantity: 80n,
      sellSide: 0n,
      sellSalt: 987654321n,
      sellTokenIn: 22n,
      sellTokenOut: 11n,
      sellDeadline: 100n,
      sellOwner: 2002n,
      sellSpendingKey: 777n,

      settledPrice: 1925n * (10n ** 18n),
      matcherAddress: 3003n,
      protocolFeeBps: 10n,
      ...overrides,
    };

    const buyCommitment = poseidon8([
      base.buyPrice,
      base.buyQuantity,
      base.buySide,
      base.buySalt,
      base.buyTokenIn,
      base.buyTokenOut,
      base.buyDeadline,
      base.buyOwner,
    ]);

    const sellCommitment = poseidon8([
      base.sellPrice,
      base.sellQuantity,
      base.sellSide,
      base.sellSalt,
      base.sellTokenIn,
      base.sellTokenOut,
      base.sellDeadline,
      base.sellOwner,
    ]);

    const buyNullifier = poseidon2([base.buySpendingKey, buyCommitment]);
    const sellNullifier = poseidon2([base.sellSpendingKey, sellCommitment]);
    const settledQty = overrides.settledQty ?? (base.buyQuantity < base.sellQuantity ? base.buyQuantity : base.sellQuantity);

    const inputs = {
      ...base,
      buyCommitment: overrides.buyCommitment ?? buyCommitment,
      sellCommitment: overrides.sellCommitment ?? sellCommitment,
      buyNullifier: overrides.buyNullifier ?? buyNullifier,
      sellNullifier: overrides.sellNullifier ?? sellNullifier,
      settledQty,
    };

    return Object.fromEntries(
      Object.entries(inputs).map(([key, value]) => [key, value.toString()])
    );
  }

  async function generateAndVerifyProof(inputs) {
    const { proof, publicSignals } = await snarkjs.groth16.fullProve(
      inputs,
      artifacts.wasm,
      artifacts.zkey
    );

    const vk = JSON.parse(fs.readFileSync(artifacts.vk, "utf8"));
    const isValid = await snarkjs.groth16.verify(vk, publicSignals, proof);
    return { proof, publicSignals, isValid };
  }

  async function expectConstraintFailure(inputs) {
    try {
      await generateAndVerifyProof(inputs);
      throw new Error("expected proof generation to fail");
    } catch (error) {
      expect(String(error.message)).to.match(/constraint|assert|failed/i);
    }
  }

  it("proves a valid match", async function () {
    const { isValid, publicSignals } = await generateAndVerifyProof(buildInputs());
    expect(isValid).to.equal(true);
    expect(publicSignals).to.have.length(8);
  });

  it("rejects when buyPrice < settledPrice", async function () {
    await expectConstraintFailure(
      buildInputs({
        buyPrice: 1900n * (10n ** 18n),
        settledPrice: 1950n * (10n ** 18n),
      })
    );
  });

  it("rejects when settledPrice < sellPrice", async function () {
    await expectConstraintFailure(
      buildInputs({
        settledPrice: 1850n * (10n ** 18n),
      })
    );
  });

  it("rejects when settledQty exceeds min(buyQty, sellQty)", async function () {
    await expectConstraintFailure(
      buildInputs({
        settledQty: 90n,
      })
    );
  });

  it("rejects when token pairs do not match", async function () {
    await expectConstraintFailure(
      buildInputs({
        sellTokenIn: 33n,
        sellTokenOut: 44n,
      })
    );
  });

  it("rejects when a nullifier does not match the spending key", async function () {
    await expectConstraintFailure(
      buildInputs({
        buyNullifier: 999999n,
      })
    );
  });
});
