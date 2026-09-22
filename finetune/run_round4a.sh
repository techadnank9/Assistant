#!/bin/zsh
# Round 4, stage A: invent callers, then generate teacher calls (Qwen3-14B). Logs to results/round4.log.
cd "$(dirname "$0")"
export HF_HUB_DISABLE_XET=1
{
  echo "== personas $(date)"
  uv run personas.py --per-category 12 --heldout-per-category 2 --out data4/personas.json --heldout data4/heldout_personas.json
  echo "== dataset $(date)"
  uv run make_dataset.py --out data4 --calls-per-scenario 1 --personas data4/personas.json --persona-calls 1 --real-share 0.1
  echo "== stageA done $(date)"
} 2>&1 | grep --line-buffered -v "Fetching\|it/s\]" | tee -a results/round4.log
