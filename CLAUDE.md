# Assistant: notes for Claude

An iPhone phone agent. An on-device Qwen3 model (MLX) answers calls to a Twilio number and takes a message.
README.md covers what it is and how to run it. This file is how to work on it.

## Build
- The project is generated: edit `project.yml`, then run `xcodegen generate`. `Assistant.xcodeproj` is gitignored.
  New Swift files are only picked up after a regenerate.
- CLI builds always need `-skipMacroValidation -skipPackagePluginValidation` (MLXHuggingFace macros, mlx-swift plugin).
  Device: `-destination 'generic/platform=iOS' -derivedDataPath build`.
  Simulator: `-destination 'id=<udid>' -derivedDataPath build/sim CODE_SIGNING_ALLOWED=NO`.
- If SwiftPM stalls on the Twilio binary, curl the xcframework zips from the twilio-voice-ios release and drop them into
  `~/Library/Caches/org.swift.swiftpm/artifacts` (`-` and `.` in the URL become `_`).
- Signing: `project.yml` targets team S2UTA2J3GD (Nysa Chandna), bundle ID `ai.assistantagent.call`. That matches the
  App Store Connect record "Phone Assistant" (app ID 6814699215) used for TestFlight. Xcode on this Mac has no account
  for that team. For ad-hoc installs, override with `DEVELOPMENT_TEAM=GTN3G5W9K2 PRODUCT_BUNDLE_IDENTIFIER=com.techadnank9.assistant`.

## Simulator vs device
- MLX aborts in the simulator (its Metal device init fails, even on CPU), and the simulator has no speech models or
  usable mic. So `#if targetEnvironment(simulator)` builds use scripted model replies (`LLMEngine`) and a scripted
  caller (`ScriptedCaller`). The UI, voice loop, TTS, saving, summary and notification are all real in the simulator.
- The real model and real speech only run on a device. Debug on device with **Settings → Logs** (share button),
  or `log stream --predicate 'subsystem == "ai.assistantagent.call"'`.

## Architecture
- `LLM/LLMEngine` is one actor owning the model and every conversation (chat, calls, summaries). It uses the CPU when
  the app is backgrounded, because iOS blocks background GPU work.
- `Voice/VoiceAgent` is the loop: greet → listen (`Listener`, SpeechAnalyzer) → stream Qwen → speak sentence by
  sentence (`Speaker`). It ends when the reply contains `[END]`. It runs over any `AudioIO`: `LocalAudio` (mic,
  speaker), `CallAudioDevice` (Twilio call), `ScriptedCaller` (simulator).
- `Listener` must `AssetInventory.reserve(locale:)` before checking or downloading speech assets. It falls back from
  SpeechTranscriber to DictationTranscriber.
- `Voice/VoiceOrb` + `LiveCallView` (in TalkView.swift) is the home screen and the call screen. `VoiceAgent.Mode`:
  `.owner` (My assistant: `Prompts.voiceChat`, no time limit, nothing saved) or `.caller` (message taking).
- `Setup/SetupModel` gates the app: mic permission, speech assets (`Listener.setUp`), model download. The orb
  only appears once they're ready; `RootView` checks on every launch.
- `MessageStore.briefing()` (date + latest messages) is appended to the Chat and My assistant prompts.
- `NaturalVoice` (Kokoro) is the neural voice: one shared 327 MB engine plus a 0.5 MB file per voice. Settings
  downloads each voice on its own (⬇ on its row); `startDownloadIfNeeded()` at launch starts the selected one,
  because the setup screen is skipped once mic, speech and model are ready. Falls back to Apple's voice until ready.
- `ModelOption.tunedShipped` switches new installs to the fine-tuned model on Hugging Face.
- `Calls/CallManager` handles PushKit → CallKit → Twilio. `CallAudioDevice` bridges call audio through AVAudioEngine
  source nodes.
- `Messages/MessageStore` saves each call (SwiftData), summarizes it with Qwen and posts a notification.

## Keep in sync
- The call prompt exists in both `Assistant/LLM/ModelChoice.swift` (`Prompts.call`) and `finetune/common.py`
  (`agent_prompt`). Change both together.
- The owner profile comes from `Assistant/Resources/OwnerProfile.txt` and `finetune/owner_profile.txt`. Both are
  gitignored because the repo is public. Never commit them.

## Fine-tuning (finetune/)
- The teacher is Qwen3-8B-4bit, the student is Qwen3-1.7B with LoRA, and training runs on this Mac (M4, 16 GB). Real data
  is Google Taskmaster-1 (CC BY 4.0), in `external/` and gitignored.
- `train.sh` keeps the checkpoint with the lowest validation loss. `evaluate.py` compares base against tuned with Qwen3-8B
  as judge.
- Round 2 lost to the base model (9.06 vs 9.19, wordier, ended only 81% of calls), so it was not shipped.
- Round 4 (`run_round4a.sh` then `run_round4b.sh`): `personas.py` invents ~150 callers, the teacher generates calls,
  SFT, then DPO (`make_dpo.py` + `dpo_train.py`, mlx-lm-lora with a multi-turn dataset patch) against the
  student's worst replies by `reply_score`, then `evaluate.py` (base vs sft vs dpo on held-out personas) and
  `ship.py`, which uploads to `adnank9/qwen3-1.7b-phone-assistant-4bit` only if it beats base. Then flip
  `ModelOption.tunedShipped`.
- Set `HF_HUB_DISABLE_XET=1`: the Xet CDN drops downloads on this network. Tailscale DNS (100.100.100.100) blips
  occasionally.

## Don't
- Don't commit `twilio/.env`, `twilio/certs/`, model weights or the owner profile.
- Don't place Twilio number purchases (`npm run setup -- --buy`) without the owner's OK.
