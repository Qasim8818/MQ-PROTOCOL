import * as snarkjs from "snarkjs";
import { readFileSync } from "fs";
import { join } from "path";

/**
 * Circuit artifacts for proof generation
 */
export interface CircuitArtifacts {
  wasmPath: string;
  zkeyPath: string;
  vkPath: string;
}

/**
 * Proof calldata formatted for Solidity
 */
export interface ProofCalldata {
  a: [string, string];
  b: [[string, string], [string, string]];
  c: [string, string];
}

/**
 * ARTIFACTS: Paths to compiled circuit files (relative to project root)
 */
export const ARTIFACTS = {
  orderValidity: {
    wasmPath: join(__dirname, "../../circuits/build/order_validity_js/order_validity.wasm"),
    zkeyPath: join(__dirname, "../../circuits/build/order_validity_final.zkey"),
    vkPath: join(__dirname, "../../circuits/build/order_validity_vk.json"),
  },
  matchProof: {
    wasmPath: join(__dirname, "../../circuits/build/match_proof_js/match_proof.wasm"),
    zkeyPath: join(__dirname, "../../circuits/build/match_proof_final.zkey"),
    vkPath: join(__dirname, "../../circuits/build/match_proof_vk.json"),
  },
  cancelProof: {
    wasmPath: join(__dirname, "../../circuits/build/cancel_proof_js/cancel_proof.wasm"),
    zkeyPath: join(__dirname, "../../circuits/build/cancel_proof_final.zkey"),
    vkPath: join(__dirname, "../../circuits/build/cancel_proof_vk.json"),
  },
};

/**
 * Generate a ZK proof using snarkjs
 * @param artifacts Circuit artifacts (wasm + zkey paths)
 * @param inputs Witness input as Record<string, any>
 * @returns Proof and public signals
 */
export async function prove(
  artifacts: CircuitArtifacts,
  inputs: Record<string, any>
): Promise<{
  proof: any;
  publicSignals: bigint[];
  calldata: ProofCalldata;
}> {
  // Full prove using witness generation + trusted setup
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    inputs,
    artifacts.wasmPath,
    artifacts.zkeyPath
  );

  // Export calldata for Solidity
  const calldata = await snarkjs.groth16.exportSolidityCallData(proof, publicSignals);
  
  // Parse calldata string to extract a, b, c
  const [a, b, c, input] = JSON.parse("[" + calldata + "]");

  const proofCalldata: ProofCalldata = { a, b, c };

  // Convert public signals to bigint
  const publicSignalsBigInt = publicSignals.map((s: string) => BigInt(s));

  return {
    proof,
    publicSignals: publicSignalsBigInt,
    calldata: proofCalldata,
  };
}

/**
 * Verify a proof locally (for testing)
 * @param artifacts Circuit artifacts
 * @param publicSignals Public signals from proof
 * @param proof Proof object
 * @returns True if valid
 */
export async function verifyOffChain(
  artifacts: CircuitArtifacts,
  publicSignals: any[],
  proof: any
): Promise<boolean> {
  const vk = JSON.parse(readFileSync(artifacts.vkPath, "utf8"));
  const isValid = await snarkjs.groth16.verify(vk, publicSignals, proof);
  return isValid;
}
