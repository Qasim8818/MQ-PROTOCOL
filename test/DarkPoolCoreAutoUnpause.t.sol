// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import "../contracts/DarkPoolCore.sol";
import "../contracts/mocks/MockERC20.sol";
import "../contracts/mocks/MockGuardian.sol";
import "../contracts/mocks/MockVerifier.sol";

contract DarkPoolCoreAutoUnpauseTest is Test {
    DarkPoolCore core;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockGuardian guardian;
    MockVerifier orderVerifier;
    MockVerifier matchVerifier;
    MockVerifier cancelVerifier;
    MockVerifier depositTransitionVerifier;

    address owner = address(0xA11CE);
    address buyer = address(0xB0B);

    uint256 constant PRICE_SCALE = 1e18;
    uint256 constant FEE_BPS = 100; // 1%
    uint256 constant ORDER_TTL_BLOCKS = 1000;
    uint256 constant MIN_QUANTITY = 1e18; // 1 token (18 decimals)

    function setUp() public {
        guardian = new MockGuardian();
        orderVerifier = new MockVerifier(true);
        matchVerifier = new MockVerifier(true);
        cancelVerifier = new MockVerifier(true);
        depositTransitionVerifier = new MockVerifier(true);

        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);

        tokenA.mint(buyer, 1000e18);
        tokenB.mint(buyer, 1000e18);

        DarkPoolCore.DeployParams memory p = DarkPoolCore.DeployParams({
            orderVerifier: address(orderVerifier),
            matchVerifier: address(matchVerifier),
            cancelVerifier: address(cancelVerifier),
            depositTransitionVerifier: address(depositTransitionVerifier),
            feeRecipient: owner,
            guardian: address(guardian),
            protocolFeeBps: FEE_BPS,
            orderTTLBlocks: ORDER_TTL_BLOCKS,
            minQuantity: MIN_QUANTITY,
            emptyTreeRoot: bytes32(0),
            maxNotesPerBlock: 1000
        });

        core = new DarkPoolCore(p);
    }

    function _deposit(address user, MockERC20 token, uint256 amount) internal {
        vm.startPrank(user);
        token.approve(address(core), amount);
        // newRoot == bytes32(0) is fine for this mock verifier
        core.deposit(address(token), amount, bytes32(0), _a(), _b(), _c());
        vm.stopPrank();
    }

    function _a() internal pure returns (uint256[2] memory out) {
        out = [uint256(0), uint256(0)];
    }

    function _b() internal pure returns (uint256[2][2] memory out) {
        out = [[uint256(0), uint256(0)], [uint256(0), uint256(0)]];
    }

    function _c() internal pure returns (uint256[2] memory out) {
        out = [uint256(0), uint256(0)];
    }

    function testAutoExpiryUnpauseEmitsAutoUnpaused() public {
        // Pause from guardian
        vm.prank(address(guardian));
        core.pause();

        // Move past the expiry window
        uint256 blocks = core.MAX_PAUSE_BLOCKS();
        vm.roll(block.number + blocks + 1);

        // Deposit some funds so createNote can proceed
        _deposit(buyer, tokenA, 5e18);

        // Trigger auto-expiry via a user call
        vm.startPrank(buyer);
        vm.expectEmit(true, false, false, false);
        emit DarkPoolCore.AutoUnpaused();

        core.createNote(
            bytes32(uint256(9002)),
            bytes32(uint256(9003)),
            address(tokenA),
            address(tokenB),
            1e18,
            uint256(block.number + 100),
            _a(),
            _b(),
            _c()
        );
        vm.stopPrank();
    }
}

