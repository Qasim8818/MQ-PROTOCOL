import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, mine } from "@nomicfoundation/hardhat-network-helpers";

const ZERO_A: [bigint, bigint] = [0n, 0n];
const ZERO_B: [[bigint, bigint], [bigint, bigint]] = [
  [0n, 0n],
  [0n, 0n],
];
const ZERO_C: [bigint, bigint] = [0n, 0n];

const PRICE_SCALE = 10n ** 18n;
const MIN_QUANTITY = ethers.parseEther("1");
const FEE_BPS = 100n; // 1%
const ORDER_TTL_BLOCKS = 1_000n;

function bytes32(value: bigint): string {
  return ethers.zeroPadValue(ethers.toBeHex(value), 32);
}

async function deployFixture(overrides?: {
  orderVerifierResult?: boolean;
  matchVerifierResult?: boolean;
  cancelVerifierResult?: boolean;
  depositTransitionVerifierResult?: boolean;
}) {
  const [owner, buyer, seller, matcher] = await ethers.getSigners();

  const MockVerifier = await ethers.getContractFactory("MockVerifier");
  const orderVerifier = await MockVerifier.deploy(overrides?.orderVerifierResult ?? true);
  const matchVerifier = await MockVerifier.deploy(overrides?.matchVerifierResult ?? true);
  const cancelVerifier = await MockVerifier.deploy(overrides?.cancelVerifierResult ?? true);
  const depositTransitionVerifier = await MockVerifier.deploy(
    overrides?.depositTransitionVerifierResult ?? true
  );

  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const tokenA = await MockERC20.deploy("Token A", "TKA", 18);
  const tokenB = await MockERC20.deploy("Token B", "TKB", 18);

  await tokenA.waitForDeployment();
  await tokenB.waitForDeployment();

  await tokenA.mint(buyer.address, ethers.parseEther("1000"));
  await tokenA.mint(seller.address, ethers.parseEther("1000"));
  await tokenB.mint(buyer.address, ethers.parseEther("1000"));
  await tokenB.mint(seller.address, ethers.parseEther("1000"));

  const DarkPoolCore = await ethers.getContractFactory("DarkPoolCore");
  const MockGuardian = await ethers.getContractFactory("MockGuardian");
  const guardian = await MockGuardian.deploy();
  await guardian.waitForDeployment();

  const darkPool: any = await (DarkPoolCore as any).deploy({
    orderVerifier: await orderVerifier.getAddress(),
    matchVerifier: await matchVerifier.getAddress(),
    cancelVerifier: await cancelVerifier.getAddress(),
    depositTransitionVerifier: await depositTransitionVerifier.getAddress(),
    feeRecipient: owner.address,
    guardian: await guardian.getAddress(),
    protocolFeeBps: FEE_BPS,
    orderTTLBlocks: ORDER_TTL_BLOCKS,
    minQuantity: MIN_QUANTITY,
    emptyTreeRoot: ethers.ZeroHash,
    maxNotesPerBlock: 1000,
  });

  return {
    owner,
    buyer,
    seller,
    matcher,
    darkPool,
    tokenA,
    tokenB,
    guardian,
  };
}

async function deployFixtureWithRejectingOrderVerifier() {
  return deployFixture({
    orderVerifierResult: false,
    depositTransitionVerifierResult: true,
  });
}

async function deposit(
  darkPool: any,
  token: any,
  signer: any,
  amount: bigint,
  root: bigint
) {
  await token.connect(signer).approve(await darkPool.getAddress(), amount);
  await darkPool.connect(signer).deposit(
    await token.getAddress(),
    amount,
    bytes32(root),
    ZERO_A,
    ZERO_B,
    ZERO_C
  );
}

async function createNote(
  darkPool: any,
  signer: any,
  params: {
    commitment: bigint;
    nullifier: bigint;
    tokenIn: string;
    tokenOut: string;
    amountLocked: bigint;
    deadline: bigint;
  }
) {
  const tx = await darkPool.connect(signer).createNote(
    bytes32(params.commitment),
    bytes32(params.nullifier),
    params.tokenIn,
    params.tokenOut,
    params.amountLocked,
    params.deadline,
    ZERO_A,
    ZERO_B,
    ZERO_C
  );

  return tx;
}


