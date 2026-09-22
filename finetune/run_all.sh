#!/bin/zsh
# Whole Phase 5 in one go: dataset → LoRA training → before/after report. Logs to results/run.log.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p results
{
  echo "== dataset $(date)"
  uv run make_dataset.py --calls-per-scenario 4
  echo "== train $(date)"
  ./train.sh
  echo "== evaluate $(date)"
  uv run evaluate.py --calls-per-scenario 2
  echo "== done $(date)"
} 2>&1 | grep --line-buffered -v "Fetching\|it/s\]" | tee results/run.log
