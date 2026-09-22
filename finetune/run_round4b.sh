#!/bin/zsh
# Round 4, stage B: fine-tune → DPO → evaluate three models → ship the winner. Needs HF_TOKEN in the env.
cd "$(dirname "$0")"
export HF_HUB_DISABLE_XET=1
{
  echo "== sft $(date)"
  DATA=data4 OUT=models/sft-4bit ITERS=${SFT_ITERS:-450} ./train.sh
  echo "== dpo data $(date)"
  uv run make_dpo.py --student models/sft-4bit --data data4 --out dpo_data --prompts 220
  PAIRS=$(cat dpo_data/train.jsonl 2>/dev/null | wc -l | tr -d ' ')
  CANDIDATES=(--candidate sft=models/sft-4bit)
  MODELS=(--model base=mlx-community/Qwen3-1.7B-4bit --model sft=models/sft-4bit)
  if [[ ${PAIRS:-0} -ge 30 ]]; then
    ITERS=$(( PAIRS > 60 ? PAIRS : 60 ))
    echo "== dpo train ($PAIRS pairs, $ITERS iters) $(date)"
    rm -rf dpo_out models/dpo-4bit
    uv run dpo_train.py --model fused --train --train-mode dpo --data dpo_data --iters $ITERS \
      --batch-size 2 --learning-rate 5e-6 --beta 0.1 --steps-per-eval 20 --max-seq-length 2048 \
      --grad-checkpoint --adapter-path dpo_out
    uv run mlx_lm.convert --hf-path dpo_out --mlx-path models/dpo-4bit -q --q-bits 4 --q-group-size 64
    CANDIDATES+=(--candidate dpo=models/dpo-4bit)
    MODELS+=(--model dpo=models/dpo-4bit)
  else
    echo "== dpo skipped: only ${PAIRS:-0} pairs"
  fi
  echo "== evaluate $(date)"
  uv run evaluate.py $MODELS --heldout data4/heldout_personas.json --out results
  echo "== ship $(date)"
  uv run ship.py $CANDIDATES
  echo "== done $(date)"
} 2>&1 | grep --line-buffered -v "Fetching\|it/s\]" | tee -a results/round4.log
