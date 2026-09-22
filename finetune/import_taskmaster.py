"""Real human phone-assistant turns from Google's Taskmaster-1 (CC BY 4.0).

Humans played the assistant on a spoken line: short replies, one question at a time, read-backs to
confirm. We keep the auto-repair and restaurant-booking calls (closest to taking a message) and
emit a few training examples per call so the student learns that spoken style from real people.

Source: https://github.com/google-research-datasets/Taskmaster (TM-1-2019/woz-dialogs.json)
"""

import json
import random
from pathlib import Path

SYSTEM = ("You are a phone assistant for a small business, speaking on a live call. Reply in one or two "
          "short, warm sentences. Ask for one missing detail at a time and read details back to confirm.")


def sentence_case(text: str) -> str:
    text = text.strip()
    if text and text[0].islower():
        text = text[0].upper() + text[1:]
    text = text.replace(" i ", " I ").replace(" i'", " I'")
    return text if text[-1:] in ".?!" else text + "."


def turns(dialog: dict) -> list[dict]:
    """Merges consecutive utterances by the same speaker into one turn."""
    out = []
    for u in dialog["utterances"]:
        # Taskmaster redacts some turns; drop them rather than teach the marker.
        if "(deleted)" in u["text"] or not u["text"].strip():
            continue
        role = "assistant" if u["speaker"] == "ASSISTANT" else "user"
        text = sentence_case(u["text"])
        if out and out[-1]["role"] == role:
            out[-1]["content"] += " " + text
        else:
            out.append({"role": role, "content": text})
    return out


def main(per_dialog: int = 2, max_dialogs: int = 160):
    random.seed(7)
    dialogs = json.load(open(Path(__file__).with_name("external") / "woz-dialogs.json"))
    keep = [d for d in dialogs if d["instruction_id"].split("-")[0] in ("auto", "restaurant")]
    random.shuffle(keep)

    examples = []
    for dialog in keep:
        convo = turns(dialog)
        if len(convo) < 6 or convo[0]["role"] != "assistant" or any(len(t["content"].split()) > 35 for t in convo if t["role"] == "assistant"):
            continue
        cuts = [i + 1 for i, t in enumerate(convo) if t["role"] == "assistant" and i >= 2]
        for cut in random.sample(cuts, min(per_dialog, len(cuts))):
            examples.append({"messages": [{"role": "system", "content": SYSTEM}] + convo[:cut]})
        if len(examples) >= max_dialogs * per_dialog:
            break

    out = Path(__file__).with_name("external") / "taskmaster.jsonl"
    with open(out, "w") as f:
        for row in examples:
            f.write(json.dumps(row) + "\n")
    print(f"{len(examples)} real examples from Taskmaster-1 in {out}")


if __name__ == "__main__":
    main()
