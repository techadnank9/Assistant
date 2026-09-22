"""Persona-driven caller generation: the teacher invents many different callers per category,
so the student sees far more variety than hand-written scenarios.

    uv run personas.py --per-category 9 --out data/personas.json --heldout data/heldout_personas.json
"""

import argparse
import json
import random
import re

from common import TEACHER_MODEL, Model

CATEGORIES = [
    "recruiters and hiring managers reaching out about roles in AI, backend or voice agents",
    "former coworkers or friends from past jobs (Centific, Guidesly, Neudesic/IBM, Yoofoo)",
    "clients of a restaurant voice-ordering AI product with a problem or request",
    "medical, dental or vet offices about appointments, results or prescriptions",
    "delivery drivers, couriers and repair or maintenance people",
    "family members, some with urgent news (health, school, travel)",
    "friends with casual plans, favors or just saying hi",
    "banks, landlords, utilities or government offices (some legitimate, some suspicious)",
    "spam, robocalls, sales pitches, surveys and scams",
    "callers fishing for personal info (address, schedule, whereabouts, other numbers)",
    "wrong numbers, confused callers, people with bad connections or heavy accents",
    "startup founders, investors, podcast hosts, conference and hackathon organizers",
]

PROMPT = """Invent {n} realistic, varied people who might phone Adnan, a San Francisco AI engineer, \
in this category: {category}.
Vary names, ages, urgency, how much they reveal at once, and speaking style. Include concrete details \
(dates, times, callback numbers in 555 format or emails) for some, and none for others.
Reply with only a JSON array of objects with keys "persona" (who they are and why they call, 1-2 sentences) \
and "style" (how they talk, a short phrase)."""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--per-category", type=int, default=9)
    parser.add_argument("--heldout-per-category", type=int, default=2)
    parser.add_argument("--out", default="data/personas.json")
    parser.add_argument("--heldout", default="data/heldout_personas.json")
    args = parser.parse_args()

    teacher = Model(TEACHER_MODEL)
    train, heldout = [], []
    for category in CATEGORIES:
        n = args.per_category + args.heldout_per_category
        text = teacher.chat([{"role": "user", "content": PROMPT.format(n=n, category=category)}],
                            max_tokens=2200, temp=0.9)
        match = re.search(r"\[.*\]", text, re.S)
        try:
            people = [p for p in json.loads(match.group(0)) if p.get("persona")] if match else []
        except json.JSONDecodeError:
            people = []
        random.shuffle(people)
        heldout += people[: args.heldout_per_category]
        train += people[args.heldout_per_category:]
        print(f"{category[:50]}…: {len(people)} personas", flush=True)

    json.dump(train, open(args.out, "w"), indent=1)
    json.dump(heldout, open(args.heldout, "w"), indent=1)
    print(f"{len(train)} training personas, {len(heldout)} held out", flush=True)


if __name__ == "__main__":
    main()
