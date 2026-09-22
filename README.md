# Assistant

A phone agent that runs on the iPhone itself. Someone calls your Twilio number, your iPhone rings,
you tap Answer, and an on-device Qwen3 model takes a message. Afterwards you get a summary notification.

| Phase | What | Where |
|---|---|---|
| 1 | On-device LLM chat (Qwen3-1.7B, MLX) | `Assistant/LLM`, `Assistant/Chat` |
| 2 | Voice loop: SpeechAnalyzer → Qwen → AVSpeechSynthesizer | `Assistant/Voice`, **Talk** tab |
| 3 | Twilio number → VoIP push → CallKit → Twilio call → agent | `Assistant/Calls`, `twilio/` |
| 4 | Transcript saved, Qwen summary, notification | `Assistant/Messages`, **Messages** tab |
| 5 | Fine-tune with MLX-LM on the Mac, swap in, compare | `finetune/` |

## Run the app
```
xcodegen generate && open Assistant.xcodeproj
```
Run on a real iPhone (MLX needs the GPU, so the simulator won't work). It signs with team GTN3G5W9K2. The first launch downloads about 1 GB of weights.
The **Talk** tab works with no setup. Talk to it like a caller would.

## Hook up the phone number (one time)
Only these steps need your logins. Everything else is scripted.

1. **Twilio account**: put `ACCOUNT_SID` and `AUTH_TOKEN` from console.twilio.com into `twilio/.env`.
2. **VoIP certificate**: in developer.apple.com → Certificates → **+** → *VoIP Services Certificate*,
   pick `com.techadnank9.assistant`, and upload `twilio/certs/voip.csr` (already generated). Download the `.cer`, then:
   ```
   twilio/voip-cert.sh import ~/Downloads/voip_services.cer
   ```
3. **Deploy**: `cd twilio && npm run setup -- --buy` creates the API key and push credential, deploys the Functions,
   buys a US number if the account has none, and points it at the app. It prints a URL and a secret.
4. In the app go to **Settings → Phone number**, paste the URL and secret, then tap **Register for calls**.

Call the number and the iPhone rings. If nobody answers within 25 seconds, the caller gets voicemail.

## Fine-tuning (Phase 5)
```
cd finetune && ./run_all.sh     # dataset → train → before/after report, a few hours on an M4
```
The result is `finetune/models/qwen3-1.7b-assistant-4bit`. Upload it with
`HF_REPO=<you>/qwen3-1.7b-assistant ./train.sh` (after `uv run hf auth login`), then in the app:
Settings → Model → type the repo → Use → Load selected model. The comparison is in `finetune/results/report.md`.

## Notes
- The call prompt lives in both `Assistant/LLM/ModelChoice.swift` and `finetune/common.py`. Keep them in sync.
- iOS blocks GPU work from background apps. When a call is answered from the lock screen, the agent runs Qwen on the CPU,
  which is slower. Open the app during the call to switch it back to the GPU.
- CLI builds need `-skipMacroValidation -skipPackagePluginValidation`.
