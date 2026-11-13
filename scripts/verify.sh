#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

flags=()
if [[ "${1:-}" == --frozen ]]; then
  flags+=(--frozen)
elif [[ $# -gt 0 ]]; then
  echo 'Usage: scripts/verify.sh [--frozen]' >&2
  exit 2
fi

# Dependency installation is handled by moon from the pinned manifests.
# PostgreSQL tests require the disposable database configured by POSTGRES_*.
for backend in native wasm; do
  moon check --target "$backend" "${flags[@]}"
  moon test --target "$backend" "${flags[@]}"
  moon build --target "$backend" "${flags[@]}"
done

export SQLMAP_NATIVE_BIN="$PWD/_build/native/debug/build/sqlmap.exe"
export SQLMAP_WASM_BIN="$PWD/_build/wasm/debug/build/sqlmap.wasm"
for backend in native wasm; do
  moon -C tests/integration check --target "$backend" "${flags[@]}"
  moon -C tests/integration test --target "$backend" "${flags[@]}"
  moon -C tests/integration build --target "$backend" "${flags[@]}"
  moon info --target "$backend" "${flags[@]}"
  moon -C tests/integration info --target "$backend" "${flags[@]}"
done
moon fmt --check
moon -C tests/integration fmt --check
