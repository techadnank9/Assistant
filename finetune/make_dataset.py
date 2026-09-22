"""Builds the fine-tuning set: the teacher (Qwen3-8B) plays both caller and an excellent assistant.

Each assistant reply becomes one training example whose prompt is the short runtime system prompt,
so the 1.7B model learns the teacher's behaviour without the teacher's extra guidance.

    uv run make_dataset.py --calls-per-scenario 6
"""

import argparse
import json
import random
from pathlib import Path

from common import END, TEACHER_MODEL, TEACHER_STYLE, Model, agent_prompt, simulate
from scenarios import TRAIN

NUMBERS = [None, "+14155550123", "+16505550188", "+12125550147"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--calls-per-scenario", type=int, default=6)
    parser.add_argument("--scenarios", type=int, default=len(TRAIN), help="use only the first N (for a trial run)")
    parser.add_argument("--out", default="data")
    args = parser.parse_args()

    teacher = Model(TEACHER_MODEL)
    examples = []
    for i, scenario in enumerate(TRAIN[: args.scenarios]):
        for n in range(args.calls_per_scenario):
            number = random.choice(NUMBERS)
            call = simulate(teacher, teacher, scenario, agent_prompt(caller_number=number) + TEACHER_STYLE)
            if not call[-1]["content"].endswith(END):
                continue  # ran out of turns; not a clean example
            # Swap in the runtime prompt, then emit one example per assistant reply.
            call[0] = {"role": "system", "content": agent_prompt(caller_number=number)}
            for cut in range(3, len(call) + 1):
                if call[cut - 1]["role"] == "assistant":
                    examples.append({"messages": call[:cut]})
            print(f"[{i + 1}/{len(TRAIN)}] call {n + 1}: {len(call) - 2} turns")

    random.shuffle(examples)
    split = max(1, len(examples) // 10)
    out = Path(args.out)
    out.mkdir(exist_ok=True)
    for name, rows in [("valid", examples[:split]), ("train", examples[split:])]:
        with open(out / f"{name}.jsonl", "w") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")
    print(f"{len(examples) - split} train / {split} valid examples in {out}/")


if __name__ == "__main__":
    main()
