#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project_dir"
swift build --configuration release
exec "$project_dir/.build/release/displaylink-guard" install
