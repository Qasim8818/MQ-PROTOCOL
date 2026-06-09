import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Deployment script for DarkPoolCore to Arbitrum Sepolia or local testnet
 * 
 * Prerequisites:
 * 1. Run circuits/compile.sh to generate verifier contracts
 * 2. Set PRIVATE_KEY in .env
 * 3. Run: npx hardhat run scripts/deploy.ts --network arbitrumSepolia
 */

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`Deploying with account: ${deployer.address}`);

  const network = await ethers.provider.getNetwork();
  console.log(`Network: ${network.name} (chainId: ${network.chainId})`);
  const isMainnet = network.chainId === 42161n;

  let tokenAAddr: string | null = null;
  let tokenBAddr: string | null = null;

  if (!isMainnet) {
    console.log("\n1. Deploying test tokens...");

  const MockERC20 = await ethers.getContractFactory("MockERC20");
    const tokenA = await MockERC20.deploy("Token A", "TKA", 18);
    const tokenB = await MockERC20.deploy("Token B", "TKB", 18);

    await tokenA.waitForDeployment();
    await tokenB.waitForDeployment();

    tokenAAddr = await tokenA.getAddress();
    tokenBAddr = await tokenB.getAddress();

    console.log(`  TokenA deployed: ${tokenAAddr}`);
    console.log(`  TokenB deployed: ${tokenBAddr}`);
  } else {
    console.log("\n1. Skipping mock token deployment on Arbitrum One.");
  }

  // ===== Deploy Verifiers =====
  console.log("\n2. Deploying verifier contracts...");
  let orderVerifier, matchVerifier, cancelVerifier, depositTransitionVerifier;
  
  // Try to load generated verifiers, fallback to MockVerifier for Day 1 demo
  try {
    const OrderVerifier = await ethers.getContractFactory("OrderValidityVerifier");
    orderVerifier = await OrderVerifier.deploy();
    await orderVerifier.waitForDeployment();
    console.log(`  ✅ OrderValidityVerifier deployed: ${await orderVerifier.getAddress()}`);
  } catch (e: any) {
    console.log(`  ⚠️  OrderValidityVerifier not found (expected if circuits not compiled)`);
    console.log(`     Falling back to MockVerifier for demo...`);
    const MockVerifier = await ethers.getContractFactory("MockVerifier");
    orderVerifier = await MockVerifier.deploy(true);
    await orderVerifier.waitForDeployment();
    console.log(`  ℹ️  MockVerifier deployed: ${await orderVerifier.getAddress()}`);
  }

  try {
    const MatchVerifier = await ethers.getContractFactory("MatchProofVerifier");
    matchVerifier = await MatchVerifier.deploy();
    await matchVerifier.waitForDeployment();
    console.log(`  ✅ MatchProofVerifier deployed: ${await matchVerifier.getAddress()}`);
  } catch (e: any) {
    console.log(`  ⚠️  MatchProofVerifier not found`);
    const MockVerifier = await ethers.getContractFactory("MockVerifier");
    matchVerifier = await MockVerifier.deploy(true);
    await matchVerifier.waitForDeployment();
    console.log(`  ℹ️  MockVerifier deployed: ${await matchVerifier.getAddress()}`);
  }

  try {
    const CancelVerifier = await ethers.getContractFactory("CancelProofVerifier");
    cancelVerifier = await CancelVerifier.deploy();
    await cancelVerifier.waitForDeployment();
    console.log(`  ✅ CancelProofVerifier deployed: ${await cancelVerifier.getAddress()}`);
  } catch (e: any) {
    console.log(`  ⚠️  CancelProofVerifier not found`);
    const MockVerifier = await ethers.getContractFactory("MockVerifier");
    cancelVerifier = await MockVerifier.deploy(true);
    await cancelVerifier.waitForDeployment();
    console.log(`  ℹ️  MockVerifier deployed: ${await cancelVerifier.getAddress()}`);
  }

  try {
    // Deposit verifier - try loading DepositTransitionVerifier if it exists
    const DepositVerifier = await ethers.getContractFactory("DepositTransitionVerifier");
    depositTransitionVerifier = await DepositVerifier.deploy();
    await depositTransitionVerifier.waitForDeployment();
    console.log(`  ✅ DepositTransitionVerifier deployed: ${await depositTransitionVerifier.getAddress()}`);
  } catch (e: any) {
    console.log(`  ⚠️  DepositTransitionVerifier not found`);
    const MockVerifier = await ethers.getContractFactory("MockVerifier");
    depositTransitionVerifier = await MockVerifier.deploy(true);
    await depositTransitionVerifier.waitForDeployment();
    console.log(`  ℹ️  MockVerifier deployed: ${await depositTransitionVerifier.getAddress()}`);
  }

  // ===== Deploy Guardian =====
  console.log("\n3. Deploying Guardian...");
  
  const MockGuardian = await ethers.getContractFactory("MockGuardian");
  const guardian = await MockGuardian.deploy();
  await guardian.waitForDeployment();
  console.log(`  Guardian deployed: ${await guardian.getAddress()}`);

  // ===== Deploy DarkPoolCore =====
  console.log("\n4. Deploying DarkPoolCore...");
  
  const DarkPoolCore = await ethers.getContractFactory("DarkPoolCore");
    const darkPoolCore: any = await (DarkPoolCore as any).deploy({
      orderVerifier: await orderVerifier.getAddress(),
      matchVerifier: await matchVerifier.getAddress(),
      cancelVerifier: await cancelVerifier.getAddress(),
      depositTransitionVerifier: await depositTransitionVerifier.getAddress(),
      feeRecipient: deployer.address,
      guardian: await guardian.getAddress(),
      protocolFeeBps: 100n, // 1%
      orderTTLBlocks: 1000n,
      minQuantity: ethers.parseEther("1"),
      emptyTreeRoot: ethers.ZeroHash,
      maxNotesPerBlock: 1000n,
    });
  
  await darkPoolCore.waitForDeployment();
  const darkPoolAddr = await darkPoolCore.getAddress();
  console.log(`  DarkPoolCore deployed: ${darkPoolAddr}`);

  // ===== Save Deployment Info =====
  console.log("\n5. Saving deployment info...");
  
  const deploymentDir = path.join(__dirname, "../deployments");
  if (!fs.existsSync(deploymentDir)) {
    fs.mkdirSync(deploymentDir, { recursive: true });
  }

  const networkName = network.name === "hardhat" ? "localhost" : network.name;
  const deploymentFile = path.join(deploymentDir, `${networkName}.json`);

  const deploymentInfo = {
    network: networkName,
    chainId: network.chainId,
    timestamp: new Date().toISOString(),
    deployer: deployer.address,
    contracts: {
      tokenA: tokenAAddr,
      tokenB: tokenBAddr,
      orderVerifier: await orderVerifier.getAddress(),
      matchVerifier: await matchVerifier.getAddress(),
      cancelVerifier: await cancelVerifier.getAddress(),
      guardian: await guardian.getAddress(),
      darkPoolCore: darkPoolAddr,
    },
    parameters: {
      feeRecipient: deployer.address,
      protocolFeeBps: 100,
      orderTTLBlocks: 1000,
      minQuantity: ethers.formatEther(ethers.parseEther("1")),
      guardian: await guardian.getAddress(),
    },
  };

  fs.writeFileSync(deploymentFile, JSON.stringify(deploymentInfo, null, 2));
  console.log(`  Deployment info saved to ${deploymentFile}`);

  // ===== Verification (Arbiscan) =====
  if (networkName !== "localhost") {
    console.log("\n6. Waiting for block confirmations...");
    await new Promise((resolve) => setTimeout(resolve, 30_000)); // Wait 30s

    console.log("  To verify on Arbiscan, run:");
    console.log(`  npx hardhat verify --network ${networkName} ${darkPoolAddr} \\`);
    const params = {
      orderVerifier: await orderVerifier.getAddress(),
      matchVerifier: await matchVerifier.getAddress(),
      cancelVerifier: await cancelVerifier.getAddress(),
      depositTransitionVerifier: await orderVerifier.getAddress(),
      feeRecipient: deployer.address,
      guardian: await guardian.getAddress(),
      protocolFeeBps: 100n,
      orderTTLBlocks: 1000n,
      minQuantity: ethers.parseEther("1"),
      emptyTreeRoot: ethers.ZeroHash,
      maxNotesPerBlock: 1000n,
    };
    console.log(`    '${JSON.stringify(params)}'`);
  }

  console.log("\n╔═══════════════════════════════════════════════╗");
  console.log("║  ✅ DEPLOYMENT COMPLETE                       ║");
  console.log("╚═══════════════════════════════════════════════╝");
  console.log(`\nDarkPoolCore:           ${darkPoolAddr}`);
  console.log(`Guardian:               ${await guardian.getAddress()}`);
  if (tokenAAddr) console.log(`WETH (Token A):         ${tokenAAddr}`);
  if (tokenBAddr) console.log(`USDC (Token B):         ${tokenBAddr}`);
  console.log(`OrderValidityVerifier:  ${await orderVerifier.getAddress()}`);
  console.log(`MatchProofVerifier:     ${await matchVerifier.getAddress()}`);
  console.log(`CancelProofVerifier:    ${await cancelVerifier.getAddress()}\n`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
