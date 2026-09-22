#!/bin/zsh
# Round 4, stage C: DPO on the 4-bit SFT model (QLoRA, fits in 16 GB), then evaluate and ship.
cd "$(dirname "$0")"
export HF_HUB_DISABLE_XET=1
{
  echo "== dpo train (qlora) $(date)"
  rm -rf dpo_out models/dpo-4bit
  uv run dpo_train.py --model models/sft-4bit --train --train-mode dpo --data dpo_data --iters 150 \
    --batch-size 1 --learning-rate 5e-6 --beta 0.1 --steps-per-eval 25 --max-seq-length 1024 \
    --grad-checkpoint --adapter-path dpo_out
  CANDIDATES=(--candidate sft=models/sft-4bit)
  MODELS=(--model base=mlx-community/Qwen3-1.7B-4bit --model sft=models/sft-4bit)
  if [[ -f dpo_out/config.json ]]; then
    uv run mlx_lm.convert --hf-path dpo_out --mlx-path models/dpo-4bit -q --q-bits 4 --q-group-size 64
    CANDIDATES+=(--candidate dpo=models/dpo-4bit)
    MODELS+=(--model dpo=models/dpo-4bit)
  else
    echo "== dpo failed; evaluating sft only"
  fi
  echo "== evaluate $(date)"
  uv run evaluate.py $MODELS --heldout data4/heldout_personas.json --out results
  echo "== ship $(date)"
  uv run ship.py $CANDIDATES
  echo "== done $(date)"
} 2>&1 | grep --line-buffered -v "Fetching\|it/s\]" | tee -a results/round4.log
