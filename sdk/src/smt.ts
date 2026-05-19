import { poseidon2 } from "poseidon-lite";

/**
 * Sparse Merkle Tree (SMT) for deposit tracking
 * Depth: 20 (supports 2^20 = 1 million leaves)
 * Uses Poseidon hashing with zero-hash ladder optimization
 */
export class SparseMerkleTree {
  private depth: number = 20;
  private nodes: Map<string, bigint> = new Map();
  private zeroHashes: bigint[];

  constructor() {
    // Initialize zero-hash ladder: ZERO_HASHES[i] = hash(ZERO_HASHES[i-1], ZERO_HASHES[i-1])
    this.zeroHashes = new Array(this.depth + 1);
    this.zeroHashes[0] = BigInt(0); // Base case: leaf zero hash

    for (let i = 1; i <= this.depth; i++) {
      this.zeroHashes[i] = poseidon2([this.zeroHashes[i - 1], this.zeroHashes[i - 1]]);
    }
  }

  /**
   * Insert a value at a given index and update root
   */
  insert(index: number, value: bigint): void {
    if (index < 0 || index >= 2 ** this.depth) {
      throw new Error(`Index ${index} out of range [0, ${2 ** this.depth})`);
    }

    // Set leaf
    this.setNode(this.depth, index, value);

    // Update parent nodes up to root
    let currentIndex = index;
    for (let level = this.depth - 1; level >= 0; level--) {
      currentIndex = Math.floor(currentIndex / 2);

      const leftIndex = currentIndex * 2;
      const rightIndex = currentIndex * 2 + 1;

      const left = this.getNode(level + 1, leftIndex);
      const right = this.getNode(level + 1, rightIndex);

      const parent = poseidon2([left, right]);
      this.setNode(level, currentIndex, parent);
    }
  }

  /**
   * Generate Merkle proof for a leaf
   */
  generateProof(leafIndex: number): {
    leaf: bigint;
    index: number;
    siblings: bigint[];
    root: bigint;
  } {
    const siblings: bigint[] = [];
    let currentIndex = leafIndex;

    for (let level = this.depth - 1; level >= 0; level--) {
      const siblingIndex = currentIndex % 2 === 0 ? currentIndex + 1 : currentIndex - 1;
      const sibling = this.getNode(level + 1, siblingIndex);
      siblings.push(sibling);

      currentIndex = Math.floor(currentIndex / 2);
    }

    const leaf = this.getNode(this.depth, leafIndex);
    const root = this.getNode(0, 0);

    return { leaf, index: leafIndex, siblings, root };
  }

  /**
   * Verify a proof locally (for testing)
   */
  verify(proof: { leaf: bigint; index: number; siblings: bigint[] }): boolean {
    let current = proof.leaf;
    let index = proof.index;

    for (const sibling of proof.siblings) {
      if (index % 2 === 0) {
        current = poseidon2([current, sibling]);
      } else {
        current = poseidon2([sibling, current]);
      }
      index = Math.floor(index / 2);
    }

    return current === this.root();
  }

  /**
   * Get current root
   */
  root(): bigint {
    return this.getNode(0, 0);
  }

  /**
   * Internal: Get node value (or zero hash if not set)
   */
  private getNode(level: number, index: number): bigint {
    const key = `${level}:${index}`;
    if (this.nodes.has(key)) {
      return this.nodes.get(key)!;
    }
    return this.zeroHashForLevel(level);
  }

  /**
   * Internal: Set node value
   */
  private setNode(level: number, index: number, value: bigint): void {
    const key = `${level}:${index}`;
    this.nodes.set(key, value);
  }

  private zeroHashForLevel(level: number): bigint {
    return this.zeroHashes[this.depth - level];
  }
}
