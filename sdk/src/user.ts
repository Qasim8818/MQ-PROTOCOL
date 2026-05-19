import { ethers } from "ethers";
import { Order, addressToField, computeNullifier, commitOrder, computeDepositLeaf } from "./crypto";
import { prove, ARTIFACTS, ProofCalldata } from "./prover";
import { SparseMerkleTree } from "./smt";
import { DARKPOOL_ABI } from "./abis";

interface CreateOrderOptions {
  amountLocked?: bigint;
  minQuantity?: bigint;
}

/**
 * User interface for creating and managing orders in the dark pool
 */
export class DarkPoolUser {
  private signer: ethers.Signer;
  private darkPoolAddress: string;
  private spendingKey: bigint;
  private depositTree: SparseMerkleTree;
  private contract: ethers.Contract;
  private depositBalances: Map<string, bigint>;

  constructor(
    signer: ethers.Signer,
    darkPoolAddress: string,
    spendingKey: bigint,
    depositTree: SparseMerkleTree
  ) {
    this.signer = signer;
    this.darkPoolAddress = darkPoolAddress;
    this.spendingKey = spendingKey;
    this.depositTree = depositTree;
    this.contract = new ethers.Contract(darkPoolAddress, DARKPOOL_ABI, signer);
    this.depositBalances = new Map();
  }

  /**
   * Deposit tokens and update SMT root
   */
  async deposit(
    tokenAddress: string,
    amount: bigint
  ): Promise<ethers.ContractTransactionReceipt | null> {
    const userAddress = await this.signer.getAddress();
    const token = ethers.getAddress(tokenAddress);
    const previousBalance = await this.readDepositBalance(userAddress, token);
    const nextBalance = previousBalance + amount;

    this.depositTree.insert(
      this.leafIndex(userAddress, token),
      computeDepositLeaf(userAddress, token, nextBalance)
    );
    this.depositBalances.set(token, nextBalance);

    // Approve token transfer
    const tokenContract = new ethers.Contract(
      token,
      ["function approve(address,uint256) external returns (bool)"],
      this.signer
    );
    const approvalTx = await tokenContract.approve(this.darkPoolAddress, amount);
    await approvalTx.wait();

    // Call contract
    const tx = await this.contract.deposit(
      token,
      amount,
      ethers.toBeHex(this.depositTree.root(), 32)
    );
    const receipt = await tx.wait();

    return receipt;
  }

  /**
   * Withdraw unlocked deposited tokens and update the local SMT root.
   */
  async withdraw(
    tokenAddress: string,
    amount: bigint
  ): Promise<ethers.ContractTransactionReceipt | null> {
    const userAddress = await this.signer.getAddress();
    const token = ethers.getAddress(tokenAddress);
    const previousBalance = await this.readDepositBalance(userAddress, token);

    if (previousBalance < amount) {
      throw new Error("Insufficient deposit balance");
    }

    const nextBalance = previousBalance - amount;
    this.depositTree.insert(
      this.leafIndex(userAddress, token),
      computeDepositLeaf(userAddress, token, nextBalance)
    );
    this.depositBalances.set(token, nextBalance);

    const tx = await this.contract.withdraw(
      token,
      amount,
      ethers.toBeHex(this.depositTree.root(), 32)
    );
    const receipt = await tx.wait();

    return receipt;
  }

