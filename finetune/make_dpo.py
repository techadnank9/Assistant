"""Preference pairs for DPO: the fine-tuned student answers real training situations several times;
its worst answer (by the rule checks) becomes "rejected", the teacher's reply "chosen".
This targets exactly what fine-tuning alone left behind: rambling, repeating, hanging up wrong.

    uv run make_dpo.py --student models/sft-4bit --data data4 --out dpo_data
"""

import argparse
import json
import random
from pathlib import Path

import re

from common import END, Model, agent_prompt, reply_score
from import_taskmaster import SYSTEM as TASKMASTER_SYSTEM


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--student", required=True)
    parser.add_argument("--data", default="data4")
    parser.add_argument("--out", default="dpo_data")
    parser.add_argument("--prompts", type=int, default=220)
    parser.add_argument("--samples", type=int, default=4)
    args = parser.parse_args()

    random.seed(11)
    rows = [json.loads(line) for line in open(Path(args.data) / "train.jsonl")]
    rows = [r for r in rows if r["messages"][0]["content"] != TASKMASTER_SYSTEM]
    # Train against the current prompt (the rules evolve; the calls don't need to be regenerated).
    for r in rows:
        number = re.search(r"caller's number is (\+?\d+)", r["messages"][0]["content"])
        r["messages"][0] = {"role": "system", "content": agent_prompt(caller_number=number.group(1) if number else None)}
    random.shuffle(rows)

    student = Model(args.student)
    pairs = []
    for i, row in enumerate(rows[: args.prompts]):
        history, reference = row["messages"][:-1], row["messages"][-1]["content"]
        should_end = END in reference
        chosen_score = reply_score(reference, history, should_end)
        candidates = [student.chat(history, max_tokens=120, temp=1.0) for _ in range(args.samples)]
        scored = sorted((reply_score(c, history, should_end), c) for c in candidates)
        worst_score, worst = scored[0]
        if chosen_score - worst_score >= 1.5:
            pairs.append({"messages": history, "chosen": reference, "rejected": worst})
        if i % 20 == 0:
            print(f"[{i}/{args.prompts}] {len(pairs)} pairs", flush=True)

    random.shuffle(pairs)
    split = max(1, len(pairs) // 10)
    out = Path(args.out)
    out.mkdir(exist_ok=True)
    for name, part in [("valid", pairs[:split]), ("train", pairs[split:])]:
        with open(out / f"{name}.jsonl", "w") as f:
            for p in part:
                f.write(json.dumps(p) + "\n")
    print(f"{len(pairs)} preference pairs ({len(pairs) - split} train / {split} valid)", flush=True)


if __name__ == "__main__":
    main()
