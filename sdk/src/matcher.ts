import { ethers } from "ethers";
import { prove, ARTIFACTS } from "./prover";
import { addressToField } from "./crypto";

/**
 * Matcher node for dark pool: finds compatible order pairs and settles them
 */
export class DarkPoolMatcher {
  private contract: any; // ethers.Contract

  constructor(contract: any) {
    this.contract = contract;
  }

  /**
   * Find best matching pair from order array
   * Uses price-time priority: highest buy price, lowest sell price
   */
  async findBestMatch(
    orders: DecryptedOrder[]
  ): Promise<MatchResult | null> {
    const buys = orders.filter((o) => o.side === 1n).sort((a, b) => {
      if (b.price !== a.price) return Number(b.price - a.price);
      return Number(a.timestamp - b.timestamp);
    });

    const sells = orders.filter((o) => o.side === 0n).sort((a, b) => {
      if (a.price !== b.price) return Number(a.price - b.price);
      return Number(a.timestamp - b.timestamp);
    });

    if (buys.length === 0 || sells.length === 0) {
      return null;
    }

    for (const buy of buys) {
      for (const sell of sells) {
        if (
          buy.tokenIn === sell.tokenOut &&
          buy.tokenOut === sell.tokenIn &&
          buy.price >= sell.price
        ) {
          return {
            buy,
            sell,
            settledPrice: this.computeSettledPrice(buy.price, sell.price),
            settledQty: this.computeSettledQty(buy.quantity, sell.quantity),
          };
        }
      }
    }

    return null;
  }

  /**
   * Prove and settle a matched pair
   */
  async proveAndSettle(match: MatchResult): Promise<any> {
    const matcherAddress = await this.resolveMatcherAddress();
    const protocolFeeBps = await this.contract.PROTOCOL_FEE_BPS();

    const proof = await prove(ARTIFACTS.matchProof, {
      buyCommitment: match.buy.commitment.toString(),
      sellCommitment: match.sell.commitment.toString(),
      settledPrice: match.settledPrice.toString(),
      settledQty: match.settledQty.toString(),
      buyNullifier: match.buy.nullifier.toString(),
      sellNullifier: match.sell.nullifier.toString(),
      matcherAddress: addressToField(matcherAddress).toString(),
      protocolFeeBps: protocolFeeBps.toString(),

      buyPrice: match.buy.price.toString(),
      buyQuantity: match.buy.quantity.toString(),
      buySide: "1",
      buySalt: match.buy.salt.toString(),
      buyTokenIn: addressToField(match.buy.tokenIn).toString(),
      buyTokenOut: addressToField(match.buy.tokenOut).toString(),
      buyDeadline: match.buy.deadline.toString(),
      buyOwner: addressToField(match.buy.owner).toString(),
      buySpendingKey: match.buy.spendingKey.toString(),

      sellPrice: match.sell.price.toString(),
      sellQuantity: match.sell.quantity.toString(),
      sellSide: "0",
      sellSalt: match.sell.salt.toString(),
      sellTokenIn: addressToField(match.sell.tokenIn).toString(),
      sellTokenOut: addressToField(match.sell.tokenOut).toString(),
      sellDeadline: match.sell.deadline.toString(),
      sellOwner: addressToField(match.sell.owner).toString(),
      sellSpendingKey: match.sell.spendingKey.toString(),
    });

    const tx = await this.contract.settle(
      proof.calldata.a,
      proof.calldata.b,
      proof.calldata.c,
      ethers.toBeHex(match.buy.nullifier, 32),
      ethers.toBeHex(match.sell.nullifier, 32),
      match.settledPrice,
      match.settledQty,
      ethers.toBeHex(match.buy.commitment, 32),
      ethers.toBeHex(match.sell.commitment, 32),
      match.buy.owner,
      match.sell.owner
    );

    return tx.wait();
  }

  /**
   * Compute settled price (midpoint for fairness)
   */
  private computeSettledPrice(buyPrice: bigint, sellPrice: bigint): bigint {
    return (buyPrice + sellPrice) / 2n;
  }

  /**
   * Compute settled quantity (minimum of both sides)
   */
  private computeSettledQty(buyQty: bigint, sellQty: bigint): bigint {
    return buyQty < sellQty ? buyQty : sellQty;
  }

  private async resolveMatcherAddress(): Promise<string> {
    const runner = this.contract.runner as ethers.Signer | null;
    if (!runner || typeof runner.getAddress !== "function") {
      throw new Error("Matcher contract must be connected to a signer");
    }

    return runner.getAddress();
  }
}

/**
 * Decrypted order (shared by user with matcher)
 */
export interface DecryptedOrder {
  commitment: bigint;
  nullifier: bigint;
  price: bigint;
  quantity: bigint;
  side: bigint;
  salt: bigint;
  tokenIn: string;
  tokenOut: string;
  deadline: bigint;
  owner: string;
  spendingKey: bigint;
  timestamp: bigint;
}

/**
 * Match result
 */
export interface MatchResult {
  buy: DecryptedOrder;
  sell: DecryptedOrder;
  settledPrice: bigint;
  settledQty: bigint;
}
