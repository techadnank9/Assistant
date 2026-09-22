#!/bin/zsh
# Round 3: more message-taking calls, real data cut to 10%, retrain, compare, and ship if it wins.
cd "$(dirname "$0")"
export HF_HUB_DISABLE_XET=1
{
  echo "== dataset $(date)"; uv run make_dataset.py --calls-per-scenario 6 --append --real-share 0.1
  echo "== train $(date)"; ITERS=500 ./train.sh
  echo "== evaluate $(date)"; uv run evaluate.py --calls-per-scenario 3
  echo "== done $(date)"
} 2>&1 | grep --line-buffered -v "Fetching\|it/s\]" | tee results/round3.log
