#!/bin/zsh
# Whole Phase 5: real data import → practice calls → LoRA training → before/after report.
cd "$(dirname "$0")"
mkdir -p results
export HF_HUB_DISABLE_XET=1   # the Xet CDN kept dropping downloads on this network
{
  echo "== import $(date)"; uv run import_taskmaster.py
  echo "== dataset $(date)"; uv run make_dataset.py --calls-per-scenario 8
  echo "== train $(date)"; ./train.sh
  echo "== evaluate $(date)"; uv run evaluate.py --calls-per-scenario 2
  echo "== done $(date)"
} 2>&1 | grep --line-buffered -v "Fetching\|it/s\]" | tee results/run.log
