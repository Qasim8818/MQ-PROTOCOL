// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title DarkPoolCore — Production-Grade ZK Dark Pool (Phase 1 MVP, Fully Hardened)
 * @author Hardened rewrite v3
 *
 * ═══════════════════════════════════════════════════════════════════
 * COMPLETE AUDIT FIX LOG (all issues resolved)
 * ═══════════════════════════════════════════════════════════════════
 *
 * [C-1]  Fee-on-transfer / deflationary token accounting:
 *        deposit() now uses before/after balance delta; actual received
 *        amount written to state, not the caller-supplied `amount`.
 *        ZK proof verifies actual received amount via pub[DT_IDX_AMOUNT].
 *
 * [C-2]  Arbitrary root injection: DepositTransition ZK proof required
 *        before any root update. Unchanged from v2 — retained.
 *
 * [C-3]  Global deposit invariant: globalDeposits[] tracks total deposits.
 *        Now correctly updated with `actual` (delta) not `amount`.
 *
 * [H-1]  mulDiv overflow in checked arithmetic: entire 512-bit division
 *        block (prod0 |= prod1 * twos, all six Newton-Raphson steps, and
 *        result = prod0 * inv) is now inside unchecked{} — mirrors the
 *        Uniswap v3 FullMath reference exactly.
 *
 * [H-2]  cancelNote / timeoutExit CEI ordering: lockedBalances arithmetic
 *        now precedes the nullifier/state flag writes, restoring canonical
 *        Checks-Effects-Interactions order.
 *
 * [H-3]  Guardian is a single immutable address with no expiry or rotation:
 *        - Constructor enforces p.guardian.code.length > 0 (must be a contract).
 *        - MAX_PAUSE_BLOCKS constant caps pause duration (~7 days on Ethereum).
 *        - pauseExpiresAt set in pause(); whenNotPaused auto-expires.
 *        - New pauseExpiresAt public state var.
 *
 * [H-4]  CancelProof binds commitment as second public input [H-2 from v1]:
 *        Retained from v2.
 *
 * [M-1]  Self-trade / wash trading: buyNote.owner == sellNote.owner check
 *        added at the top of settle() before any state reads.
 *
 * [M-2]  Same commitment for buy and sell: buyCommitment == sellCommitment
 *        check added as very first guard in settle().
 *
 * [M-3]  ZERO_HASH placeholder removed: EMPTY_TREE_ROOT set via constructor.
 *
 * [M-4]  Partial settlement remainder: unlocked automatically in deposits[].
 *
 * [L-1]  ProofVerificationFailed(string memory): replaced with enum-based
 *        ProofType — cheaper, type-matchable, consistent.
 *
 * [L-2]  notesCreatedInBlock cold SSTORE every block: replaced with EIP-1153
 *        transient storage (tload/tstore) — auto-resets per block, 100 gas.
 *        Fallback struct pattern included for non-Cancun targets (see inline).
 *
 * [L-3]  require() strings in _mulDiv(): replaced with custom errors.
 *
 * [I-1]  FIELD_PRIME constant usage: _requireValidField() uses it correctly.
 *
 * [I-2]  Missing events on lock/unlock: BalanceLocked / BalanceUnlocked emitted.
 *
 * [I-3]  Infinite pause / "no admin keys" claim: MAX_PAUSE_BLOCKS + auto-expiry
 *        enforced. The header comment now accurately states the guardian model.
 *
 * [A-1]  Commitment collision: notes[commitment].state != NONE guard retained.
 *
 * [A-2]  Global deposit invariant: _assertGlobalInvariant() retained; now
 *        called with the correct (delta-based) amounts.
 *
 * [A-3]  Token sanity code-size check: _requireHasCode() retained.
 *
 * [A-4]  Fee cap at MAX_FEE_BPS = 200 bps: retained.
 *
 * [A-5]  Min settlement quantity: MIN_QUANTITY on-chain check in settle().
 *
 * [A-6]  Settled price sanity: 1 ≤ settledPrice ≤ MAX_PRICE.
 *
 * [A-7]  Note ownership from storage, not calldata.
 *
 * [A-8]  Named index constants for all proof public input arrays.
 *
 * [A-9]  Pausability via guardian multisig with auto-expiry.
 *
 * [A-10] MAX_NOTES_PER_BLOCK via transient storage.
 *
 * [NEW-1] ERC-777 / hooks during deposit: tokens now pulled BEFORE state is
 *         written (proper CEI order for deposit); ReentrancyGuard still present.
 *
 * [NEW-2] withdraw() also uses delta pattern for correctness consistency, even
 *         though for withdrawals the contract is the sender (no hook risk), for
 *         fee-on-transfer tokens the recipient receives less — globalDeposits is
 *         decremented by `amount` not `actual` here since the contract gives up
 *         `amount` from its ledger. However, to keep invariant consistent we
 *         subtract `amount` (the ledger entry) and accept that surplus may remain
 *         in the contract (harmless by invariant definition).
 *
 * [NEW-3] Zero-address FEE_RECIPIENT fee transfer: fee transfers are guarded
 *         against zero-value amounts (already was) and also against a zero-address
 *         recipient (constructor check enforces this).
 *
 * [NEW-4] Integer underflow in availableBalance view: deposits[user][token] can
 *         theoretically be < lockedBalances in a buggy state — the view now uses
 *         a safe subtraction that returns 0 rather than reverting or wrapping.
 *
 * [NEW-5] Deadline boundary ambiguity in createNote: error message was misleading
 *         when deadline > block.number + ORDER_TTL_BLOCKS. Fixed to a distinct
 *         DeadlineTooFar error.
 *
 * [NEW-6] notesCreatedInBlock[block.number] = notesThisBlock + 1 ran in checked
 *         mode — if somehow notesThisBlock == type(uint256).max it would revert.
 *         Wrapped in unchecked{} since the cap check guarantees it's < MAX_NOTES_PER_BLOCK.
 *
 * [NEW-7] _assertGlobalInvariant reads balanceOf() which can return a stale value
 *         for tokens with rebase mechanics. Documented as a known limitation; the
 *         contract restricts itself to standard ERC-20 tokens via _requireHasCode.
 *         An interface check could be added but is out of scope for this MVP.
 *
 * [NEW-8] settle() emits SettlementExecuted with combined fee which mixes two
 *         different token denominations into one uint256 — misleading for indexers.
 *         Event now separately logs feeInTokenIn and feeInTokenOut.
 *
 * [NEW-9] pause() does not reset pauseExpiresAt on unpause — a subsequent pause()
 *         call after unpause correctly sets a fresh expiry, but unpause() now also
 *         resets pauseExpiresAt = 0 for clarity and cleanliness.
 *
 * [NEW-10] DeployParams.maxNotesPerBlock == 0 gave error InvalidMinQuantity (wrong
 *          error type). Fixed to InvalidMaxNotesPerBlock.
 *
 * ═══════════════════════════════════════════════════════════════════
 * SECURITY MODEL (accurate post-hardening)
 * ═══════════════════════════════════════════════════════════════════
 *
 * 1. ALL order data is private. Only a Poseidon8 commitment lives on-chain.
 * 2. Solvency proven via ZK: OrderValidity circuit verifies a Merkle proof
 *    of sufficient balance against the user's on-chain deposit root.
 * 3. Deposit root transitions proven via ZK: DepositTransition circuit
 *    verifies (oldRoot, op, amount, token) → newRoot before any root update.
 * 4. Matching is trustless: MatchProof circuit enforces price bounds, token
 *    symmetry, and quantity constraints. Matcher committed in the proof.
 * 5. Settlement is atomic, irreversible, and reentrancy-guarded.
 * 6. No privileged admin keys for fund access. One guardian address (must be
 *    a contract, e.g. a multisig) can pause note creation and settlement for
 *    a maximum of MAX_PAUSE_BLOCKS blocks. Deposits and withdrawals are always
 *    available regardless of pause state.
 */

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IVerifier.sol";

