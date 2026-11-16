#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { constants } from "node:os";
import { fileURLToPath } from "node:url";

const flags = process.argv.slice(2);
if (flags.length > 1 || (flags.length === 1 && flags[0] !== "--frozen")) {
  console.error("Usage: node scripts/verify.mjs [--frozen]");
  process.exit(2);
}

process.chdir(fileURLToPath(new URL("../", import.meta.url)));

function moon(...args) {
  const result = spawnSync("moon", args, { stdio: "inherit" });
  if (result.error) {
    console.error(result.error.message);
    process.exit(1);
  }
  if (result.signal) {
    process.exit(128 + constants.signals[result.signal]);
  }
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

// Dependency installation is handled by moon from the pinned manifests.
// PostgreSQL tests require the disposable database configured by POSTGRES_*.
for (const backend of ["native", "wasm"]) {
  moon("check", "--target", backend, ...flags);
  moon("test", "--target", backend, ...flags);
  moon("build", "--target", backend, ...flags);
}

process.env.SQLMAP_NATIVE_BIN = fileURLToPath(
  new URL("../_build/native/debug/build/sqlmap.exe", import.meta.url),
);
process.env.SQLMAP_WASM_BIN = fileURLToPath(
  new URL("../_build/wasm/debug/build/sqlmap.wasm", import.meta.url),
);
for (const backend of ["native", "wasm"]) {
  moon("-C", "tests/integration", "check", "--target", backend, ...flags);
  moon("-C", "tests/integration", "test", "--target", backend, ...flags);
  moon("-C", "tests/integration", "build", "--target", backend, ...flags);
  moon("info", "--target", backend, ...flags);
  moon("-C", "tests/integration", "info", "--target", backend, ...flags);
}
moon("fmt", "--check");
moon("-C", "tests/integration", "fmt", "--check");
