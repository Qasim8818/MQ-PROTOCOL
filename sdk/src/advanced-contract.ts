/**
 * Advanced Contract Interactions
 * - Batch operations
 * - Event monitoring
 * - Error recovery
 * - Health checks
 */

import { ethers } from "ethers";
import { EventLog } from "ethers";

// ═══════════════════════════════════════════════════════════════
// ERROR HANDLING & RECOVERY
// ═══════════════════════════════════════════════════════════════

export class DarkPoolError extends Error {
  constructor(
    public code: string,
    public details: any = {}
  ) {
    super(`[${code}] ${DarkPoolError.MESSAGE[code as keyof typeof DarkPoolError.MESSAGE] || "Unknown error"}`);
    Object.setPrototypeOf(this, DarkPoolError.prototype);
  }

  static MESSAGE = {
    INVALID_ORDER: "Order parameters are invalid",
    INSUFFICIENT_BALANCE: "Insufficient deposited balance",
    PRICE_MISMATCH: "Prices do not cross",
    DUPLICATE_ORDER: "Order commitment already exists",
    EXPIRED_ORDER: "Order deadline has passed",
    INVALID_PROOF: "ZK proof verification failed",
    REUSED_NULLIFIER: "Order nullifier already used",
    SETTLEMENT_FAILED: "Settlement execution failed",
    TOKEN_TRANSFER_FAILED: "Token transfer failed",
    UNAUTHORIZED: "Caller is not authorized",
    PAUSED: "Protocol is paused",
    GUARDIAN_ERROR: "Guardian contract call failed",
    GAS_ESTIMATION_FAILED: "Gas estimation failed",
    NETWORK_ERROR: "Network request failed",
    TIMEOUT: "Operation timed out",
  } as const;

  static isRecoverable(error: any): boolean {
    const msg = error?.message?.toLowerCase() || "";
    return (
      msg.includes("timeout") ||
      msg.includes("network") ||
      msg.includes("econnrefused") ||
      msg.includes("503") ||
      msg.includes("502")
    );
  }
}

/**
 * Retry with exponential backoff
 */
export async function retryWithBackoff<T>(
  fn: () => Promise<T>,
  maxAttempts = 3,
  initialDelayMs = 100
): Promise<T> {
  let lastError: any;

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error;

      if (!DarkPoolError.isRecoverable(error)) {
        throw error;
      }

      if (attempt < maxAttempts - 1) {
        const delayMs = initialDelayMs * Math.pow(2, attempt);
        await new Promise((resolve) => setTimeout(resolve, delayMs));
      }
    }
  }

  throw new DarkPoolError("TIMEOUT", { attempts: maxAttempts, lastError });
}

// ═══════════════════════════════════════════════════════════════
// VALIDATION UTILITIES
// ═══════════════════════════════════════════════════════════════

export class Validator {
  static validateAddress(address: string): void {
    if (!ethers.isAddress(address)) {
      throw new DarkPoolError("INVALID_ORDER", { field: "address", value: address });
    }
  }

  static validateAmount(amount: bigint, minAmount = 0n, maxAmount = ethers.MaxUint256): void {
    if (amount < minAmount || amount > maxAmount) {
      throw new DarkPoolError("INVALID_ORDER", {
        field: "amount",
        value: amount.toString(),
        min: minAmount.toString(),
        max: maxAmount.toString(),
      });
    }
  }

  static validatePrice(price: bigint, maxPrice = BigInt("1" + "0".repeat(36))): void {
    if (price === 0n) {
      throw new DarkPoolError("INVALID_ORDER", { field: "price", reason: "Cannot be zero" });
    }
    if (price > maxPrice) {
      throw new DarkPoolError("INVALID_ORDER", { field: "price", reason: "Exceeds maximum" });
    }
  }

  static validateSide(side: bigint): void {
    if (side !== 0n && side !== 1n) {
      throw new DarkPoolError("INVALID_ORDER", { field: "side", value: side.toString() });
    }
  }

