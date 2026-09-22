"""Builds the fine-tuning set: the teacher (Qwen3-8B) plays both caller and an excellent assistant.

Each assistant reply becomes one training example whose prompt is the short runtime system prompt,
so the 1.7B model learns the teacher's behaviour without the teacher's extra guidance.

    uv run make_dataset.py --calls-per-scenario 6
"""

import argparse
import json
import random
from pathlib import Path

from common import TEACHER_MODEL, TEACHER_STYLE, Model, agent_prompt, is_clean, simulate
from scenarios import TRAIN

NUMBERS = [None, "+14155550123", "+16505550188", "+12125550147"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--calls-per-scenario", type=int, default=6)
    parser.add_argument("--scenarios", type=int, default=len(TRAIN), help="use only the first N (for a trial run)")
    parser.add_argument("--out", default="data")
    parser.add_argument("--append", action="store_true", help="keep earlier generated calls (data/generated.jsonl)")
    parser.add_argument("--personas", help="JSON list of extra caller personas (from personas.py)")
    parser.add_argument("--persona-calls", type=int, default=1, help="calls per generated persona")
    parser.add_argument("--real-share", type=float, default=0.1, help="fraction of training rows from Taskmaster")
    args = parser.parse_args()

    teacher = Model(TEACHER_MODEL)
    examples = []
    plan = [(s, args.calls_per_scenario) for s in TRAIN[: args.scenarios]]
    if args.personas:
        plan += [(p, args.persona_calls) for p in json.load(open(args.personas))]
    for i, (scenario, calls) in enumerate(plan):
        for n in range(calls):
            number = random.choice(NUMBERS)
            call = simulate(teacher, teacher, scenario, agent_prompt(caller_number=number) + TEACHER_STYLE)
            if not is_clean(call):
                print(f"[{i + 1}/{len(plan)}] call {n + 1}: rejected (loop, long reply or no ending)", flush=True)
                continue
            # Swap in the runtime prompt, then emit one example per assistant reply.
            call[0] = {"role": "system", "content": agent_prompt(caller_number=number)}
            for cut in range(3, len(call) + 1):
                if call[cut - 1]["role"] == "assistant":
                    examples.append({"messages": call[:cut]})
            print(f"[{i + 1}/{len(plan)}] call {n + 1}: {len(call) - 2} turns", flush=True)

    cache = Path(args.out) / "generated.jsonl"
    if args.append and cache.exists():
        earlier = [json.loads(line) for line in open(cache)]
        print(f"Keeping {len(earlier)} earlier generated examples")
        examples = earlier + examples
    Path(args.out).mkdir(exist_ok=True)
    with open(cache, "w") as f:
        for row in examples:
            f.write(json.dumps(row) + "\n")

    random.shuffle(examples)
    split = max(1, len(examples) // 10)
    # Real human phone-assistant turns go into training only; validation stays on our own task.
    real = Path(__file__).with_name("external") / "taskmaster.jsonl"
    extra = [json.loads(line) for line in open(real)] if real.exists() else []
    # Keep real data a small slice: it teaches spoken brevity but not our task or the [END] signal.
    keep = int((len(examples) - split) * args.real_share / (1 - args.real_share))
    extra = random.sample(extra, min(keep, len(extra)))
    out = Path(args.out)
    out.mkdir(exist_ok=True)
    train = examples[split:] + extra
    random.shuffle(train)
    for name, rows in [("valid", examples[:split]), ("train", train)]:
        with open(out / f"{name}.jsonl", "w") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")
    print(f"{len(train)} train ({len(extra)} real from Taskmaster) / {split} valid examples in {out}/")


if __name__ == "__main__":
    main()
