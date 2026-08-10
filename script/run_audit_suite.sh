#!/usr/bin/env bash
set -e

echo "=== MULTYR Audit Suite ==="
echo ""

echo "--- Step 1: Format check ---"
forge fmt --check

echo "--- Step 2: Build ---"
forge build

echo "--- Step 3: Unit + integration + fuzz + invariant tests ---"
forge test --no-match-path "test/ForkArbitrum*"

echo "--- Step 4: Fork tests (requires ARBITRUM_RPC_URL) ---"
if [ -n "$ARBITRUM_RPC_URL" ]; then
    forge test --match-path "test/ForkArbitrum*" -vvv
else
    echo "ARBITRUM_RPC_URL not set — skipping fork tests"
fi

echo "--- Step 5: Slither static analysis ---"
if command -v slither &> /dev/null; then
    slither . --config-file slither.config.json
else
    echo "Slither not installed — skipping"
    echo "Install: pip install slither-analyzer"
fi

echo ""
echo "=== Audit suite complete ==="
