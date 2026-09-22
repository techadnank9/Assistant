#!/bin/zsh
# Round 5: DPO straight on the base model (no SFT), with the current prompt; evaluate against base; ship if it wins.
cd "$(dirname "$0")"
export HF_HUB_DISABLE_XET=1
{
  echo "== r5 dpo data $(date)"
  uv run make_dpo.py --student mlx-community/Qwen3-1.7B-4bit --data data4 --out dpo_base_data --prompts 260
  echo "== r5 dpo train $(date)"
  rm -rf dpo_base_out models/dpo-base-4bit
  uv run dpo_train.py --model mlx-community/Qwen3-1.7B-4bit --train --train-mode dpo --data dpo_base_data --iters 150 \
    --batch-size 1 --learning-rate 5e-6 --beta 0.1 --steps-per-eval 25 --max-seq-length 1024 \
    --grad-checkpoint --adapter-path dpo_base_out
  uv run mlx_lm.convert --hf-path dpo_base_out --mlx-path models/dpo-base-4bit -q --q-bits 4 --q-group-size 64
  echo "== r5 evaluate $(date)"
  uv run evaluate.py --model base=mlx-community/Qwen3-1.7B-4bit --model dpo_base=models/dpo-base-4bit \
    --heldout data4/heldout_personas.json --out results_round5
  echo "== r5 ship $(date)"
  uv run ship.py --candidate dpo_base=models/dpo-base-4bit --summary results_round5/summary.json
  echo "== r5 done $(date)"
} 2>&1 | grep --line-buffered -v "Fetching\|it/s\]" | tee -a results/round5.log
