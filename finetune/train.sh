#!/bin/zsh
# LoRA fine-tune Qwen3-1.7B on data/, fuse, quantize to 4-bit for the iPhone,
# and (if you're logged in to Hugging Face) upload so the app can download it.
#
#   ./train.sh                   # train + fuse + quantize
#   HF_REPO=you/qwen3-1.7b-assistant ./train.sh   # ...and upload
set -euo pipefail
cd "$(dirname "$0")"

BASE=Qwen/Qwen3-1.7B
OUT=models/qwen3-1.7b-assistant-4bit

uv run mlx_lm.lora \
  --model "$BASE" \
  --train --data data \
  --fine-tune-type lora --num-layers 16 \
  --mask-prompt \
  --batch-size 4 --iters 600 --learning-rate 1e-4 \
  --steps-per-eval 100 --save-every 200 \
  --grad-checkpoint \
  --adapter-path adapters

rm -rf fused "$OUT"
uv run mlx_lm.fuse --model "$BASE" --adapter-path adapters --save-path fused
uv run mlx_lm.convert --hf-path fused --mlx-path "$OUT" -q --q-bits 4 --q-group-size 64
echo "Quantized model: $OUT"

if [[ -n "${HF_REPO:-}" ]]; then
  uv run hf upload "$HF_REPO" "$OUT" . --repo-type model
  echo "Uploaded. In the app: Settings → Model → type $HF_REPO → Use → Load selected model"
fi
