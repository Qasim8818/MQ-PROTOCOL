import { poseidon2, poseidon3, poseidon8 } from "poseidon-lite";
import { randomBytes } from "crypto";

type FieldLike = bigint | string;

/**
 * Order structure matching circuit inputs
 */
export interface Order {
  price: bigint;
  quantity: bigint;
  side: bigint; // 0 = sell, 1 = buy
  salt: bigint;
  tokenIn: string;
  tokenOut: string;
  deadline: bigint;
  owner: string;
}

/**
 * Note structure for tracking orders on-chain
 */
export interface Note {
  commitment: bigint;
  nullifier: bigint;
  owner: string;
  tokenIn: string;
  tokenOut: string;
  amountLocked: bigint;
  deadline: bigint;
}

/**
 * Compute order commitment: Poseidon8(price, quantity, side, salt, tokenIn, tokenOut, deadline, owner)
 */
export function commitOrder(order: Order): bigint {
  return poseidon8([
    order.price,
    order.quantity,
    order.side,
    order.salt,
    toField(order.tokenIn),
    toField(order.tokenOut),
    order.deadline,
    toField(order.owner),
  ]);
}

/**
 * Compute nullifier: Poseidon2(spendingKey, commitment)
 * Prevents double-spending by binding nullifier to owner's spending key
 */
export function computeNullifier(spendingKey: bigint, commitment: bigint): bigint {
  return poseidon2([spendingKey, commitment]);
}

/**
 * Compute deposit leaf: Poseidon3(owner, tokenIn, depositAmount)
 * Used in Merkle proof for solvency check
 */
export function computeDepositLeaf(
  owner: FieldLike,
  tokenIn: FieldLike,
  depositAmount: bigint
): bigint {
  return poseidon3([toField(owner), toField(tokenIn), depositAmount]);
}

/**
 * Convert Ethereum address to field element
 */
export function addressToField(address: string): bigint {
  return BigInt("0x" + address.slice(2).toLowerCase());
}

function toField(value: FieldLike): bigint {
  if (typeof value === "bigint") {
    return value;
  }

  return value.startsWith("0x") || value.startsWith("0X")
    ? addressToField(value)
    : BigInt(value);
}

/**
 * Normalize price to PRICE_SCALE (1e18)
 * 
 * Raw price: tokenOut_amount / tokenIn_amount
 * Normalized: (tokenOut_amount / tokenIn_amount) * 1e18
 * 
 * Example:
 * - tokenIn = 6 decimals (USDC)
 * - tokenOut = 18 decimals (ETH)
 * - 1 ETH costs 1500 USDC
 * - Raw: 1500 * 1e6 / 1e18 = 1.5e-12
 * - Normalized: 1.5e-12 * 1e18 = 1500e6
 */
export function normalizePrice(
  rawPrice: bigint,
  inDecimals: number,
  outDecimals: number
): bigint {
  const PRICE_SCALE = 10n ** 18n;

  if (outDecimals >= inDecimals) {
    const scaleFactor = 10n ** BigInt(outDecimals - inDecimals);
    return (rawPrice * PRICE_SCALE) / scaleFactor;
  }

  const scaleFactor = 10n ** BigInt(inDecimals - outDecimals);
  return rawPrice * PRICE_SCALE * scaleFactor;
}

/**
 * Generate cryptographically secure random salt (248 bits)
 */
export function randomSalt(): bigint {
  return BigInt("0x" + randomBytes(31).toString("hex"));
}

/**
 * BN254 scalar field prime
 */
export const FIELD_PRIME = BigInt(
  "21888242871839275222246405745257275088548364400416034343698204186575808495617"
);

/**
 * Ensure value is in valid field range
 */
export function assertInField(value: bigint): void {
  if (value >= FIELD_PRIME) {
    throw new Error(`Value ${value} is not in BN254 field`);
  }
}
