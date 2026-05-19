#!/bin/bash
set -e

echo "=== Compiling Circom Circuits ==="

# Ensure we're in the circuits directory
cd "$(dirname "$0")"

# Verify circom is installed
if ! command -v circom &> /dev/null; then
    echo "❌ circom not found in PATH"
    echo "Install via: curl -Ls https://github.com/iden3/circom/releases/download/v2.1.6/circom-linux-amd64 -o /usr/local/bin/circom && chmod +x /usr/local/bin/circom"
    exit 1
fi

echo "✅ Using circom: $(circom --version)"

# Verify snarkjs is installed
if ! command -v snarkjs &> /dev/null; then
    echo "❌ snarkjs not found"
    echo "Install via: npm install -g snarkjs"
    exit 1
fi

# Create build directory
mkdir -p build
mkdir -p ../contracts/verifiers

PTAU_FILE="build/powersOfTau28_hez_final_15.ptau"

# Check ptau file - warn if stub
if [ -f "$PTAU_FILE" ]; then
    SIZE=$(wc -c < "$PTAU_FILE")
    if [ $SIZE -lt 1000000 ]; then
        echo "⚠️  Powers of Tau file is only $SIZE bytes (stub detected)"
        echo "Downloading real ptau file (~55MB)..."
        rm "$PTAU_FILE"
    fi
fi

# Download powers of Tau file if not present
if [ ! -f "$PTAU_FILE" ]; then
    echo "📥 Downloading Powers of Tau file (may take 2-3 minutes)..."
    curl -L https://hermez.s3-eu-west-1.amazonaws.com/powersOfTau28_hez_final_15.ptau -o "$PTAU_FILE"
    echo "✅ Downloaded: $(ls -lh $PTAU_FILE | awk '{print $5}')"
fi

echo "✅ Powers of Tau file ready at $PTAU_FILE"

# Compile each circuit
CIRCUITS=("order_validity" "match_proof" "cancel_proof")

for CIRCUIT in "${CIRCUITS[@]}"; do
    echo ""
    echo "╔════════════════════════════════════════════════╗"
    echo "║ Compiling: $CIRCUIT"
    echo "╚════════════════════════════════════════════════╝"

    case "$CIRCUIT" in
        order_validity)
            VERIFIER_NAME="OrderValidityVerifier"
            PAIRING_NAME="OrderValidityPairing"
            ;;
        match_proof)
            VERIFIER_NAME="MatchProofVerifier"
            PAIRING_NAME="MatchProofPairing"
            ;;
        cancel_proof)
            VERIFIER_NAME="CancelProofVerifier"
            PAIRING_NAME="CancelProofPairing"
            ;;
        *)
            echo "Unknown circuit: $CIRCUIT"
            exit 1
            ;;
    esac

    # Compile circuit to r1cs, wasm, and symbol files
    echo "[1/5] Compiling $CIRCUIT.circom → r1cs/wasm..."
    circom "$CIRCUIT.circom" --r1cs --wasm --sym -o build

    echo "[2/5] Setting up Groth16 (Phase 1)..."
    snarkjs groth16 setup \
        "build/${CIRCUIT}.r1cs" \
        "$PTAU_FILE" \
        "build/${CIRCUIT}_0000.zkey" \
        -v 2>&1 | tail -5

    echo "[3/5] Contributing to setup (Phase 2)..."
    snarkjs zkey contribute \
        "build/${CIRCUIT}_0000.zkey" \
        "build/${CIRCUIT}_final.zkey" \
        --name="1st Contributor" \
        -v \
        -e="$CIRCUIT" 2>&1 | tail -3

    echo "[4/5] Exporting Solidity verifier contract..."
    VERIFIER_PATH="../contracts/verifiers/${VERIFIER_NAME}.sol"
    snarkjs zkey export solidityverifier \
        "build/${CIRCUIT}_final.zkey" \
        "$VERIFIER_PATH"

    # Fix Solidity contract names
    sed -i "s/library Pairing/library ${PAIRING_NAME}/" "$VERIFIER_PATH"
    sed -i "s/using Pairing for \\*/using ${PAIRING_NAME} for */" "$VERIFIER_PATH"
    sed -i "s/Pairing\\./${PAIRING_NAME}./g" "$VERIFIER_PATH"
    sed -i "s/contract Groth16Verifier/contract ${VERIFIER_NAME}/" "$VERIFIER_PATH"

    echo "[5/5] Exporting verification key..."
    snarkjs zkey export verificationkey \
        "build/${CIRCUIT}_final.zkey" \
        "build/${CIRCUIT}_vk.json"
    
    echo "✅ $CIRCUIT compiled successfully!"
done

echo ""
echo "╔════════════════════════════════════════════════╗"
echo "║ ✅ ALL CIRCUITS COMPILED SUCCESSFULLY!         ║"
echo "╚════════════════════════════════════════════════╝"
echo ""
echo "📂 Generated artifacts:"
echo "   Verifiers:        ../contracts/verifiers/"
echo "   ZK artifacts:     build/"
echo "   Verification keys: build/*_vk.json"
echo ""
echo "Next: npx hardhat compile && npx hardhat run scripts/deploy.ts --network localhost"

