#!/bin/bash
# Build Rust WASM module for Nexus

set -e

echo "Building Rust WASM module..."

# Build with cargo
cargo build --target wasm32-wasi --release

# Copy output
cp target/wasm32-wasi/release/rust_hello_wasm.wasm ../rust-hello.wasm

# Optimize with wasm-opt if available
if command -v wasm-opt &> /dev/null; then
    echo "Optimizing with wasm-opt..."
    wasm-opt -Oz ../rust-hello.wasm -o ../rust-hello.wasm
fi

echo "✓ Build complete: ../rust-hello.wasm"
ls -lh ../rust-hello.wasm
