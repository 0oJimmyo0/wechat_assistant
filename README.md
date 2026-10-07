# WeChat Reply Copilot

A suggestion-only macOS sidebar for the currently open WeChat conversation. It watches the visible chat, waits for an incoming message burst to settle, and asks the signed-in ChatGPT account for exactly three reply ideas. You choose and copy a candidate yourself.

**The app does not type into WeChat, paste into WeChat, or send messages.** Candidate buttons only copy text to the macOS clipboard.

## Requirements

- Apple Silicon Mac with macOS 14 or later
- WeChat for Mac, open to the conversation you want to monitor
- Xcode Command Line Tools (`xcrun`, `swiftc`, `codesign`)
- A ChatGPT account that authorizes ChatGPT plan usage for this app

## Build and install

```bash
bash build.sh
open .build/WeChatReplyCopilot.app
```

To copy the app into `/Applications`:

```bash
bash build.sh --install
open /Applications/WeChatReplyCopilot.app
```

Run the local parser and sender-safety checks with:

```bash
bash test-wechat-parsing.sh
```

The build targets `arm64-apple-macos14.0` and uses an ad-hoc signature unless a stable local signing identity is installed. Ad-hoc builds can require granting Accessibility permission again after each rebuild. The app bundle name is `WeChatReplyCopilot.app`.

### Keep Accessibility approval across rebuilds

For a personal local build, create a self-signed code-signing identity in **Keychain Access → Certificate Assistant → Create a Certificate**. Name it `WeChat Reply Copilot Local Signing`, choose **Self Signed Root** as the identity type and **Code Signing** as the certificate type. Then run `bash build.sh --install`. The build script detects that identity and uses it for subsequent builds, giving macOS a stable app identity. If macOS asks whether `codesign` may access the private signing key, choose **Always Allow** once; choosing **Allow** authorizes only that build and causes the prompt to return. After the first stable-signed install, grant Accessibility to `/Applications/WeChatReplyCopilot.app` once. A self-signed certificate identifies your local builds to your Mac; it does not establish a publicly verified developer identity.

## First run

1. Open **System Settings → Privacy & Security → Accessibility** and allow **WeChat Reply Copilot**. The app prompts for this permission when needed. If the Accessibility tree is collapsed, it requests Screen Recording permission once; enable the app in **System Settings → Privacy & Security → Screen Recording** if macOS asks. Later capture checks only preflight permission and do not repeatedly open prompts.
2. Open WeChat and navigate to a direct conversation.
3. Choose **Continue with ChatGPT** and finish sign-in in the browser. The app uses OAuth/OIDC with PKCE and a loopback callback.
4. Choose account-available Everyday and Careful models in Settings.
5. Choose **Activate** while the intended conversation is open. The app locks monitoring to that conversation and reads visible context into memory. A conversation change stops monitoring and clears the local session. By default, new messages stay local until you choose **Analyze latest message**. You can opt into automatic analysis for clearly identified incoming messages.
6. Review the assessment and candidates. **Copy** puts only the selected candidate on the clipboard; paste and send it yourself if you want.

## What is kept and sent

- The active conversation accumulates up to 100 recognized message blocks in memory. Overlapping screen snapshots are merged; scrolling older rows into view can add them when they overlap the captured timeline. Deactivation or a confirmed conversation change clears the buffer. A manual analysis sends up to the latest 100 captured messages; optional automatic analysis sends at most 50 Accessibility-identified messages.
- Responses API requests use `stream: true` and `store: false` with the selected account's OAuth access token.
- `store: false` prevents Responses application-state storage; it is not a zero-retention guarantee. OpenAI's current API data controls say abuse-monitoring logs may contain prompts and responses and are generally retained for up to 30 days. See [OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data).
- Access, refresh, and ID tokens are stored in macOS Keychain. The generated host identifier and UI preferences are local app preferences.
- Relationship profile details are stored in local app preferences and are not encrypted separately by the app. Raw chat text and credentials are not written to logs.
- Monitoring is locked to the conversation active at activation. A confirmed conversation change stops monitoring and clears the in-memory context and suggestions. Automatic analysis is off by default; when enabled, only Accessibility messages with identified senders can trigger requests. If WeChat's Accessibility tree is collapsed, OCR reads only the visible conversation pane of the WeChat window. A request already received by OpenAI cannot be recalled. Closing the sidebar also deactivates monitoring.
- The model prompt uses speaker labels such as “我”, “对方”, or “说话方不确定”; it does not include the contact's display name. Manual analysis sends up to 100 recent captured messages and the configured local relationship profile.
- Everyday and Careful model choices come from the signed-in account's live model catalog. A usage-limit response stops monitoring and disables automatic analysis until you reactivate.
- Sign out attempts to revoke the refresh token and always removes local credentials. Keychain credentials are available only while the device is unlocked.
- Copying a suggestion leaves it in the system clipboard, where clipboard managers or Universal Clipboard may retain or sync it.
- The model list is fetched from the account's `/v1/models` catalog. If the account reports `subscription_sharing_usage_limit_exceeded`, monitoring stops and the app points you to ChatGPT Settings → Usage. There is no API-key or separately billed fallback.

