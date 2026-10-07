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

For a personal local build, create a self-signed code-signing identity in **Keychain Access → Certificate Assistant → Create a Certificate**. Name it `WeChat Reply Copilot Local Signing`, choose **Self Signed Root** as the identity type and **Code Signing** as the certificate type. Then run `bash build.sh --install`. The build script detects that identity and uses it for subsequent builds, giving macOS a stable app identity. After the first stable-signed install, grant Accessibility to `/Applications/WeChatReplyCopilot.app` once. A self-signed certificate identifies your local builds to your Mac; it does not establish a publicly verified developer identity.

## First run

1. Open **System Settings → Privacy & Security → Accessibility** and allow **WeChat Reply Copilot**. The app prompts for this permission when needed.
2. Open WeChat and navigate to a direct conversation.
3. Choose **Continue with ChatGPT** and finish sign-in in the browser. The app uses OAuth/OIDC with PKCE and a loopback callback.
4. Choose account-available Everyday and Careful models in Settings.
5. Choose **Activate** while the intended conversation is open. The app locks monitoring to that conversation and reads visible context into memory. A conversation change stops monitoring and clears the local session. By default, new messages stay local until you choose **Analyze latest message**. You can opt into automatic analysis for clearly identified incoming messages.
6. Review the assessment and candidates. **Copy** puts only the selected candidate on the clipboard; paste and send it yourself if you want.

## What is kept and sent

- Chat context is held in memory, limited to the latest 20 messages, and sent only with the current suggestion request.
- Responses API requests use `stream: true` and `store: false` with the selected account's OAuth access token.
- `store: false` prevents Responses application-state storage; it is not a zero-retention guarantee. OpenAI's current API data controls say abuse-monitoring logs may contain prompts and responses and are generally retained for up to 30 days. See [OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data).
- Access, refresh, and ID tokens are stored in macOS Keychain. The generated host identifier and UI preferences are local app preferences.
- Relationship profile details are stored in local app preferences and are not encrypted separately by the app. Raw chat text and credentials are not written to logs.
- Monitoring is locked to the conversation active at activation. Switching conversations stops monitoring, clears the in-memory snapshot and suggestions, and requires activation again. Automatic analysis is off by default; when enabled, only bursts with identified senders can trigger requests. Text outside a recognized WeChat message list is ignored, including contact details and notes; if WeChat does not expose its message list, analysis remains unavailable. A request already received by OpenAI cannot be recalled. Closing the sidebar also deactivates monitoring.
- The model prompt uses speaker labels such as “我”, “对方”, or “说话方不确定”; it does not include the contact's display name. Analysis still sends up to 20 visible messages and the configured local relationship profile.
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

The monitor reads the currently selected WeChat window's recognized message list. If WeChat exposes a collapsed Accessibility tree, it can request Screen Recording access and OCR only that visible WeChat window locally. OCR is limited to the conversation header and right-hand message pane; OCR rows have unknown senders and cannot trigger automatic analysis. It does not read WeChat's local database, access chat history outside the visible window, or automatically scroll older messages. Captured images and OCR text are not saved; text stays local until the user chooses Analyze.

For target-Mac Accessibility troubleshooting, open **Settings → Developer diagnostics → Inspect WeChat AX**. The report is saved only after you choose a location and contains structural roles, sanitized identifiers, frames, and row counts; it omits message text, contact names, profile notes, and credentials.

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
- [ ] Relaunch and confirm ChatGPT authorization remains connected; test sign-in again after token expiry/revocation.
- [ ] Inspect logs and source behavior: chat text and tokens are not logged, and there is no WeChat input or send path.

## Known limitations

- Accessibility structure varies by WeChat release. OCR fallback depends on Screen Recording permission and visible-window text recognition. OCR rows remain sender-unknown and are never sent automatically.
- Only the current conversation's visible/retrievable messages are available; historical scrolling is manual.
- OAuth uses the documented local loopback callback. First-time use requires browser sign-in and plan-use authorization.
- ChatGPT plan access/model availability is controlled by the signed-in account and OpenAI service availability.
- Live WeChat and OAuth behavior must be manually checked on the target Mac; a successful compile cannot verify those integrations.
