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

# Enforce circom 2.1.6 (avoid circuit/compiler mismatches)
CIRCOM_VERSION="$(circom --version | tr -d '\r\n' || true)"
if [[ "$CIRCOM_VERSION" != *"2.1.6"* ]]; then
    echo "❌ Circom version mismatch."
    echo "   Found: $CIRCOM_VERSION"
    echo "   Expected: circom compiler 2.1.6"
    echo "Install/upgrade via:"
    echo "  curl -Ls https://github.com/iden3/circom/releases/download/v2.1.6/circom-linux-amd64 -o /usr/local/bin/circom"
    echo "  chmod +x /usr/local/bin/circom"
    exit 1
fi

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

# Check ptau file - hard fail if suspicious (avoid silent stub)
# Real ptau is ~55MB. We'll require at least 30MB.
MIN_PTAU_BYTES=$((30 * 1024 * 1024))

if [ -f "$PTAU_FILE" ]; then
    SIZE=$(wc -c < "$PTAU_FILE")
    if [ "$SIZE" -lt "$MIN_PTAU_BYTES" ]; then
        echo "❌ Powers of Tau file is suspiciously small: $SIZE bytes"
        echo "   Expected real file (~55MB). Refusing to continue."
        echo "   Removing stub and downloading the real ptau..."
        rm -f "$PTAU_FILE"
    else
        echo "✅ Powers of Tau file size looks valid: $SIZE bytes"
    fi
fi

# Download powers of Tau file if not present
if [ ! -f "$PTAU_FILE" ]; then
    echo "📥 Downloading Powers of Tau file (~55MB)..."
    curl -L --fail https://hermez.s3-eu-west-1.amazonaws.com/powersOfTau28_hez_final_15.ptau -o "$PTAU_FILE"
fi

# Final verification
SIZE=$(wc -c < "$PTAU_FILE")
if [ "$SIZE" -lt "$MIN_PTAU_BYTES" ]; then
    echo "❌ Powers of Tau download failed or produced incomplete file."
    echo "   File size: $SIZE bytes (min required: $MIN_PTAU_BYTES)"
    exit 1
fi

echo "✅ Powers of Tau file ready at $PTAU_FILE (size: $SIZE bytes)"

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
        -v

    echo "[3/5] Contributing to setup (Phase 2)..."
    snarkjs zkey contribute \
        "build/${CIRCUIT}_0000.zkey" \
        "build/${CIRCUIT}_final.zkey" \
        --name="1st Contributor" \
        -v \
        -e="$CIRCUIT"

    echo "[4/5] Exporting Solidity verifier contract..."
    VERIFIER_PATH="../contracts/verifiers/${VERIFIER_NAME}.sol"
    rm -f "$VERIFIER_PATH"
    snarkjs zkey export solidityverifier \
        "build/${CIRCUIT}_final.zkey" \
        "$VERIFIER_PATH"

    if [ ! -s "$VERIFIER_PATH" ]; then
        echo "❌ Failed to generate ${VERIFIER_PATH}"
        exit 1
    fi

    # Fix Solidity contract names (fail fast if patterns not found)
    if ! grep -q "library Pairing" "$VERIFIER_PATH"; then
        echo "❌ Expected Pairing library pattern not found in ${VERIFIER_PATH}"
        exit 1
    fi
    sed -i "s/library Pairing/library ${PAIRING_NAME}/" "$VERIFIER_PATH"

    if ! grep -q "using Pairing for" "$VERIFIER_PATH"; then
        echo "❌ Expected 'using Pairing for' pattern not found in ${VERIFIER_PATH}"
        exit 1
    fi
    sed -i "s/using Pairing for \\*/using ${PAIRING_NAME} for */" "$VERIFIER_PATH"

    sed -i "s/Pairing\\./${PAIRING_NAME}./g" "$VERIFIER_PATH"

    if ! grep -q "contract Groth16Verifier" "$VERIFIER_PATH"; then
        echo "❌ Expected Groth16Verifier contract pattern not found in ${VERIFIER_PATH}"
        exit 1
    fi
    sed -i "s/contract Groth16Verifier/contract ${VERIFIER_NAME}/" "$VERIFIER_PATH"

    echo "[5/5] Exporting verification key..."
    snarkjs zkey export verificationkey \
        "build/${CIRCUIT}_final.zkey" \
        "build/${CIRCUIT}_vk.json"

    if [ ! -s "build/${CIRCUIT}_vk.json" ]; then
        echo "❌ Failed to export verification key for $CIRCUIT"
        exit 1
    fi

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

