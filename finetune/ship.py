"""Ship gate: upload the best trained model to Hugging Face only if it beats the base model
on held-out callers. Writes results/decision.json either way.

    HF_TOKEN=... uv run ship.py --candidate sft=models/sft-4bit --candidate dpo=models/dpo-4bit
"""

import argparse
import json
import os
from pathlib import Path

REPO = "adnank9/qwen3-1.7b-phone-assistant-4bit"


def beats(c: dict, base: dict) -> bool:
    return (c["overall /10"] >= base["overall /10"] + 0.1
            and c["ended call %"] >= base["ended call %"] - 5
            and c["words/reply"] <= base["words/reply"] * 1.1
            and c["repeat %"] <= base["repeat %"] + 2)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", action="append", required=True, help="label=path")
    parser.add_argument("--summary", default="results/summary.json")
    args = parser.parse_args()

    summary = json.load(open(args.summary))
    base = summary["base"]
    paths = dict(spec.split("=", 1) for spec in args.candidate)
    winners = [(summary[l]["overall /10"], l) for l in paths if l in summary and beats(summary[l], base)]
    decision = {"base": base, "candidates": {l: summary.get(l) for l in paths}, "shipped": None}

    if winners:
        _, label = max(winners)
        from huggingface_hub import HfApi
        api = HfApi(token=os.environ["HF_TOKEN"])
        api.create_repo(REPO, repo_type="model", private=False, exist_ok=True)
        card = Path(paths[label]) / "README.md"
        card.write_text(f"""---
license: apache-2.0
base_model: Qwen/Qwen3-1.7B
library_name: mlx
tags: [mlx, phone-assistant, on-device]
---
# Qwen3-1.7B phone assistant (4-bit, MLX)

The on-device model behind [Assistant](https://github.com/techadnank9/Assistant): answers calls and takes messages
on an iPhone. Fine-tuned from Qwen3-1.7B ({label}): LoRA on teacher-generated calls from 100+ caller personas
plus a slice of Google Taskmaster-1{", then DPO against its own worst replies" if label == "dpo" else ""}.

Held-out evaluation vs base: overall {summary[label]['overall /10']:.2f} vs {base['overall /10']:.2f} /10,
{summary[label]['words/reply']:.1f} vs {base['words/reply']:.1f} words per reply,
ended calls {summary[label]['ended call %']:.0f}% vs {base['ended call %']:.0f}%.
""")
        api.upload_folder(repo_id=REPO, folder_path=paths[label], repo_type="model",
                          allow_patterns=["*.json", "*.safetensors", "*.jinja", "*.txt", "README.md"])
        decision["shipped"] = {"label": label, "repo": REPO}
        print(f"Shipped {label} to https://huggingface.co/{REPO}", flush=True)
    else:
        print("No candidate beat the base model; nothing uploaded.", flush=True)

    json.dump(decision, open("results/decision.json", "w"), indent=1)


if __name__ == "__main__":
    main()