describe("DarkPoolCore", function () {
  it("settles a matched pair and pays the fee recipient", async function () {
    const { owner, buyer, seller, matcher, darkPool, tokenA, tokenB } = await loadFixture(deployFixture);
    const deadline = BigInt((await ethers.provider.getBlockNumber()) + 100);

    await deposit(darkPool, tokenA, buyer, ethers.parseEther("200"), 11n);
    await deposit(darkPool, tokenB, seller, ethers.parseEther("100"), 22n);

    expect(await darkPool.userDepositRoots(buyer.address)).to.equal(bytes32(11n));
    expect(await darkPool.userDepositRoots(seller.address)).to.equal(bytes32(22n));

    await createNote(darkPool, buyer, {
      commitment: 1n,
      nullifier: 101n,
      tokenIn: await tokenA.getAddress(),
      tokenOut: await tokenB.getAddress(),
      amountLocked: ethers.parseEther("200"),
      deadline,
    });

    await createNote(darkPool, seller, {
      commitment: 2n,
      nullifier: 202n,
      tokenIn: await tokenB.getAddress(),
      tokenOut: await tokenA.getAddress(),
      amountLocked: ethers.parseEther("100"),
      deadline,
    });

    expect(await darkPool.lockedBalances(buyer.address, await tokenA.getAddress())).to.equal(
      ethers.parseEther("200")
    );
    expect(await darkPool.lockedBalances(seller.address, await tokenB.getAddress())).to.equal(
      ethers.parseEther("100")
    );

    await darkPool.connect(matcher).settle(
      ZERO_A,
      ZERO_B,
      ZERO_C,
      bytes32(1010n),
      bytes32(2020n),
      2n * PRICE_SCALE,
      ethers.parseEther("60"),
      bytes32(1n),
      bytes32(2n)
    );

    expect(await tokenA.balanceOf(owner.address)).to.equal(ethers.parseEther("1.2"));
    expect(await tokenA.balanceOf(buyer.address)).to.equal(ethers.parseEther("800"));
    expect(await tokenB.balanceOf(buyer.address)).to.equal(ethers.parseEther("1059.4"));
    expect(await tokenA.balanceOf(seller.address)).to.equal(ethers.parseEther("1118.8"));
    expect(await tokenB.balanceOf(seller.address)).to.equal(ethers.parseEther("900"));

    const buyNote = await darkPool.notes(bytes32(1n));
    const sellNote = await darkPool.notes(bytes32(2n));
    expect(buyNote.state).to.equal(2n);
    expect(sellNote.state).to.equal(2n);
    expect(await darkPool.nullifiers(bytes32(101n))).to.equal(true);
    expect(await darkPool.nullifiers(bytes32(202n))).to.equal(true);
    expect(await darkPool.deposits(buyer.address, await tokenA.getAddress())).to.equal(
      ethers.parseEther("80")
    );
    expect(await darkPool.deposits(seller.address, await tokenB.getAddress())).to.equal(
      ethers.parseEther("40")
    );
  });

  it("prevents withdrawing locked collateral but allows withdrawing unlocked deposits", async function () {
    const { buyer, darkPool, tokenA, tokenB } = await loadFixture(deployFixture);
    const deadline = BigInt((await ethers.provider.getBlockNumber()) + 100);

    await deposit(darkPool, tokenA, buyer, ethers.parseEther("100"), 31n);
    await createNote(darkPool, buyer, {
      commitment: 3n,
      nullifier: 303n,
      tokenIn: await tokenA.getAddress(),
      tokenOut: await tokenB.getAddress(),
      amountLocked: ethers.parseEther("60"),
      deadline,
    });

    await expect(
      darkPool.connect(buyer).withdraw(
        await tokenA.getAddress(),
        ethers.parseEther("50"),
        bytes32(32n),
        ZERO_A,
        ZERO_B,
        ZERO_C
      )
    ).to.be.revertedWithCustomError(darkPool, "InsufficientUnlockedDeposit");

    await darkPool.connect(buyer).withdraw(
      await tokenA.getAddress(),
      ethers.parseEther("40"),
      bytes32(32n),
      ZERO_A,
      ZERO_B,
      ZERO_C
    );

    expect(await darkPool.deposits(buyer.address, await tokenA.getAddress())).to.equal(
      ethers.parseEther("60")
    );
    expect(await darkPool.userDepositRoots(buyer.address)).to.equal(bytes32(32n));
    expect(await tokenA.balanceOf(buyer.address)).to.equal(ethers.parseEther("940"));
  });

  it("cancels an order and refunds the locked collateral", async function () {
    const { buyer, darkPool, tokenA, tokenB } = await loadFixture(deployFixture);
    const deadline = BigInt((await ethers.provider.getBlockNumber()) + 100);

    await deposit(darkPool, tokenA, buyer, ethers.parseEther("50"), 41n);
    await createNote(darkPool, buyer, {
      commitment: 4n,
      nullifier: 404n,
      tokenIn: await tokenA.getAddress(),
      tokenOut: await tokenB.getAddress(),
      amountLocked: ethers.parseEther("50"),
      deadline,
    });

    await darkPool.connect(buyer).cancelNote(
      bytes32(4n),
      bytes32(4040n),
      ZERO_A,
      ZERO_B,
      ZERO_C
    );

    const note = await darkPool.notes(bytes32(4n));
    expect(note.state).to.equal(3n);
    expect(await darkPool.nullifiers(bytes32(404n))).to.equal(true);
    expect(await darkPool.nullifiers(bytes32(4040n))).to.equal(true);
    expect(await darkPool.deposits(buyer.address, await tokenA.getAddress())).to.equal(ethers.parseEther("50"));
    expect(await darkPool.lockedBalances(buyer.address, await tokenA.getAddress())).to.equal(0n);
    expect(await tokenA.balanceOf(buyer.address)).to.equal(ethers.parseEther("950"));
  });

  it("allows timeoutExit after the order deadline passes", async function () {
    const { buyer, darkPool, tokenA, tokenB } = await loadFixture(deployFixture);
    const deadline = BigInt((await ethers.provider.getBlockNumber()) + 5);

    await deposit(darkPool, tokenA, buyer, ethers.parseEther("25"), 51n);
    await createNote(darkPool, buyer, {
      commitment: 5n,
      nullifier: 505n,
      tokenIn: await tokenA.getAddress(),
      tokenOut: await tokenB.getAddress(),
      amountLocked: ethers.parseEther("25"),
      deadline,
    });

    await mine(2);

    await darkPool.connect(buyer).timeoutExit(
      bytes32(5n),
      bytes32(5050n),
      ZERO_A,
      ZERO_B,
      ZERO_C
    );

    const note = await darkPool.notes(bytes32(5n));
    expect(note.state).to.equal(3n);
    expect(await tokenA.balanceOf(buyer.address)).to.equal(ethers.parseEther("975"));
  });

  it("rejects nullifier reuse after a note has been cancelled", async function () {
    const { buyer, darkPool, tokenA, tokenB } = await loadFixture(deployFixture);
    const deadline = BigInt((await ethers.provider.getBlockNumber()) + 100);

    await deposit(darkPool, tokenA, buyer, ethers.parseEther("50"), 61n);
    await createNote(darkPool, buyer, {
      commitment: 6n,
      nullifier: 606n,
      tokenIn: await tokenA.getAddress(),
      tokenOut: await tokenB.getAddress(),
      amountLocked: ethers.parseEther("50"),
      deadline,
    });

    await darkPool.connect(buyer).cancelNote(
      bytes32(6n),
      bytes32(6060n),
      ZERO_A,
      ZERO_B,
      ZERO_C
    );

    await deposit(darkPool, tokenA, buyer, ethers.parseEther("50"), 62n);

    await expect(
      darkPool.connect(buyer).createNote(
        bytes32(7n),
        bytes32(6060n),
        await tokenA.getAddress(),
        await tokenB.getAddress(),
        ethers.parseEther("50"),
        deadline + 10n,
        ZERO_A,
        ZERO_B,
        ZERO_C
      )
    ).to.be.revertedWithCustomError(darkPool, "NullifierAlreadySpent");
  });

  it("rejects createNote when the verifier rejects the proof", async function () {
    const { buyer, darkPool, tokenA, tokenB } = await loadFixture(deployFixtureWithRejectingOrderVerifier);
    const deadline = BigInt((await ethers.provider.getBlockNumber()) + 100);

    await deposit(darkPool, tokenA, buyer, ethers.parseEther("10"), 71n);

    await expect(
      darkPool.connect(buyer).createNote(
        bytes32(8n),
        bytes32(808n),
        await tokenA.getAddress(),
        await tokenB.getAddress(),
        ethers.parseEther("10"),
        deadline,
        ZERO_A,
        ZERO_B,
        ZERO_C
      )
    ).to.be.revertedWithCustomError(darkPool, "ProofVerificationFailed");
  });

  it("auto-expiry unpause emits AutoUnpaused (not guardian address)", async function () {
    const { buyer, darkPool, tokenA, tokenB, guardian } = await loadFixture(deployFixture);

// Pause
await guardian.pauseDarkPool(await darkPool.getAddress());


    // Fast-forward beyond MAX_PAUSE_BLOCKS so the next user call triggers auto-expiry.
    // MAX_PAUSE_BLOCKS is 50_400 in the contract.
    await mine(50_401);


    const deadline = BigInt((await ethers.provider.getBlockNumber()) + 100);

    // Prepare minimal funds to hit createNote path.
    await deposit(darkPool, tokenA, buyer, ethers.parseEther("5"), 9001n);

    // Expect the auto-unpause to happen inside the next user call.
    const tx = await createNote(darkPool, buyer, {
      commitment: 9002n,
      nullifier: 9003n,
      tokenIn: await tokenA.getAddress(),
      tokenOut: await tokenB.getAddress(),
      amountLocked: ethers.parseEther("1"),
      deadline,
    });

    await expect(tx).to.emit(darkPool, "AutoUnpaused");

  });
});

