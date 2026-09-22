"""Runs mlx-lm-lora DPO on multi-turn calls. Its stock DPO dataset only takes a single user prompt,
so this swaps in one that renders the whole conversation with the model's chat template,
exactly as the app sends it.

    uv run dpo_train.py --model fused --data dpo_data --train --train-mode dpo ...
"""

import sys

import mlx_lm_lora.trainer.datasets as datasets


class ChatDPODataset:
    def __init__(self, data, tokenizer, **_):
        self._chosen, self._rejected = [], []
        for row in data:
            history = row["messages"]
            for key, bucket in (("chosen", self._chosen), ("rejected", self._rejected)):
                ids = tokenizer.apply_chat_template(
                    history + [{"role": "assistant", "content": row[key]}],
                    add_generation_prompt=False, enable_thinking=False)
                bucket.append(ids)

    def __getitem__(self, idx):
        return {"chosen": self._chosen[idx], "rejected": self._rejected[idx]}

    def __len__(self):
        return len(self._chosen)

    def process(self, d):
        return d


datasets.DPODataset = ChatDPODataset

if __name__ == "__main__":
    from mlx_lm_lora.train import main
    sys.argv[0] = "mlx_lm_lora.train"
    main()
