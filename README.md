# Assistant

A phone agent that runs on the iPhone itself. Someone calls your Twilio number, your iPhone rings,
you tap Answer, and an on-device Qwen3 model takes a message. Afterwards you get a summary notification.

| Phase | What | Where |
|---|---|---|
| 1 | On-device LLM chat (Qwen3-1.7B, MLX) | `Assistant/LLM`, `Assistant/Chat` |
| 2 | Voice loop: SpeechAnalyzer → Qwen → AVSpeechSynthesizer, with a live voice orb | `Assistant/Voice`, **Assistant** tab (home) |
| 3 | Twilio number → VoIP push → CallKit → Twilio call → agent | `Assistant/Calls`, `twilio/` |
| 4 | Transcript saved, Qwen summary, notification | `Assistant/Messages`, **Messages** tab |
| 5 | Fine-tune with MLX-LM on the Mac, swap in, compare | `finetune/` |

## Run the app
```
xcodegen generate && open Assistant.xcodeproj
```
Run on a real iPhone for the real model and speech. The first launch downloads about 1 GB of weights, once.
The home screen is the voice orb: tap it and talk like a caller would. No setup needed.
The simulator runs the whole app with a scripted model and a scripted caller, because MLX and speech models can't run there.

Signing: team S2UTA2J3GD, bundle ID `ai.assistantagent.call` (App Store Connect "Phone Assistant", for TestFlight).
Having trouble on a device? **Settings → Logs** shows every step, with a share button.

**Your profile:** the assistant can tell recruiters and collaborators what you do, and nothing personal. The text comes
from `Assistant/Resources/OwnerProfile.txt` and is editable in Settings. That file is gitignored.

## Hook up the phone number (one time)
Only these steps need your logins. Everything else is scripted.

1. **Twilio account**: put `ACCOUNT_SID` and `AUTH_TOKEN` from console.twilio.com into `twilio/.env`.
2. **VoIP certificate**: in developer.apple.com → Certificates → **+** → *VoIP Services Certificate*,
   pick `ai.assistantagent.call`, and upload `twilio/certs/voip.csr` (already generated). Download the `.cer`, then:
   ```
   twilio/voip-cert.sh import ~/Downloads/voip_services.cer
   ```
3. **Deploy**: `cd twilio && npm run setup -- --buy` creates the API key and push credential, deploys the Functions,
   buys a US number if the account has none, and points it at the app. It prints a URL and a secret.
4. In the app go to **Settings → Phone number**, paste the URL and secret, then tap **Register for calls**.

Call the number and the iPhone rings. If nobody answers within 25 seconds, the caller gets voicemail.

## Fine-tuning (Phase 5)
Training runs on the Mac with MLX-LM. Qwen3-8B plays caller and ideal assistant, and Qwen3-1.7B learns from it with LoRA.
The training data is practice calls (including recruiter and collaborator calls based on the owner profile) plus a 10% slice of real
spoken phone-assistant dialogs from [Google Taskmaster-1](https://github.com/google-research-datasets/Taskmaster) (CC BY 4.0).
```
cd finetune && ./run_all.sh     # real data → practice calls → train → before/after report, a few hours on an M4
```
The result is `finetune/models/qwen3-1.7b-assistant-4bit`, and the comparison is in `finetune/results/report.md`. A tuned
model only ships if it beats the base model. Then it goes to Hugging Face and becomes the default in `ModelOption`.

| Round | Data | Score (/10) vs base | Shipped |
|---|---|---|---|
| 2 | 317 practice calls + 320 Taskmaster | 9.06 vs 9.19, wordier, ended 81% of calls | no |
| 3 | more practice calls, Taskmaster capped at 10% | running | — |

## Notes
- The call prompt lives in both `Assistant/LLM/ModelChoice.swift` and `finetune/common.py`. Keep them in sync.
- iOS blocks GPU work from background apps. When a call is answered from the lock screen, the agent runs Qwen on the CPU,
  which is slower. Open the app during the call to switch it back to the GPU.
- CLI builds need `-skipMacroValidation -skipPackagePluginValidation`. More build and architecture notes are in CLAUDE.md.
