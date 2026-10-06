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

The build targets `arm64-apple-macos14.0` and uses an ad-hoc signature. Rebuilding can require granting Accessibility permission again. The app bundle name is `WeChatReplyCopilot.app`.

## First run

1. Open **System Settings → Privacy & Security → Accessibility** and allow **WeChat Reply Copilot**. The app prompts for this permission when needed.
2. Open WeChat and navigate to a direct conversation.
3. Choose **Continue with ChatGPT** and finish sign-in in the browser. The app uses OAuth/OIDC with PKCE and a loopback callback.
4. Choose an account-available model in Settings.
5. Choose **Activate**. The app reads the current visible context into memory. New incoming messages are grouped until roughly two seconds of quiet, then the app requests three suggestions.
6. Review the assessment and candidates. **Copy** puts only the selected candidate on the clipboard; paste and send it yourself if you want.

## What is kept and sent

- Chat context is held in memory, limited to the latest 20 messages, and sent only with the current suggestion request.
- Responses API requests use `stream: true` and `store: false` with the selected account's OAuth access token.
- `store: false` prevents Responses application-state storage; it is not a zero-retention guarantee. OpenAI's current API data controls say abuse-monitoring logs may contain prompts and responses and are generally retained for up to 30 days. See [OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data).
- Access, refresh, and ID tokens are stored in macOS Keychain. The generated host identifier and UI preferences are local app preferences.
- Relationship profile details are stored in local app preferences and are not encrypted separately by the app. Raw chat text and credentials are not written to logs.
- Each incoming burst triggers inference automatically while monitoring is enabled. Deactivating clears the in-memory conversation snapshot and suggestions and cancels pending local work. A request already received by OpenAI cannot be recalled. Closing the sidebar also deactivates monitoring.
- Copying a suggestion leaves it in the system clipboard, where clipboard managers or Universal Clipboard may retain or sync it.
- The model list is fetched from the account's `/v1/models` catalog. There is no API-key or separately billed fallback.

## Architecture

```text
Sources/
├── WeChat/       Accessibility bridge, message model, polling and burst debounce
├── AI/           ChatGPT OAuth, Keychain, model discovery, streaming Responses API, prompt parsing
├── Profile/      Local relationship profile
├── UI/           Suggestion sidebar, copy-only cards, account/profile settings
└── main.swift    App and menu-bar lifecycle
```

The monitor reads the currently selected WeChat window. It does not read WeChat's local database, access chat history outside the visible/retrievable Accessibility tree, or automatically scroll older messages.

## Manual acceptance checklist

- [ ] Launch on Apple Silicon macOS 14+ and grant Accessibility permission.
- [ ] With WeChat open to a direct conversation, verify the contact and latest visible messages appear.
- [ ] Send a few incoming messages quickly; verify one suggestion request starts after the burst settles.
- [ ] Sign in with ChatGPT, select a model shown for that account, and confirm three distinct labeled candidates appear.
- [ ] Copy each candidate and verify the clipboard contains its text.
- [ ] Use Regenerate and a special instruction.
- [ ] Activate and deactivate monitoring; verify deactivation clears the visible session and closing the sidebar stops monitoring.
- [ ] Switch conversations and verify old context and suggestions are cleared.
- [ ] Relaunch and confirm ChatGPT authorization remains connected; test sign-in again after token expiry/revocation.
- [ ] Inspect logs and source behavior: chat text and tokens are not logged, and there is no WeChat input or send path.

## Known limitations

- Accessibility structure varies by WeChat release. If message rows are not exposed, the fallback can read visible text but cannot reliably distinguish your own messages from incoming ones.
- Only the current conversation's visible/retrievable messages are available; historical scrolling is manual.
- OAuth uses the documented local loopback callback. First-time use requires browser sign-in and plan-use authorization.
- ChatGPT plan access/model availability is controlled by the signed-in account and OpenAI service availability.
- Live WeChat and OAuth behavior must be manually checked on the target Mac; a successful compile cannot verify those integrations.
