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

Run the local parsing, sender-safety, and in-memory merge checks with:

```bash
bash test-wechat-parsing.sh
```

The build targets `arm64-apple-macos14.0` and uses an ad-hoc signature unless a stable local signing identity is installed. Ad-hoc builds can require granting Accessibility permission again after each rebuild. The app bundle name is `WeChatReplyCopilot.app`.

### Keep Accessibility approval across rebuilds

For a personal local build, create a self-signed code-signing identity in **Keychain Access → Certificate Assistant → Create a Certificate**. Name it `WeChat Reply Copilot Local Signing`, choose **Self Signed Root** as the identity type and **Code Signing** as the certificate type. Then run `bash build.sh --install`. The build script detects that identity and uses it for subsequent builds, giving macOS a stable app identity. If macOS asks whether `codesign` may access the private signing key, choose **Always Allow** once; choosing **Allow** authorizes only that build and causes the prompt to return. After the first stable-signed install, grant Accessibility to `/Applications/WeChatReplyCopilot.app` once. A self-signed certificate identifies your local builds to your Mac; it does not establish a publicly verified developer identity.

## First run

1. Open **System Settings → Privacy & Security → Accessibility** and allow **WeChat Reply Copilot**. The app prompts for this permission when needed. If WeChat's Accessibility tree does not expose messages, the Vision fallback needs Screen Recording permission; enable the app in **System Settings → Privacy & Security → Screen Recording**.
2. Open WeChat and navigate to a direct conversation.
3. Choose **Continue with ChatGPT** and finish sign-in in the browser. The app uses OAuth/OIDC with PKCE and a loopback callback.
4. Choose account-available Everyday and Careful models in Settings.
5. Choose **Activate** while the intended conversation is open. The app locks monitoring to that conversation and reads visible context into memory. A conversation change stops monitoring and clears the local session. By default, new messages stay local until you choose **Analyze latest message**. You can opt into automatic analysis for clearly identified incoming messages.
6. Review the assessment and candidates. **Copy** puts only the selected candidate on the clipboard; paste and send it yourself if you want.

## What is kept and sent

- Conversation context exists in memory only while monitoring the active chat. The store retains up to 200 observed messages and clears on deactivation or a confirmed conversation change. It does not write raw chat content to disk. The sidebar shows 5 messages initially and can expand to the latest 20; each model request receives at most those 20 messages, the local relationship profile, and any special instruction. **Refresh** reads the current viewport without scrolling or triggering automatic analysis. **Follow latest** returns to the bottom when needed. Both preserve the validated conversation history.
- Responses API requests use `stream: true` and `store: false` with the selected account's OAuth access token.
- `store: false` prevents Responses application-state storage; it is not a zero-retention guarantee. OpenAI's current API data controls say abuse-monitoring logs may contain prompts and responses and are generally retained for up to 30 days. See [OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data).
- Access, refresh, and ID tokens are stored in macOS Keychain. The generated host identifier and UI preferences are local app preferences.
- Relationship profile details are stored in local app preferences and are not encrypted separately by the app. Raw chat text and credentials are not written to logs.
- Monitoring is locked to the conversation active at activation. A confirmed conversation change stops monitoring and clears the in-memory context and suggestions. Automatic analysis is off by default; when enabled, only Accessibility messages with identified senders, a unique ordered overlap, and confirmed bottom-scrollbar evidence can trigger requests. Missing arrival evidence requires manual analysis. If WeChat's Accessibility tree is collapsed, the active monitor cannot read the chat. A request already received by OpenAI cannot be recalled. Closing the sidebar also deactivates monitoring.
- The model prompt uses speaker labels such as “我”, “对方”, or “说话方不确定”; it does not include the contact's display name. Analysis sends at most 20 recent captured messages and the configured local relationship profile.
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

The monitor captures one unified snapshot using independent identity and message sources. When both the chat identity and message list are available through Accessibility, it reads them from the same WeChat window/list. If AX exposes only one, it combines that half with local Vision capture; if neither is exposed, it uses the existing Vision title and message readers. Vision reads the visible WeChat window locally and needs Screen Recording permission. The in-memory `ConversationStore` owns the accumulated timeline. Snapshots merge by ordered overlap, so virtualization and temporary empty reads do not erase observed rows, and repeated identical messages remain separate entries. Snapshots that overlap the known tail can append live rows; historical rows can only backfill earlier context and never trigger incoming-message analysis. The active monitor watches WeChat with `AXObserver` where notifications are supported and retains a 3-second polling watchdog. **Refresh** captures the current viewport without scrolling or triggering analysis; **Follow latest** scrolls toward the bottom, waits for rows to materialize, and merges; **Load older to 20** performs at most six upward scroll/capture attempts and returns to the latest viewport when it can verify it. Analysis receives at most the latest 20 messages. Vision capture remains local; model requests occur only under the app's manual or automatic analysis settings. If no source can identify the chat or read messages, activation or sync reports that limitation and keeps previously stored context. Developer diagnostics list the identity/message source and the permission state.

