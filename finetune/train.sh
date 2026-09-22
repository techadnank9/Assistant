#!/bin/zsh
# LoRA fine-tune Qwen3-1.7B on data/, keep the checkpoint with the lowest validation loss,
# fuse it and quantize to 4-bit for the iPhone.
set -euo pipefail
cd "$(dirname "$0")"

BASE=Qwen/Qwen3-1.7B
OUT=models/qwen3-1.7b-assistant-4bit
ITERS=${ITERS:-400}
rm -rf adapters best

uv run mlx_lm.lora \
  --model "$BASE" \
  --train --data data \
  --fine-tune-type lora --num-layers 16 \
  --mask-prompt \
  --batch-size 4 --iters "$ITERS" --learning-rate 1e-4 \
  --steps-per-eval 25 --save-every 25 \
  --grad-checkpoint \
  --adapter-path adapters 2>&1 | tee results/train.log

# Pick the saved checkpoint with the lowest validation loss (training past it just memorizes).
BEST=$(python3 - <<'PY'
import re
losses = {int(i): float(v) for i, v in re.findall(r"Iter (\d+): Val loss ([\d.]+)", open("results/train.log").read()) if int(i) > 1}
best = min(losses, key=losses.get)
print(f"{best:07d}")
PY
)
echo "Best checkpoint: step $((10#$BEST))"
mkdir -p best
cp adapters/adapter_config.json best/
cp "adapters/${BEST}_adapters.safetensors" best/adapters.safetensors

rm -rf fused "$OUT"
uv run mlx_lm.fuse --model "$BASE" --adapter-path best --save-path fused
uv run mlx_lm.convert --hf-path fused --mlx-path "$OUT" -q --q-bits 4 --q-group-size 64
echo "Quantized model: $OUT"