## Architecture

```text
Sources/
├── WeChat/       Accessibility bridge, message model, polling and burst debounce
├── AI/           ChatGPT OAuth, Keychain, model discovery, streaming Responses API, prompt parsing
├── Profile/      Local relationship profile
├── UI/           Suggestion sidebar, copy-only cards, account/profile settings
└── main.swift    App and menu-bar lifecycle
```

The monitor reads the currently selected WeChat window's recognized message list. If WeChat exposes a collapsed Accessibility tree, a bounded one-time capability probe selects the Vision backend for that WeChat PID; subsequent title and message polls skip recursive semantic AX searches and use local OCR on the selected WeChat window. The backend is reset when WeChat quits/restarts or from Developer Settings. Vision fallback separates accurate header-only identity checks from message-only OCR. Activation accepts two strong, spatially consistent title captures quickly and takes a third only when the first pair is uncertain; after confirmation, the current contact appears while the first accurate message read runs. Identification has a five-second deadline and reports its current stage. Routine title validation stays lightweight for cross-chat checks, while message polling uses fast OCR. ScreenCaptureKit reuses the selected WeChat window between captures and refreshes discovery when that target becomes stale or capture fails. Capture/OCR work runs outside the cache lock and is single-flight to avoid duplicate captures. Developer Settings provides local sliders for the conversation pane, header, and composer boundaries; its Vision report includes backend and activation timing without recognized text or contact names. OCR is limited to the calibrated conversation pane and message canvas; obvious OCR artifacts and unanchored text are filtered, clear left/right alignment may be labeled Target/Self, ambiguous rows stay unknown, and OCR never triggers automatic analysis. The monitor accumulates up to 100 recognized message blocks in memory by merging overlapping snapshots; the user can scroll to older messages to add context when the visible rows overlap the captured timeline. It does not read WeChat's local database or automatically scroll older messages. Captured images and OCR text are not saved automatically; text stays local until the user chooses Analyze, which sends up to 100 recent captured messages.

For target-Mac diagnostics, **Inspect WeChat AX** saves structural metadata only. **Inspect Vision Capture** reports window/crop geometry and observation counts; it omits recognized text, contact names, and messages. In **Settings → Developer diagnostics**, adjust the normalized conversation-left, header-bottom, and composer-top ratios, then use **Save Annotated Vision Preview** to inspect the blue pane boundary, yellow header, green message canvas, orange excluded composer, accepted red title, rejected purple title candidates, accepted green message blocks, and rejected gray observations. The preview is saved only after you explicitly choose a destination; it contains visible WeChat content, so handle and remove it as sensitive data after debugging.

## Manual acceptance checklist

- [ ] Launch on Apple Silicon macOS 14+ and grant Accessibility permission; if prompted for Screen Recording due to a collapsed WeChat tree, grant it for visible-window OCR.
- [ ] With WeChat open to a direct conversation, verify the contact and latest visible messages appear.
- [ ] Activate in one conversation, switch to another, and verify monitoring stops and the local session clears.
- [ ] Verify manual mode does not make requests until Analyze is clicked; opt into automatic analysis and verify only identified incoming messages trigger it.
- [ ] Sign in with ChatGPT, select a model shown for that account, and confirm three distinct labeled candidates appear.
- [ ] Copy each candidate and verify the clipboard contains its text.
- [ ] Use Analyze, Regenerate carefully, and a special instruction.
- [ ] Activate and deactivate monitoring; verify deactivation clears the visible session and closing the sidebar stops monitoring.
- [ ] Confirm OCR fallback is limited to the WeChat conversation pane, remains manual-only, and sends no text until Analyze is clicked.
- [ ] Save an **Inspect WeChat AX** report and verify only structural metadata is included.
- [ ] On collapsed-tree WeChat builds, save an **Inspect Vision Capture** report and confirm it contains counts/geometry only; save an annotated preview only when explicitly needed and treat the image as sensitive.
- [ ] Adjust the Vision layout sliders so the conversation list is outside the pane crop and the composer is below the message canvas; verify with the annotated preview.
- [ ] Relaunch and confirm ChatGPT authorization remains connected; test sign-in again after token expiry/revocation.
- [ ] Inspect logs and source behavior: chat text and tokens are not logged, and there is no WeChat input or send path.

## Known limitations

- Accessibility structure varies by WeChat release. OCR fallback depends on Screen Recording permission and visible-window text recognition. OCR sender hints use conservative bubble alignment; uncertain rows remain unknown and all OCR rows are manual-only.
- Only visible/retrievable messages are available; the app does not read WeChat's database or scroll automatically. Manually scrolling to older messages can add context where snapshots overlap the captured timeline.
- OAuth uses the documented local loopback callback. First-time use requires browser sign-in and plan-use authorization.
- ChatGPT plan access/model availability is controlled by the signed-in account and OpenAI service availability.
- Live WeChat and OAuth behavior must be manually checked on the target Mac; a successful compile cannot verify those integrations.