For target-Mac diagnostics, **Inspect WeChat AX** saves structural metadata only. **Inspect Vision Capture** reports window/crop geometry and observation counts; it omits recognized text, contact names, and messages. In **Settings → Developer diagnostics**, adjust the normalized conversation-left, header-bottom, and composer-top ratios, then use **Save Annotated Vision Preview** to inspect the blue pane boundary, yellow header, green message canvas, orange excluded composer, accepted red title, rejected purple title candidates, accepted green message blocks, and rejected gray observations. The preview is saved only after you explicitly choose a destination; it contains visible WeChat content, so handle and remove it as sensitive data after debugging.

## Manual acceptance checklist

- [ ] Launch on Apple Silicon macOS 14+ and grant Accessibility permission; grant Screen Recording if WeChat requires the Vision fallback.
- [ ] With WeChat open to a direct conversation, verify the contact and latest visible messages appear.
- [ ] Activate in one conversation, switch to another, and verify monitoring stops and the local session clears.
- [ ] Verify manual mode does not make requests until Analyze is clicked; opt into automatic analysis and verify only identified incoming messages trigger it.
- [ ] Sign in with ChatGPT, select a model shown for that account, and confirm three distinct labeled candidates appear.
- [ ] Copy each candidate and verify the clipboard contains its text.
- [ ] Use Analyze, Regenerate carefully, and a special instruction.
- [ ] Activate and deactivate monitoring; verify deactivation clears the visible session and closing the sidebar stops monitoring.
- [ ] Confirm AX-capable chats use Accessibility and a collapsed AX message tree falls back to local Vision capture.
- [ ] Save an **Inspect WeChat AX** report and verify only structural metadata is included.
- [ ] Save an **Inspect Vision Capture** report and confirm it contains counts/geometry only; save an annotated preview only when explicitly needed and treat the image as sensitive.
- [ ] With WeChat open, check that incoming messages and manual scrolling update within about 1–2 seconds; verify historical rows never trigger analysis and returning to the bottom resumes live tracking.
- [ ] Load older to 20 and confirm the app either restores the latest viewport or explicitly reports that live tracking remains paused.
- [ ] Click **Refresh** after a new message or while viewing older rows; confirm it reconciles visible text without automatically requesting analysis.
- [ ] Adjust the Vision layout sliders so the conversation list is outside the pane crop and the composer is below the message canvas; verify with the annotated preview.
- [ ] Relaunch and confirm ChatGPT authorization remains connected; test sign-in again after token expiry/revocation.
- [ ] Inspect logs and source behavior: chat text and tokens are not logged, and there is no WeChat input or send path.

## Local conversation timeline (development branch)

- The sidebar has an **independently scrollable chat transcript**. Scrolling in this pane never scrolls or changes WeChat, so real-time monitoring can continue while the user reads older locally captured messages.
- **Jump to latest** navigates to the newest *local* message. If verified new messages arrive while the user reads older rows, the button shows a pending count without pulling the viewport away. **WeChat: follow latest** is a separate control that moves WeChat's own window when monitoring has switched into a historical viewport.
- **Load 20 earlier** calls the existing controlled WeChat scroll-and-capture workflow. It restores WeChat to its latest viewport after loading and merges older messages into session-only history. The history is capped at 200 message occurrences; more history requires a subsequent load and can stop on ambiguous overlap or unavailable content.
- Message display order follows the verified conversation sequence, not an assumed timestamp. The UI shows *literal* time/date separators only when recovered from recognized Accessibility message-list rows or high-confidence centered OCR within validated transcript geometry. Not every message exposes a send time; the `firstSeenAt` field records observation time and is never presented as a sent timestamp.
- This feature does not persist chat text or inferred time metadata to disk. Deactivation/chat changes clear the in-memory history and existing privacy controls still gate analysis.
- Before merging, verify AX and Vision timestamp-label placement on the user's installed WeChat version, scrolling/bottom anchoring, repeated-message identity, incoming badges, and that backfill never triggers automatic analysis. A passing macOS compile cannot validate live WeChat behavior.

### macOS CI versus screenshot OCR validation

The new CI workflow compiles the app and runs deterministic parsing, history,
and Vision bubble-reconstruction tests. The synthetic pixel-to-text Vision
integration fixture remains enabled for normal local runs of
`bash test-wechat-vision.sh`. On hosted macOS CI only, the fixture is
explicitly deferred: the unchanged base branch and feature branch both miss
the same mixed-language multiline bubble on the hosted runner.
**Run the unskipped test on your target Mac** and verify real WeChat content
before merging this draft PR.

## Known limitations

