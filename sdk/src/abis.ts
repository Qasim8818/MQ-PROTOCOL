export const DARKPOOL_ABI = [
  "function MIN_QUANTITY() public view returns (uint256)",
  "function PROTOCOL_FEE_BPS() public view returns (uint256)",
  "function EMPTY_TREE_ROOT() public view returns (bytes32)",
  "function userDepositRoots(address user) public view returns (bytes32)",
  "function deposits(address user, address token) public view returns (uint256)",
  "function lockedBalances(address user, address token) public view returns (uint256)",
  "function deposit(address token, uint256 amount, bytes32 newRoot) external",
  "function withdraw(address token, uint256 amount, bytes32 newRoot) external",
  "function createNote(bytes32 commitment, bytes32 nullifier, address tokenIn, address tokenOut, uint256 amountLocked, uint256 deadline, uint256[2] a, uint256[2][2] b, uint256[2] c) external",
  "function cancelNote(bytes32 commitment, bytes32 nullifier, uint256[2] a, uint256[2][2] b, uint256[2] c) external",
  "function settle(uint256[2] a, uint256[2][2] b, uint256[2] c, bytes32 buyNullifier, bytes32 sellNullifier, uint256 settledPrice, uint256 settledQty, bytes32 buyCommitment, bytes32 sellCommitment, address buyOwner, address sellOwner) external",
];
