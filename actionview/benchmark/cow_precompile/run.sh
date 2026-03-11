#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RAILS_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

cd "$RAILS_ROOT"

echo "Building benchmark image (this copies the Rails source into Docker)..."
docker build \
  -f actionview/benchmark/cow_precompile/Dockerfile \
  -t rails-cow-benchmark \
  .

echo ""
echo "Running benchmark..."
docker run --rm rails-cow-benchmark