- Accessibility structure varies by WeChat release. When AX lacks the identity or message list, local Vision capture fills the missing source and requires Screen Recording permission. If neither source can identify the chat or read messages, live capture cannot proceed.
- Only visible/retrievable messages are available; the app does not read WeChat's database. Incoming messages may not appear in a historical viewport until **Follow latest** returns to the bottom. Ordered overlap can be uncertain when WeChat exposes too few shared rows; the app keeps the existing context and waits for an anchored snapshot.
- The reader identifies conversations by the confirmed display title. Two distinct chats with the same normalized title may not be distinguishable; monitoring stops when a title change is confirmed.
- OAuth uses the documented local loopback callback. First-time use requires browser sign-in and plan-use authorization.
- ChatGPT plan access/model availability is controlled by the signed-in account and OpenAI service availability.
- Live WeChat and OAuth behavior must be manually checked on the target Mac; a successful compile cannot verify those integrations.

## AX extraction validation

The AX message source requires `chat_message_list` and reads only confirmed
`chat_bubble_item_view` rows. Direct `AXTitle`/`AXValue` reads are batched;
missing row text falls back to text descendants inside that bubble, with
metadata/control identifiers and timestamp labels excluded. A known list with
unreadable bubble text reports its exact failure stage instead of treating an
unrelated list as the transcript. Existing local Vision support remains; no new
OCR source or database access was added.

Message-list elements are cached for the current window/PID, checked before
reuse, and rediscovered with bounded probes after invalidation. Row reading
prefers `AXVisibleChildren`, reads at most 200 rows, and caps traversal at 500
nodes, four descendant levels, and a 700 ms budget plus the final AX IPC call.
Discovery and diagnostic walks have independent limits. The sidebar reports
last capture duration and rolling P50/P95 for validated captures only; failed
captures do not count as evidence of fast extraction. Metrics retain at most
200 samples and include no message text.

Content-free command-line probes are available in the built app:

```bash
.build/WeChatReplyCopilot.app/Contents/MacOS/WeChatReplyCopilot --ax-diagnostic
.build/WeChatReplyCopilot.app/Contents/MacOS/WeChatReplyCopilot --capture-benchmark
```

The diagnostic reports bounded hierarchy, sanitized identifiers, roles, sampled
row counts, and supported text attribute names without printing their values.
The benchmark performs ten read-only capture attempts, reports extracted counts
and trust status, and makes no model requests or scroll actions. It can use the
existing local Vision source when AX cannot supply a source. An open WeChat
conversation and the app's macOS permissions are required. See
[LIVE_VALIDATION.md](LIVE_VALIDATION.md) for the outstanding WeChat 4.x merge gate.


### Transcript geometry and OCR reliability

On older WeChat builds, the existing Vision fallback uses the measured AX
transcript scroll area and aligned composer to establish its crop. A guessed
calibration or visual divider alone stays unverified. Discovery uses bounded
breadth-first walks that skip off-screen virtual sidebar rows. Verified elements
are remeasured before reuse; unchanged exact header/transcript pixel fingerprints
allow OCR results to be reused.

Chinese, mixed-language, or suspicious fast observations retry accurate OCR with
automatic language detection. Text lines require a confirmed visible bubble
background; neighboring messages never merge solely by proximity. Low-confidence
rows exclude their whole bubble. Unverified captures and ambiguous overlap keep
the previous trusted history. Vision messages cannot trigger automatic analysis.
The sidebar shows source, geometry, OCR mode, duration, raw/candidate/accepted
counts, and rejection reasons after every attempt.

Run the synthetic screenshot regression suite with:

```bash
bash test-wechat-vision.sh
```

Fixtures contain public test text only. Private screenshots are never committed.
See [LIVE_VALIDATION.md](LIVE_VALIDATION.md) for measured results and outstanding
interactive tests, including the unresolved visual-only geometry fallback.

### Transcript refinements

The local timeline and assistant suggestions occupy independently scrollable,
resizable split panes. The timeline renders all retained validated messages in
chronological order (up to 200). Loading 20 earlier preserves the visible local
row and offset; Jump to latest changes only Copilot's scroll position. Confirmed
incoming occurrences increment the local unread badge while browsing history.
“WeChat: follow latest” separately controls the WeChat viewport. Missing live-tail
evidence is shown as Monitoring uncertain and cannot authorize automatic analysis.

Observed time separators retain their literal label and capture evidence beside
the following occurrence. Individual send times remain unknown. Ambiguous
historical overlap cannot attach a label to a guessed repeated message.

Manual analysis previews the latest 20 validated messages or a selected contiguous
range of up to 20. Select the first and last rows using Analyze selected context;
then review the exact chronological message block, separators, model, profile,
and instruction before sending. A changed session or evicted/changed context
invalidates the preview. Capture times and contact metadata are excluded.
Detailed capture diagnostics are in Settings.

`bash test-transcript-ui.sh` exercises the real SwiftUI scroll viewport with public
fixture data in a temporary macOS window. It requires a logged-in desktop and
never interacts with WeChat or a model. See [REFINEMENT_VALIDATION.md](REFINEMENT_VALIDATION.md)
for per-stage files, test results, measurements, and the outstanding live merge gate.