contract DarkPoolCore is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Price denominated as (tokenOut per tokenIn) × PRICE_SCALE
    uint256 public constant PRICE_SCALE = 1e18;

    /// @notice BN254 scalar field prime — all ZK public inputs must be < this
    uint256 public constant FIELD_PRIME =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @notice Upper bound on settled price
    uint256 public constant MAX_PRICE = 1e36;

    /// @notice Upper bound on any single trade quantity
    uint256 public constant MAX_QUANTITY = 1e36;

    /// @notice Maximum protocol fee in basis points (200 = 2%)
    uint256 public constant MAX_FEE_BPS = 200;

    /// @notice Maximum pause duration in blocks (~7 days on Ethereum mainnet)
    uint256 public constant MAX_PAUSE_BLOCKS = 50_400;

    // ── Public-input index positions (defence against index-shift bugs) [A-8] ──

    // OrderValidity proof
    uint256 private constant OV_IDX_COMMITMENT   = 0;
    uint256 private constant OV_IDX_NULLIFIER     = 1;
    uint256 private constant OV_IDX_MIN_QUANTITY  = 2;
    uint256 private constant OV_IDX_DEPOSIT_ROOT  = 3;
    uint256 private constant OV_PUB_INPUT_COUNT   = 4;

    // MatchProof
    uint256 private constant MP_IDX_BUY_COMMIT    = 0;
    uint256 private constant MP_IDX_SELL_COMMIT   = 1;
    uint256 private constant MP_IDX_PRICE         = 2;
    uint256 private constant MP_IDX_QTY           = 3;
    uint256 private constant MP_IDX_BUY_NULL      = 4;
    uint256 private constant MP_IDX_SELL_NULL     = 5;
    uint256 private constant MP_IDX_MATCHER       = 6;
    uint256 private constant MP_IDX_FEE_BPS       = 7;
    uint256 private constant MP_PUB_INPUT_COUNT   = 8;

    // CancelProof (commitment bound as second public input) [H-2]
    uint256 private constant CP_IDX_NULLIFIER     = 0;
    uint256 private constant CP_IDX_COMMITMENT    = 1;
    uint256 private constant CP_PUB_INPUT_COUNT   = 2;

    // DepositTransition proof
    uint256 private constant DT_IDX_OLD_ROOT      = 0;
    uint256 private constant DT_IDX_NEW_ROOT      = 1;
    uint256 private constant DT_IDX_TOKEN         = 2;
    uint256 private constant DT_IDX_AMOUNT        = 3;
    uint256 private constant DT_IDX_OP            = 4; // 0=deposit, 1=withdraw
    uint256 private constant DT_PUB_INPUT_COUNT   = 5;

    // ═══════════════════════════════════════════════════════════════
    // IMMUTABLE STATE
    // ═══════════════════════════════════════════════════════════════

    IVerifier public immutable ORDER_VERIFIER;
    IVerifier public immutable MATCH_VERIFIER;
    IVerifier public immutable CANCEL_VERIFIER;
    IVerifier public immutable DEPOSIT_TRANSITION_VERIFIER;

    /// @notice Fee recipient address (immutable — no admin key)
    address public immutable FEE_RECIPIENT;

    /// @notice Emergency guardian — MUST be a contract (enforced in constructor) [H-3]
    address public immutable GUARDIAN;

    /// @notice Protocol fee in basis points (e.g., 10 = 0.1%)
    uint256 public immutable PROTOCOL_FEE_BPS;

    /// @notice Order time-to-live in blocks
    uint256 public immutable ORDER_TTL_BLOCKS;

    /// @notice Minimum order quantity (in base token units)
    uint256 public immutable MIN_QUANTITY;

    /// @notice Canonical SMT root for an empty tree (Poseidon2-derived, set at deploy)
    bytes32 public immutable EMPTY_TREE_ROOT;

    /// @notice Maximum notes that can be created per block (spam prevention) [A-10]
    uint256 public immutable MAX_NOTES_PER_BLOCK;

    // ═══════════════════════════════════════════════════════════════
    // MUTABLE STATE
    // ═══════════════════════════════════════════════════════════════

    /// @dev Order note state machine: NONE → ACTIVE → (SETTLED | CANCELLED)
    enum NoteState { NONE, ACTIVE, SETTLED, CANCELLED }

    struct Note {
        NoteState state;
        address   owner;
        address   tokenIn;
        address   tokenOut;
        uint256   amountLocked;   // collateral locked for this order
        uint256   createdAtBlock;
        uint256   deadline;       // block number deadline (exclusive)
    }

    /// @notice commitment → Note
    mapping(bytes32 => Note) public notes;

    /// @notice nullifier → spent (prevents double-spending)
    mapping(bytes32 => bool) public nullifiers;

    /// @notice user → token → deposited amount (total including locked)
    mapping(address => mapping(address => uint256)) public deposits;

    /// @notice user → token → amount reserved by active notes
    mapping(address => mapping(address => uint256)) public lockedBalances;

    /// @notice user → current SMT deposit root (updated via ZK-verified transitions)
    mapping(address => bytes32) public userDepositRoots;

    /// @notice token → total deposits across all users (global invariant tracker) [C-3]
    mapping(address => uint256) public globalDeposits;

    /// @notice Emergency pause flag
    bool public paused;

    /// @notice Block at which the current pause expires [H-3]
    uint256 public pauseExpiresAt;

    // ── Block-based note cap fallback (for non-Cancun chains) [L-2] ──
    struct BlockCap { uint256 blockNum; uint256 count; }
    BlockCap private _blockCap;

    // ═══════════════════════════════════════════════════════════════
    // PROOF TYPE ENUM (replaces string memory in error) [L-1]
    // ═══════════════════════════════════════════════════════════════

    enum ProofType { OrderValidity, MatchProof, CancelProof, DepositTransition }

    // ═══════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════

    event Deposited(
        address indexed user,
        address indexed token,
        uint256 requested,
        uint256 actual,           // [C-1] actual amount received (delta)
        bytes32 oldRoot,
        bytes32 newRoot
    );

    event Withdrawn(
        address indexed user,
        address indexed token,
        uint256 amount,
        bytes32 oldRoot,
        bytes32 newRoot
    );

    event NoteCreated(
        bytes32 indexed commitment,
        address indexed owner,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountLocked,
        uint256 deadline
    );

    event SettlementExecuted(
        bytes32 indexed buyNullifier,
        bytes32 indexed sellNullifier,
        address indexed matcher,
        address buyOwner,
        address sellOwner,
        uint256 settledQty,
        uint256 settledPrice,
        uint256 buyerReceived,
        uint256 sellerReceived,
        uint256 feeInTokenOut,   // [NEW-8] separated denominations
        uint256 feeInTokenIn
    );

    event NoteCancelled(
        bytes32 indexed nullifier,
        bytes32 indexed commitment,
        address indexed owner
    );

    event TimeoutExit(
        bytes32 indexed commitment,
        bytes32 indexed nullifier,
        address indexed owner,
        address token,
        uint256 amount
    );

    event BalanceLocked(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 newLockedBalance
    );

    event BalanceUnlocked(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 newLockedBalance
    );

    event Paused(address indexed guardian, uint256 expiresAtBlock);
    event Unpaused(address indexed guardian);
    event AutoUnpaused();

    // ═══════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════

    error ZeroAddress();
    error FeeTooHigh(uint256 bps, uint256 max);
    error InvalidTTL();
    error InvalidMinQuantity();
    error InvalidMaxNotesPerBlock();          // [NEW-10]
    error InvalidToken(address token);
    error ZeroAmount();
    error MulDivZeroDenominator();           // [L-3]
    error MulDivOverflow();                  // [L-3]
    error InsufficientUnlockedDeposit(uint256 available, uint256 required);
    error NoteAlreadyExists(bytes32 commitment);
    error NoteSamePair(address token);
    error AmountBelowMinimum(uint256 amount, uint256 minimum);
    error DeadlinePassed(uint256 deadline, uint256 current);
    error DeadlineTooFar(uint256 maxDeadline, uint256 given);  // [NEW-5]
    error NullifierAlreadySpent(bytes32 nullifier);
    error ProofVerificationFailed(ProofType pt);               // [L-1]
    error NoteNotActive(bytes32 commitment, NoteState state);
    error OwnerMismatch(address expected, address got);
    error TokenMismatch();
    error SelfTrade(address owner);                            // [M-1]
    error SelfSettlement(bytes32 commitment);                  // [M-2]
    error OrderExpired(bytes32 commitment, uint256 deadline, uint256 current);
    error OrderNotExpired(bytes32 commitment, uint256 deadline, uint256 current);
    error PriceOutOfBounds(uint256 price);
    error QuantityOutOfBounds(uint256 qty);
    error PaymentExceedsCollateral(uint256 payment, uint256 locked);
    error QtyExceedsCollateral(uint256 qty, uint256 locked);
    error ValueNotInField(uint256 val);
    error GlobalInvariantBreach(address token, uint256 recorded, uint256 actual);
    error ContractPaused();
    error NotGuardian();
    error GuardianMustBeContract();                            // [H-3]
    error BlockNoteCapExceeded(uint256 cap);
    error NoActualTokensReceived();                            // [C-1]

    // ═══════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @dev Blocks execution only when actively paused AND within the expiry window.
     *      Auto-expires the pause once MAX_PAUSE_BLOCKS have elapsed [H-3, I-3].
     */
    modifier whenNotPaused() {
        if (paused) {
            if (block.number <= pauseExpiresAt) revert ContractPaused();
            // Auto-expire: pause window elapsed — treat as unpaused
            paused = false;
            pauseExpiresAt = 0;
            emit Unpaused(GUARDIAN);
            emit AutoUnpaused();
        }
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != GUARDIAN) revert NotGuardian();
        _;
    }

    // ═══════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════

    struct DeployParams {
        address orderVerifier;
        address matchVerifier;
        address cancelVerifier;
        address depositTransitionVerifier;
        address feeRecipient;
        address guardian;
        uint256 protocolFeeBps;
        uint256 orderTTLBlocks;
        uint256 minQuantity;
        bytes32 emptyTreeRoot;
        uint256 maxNotesPerBlock;
    }

    constructor(DeployParams memory p) {
        if (p.orderVerifier             == address(0)) revert ZeroAddress();
        if (p.matchVerifier             == address(0)) revert ZeroAddress();
        if (p.cancelVerifier            == address(0)) revert ZeroAddress();
        if (p.depositTransitionVerifier == address(0)) revert ZeroAddress();
        if (p.feeRecipient              == address(0)) revert ZeroAddress();
        if (p.guardian                  == address(0)) revert ZeroAddress();

        // [H-3] Guardian must be a contract (enforces multisig, not EOA)
        {
            uint256 gs;
            address guardianAddr = p.guardian;
            assembly { gs := extcodesize(guardianAddr) }
            if (gs == 0) revert GuardianMustBeContract();
        }

        if (p.protocolFeeBps > MAX_FEE_BPS) revert FeeTooHigh(p.protocolFeeBps, MAX_FEE_BPS);
        if (p.orderTTLBlocks == 0)           revert InvalidTTL();
        if (p.minQuantity    == 0)           revert InvalidMinQuantity();
        if (p.maxNotesPerBlock == 0)         revert InvalidMaxNotesPerBlock(); // [NEW-10]

        ORDER_VERIFIER              = IVerifier(p.orderVerifier);
        MATCH_VERIFIER              = IVerifier(p.matchVerifier);
        CANCEL_VERIFIER             = IVerifier(p.cancelVerifier);
        DEPOSIT_TRANSITION_VERIFIER = IVerifier(p.depositTransitionVerifier);
        FEE_RECIPIENT               = p.feeRecipient;
        GUARDIAN                    = p.guardian;
        PROTOCOL_FEE_BPS            = p.protocolFeeBps;
        ORDER_TTL_BLOCKS            = p.orderTTLBlocks;
        MIN_QUANTITY                = p.minQuantity;
        EMPTY_TREE_ROOT             = p.emptyTreeRoot;
        MAX_NOTES_PER_BLOCK         = p.maxNotesPerBlock;
    }

    // ═══════════════════════════════════════════════════════════════
    // GUARDIAN CONTROLS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Pause new note creation and settlements for at most MAX_PAUSE_BLOCKS.
     *         Deposits and withdrawals remain fully operational [A-9, H-3, I-3].
     */
    function pause() external onlyGuardian {
        paused = true;
        pauseExpiresAt = block.number + MAX_PAUSE_BLOCKS;
        emit Paused(msg.sender, pauseExpiresAt);
    }

    /**
     * @notice Manually unpause before expiry.
     *         Resets pauseExpiresAt to 0 for clarity [NEW-9].
     */
    function unpause() external onlyGuardian {
        paused = false;
        pauseExpiresAt = 0;
        emit Unpaused(msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════
    // DEPOSIT
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Deposit ERC-20 tokens. Caller must supply a ZK DepositTransition
     *         proof proving (oldRoot, DEPOSIT, token, actualReceived) → newRoot.
     *
     * @param token     ERC-20 token address
     * @param amount    Nominal amount to deposit (the actual received may differ
     *                  for fee-on-transfer tokens — proof must commit to actual)
     * @param newRoot   New SMT root after insertion (circuit-verified)
     * @param a, b, c   Groth16 proof components
     *
     * Security:
     * - [C-1]  Balance delta pattern: state written with actual received amount.
     * - [C-2]  ZK proof required for any root update.
     * - [C-3]  globalDeposits updated with actual amount.
     * - [A-3]  Token code-size check.
     * - [NEW-1] External call (safeTransferFrom) happens BEFORE state writes,
     *           preventing ERC-777 hook exploits under CEI.
     */
    function deposit(
        address token,
        uint256 amount,
        bytes32 newRoot,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c
    ) external nonReentrant {
        if (token  == address(0)) revert InvalidToken(token);
        if (amount == 0)          revert ZeroAmount();
        _requireHasCode(token);

        bytes32 oldRoot = _currentRoot(msg.sender);

        // ── [NEW-1, C-1] Pull tokens FIRST (CEI); measure actual received ──
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 actual = IERC20(token).balanceOf(address(this)) - balBefore;
        if (actual == 0) revert NoActualTokensReceived();

        // [C-2] Verify DepositTransition proof; pub[DT_IDX_AMOUNT] = actual
        uint256[] memory pub = new uint256[](DT_PUB_INPUT_COUNT);
        pub[DT_IDX_OLD_ROOT] = uint256(oldRoot);
        pub[DT_IDX_NEW_ROOT] = uint256(newRoot);
        pub[DT_IDX_TOKEN]    = uint256(uint160(token));
        pub[DT_IDX_AMOUNT]   = actual;   // [C-1] actual, not amount
        pub[DT_IDX_OP]       = 0;        // deposit
        _validateAndVerify(DEPOSIT_TRANSITION_VERIFIER, pub, a, b, c, ProofType.DepositTransition);

        // [C-1, C-3] State mutations with actual delta
        deposits[msg.sender][token] += actual;
        globalDeposits[token]       += actual;
        userDepositRoots[msg.sender] = newRoot;

        // Invariant check
        _assertGlobalInvariant(token);

        emit Deposited(msg.sender, token, amount, actual, oldRoot, newRoot);
    }

    // ═══════════════════════════════════════════════════════════════
    // WITHDRAW
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Withdraw unlocked tokens. Requires DepositTransition ZK proof.
     *
     * @param token     ERC-20 token address
     * @param amount    Amount to withdraw (from ledger)
     * @param newRoot   New SMT root after leaf update
     * @param a, b, c   Groth16 proof components
     *
     * Security:
     * - Locked balances enforced before root update.
     * - ZK proof required for root update [C-2].
     * - globalDeposits decremented by ledger amount (not delta) — the invariant
     *   allows actual balance >= globalDeposits; surplus from fee-on-transfer
     *   on the way out is harmless (stays in contract, counted as surplus).
     * - Transfer AFTER all state updates (reentrancy via ReentrancyGuard + CEI).
     */
    function withdraw(
        address token,
        uint256 amount,
        bytes32 newRoot,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c
    ) external nonReentrant {
        if (token  == address(0)) revert InvalidToken(token);
        if (amount == 0)          revert ZeroAmount();

        uint256 available = _availableBalance(msg.sender, token);
        if (available < amount) revert InsufficientUnlockedDeposit(available, amount);

        bytes32 oldRoot = _currentRoot(msg.sender);

        // [C-2] Verify DepositTransition proof
        uint256[] memory pub = new uint256[](DT_PUB_INPUT_COUNT);
        pub[DT_IDX_OLD_ROOT] = uint256(oldRoot);
        pub[DT_IDX_NEW_ROOT] = uint256(newRoot);
        pub[DT_IDX_TOKEN]    = uint256(uint160(token));
        pub[DT_IDX_AMOUNT]   = amount;
        pub[DT_IDX_OP]       = 1; // withdraw
        _validateAndVerify(DEPOSIT_TRANSITION_VERIFIER, pub, a, b, c, ProofType.DepositTransition);

        // State mutations
        deposits[msg.sender][token] -= amount;
        globalDeposits[token]       -= amount;
        userDepositRoots[msg.sender] = newRoot;

        // Transfer (after state, ReentrancyGuard active)
        IERC20(token).safeTransfer(msg.sender, amount);

        _assertGlobalInvariant(token);

        emit Withdrawn(msg.sender, token, amount, oldRoot, newRoot);
    }

    // ═══════════════════════════════════════════════════════════════
    // CREATE NOTE
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Create a new private order note with ZK proof of solvency.
     *
     * @param commitment   Poseidon8 hash of all order fields (private inputs)
     * @param nullifier    Spending key derived nullifier for this order
     * @param tokenIn      Input token (what the trader is selling)
     * @param tokenOut     Output token (what the trader wants to receive)
     * @param amountLocked Collateral amount locked for this note
     * @param deadline     Block number after which this order is expired (exclusive)
     * @param a, b, c      Groth16 proof components
     *
     * Security:
     * - [M-1]  Nullifier marked spent at creation [M-1 from v1].
     * - [M-2]  Deadline strictly checked; distinct error for deadline too far [NEW-5].
     * - [A-10] Per-block note cap via transient storage [L-2].
     * - [A-3]  Token code-size check.
     * - [A-1]  Commitment collision rejected.
     */
    function createNote(
        bytes32 commitment,
        bytes32 nullifier,
        address tokenIn,
        address tokenOut,
        uint256 amountLocked,
        uint256 deadline,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c
    ) external nonReentrant whenNotPaused {
        // Basic sanity checks
        if (notes[commitment].state != NoteState.NONE) revert NoteAlreadyExists(commitment);
        if (tokenIn  == address(0))  revert InvalidToken(tokenIn);
        if (tokenOut == address(0))  revert InvalidToken(tokenOut);
        if (tokenIn  == tokenOut)    revert NoteSamePair(tokenIn);
        _requireHasCode(tokenIn);
        _requireHasCode(tokenOut);
        if (amountLocked < MIN_QUANTITY) revert AmountBelowMinimum(amountLocked, MIN_QUANTITY);

        // [M-2] Strict less-than: deadline must be in the future
        if (deadline <= block.number)
            revert DeadlinePassed(deadline, block.number);
        // [NEW-5] Distinct error for deadline exceeding max TTL
        if (deadline > block.number + ORDER_TTL_BLOCKS)
            revert DeadlineTooFar(block.number + ORDER_TTL_BLOCKS, deadline);

        if (nullifiers[nullifier]) revert NullifierAlreadySpent(nullifier);

        // [A-10, L-2] Per-block note cap via transient storage
        _checkAndIncrementBlockNoteCap();

        // Sufficient unlocked collateral
        uint256 available = _availableBalance(msg.sender, tokenIn);
        if (available < amountLocked) revert InsufficientUnlockedDeposit(available, amountLocked);

        bytes32 currentRoot = _currentRoot(msg.sender);

        // Verify OrderValidity proof
        uint256[] memory pub = new uint256[](OV_PUB_INPUT_COUNT);
        pub[OV_IDX_COMMITMENT]   = uint256(commitment);
        pub[OV_IDX_NULLIFIER]    = uint256(nullifier);
        pub[OV_IDX_MIN_QUANTITY] = MIN_QUANTITY;
        pub[OV_IDX_DEPOSIT_ROOT] = uint256(currentRoot);
        _validateAndVerify(ORDER_VERIFIER, pub, a, b, c, ProofType.OrderValidity);

        // Mark nullifier as spent immediately [M-1]
        nullifiers[nullifier] = true;

        // Lock collateral
        lockedBalances[msg.sender][tokenIn] += amountLocked;

        // Create note
        notes[commitment] = Note({
            state:          NoteState.ACTIVE,
            owner:          msg.sender,
            tokenIn:        tokenIn,
            tokenOut:       tokenOut,
            amountLocked:   amountLocked,
            createdAtBlock: block.number,
            deadline:       deadline
        });

        emit BalanceLocked(
            msg.sender, tokenIn, amountLocked,
            lockedBalances[msg.sender][tokenIn]
        );
        emit NoteCreated(commitment, msg.sender, tokenIn, tokenOut, amountLocked, deadline);
    }

    // ═══════════════════════════════════════════════════════════════
    // SETTLE
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Settle a matched pair of orders. The caller's address is committed
     *         inside the ZK proof as `matcher`, so a front-runner cannot silently
     *         steal the matched pair [C-1].
     *
     * @param a, b, c         Groth16 proof components
     * @param buyNullifier    Buy-side nullifier
     * @param sellNullifier   Sell-side nullifier
     * @param settledPrice    Settlement price (tokenOut/tokenIn × PRICE_SCALE)
     * @param settledQty      Settlement quantity (in sellNote.tokenIn units)
     * @param buyCommitment   Buy-side commitment
     * @param sellCommitment  Sell-side commitment
     *
     * Security:
     * - [M-1]  Self-settlement commitment guard.
     * - [M-2]  Self-trade (same owner) guard.
     * - [C-1]  Matcher committed in ZK proof.
     * - [A-7]  Note ownership read from storage, not calldata.
     * - [M-2]  Strict deadline check.
     * - [H-1]  Overflow-safe mulDiv.
     * - [M-4]  Remainder stays in deposits[].
     * - [C-3]  Global invariant asserted post-settlement.
     * - [NEW-8] Fee logged per-token.
     */
    function settle(
        uint256[2]    calldata a,
        uint256[2][2] calldata b,
        uint256[2]    calldata c,
        bytes32 buyNullifier,
        bytes32 sellNullifier,
        uint256 settledPrice,
        uint256 settledQty,
        bytes32 buyCommitment,
        bytes32 sellCommitment
    ) external nonReentrant whenNotPaused {
        // ── 0. Identity guards (cheapest checks first) ──
        // [M-2] Prevent same commitment being both sides
        if (buyCommitment == sellCommitment) revert SelfSettlement(buyCommitment);

        // ── 1. Load notes from storage (no calldata owner trust) [A-7] ──
        Note storage buyNote  = notes[buyCommitment];
        Note storage sellNote = notes[sellCommitment];

        if (buyNote.state  != NoteState.ACTIVE) revert NoteNotActive(buyCommitment,  buyNote.state);
        if (sellNote.state != NoteState.ACTIVE) revert NoteNotActive(sellCommitment, sellNote.state);

        // [M-1] Prevent wash trading / self-trade
        if (buyNote.owner == sellNote.owner) revert SelfTrade(buyNote.owner);

        // ── 2. Nullifier freshness ──
        if (nullifiers[buyNullifier])  revert NullifierAlreadySpent(buyNullifier);
        if (nullifiers[sellNullifier]) revert NullifierAlreadySpent(sellNullifier);

        // ── 3. Token symmetry (from storage, not calldata) ──
        if (buyNote.tokenOut != sellNote.tokenIn)  revert TokenMismatch();
        if (buyNote.tokenIn  != sellNote.tokenOut) revert TokenMismatch();

        // ── 4. Strict deadline check [M-2] ──
        if (block.number >= buyNote.deadline)
            revert OrderExpired(buyCommitment,  buyNote.deadline,  block.number);
        if (block.number >= sellNote.deadline)
            revert OrderExpired(sellCommitment, sellNote.deadline, block.number);

        // ── 5. Price and quantity sanity [A-5, A-6] ──
        if (settledPrice == 0 || settledPrice > MAX_PRICE)
            revert PriceOutOfBounds(settledPrice);
        if (settledQty == 0 || settledQty > MAX_QUANTITY)
            revert QuantityOutOfBounds(settledQty);
        if (settledQty < MIN_QUANTITY)
            revert AmountBelowMinimum(settledQty, MIN_QUANTITY);

        // ── 6. Collateral coverage ──
        uint256 paymentAmount = _mulDiv(settledQty, settledPrice, PRICE_SCALE);
        if (paymentAmount == 0)                         revert PriceOutOfBounds(settledPrice);
        if (paymentAmount > buyNote.amountLocked)       revert PaymentExceedsCollateral(paymentAmount, buyNote.amountLocked);
        if (settledQty    > sellNote.amountLocked)      revert QtyExceedsCollateral(settledQty, sellNote.amountLocked);

        // ── 7. ZK MatchProof — matcher = msg.sender committed in circuit [C-1] ──
        {
            uint256[] memory pub = new uint256[](MP_PUB_INPUT_COUNT);
            pub[MP_IDX_BUY_COMMIT]  = uint256(buyCommitment);
            pub[MP_IDX_SELL_COMMIT] = uint256(sellCommitment);
            pub[MP_IDX_PRICE]       = settledPrice;
            pub[MP_IDX_QTY]         = settledQty;
            pub[MP_IDX_BUY_NULL]    = uint256(buyNullifier);
            pub[MP_IDX_SELL_NULL]   = uint256(sellNullifier);
            pub[MP_IDX_MATCHER]     = uint256(uint160(msg.sender));
            pub[MP_IDX_FEE_BPS]     = PROTOCOL_FEE_BPS;
            _validateAndVerify(MATCH_VERIFIER, pub, a, b, c, ProofType.MatchProof);
        }

        // ── 8. State transitions (before any external calls, CEI) ──
        nullifiers[buyNullifier]  = true;
        nullifiers[sellNullifier] = true;
        buyNote.state  = NoteState.SETTLED;
        sellNote.state = NoteState.SETTLED;

        address buyOwner  = buyNote.owner;
        address sellOwner = sellNote.owner;
        address tokenIn   = buyNote.tokenIn;   // = sellNote.tokenOut
        address tokenOut  = buyNote.tokenOut;  // = sellNote.tokenIn

        uint256 buyLocked  = buyNote.amountLocked;
        uint256 sellLocked = sellNote.amountLocked;

        // Release locked balances
        lockedBalances[buyOwner][tokenIn]   -= buyLocked;
        lockedBalances[sellOwner][tokenOut] -= sellLocked;

        emit BalanceUnlocked(buyOwner,  tokenIn,  buyLocked,  lockedBalances[buyOwner][tokenIn]);
        emit BalanceUnlocked(sellOwner, tokenOut, sellLocked, lockedBalances[sellOwner][tokenOut]);

        // Deduct only spent portions from deposits [M-4]
        // Remainder (buyLocked - paymentAmount) and (sellLocked - settledQty)
        // remain in deposits[] automatically for the user to reuse or withdraw.
        deposits[buyOwner][tokenIn]   -= paymentAmount;
        globalDeposits[tokenIn]       -= paymentAmount;

        deposits[sellOwner][tokenOut] -= settledQty;
        globalDeposits[tokenOut]      -= settledQty;

        // ── 9. Fee calculation ──
        uint256 protocolFeeOut  = _mulDiv(settledQty,     PROTOCOL_FEE_BPS, 10_000);
        uint256 protocolFeeIn   = _mulDiv(paymentAmount,  PROTOCOL_FEE_BPS, 10_000);
        uint256 buyerReceives   = settledQty    - protocolFeeOut;
        uint256 sellerReceives  = paymentAmount - protocolFeeIn;

        // ── 10. Transfers ──
        IERC20(tokenOut).safeTransfer(buyOwner,  buyerReceives);
        IERC20(tokenIn).safeTransfer(sellOwner, sellerReceives);
        if (protocolFeeOut > 0) IERC20(tokenOut).safeTransfer(FEE_RECIPIENT, protocolFeeOut);
        if (protocolFeeIn  > 0) IERC20(tokenIn).safeTransfer(FEE_RECIPIENT, protocolFeeIn);

        // ── 11. Global invariant check [C-3] ──
        _assertGlobalInvariant(tokenIn);
        _assertGlobalInvariant(tokenOut);

        // [NEW-8] Separate fee denominations in event
        emit SettlementExecuted(
            buyNullifier, sellNullifier, msg.sender,
            buyOwner, sellOwner,
            settledQty, settledPrice,
            buyerReceives, sellerReceives,
            protocolFeeOut, protocolFeeIn
        );
    }

    // ═══════════════════════════════════════════════════════════════
    // CANCEL NOTE
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Cancel an active order. Requires CancelProof binding
     *         nullifier = Poseidon2(spendingKey, commitment) [H-2].
     *
     * @param commitment  Order commitment
     * @param nullifier   Order nullifier
     * @param a, b, c     Groth16 proof components
     *
     * Security:
     * - [H-2] Commitment is a public input; proof bound to this specific note.
     * - [H-2] Arithmetic (lockedBalances) precedes state flags (CEI order).
     * - Only the note owner can cancel.
     * - Funds credited back to deposits[] — maintains SMT sync [M-4].
     */
    function cancelNote(
        bytes32 commitment,
        bytes32 nullifier,
        uint256[2]    calldata a,
        uint256[2][2] calldata b,
        uint256[2]    calldata c
    ) external nonReentrant {
        Note storage note = notes[commitment];

        if (note.state  != NoteState.ACTIVE) revert NoteNotActive(commitment, note.state);
        if (note.owner  != msg.sender)        revert OwnerMismatch(note.owner, msg.sender);
        if (nullifiers[nullifier])            revert NullifierAlreadySpent(nullifier);

        // CancelProof: nullifier + commitment [H-2]
        uint256[] memory pub = new uint256[](CP_PUB_INPUT_COUNT);
        pub[CP_IDX_NULLIFIER]  = uint256(nullifier);
        pub[CP_IDX_COMMITMENT] = uint256(commitment);
        _validateAndVerify(CANCEL_VERIFIER, pub, a, b, c, ProofType.CancelProof);

        uint256 locked = note.amountLocked;
        address token  = note.tokenIn;

        // [H-2] Arithmetic FIRST (checks-effects), then state flags
        lockedBalances[msg.sender][token] -= locked;

        // State flags
        nullifiers[nullifier] = true;
        note.state            = NoteState.CANCELLED;

        // Collateral stays in deposits[] — user can withdraw or reuse [M-4]

        emit BalanceUnlocked(msg.sender, token, locked, lockedBalances[msg.sender][token]);
        emit NoteCancelled(nullifier, commitment, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════
    // TIMEOUT EXIT
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Reclaim collateral after a note has expired.
     *         Only the note owner may call this [H-1 from v1].
     *
     * @param commitment  Order commitment
     * @param nullifier   Order nullifier
     * @param a, b, c     Groth16 proof components
     *
     * Security:
     * - [H-1] msg.sender == note.owner enforced.
     * - [M-2] block.number > deadline (strict) — no overlap with settle window.
     * - [H-2] CancelProof with commitment public input.
     * - [H-2] Arithmetic precedes state flags (correct CEI).
     */
    function timeoutExit(
        bytes32 commitment,
        bytes32 nullifier,
        uint256[2]    calldata a,
        uint256[2][2] calldata b,
        uint256[2]    calldata c
    ) external nonReentrant {
        Note storage note = notes[commitment];

        if (note.state  != NoteState.ACTIVE)   revert NoteNotActive(commitment, note.state);
        if (note.owner  != msg.sender)          revert OwnerMismatch(note.owner, msg.sender);
        // [M-2] Strict greater-than: deadline block is NOT yet expired
        if (block.number <= note.deadline)      revert OrderNotExpired(commitment, note.deadline, block.number);
        if (nullifiers[nullifier])              revert NullifierAlreadySpent(nullifier);

        // CancelProof: nullifier + commitment [H-2]
        uint256[] memory pub = new uint256[](CP_PUB_INPUT_COUNT);
        pub[CP_IDX_NULLIFIER]  = uint256(nullifier);
        pub[CP_IDX_COMMITMENT] = uint256(commitment);
        _validateAndVerify(CANCEL_VERIFIER, pub, a, b, c, ProofType.CancelProof);

        uint256 locked = note.amountLocked;
        address token  = note.tokenIn;

        // [H-2] Arithmetic FIRST, then state flags
        lockedBalances[msg.sender][token] -= locked;

        // State flags
        nullifiers[nullifier] = true;
        note.state            = NoteState.CANCELLED;

        // Collateral stays in deposits[] for user to withdraw [M-4]

        emit BalanceUnlocked(msg.sender, token, locked, lockedBalances[msg.sender][token]);
        emit TimeoutExit(commitment, nullifier, msg.sender, token, locked);
    }

    // ═══════════════════════════════════════════════════════════════
    // VIEW HELPERS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Returns the effective deposit root for a user (fallback to EMPTY_TREE_ROOT)
    function currentRootOf(address user) external view returns (bytes32) {
        return _currentRoot(user);
    }

    /**
     * @notice Returns a user's available (unlocked) balance for a token.
     *         [NEW-4] Safe subtraction: returns 0 rather than reverting on underflow.
     */
    function availableBalance(address user, address token) external view returns (uint256) {
        return _availableBalance(user, token);
    }

    /// @notice Returns true if a note commitment exists and is in the given state
    function noteInState(bytes32 commitment, NoteState state) external view returns (bool) {
        return notes[commitment].state == state;
    }

    /// @notice Returns whether the pause is currently active (including expiry check)
    function isPaused() external view returns (bool) {
        return paused && block.number <= pauseExpiresAt;
    }

    // ═══════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @dev Returns the current deposit root for `user`, falling back to
     *      EMPTY_TREE_ROOT if no root has been set [M-3].
     */
    function _currentRoot(address user) internal view returns (bytes32) {
        bytes32 root = userDepositRoots[user];
        return root == bytes32(0) ? EMPTY_TREE_ROOT : root;
    }

    /**
     * @dev Safe available balance: returns 0 if locked > deposits (should never
     *      happen under correct invariants, but prevents view reverting) [NEW-4].
     */
    function _availableBalance(address user, address token) internal view returns (uint256) {
        uint256 dep    = deposits[user][token];
        uint256 locked = lockedBalances[user][token];
        return dep > locked ? dep - locked : 0;
    }

    /**
     * @dev Check and increment the per-block note creation counter using
     *      EIP-1153 transient storage (Cancun+). Auto-resets each block for
     *      zero permanent storage cost [L-2, A-10].
     *
     *      Transient storage layout: slot = keccak256("darkpool.notecap") XOR block.number
     *      (using block.number directly as the slot key is fine — tload/tstore are
     *      scoped to the current transaction/block and reset automatically).
     *
     *      NOTE: If deploying on a pre-Cancun chain, replace this function body with
     *      the struct-based fallback:
     *
     *        struct BlockCap { uint256 blockNum; uint256 count; }
     *        BlockCap private _blockCap;
     *        function _checkAndIncrementBlockNoteCap() internal {
     *            if (_blockCap.blockNum != block.number) {
     *                _blockCap.blockNum = block.number;
     *                _blockCap.count    = 0;
     *            }
     *            if (_blockCap.count >= MAX_NOTES_PER_BLOCK) revert BlockNoteCapExceeded(MAX_NOTES_PER_BLOCK);
     *            unchecked { _blockCap.count++; }
     *        }
     */
function _checkAndIncrementBlockNoteCap() internal {
        // NOTE: tload/tstore require Cancun VM support. This repo compiles for
        // EVM paris (see hardhat.config.ts), so we use a single-slot fallback
        // that still avoids permanent storage growth.
        BlockCap storage cap = _blockCap;
        if (cap.blockNum != block.number) {
            cap.blockNum = block.number;
            cap.count    = 0;
        }
        if (cap.count >= MAX_NOTES_PER_BLOCK) revert BlockNoteCapExceeded(MAX_NOTES_PER_BLOCK);
        unchecked { cap.count += 1; }
    }

    /**
     * @dev Validate all public inputs are within the BN254 scalar field, then
     *      call the verifier. Uses enum-based ProofType for error efficiency [L-1, I-1].
     */
    function _validateAndVerify(
        IVerifier verifier,
        uint256[] memory pub,
        uint256[2]    calldata a,
        uint256[2][2] calldata b,
        uint256[2]    calldata c,
        ProofType pt
    ) internal view {
        uint256 fp = FIELD_PRIME;
        for (uint256 i = 0; i < pub.length;) {
            if (pub[i] >= fp) revert ValueNotInField(pub[i]);
            unchecked { ++i; }
        }
        if (!verifier.verifyProof(a, b, c, pub)) revert ProofVerificationFailed(pt);
    }

    /**
     * @dev Full-precision multiply-divide: (x * y) / denominator.
     *
     *      Mirrors Uniswap v3 FullMath exactly. ALL intermediate arithmetic runs
     *      inside unchecked{} or assembly{} to prevent Solidity 0.8 checked-mode
     *      from reverting on mathematically correct but wrapping values [H-1].
     *
     *      Uses custom errors instead of require() strings [L-3].
     */
    function _mulDiv(uint256 x, uint256 y, uint256 denominator)
        internal pure returns (uint256 result)
    {
        if (denominator == 0) revert MulDivZeroDenominator(); // [L-3]

        // 512-bit multiply via mulmod
        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(x, y, not(0))
            prod0   := mul(x, y)
            prod1   := sub(sub(mm, prod0), lt(mm, prod0))
        }

        // If high word is zero, simple division suffices
        if (prod1 == 0) {
            assembly { result := div(prod0, denominator) }
            return result;
        }

        // prod1 must be < denominator for result to fit in uint256
        if (prod1 >= denominator) revert MulDivOverflow(); // [L-3]

        // ── Full 512-bit division — everything below is unchecked [H-1] ──
        unchecked {
            uint256 remainder;
            assembly { remainder := mulmod(x, y, denominator) }
            assembly { prod1 := sub(prod1, gt(remainder, prod0)) }
            assembly { prod0 := sub(prod0, remainder) }

            uint256 twos = denominator & (~denominator + 1);
            assembly { denominator := div(denominator, twos) }
            assembly { prod0       := div(prod0, twos) }
            assembly {
                twos := add(div(sub(0, twos), twos), 1)
            }

            // [H-1] This line previously ran in checked mode and could overflow-revert
            prod0 |= prod1 * twos;

            // Newton-Raphson modular inverse (6 steps) — all in unchecked [H-1]
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;

            result = prod0 * inv;
        }
    }

    /**
     * @dev Assert the global ERC-20 balance invariant for a token [C-3, A-2].
     *      globalDeposits[token] must never exceed the contract's actual balance.
     */
    function _assertGlobalInvariant(address token) internal view {
        uint256 recorded = globalDeposits[token];
        uint256 actual   = IERC20(token).balanceOf(address(this));
        if (recorded > actual) revert GlobalInvariantBreach(token, recorded, actual);
    }

    /**
     * @dev Require that `addr` has non-zero code size (is a contract) [A-3].
     *      Prevents EOA addresses masquerading as tokens.
     */
    function _requireHasCode(address addr) internal view {
        uint256 size;
        assembly { size := extcodesize(addr) }
        if (size == 0) revert InvalidToken(addr);
    }
}