  static validateDeadline(deadline: bigint, currentBlock: bigint, maxTTL: bigint): void {
    if (deadline <= currentBlock) {
      throw new DarkPoolError("EXPIRED_ORDER", { deadline, currentBlock });
    }
    if (deadline > currentBlock + maxTTL) {
      throw new DarkPoolError("INVALID_ORDER", { field: "deadline", reason: "Too far in future" });
    }
  }

  static validateTokenPair(tokenIn: string, tokenOut: string): void {
    this.validateAddress(tokenIn);
    this.validateAddress(tokenOut);
    if (tokenIn === tokenOut) {
      throw new DarkPoolError("INVALID_ORDER", { reason: "Cannot trade same token" });
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// EVENT MONITORING
// ═══════════════════════════════════════════════════════════════

export interface DarkPoolEvent {
  name: string;
  blockNumber: number;
  transactionHash: string;
  logIndex: number;
  args: any;
  timestamp: number;
}

/**
 * Monitor DarkPool events in real-time
 */
export class EventMonitor {
  private contract: ethers.Contract;
  private listeners: Map<string, Set<(event: DarkPoolEvent) => void>> = new Map();
  private eventCache: DarkPoolEvent[] = [];
  private maxCacheSize: number;

  constructor(contract: ethers.Contract, maxCacheSize = 1000) {
    this.contract = contract;
    this.maxCacheSize = maxCacheSize;
  }

  /**
   * Subscribe to event
   */
  on(eventName: string, listener: (event: DarkPoolEvent) => void): () => void {
    if (!this.listeners.has(eventName)) {
      this.listeners.set(eventName, new Set());

      // Setup contract listener
      this.contract.on(eventName, (...args: any[]) => {
        const event = this.parseEvent(eventName, args);
        this.eventCache.push(event);

        if (this.eventCache.length > this.maxCacheSize) {
          this.eventCache.shift();
        }

        // Notify all subscribers
        const subscribers = this.listeners.get(eventName);
        if (subscribers) {
          subscribers.forEach((cb) => {
            try {
              cb(event);
            } catch (error) {
              console.error(`Error in event listener for ${eventName}:`, error);
            }
          });
        }
      });
    }

    this.listeners.get(eventName)!.add(listener);

    // Return unsubscribe function
    return () => {
      this.listeners.get(eventName)?.delete(listener);
    };
  }

  /**
   * Get recent events
   */
  getRecentEvents(eventName: string, limit = 100): DarkPoolEvent[] {
    return this.eventCache
      .filter((e) => e.name === eventName)
      .slice(-limit);
  }

  /**
   * Query historical events
   */
  async queryEvents(eventName: string, fromBlock: number, toBlock: number): Promise<DarkPoolEvent[]> {
    const filter = this.contract.filters[eventName]?.();
    if (!filter) throw new Error(`Unknown event: ${eventName}`);

    const logs = await this.contract.provider?.getLogs({
      address: this.contract.address,
      topics: filter.topics,
      fromBlock,
      toBlock,
    });

    if (!logs) return [];

    return logs.map((log: EventLog) => this.parseEvent(eventName, log));
  }

  private parseEvent(eventName: string, args: any): DarkPoolEvent {
    return {
      name: eventName,
      blockNumber: args.blockNumber || 0,
      transactionHash: args.transactionHash || "",
      logIndex: args.logIndex || 0,
      args: this.extractArgs(args),
      timestamp: Date.now(),
    };
  }

  private extractArgs(args: any): any {
    if (!args) return {};
    if (Array.isArray(args)) {
      return args.filter((_, i) => typeof args[i] !== "function");
    }
    const result: any = {};
    for (const [key, value] of Object.entries(args)) {
      if (typeof value !== "function" && !key.match(/^\d+$/)) {
        result[key] = value;
      }
    }
    return result;
  }
}

// ═══════════════════════════════════════════════════════════════
// BATCH OPERATIONS
// ═══════════════════════════════════════════════════════════════

/**
 * Batch multiple operations for gas efficiency
 */
export class BatchExecutor {
  private contract: ethers.Contract;
  private signer: ethers.Signer;
  private batchSize: number;

  constructor(contract: ethers.Contract, signer: ethers.Signer, batchSize = 10) {
    this.contract = contract;
    this.signer = signer;
    this.batchSize = batchSize;
  }

  /**
   * Execute multiple deposits in sequence (not batched, but optimized)
   */
  async batchDeposit(
    deposits: {
      token: string;
      amount: bigint;
      root: bigint;
    }[]
  ): Promise<ethers.ContractTransactionReceipt[]> {
    const results: ethers.ContractTransactionReceipt[] = [];

    for (let i = 0; i < deposits.length; i += this.batchSize) {
      const batch = deposits.slice(i, i + this.batchSize);

      for (const deposit of batch) {
        await retryWithBackoff(async () => {
          const tx = await this.contract.deposit(deposit.token, deposit.amount, ethers.toBeHex(deposit.root, 32));
          const receipt = await tx.wait();
          if (receipt) results.push(receipt);
        });
      }
    }

    return results;
  }

  /**
   * Settle multiple matched pairs efficiently
   */
  async batchSettle(
    settlements: {
      buyCommitment: bigint;
      sellCommitment: bigint;
      settledPrice: bigint;
      settledQty: bigint;
      proof: any;
    }[]
  ): Promise<ethers.ContractTransactionReceipt[]> {
    const results: ethers.ContractTransactionReceipt[] = [];

    for (let i = 0; i < settlements.length; i += this.batchSize) {
      const batch = settlements.slice(i, i + this.batchSize);

      for (const settlement of batch) {
        await retryWithBackoff(async () => {
          const tx = await this.contract.settle(
            settlement.buyCommitment,
            settlement.sellCommitment,
            settlement.settledPrice,
            settlement.settledQty,
            settlement.proof.a,
            settlement.proof.b,
            settlement.proof.c,
            [settlement.buyCommitment, settlement.sellCommitment, settlement.settledPrice, settlement.settledQty]
          );
          const receipt = await tx.wait();
          if (receipt) results.push(receipt);
        });
      }
    }

    return results;
  }
}

// ═══════════════════════════════════════════════════════════════
// HEALTH CHECKS & MONITORING
// ═══════════════════════════════════════════════════════════════

export interface HealthStatus {
  isHealthy: boolean;
  uptime: number;
  lastBlockNumber: number;
  lastCheckTimestamp: number;
  errors: string[];
  warnings: string[];
}

/**
 * Monitor protocol health
 */
export class HealthMonitor {
  private contract: ethers.Contract;
  private provider: ethers.Provider;
  private startTime: number = Date.now();
  private lastCheck: number = 0;
  private errors: string[] = [];
  private warnings: string[] = [];

  constructor(contract: ethers.Contract, provider: ethers.Provider) {
    this.contract = contract;
    this.provider = provider;
  }

  /**
   * Run health check
   */
  async check(): Promise<HealthStatus> {
    this.errors = [];
    this.warnings = [];

    try {
      // Check provider connectivity
      const blockNumber = await this.provider.getBlockNumber();

      // Check contract is accessible
      try {
        const isPaused = await this.contract.pauseExpiresAt?.();
        if (isPaused && isPaused > BigInt(Math.floor(Date.now() / 1000))) {
          this.warnings.push("Protocol is paused");
        }
      } catch (e) {
        this.errors.push("Cannot read contract state");
      }

      // Check for recent activity
      try {
        const currentBlock = await this.provider.getBlockNumber();
        if (currentBlock < 1) {
          this.errors.push("Cannot get current block");
        }
      } catch (e) {
        this.errors.push("Provider error: " + String(e));
      }
    } catch (e) {
      this.errors.push("Health check failed: " + String(e));
    }

    this.lastCheck = Date.now();

    return {
      isHealthy: this.errors.length === 0,
      uptime: Date.now() - this.startTime,
      lastBlockNumber: await this.provider.getBlockNumber(),
      lastCheckTimestamp: this.lastCheck,
      errors: this.errors,
      warnings: this.warnings,
    };
  }
}

export default {
  DarkPoolError,
  Validator,
  EventMonitor,
  BatchExecutor,
  HealthMonitor,
  retryWithBackoff,
};