  /**
   * Create a new order with ZK proof of solvency
   */
  async createOrder(
    order: Order,
    options: CreateOrderOptions = {}
  ): Promise<{
    commitment: bigint;
    nullifier: bigint;
    receipt: ethers.ContractTransactionReceipt | null;
  }> {
    const userAddress = await this.signer.getAddress();
    const normalizedOrder: Order = {
      ...order,
      owner: userAddress,
      tokenIn: ethers.getAddress(order.tokenIn),
      tokenOut: ethers.getAddress(order.tokenOut),
    };

    // Compute commitment and nullifier
    const commitment = commitOrder(normalizedOrder);
    const nullifier = computeNullifier(this.spendingKey, commitment);
    const minQuantity =
      options.minQuantity ??
      (await this.contract.MIN_QUANTITY()) as bigint;
    const amountLocked = options.amountLocked ?? normalizedOrder.quantity;

    // Verify deposit root is current (critical for proof validity)
    const currentRoot = await this.contract.userDepositRoots(userAddress);
    const localRoot = ethers.toBeHex(this.depositTree.root(), 32);
    if (currentRoot.toLowerCase() !== localRoot.toLowerCase()) {
      throw new Error(
        `Deposit root mismatch: contract has ${currentRoot}, local tree has ${localRoot}. Resync deposit tree.`
      );
    }

    const leafIndex = this.leafIndex(userAddress, normalizedOrder.tokenIn);

    const proof = await this.generateOrderValidityProof(
      normalizedOrder,
      commitment,
      nullifier,
      minQuantity,
      leafIndex
    );

    // Call contract to create note
    const tx = await this.contract.createNote(
      ethers.toBeHex(commitment, 32),
      ethers.toBeHex(nullifier, 32),
      normalizedOrder.tokenIn,
      normalizedOrder.tokenOut,
      amountLocked,
      normalizedOrder.deadline,
      proof.calldata.a,
      proof.calldata.b,
      proof.calldata.c
    );

    const receipt = await tx.wait();

    return { commitment, nullifier, receipt };
  }

  /**
   * Cancel an order with ZK proof of ownership
   */
  async cancelOrder(
    commitment: bigint,
    nullifier: bigint
  ): Promise<ethers.ContractTransactionReceipt | null> {
    // Generate CancelProof
    const proof = await prove(ARTIFACTS.cancelProof, {
      nullifier: nullifier.toString(),
      spendingKey: this.spendingKey.toString(),
      commitment: commitment.toString(),
    });

    // Call contract
    const tx = await this.contract.cancelNote(
      ethers.toBeHex(commitment, 32),
      ethers.toBeHex(nullifier, 32),
      proof.calldata.a,
      proof.calldata.b,
      proof.calldata.c
    );

    const receipt = await tx.wait();
    return receipt;
  }

  /**
   * Generate OrderValidity proof
   */
  private async generateOrderValidityProof(
    order: Order,
    commitment: bigint,
    nullifier: bigint,
    minQuantity: bigint,
    leafIndex: number
  ): Promise<{ calldata: ProofCalldata; publicSignals: bigint[] }> {
    const userAddress = await this.signer.getAddress();
    const depositAmount = await this.readDepositBalance(userAddress, order.tokenIn);

    const depositProof = this.depositTree.generateProof(leafIndex);
    const siblings = depositProof.siblings.map((s: bigint) => s.toString());

    const proof = await prove(ARTIFACTS.orderValidity, {
      // Public inputs
      commitment: commitment.toString(),
      nullifier: nullifier.toString(),
      minQuantity: minQuantity.toString(),
      depositRoot: this.depositTree.root().toString(),

      // Private inputs (order)
      price: order.price.toString(),
      quantity: order.quantity.toString(),
      side: order.side.toString(),
      salt: order.salt.toString(),
      tokenIn: addressToField(order.tokenIn).toString(),
      tokenOut: addressToField(order.tokenOut).toString(),
      deadline: order.deadline.toString(),
      owner: addressToField(order.owner).toString(),

      // Private inputs (solvency)
      spendingKey: this.spendingKey.toString(),
      depositAmount: depositAmount.toString(),
      depositMerkleIndex: leafIndex.toString(),
      depositSiblings: siblings,
    });

    return {
      calldata: proof.calldata,
      publicSignals: proof.publicSignals,
    };
  }

  private leafIndex(userAddress: string, tokenAddress: string): number {
    const leafIndex = BigInt(
      ethers.solidityPackedKeccak256(
        ["address", "address"],
        [userAddress, tokenAddress]
      )
    );

    return Number(leafIndex % (2n ** 20n));
  }

  private async readDepositBalance(userAddress: string, tokenAddress: string): Promise<bigint> {
    const cached = this.depositBalances.get(tokenAddress);
    if (cached !== undefined) {
      return cached;
    }

    const balance = await this.contract.deposits(userAddress, tokenAddress) as bigint;
    this.depositBalances.set(tokenAddress, balance);
    return balance;
  }
}
