# Pickup

A phone agent that runs on the iPhone itself: Qwen3 on device (MLX), answering calls to a Twilio number.

## Phases
1. **On-device LLM chat** ✅ Qwen3-1.7B-4bit via mlx-swift-lm, streaming chat screen
2. Voice loop (speech-to-text → Qwen → text-to-speech)
3. Twilio number + Voice SDK + PushKit/CallKit
4. After the call: transcript, summary, notification
5. Fine-tune with MLX-LM on the Mac, swap the model in, compare before and after

## Run
```
xcodegen generate
open Pickup.xcodeproj
```
Choose your team under Signing & Capabilities, then run on a **real iPhone**. MLX needs the device GPU, so the simulator won't work.
The first launch downloads about 1 GB of weights from Hugging Face; later launches load them from the cache.

To change the model, edit `Pickup/LLM/ModelChoice.swift`.
