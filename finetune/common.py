"""Shared pieces: the agent's prompt (kept identical to the app), model helpers, and simulated calls."""

import re

from mlx_lm import generate, load
from mlx_lm.sample_utils import make_sampler

OWNER = "Adnan"
END = "[END]"
BASE_MODEL = "mlx-community/Qwen3-1.7B-4bit"
TEACHER_MODEL = "mlx-community/Qwen3-8B-4bit"


def greeting(owner: str = OWNER) -> str:
    """Same as Prompts.greeting in Assistant/LLM/ModelChoice.swift."""
    return (f"Hi, you've reached {owner}'s phone. {owner} can't pick up right now, "
            "this is their assistant. Can I take a message?")


def agent_prompt(owner: str = OWNER, caller_number: str | None = None) -> str:
    """Same as Prompts.call in Assistant/LLM/ModelChoice.swift. Keep the two in sync."""
    caller = f"The caller's number is {caller_number}." if caller_number else "The caller's number is unknown."
    return (
        f"You are {owner}'s phone assistant, answering a live phone call because {owner} can't pick up. "
        f"{caller} Your job is to take a message: find out who is calling, why, and the best way to reach them back. \n\n"
        "Rules:\n"
        "- You are speaking out loud. Reply in one or two short, warm sentences. Never use lists, emoji or markdown.\n"
        "- Ask for one missing thing at a time: name, then reason, then callback number or time if they haven't said it.\n"
        f"- Never promise what {owner} will do. Say you'll pass the message on.\n"
        f"- Don't give out personal information about {owner}.\n"
        "- The caller's words come from speech recognition and may have small errors; don't point them out.\n"
        "- When you have the message, or the caller says goodbye, read back the key details in one sentence, "
        f"say goodbye, and end your reply with {END}."
    )


# The teacher gets the same rules plus what "great" looks like, so the student learns the behaviour
# without needing the long guidance at runtime.
TEACHER_STYLE = """

How an excellent assistant sounds:
- Natural and human, like a sharp receptionist. Contractions, no filler, no "Certainly!" or "I understand".
- Never more than 25 words in a reply. Usually 8 to 15.
- Use the caller's name once you know it, but not in every reply.
- If the caller already gave several details at once, don't ask for them again; ask only for what's missing.
- If the number they're calling from is known and they say to call back on it, confirm it rather than asking.
- If it sounds urgent (health, safety, a deadline today), acknowledge it briefly and make sure you have a callback.
- Spam, sales or robocalls: be polite, don't take details, say goodbye and end.
- If they ask for personal info about the owner (address, schedule, other numbers), decline kindly and move on.
- Read-back at the end is one sentence with name, reason and callback. Then "Bye!" or similar, then [END]."""


class Model:
    def __init__(self, path: str):
        self.path = path
        self.model, self.tokenizer = load(path)

    def chat(self, messages: list[dict], max_tokens: int = 160, temp: float = 0.7) -> str:
        prompt = self.tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, tokenize=False, enable_thinking=False)
        text = generate(self.model, self.tokenizer, prompt=prompt, max_tokens=max_tokens,
                        sampler=make_sampler(temp=temp, top_p=0.8))
        return clean(text)


def clean(text: str) -> str:
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.S)
    return text.replace("<|im_end|>", "").strip()


def caller_prompt(scenario: dict) -> str:
    return (
        "You are role-playing a person on a phone call. You called someone and their AI assistant answered. "
        f"Who you are and why you're calling: {scenario['persona']}\n"
        f"How you talk: {scenario.get('style', 'naturally, like a real person on the phone')}.\n"
        "Speak only your own lines, one or two sentences, as plain spoken words (no stage directions, no quotes). "
        "Don't volunteer everything at once unless your style says so. Answer what you're asked. "
        "When the assistant reads back your message and says goodbye, say a short goodbye."
    )


def simulate(agent: Model, caller: Model, scenario: dict, agent_system: str, max_turns: int = 8) -> list[dict]:
    """Plays one call. Returns the agent's view of the conversation as chat messages."""
    hello = greeting()
    agent_view = [{"role": "system", "content": agent_system}, {"role": "assistant", "content": hello}]
    caller_view = [{"role": "system", "content": caller_prompt(scenario)}, {"role": "user", "content": hello}]

    for _ in range(max_turns):
        said = caller.chat(caller_view, max_tokens=80, temp=0.9)
        caller_view.append({"role": "assistant", "content": said})
        agent_view.append({"role": "user", "content": said})

        reply = agent.chat(agent_view)
        agent_view.append({"role": "assistant", "content": reply})
        caller_view.append({"role": "user", "content": reply.replace(END, "").strip()})
        if END in reply:
            break
    return agent_view
