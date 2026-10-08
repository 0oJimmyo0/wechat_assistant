# Refinement validation — 2026-10-07

Base: `feat/local-scrollable-transcript` at `128ae7a` (draft [PR #3](https://github.com/0oJimmyo0/wechat_assistant/pull/3)).
The target Mac runs **WeChat 3.3.1**. No merge is authorized by these results.

## Stage results and changed files

| Stage | Implementation / changed files | Verification and limits |
| --- | --- | --- |
| P0 | Baseline only; existing capture pipeline retained. | Parsing/store/source tests, unskipped screenshot OCR fixture, and signed macOS build passed before feature edits. A live read-only harness observed four accepted bubbles and eight subsequent identical trusted histories. Chinese/English character-by-character comparison and real scroll/arrival workflows remain manual checks. |
| P1 | `ChatTranscriptView.swift`, `ReplySidebarView.swift`, new `TranscriptScrollState.swift` and scroll-state/native UI tests. | Dedicated resizable `VSplitView` pane, chronological `LazyVStack`, floating Jump to latest, incremental 20-row load action. Native test verifies actual viewport resize, no movement on incoming rows, and preserved visible row identity/offset on prepending. Local scrolling never calls WeChat scroll functions. |
| P2 | `ChatMessage.swift`, `WeChatParsing.swift`, `TimeSeparatorPlacement.swift`, `WeChatScreenReader.swift`, `ConversationStore.swift`; parsing/store/Vision tests. | Separators retain literal labels, source, confidence, observation time, and a stable following-message occurrence. No individual send time is invented. English/Chinese day/date/clock labels supported. Low-confidence OCR labels and labels whose next bubble is unreadable are excluded. Ambiguous historical overlap cannot enrich arbitrary repeated occurrences or modify history before a failed merge. |
| P3 | `MessageMonitor.swift`, `ConversationMonitoringState.swift`, `WeChatBridge.swift`, transcript/sidebar arrival wiring; monitoring tests. | Incoming events require live observations, previously observable tail, unique ordered overlap, confirmed identity, and identified other sender. Refresh, return from history, and backfill cannot produce arrival events. An unchanged cached OCR snapshot still updates live-edge evidence. Verified native scroll-area scrollbar evidence can serve older builds without semantic list identifiers; missing values remain unknown. Vision remains ineligible for automatic inference. |
| P4 | `AnalysisContext.swift`, `AnalysisContextPreview.swift`, `SuggestionEngine.swift`, `ReplySidebarView.swift`, monitor session IDs; context tests. | Latest 20 validated messages by default, or an explicitly chosen chronological range of up to 20. Oversized selections fail instead of silently truncating. Manual preview freezes the exact serialized message block, model, profile, and instruction. Changed sessions, evicted messages, or changed metadata invalidate it. No model request was made during verification. |
| P5 | `SettingsView.swift`, `ReplySidebarView.swift`, native UI and incremental-history/lifecycle tests. | Detailed capture metrics moved to Settings; user-facing loading, failure, and monitoring states stay visible. Existing background capture, exact-image OCR reuse, geometry cache, and 200-message cap retained. Tests cover 20/40/60-row backfill, returning to latest, three unchanged refreshes, capped messages/separator events, and clearing history. |

## Commands and measured observations

Run on the logged-in target Mac:

```bash
bash test-wechat-parsing.sh
bash test-wechat-vision.sh
bash test-transcript-ui.sh
./build.sh
```

The Vision fixture was run **without** `WECHAT_TEST_SKIP_SCREENSHOT_OCR`. It uses
public synthetic test text and does not load or save private chat screenshots.
The native UI test requires a graphical macOS session and opens a temporary
window containing public fixture text only. It neither reads/scrolls WeChat nor
calls a model. The existing CoreGraphics screenshot deprecation warning remains.

The baseline ten-attempt live capture run on PR #3 produced one identity-pending
capture and nine validated captures. Accepted content/order/count/local IDs
remained identical for eight subsequent observations, exceeding the three-refresh
capture/store criterion. Timings: first pending 1410 ms, first validated 450 ms,
eight cached captures 122–128 ms; validated **P50/P95 125/450 ms**. This is a small
capture/store benchmark, not an end-to-end UI Refresh benchmark across all chats.

The native UI test found a prepend-restoration discrepancy during development.
Restoration now follows measured row geometry after lazy layout. The corrected
probe preserved the same visible occurrence with **0 px offset error**, kept the
reader stationary during a new incoming row, counted the unread occurrence once,
and retained that count through three unchanged UI refreshes. A synthetic
200-row scroll sweep took about 562 ms including 550 ms of intentional event-loop
waits. It establishes rendering without a crash; it is not an FPS or CPU benchmark.

Later real-WeChat probes saw an unavailable window or an unverified configured
crop, with zero accepted messages. Their durations are **not** validated latency
samples. Geometry rejection prevented those observations from entering trusted
context. The earlier valid sample must not be presented as proof that every later
window state works. No private content was logged, no screenshot was saved by
these refinement tests, no outgoing WeChat message was sent, and no database was
accessed.

## Follow-up live validation and scrollbar fix

On the open conversation, the verified transcript scroll area's vertical
`AXScrollBar` reported `AXValue = 1` and `AXVerticalOrientation`, while both
`AXMinValue` and `AXMaxValue` were absent. Requiring those range attributes left
monitoring uncertain at the real bottom. `ScrollBarEvidence.swift` now accepts
normalized values only for a verified vertical scrollbar. Explicit ranges must
be complete and valid; unsupported roles, orientations, missing values, and
out-of-range numbers remain uncertain. Near-bottom history does not count as
the live endpoint. Vision remains ineligible for automatic analysis.

The new deterministic evidence tests cover these cases. The native AppKit probe
verifies normalized top/bottom values using a fixed-height flipped document;
the SwiftUI lazy transcript changes its measured document height during layout
and therefore cannot serve as a fixed endpoint fixture. Existing transcript
resize, unread, prepend, and 200-row checks still pass (0 px prepend error;
571 ms synthetic sweep including 550 ms intentional waits). Parsing/store,
unskipped Vision OCR, native UI tests, and the signed build all passed.

A fresh ten-attempt read-only live run accepted two Chinese messages and one
observed separator after one identity-pending observation. Eight subsequent
trusted histories matched including occurrence IDs and metadata. All nine
validated snapshots reported `liveEdge=true`; automatic eligibility remained
false. Validated capture **P50/P95: 121/923 ms**, cached captures 119–123 ms.
This measures capture/store latency, not end-to-end sidebar Refresh. The open
view had no accepted Latin or multiline messages, so live mixed-language and
multiline coverage is still unverified. The user has confirmed a conversation
is open; text/contact comparison and actual arrival/history workflows remain
pending. No private text or screenshot was saved by this probe.

## Outstanding interactive acceptance tests

Keep PR #3 draft until the following pass on the intended WeChat version:

- Open a normal conversation with validated transcript geometry. Compare actual
  contact, Chinese/English/multiline characters, and literal time separators.
- Use Load 20 earlier three times. Confirm real chronological backfill and return
  to WeChat's latest viewport. Six bounded scroll attempts may reach fewer than
  20 readable new rows; incomplete progress is reported instead of guessed.
- Browse old local context while a participant sends new messages. Confirm capture
  continues, the local reader stays stationary, and confirmed unread occurrences
  appear exactly once. When scrollbar evidence is unavailable, “Monitoring
  uncertain” is intentional and incoming-event classification is withheld.
- Verify repeated identical real messages and three actual sidebar Refresh actions.
- Jump to latest locally; scroll WeChat separately and test Follow latest. Refresh,
  local browsing, history loading, and returning from history must never trigger
  automatic inference.
- Switch conversations and deactivate; verify all temporary context, selections,
  previews, unread IDs, and suggestions clear. A request already sent to the model
  cannot be recalled, but no stale response may populate the new session.
- Preview latest and selected historical context. Confirm its exact message block,
  separators, sender labels, model, profile, and instruction match the eventual
  request. Requests remain limited to 20 validated messages.
- Measure real UI Refresh, 200-message scrolling, and idle CPU usage. The existing
  3-second watchdog still takes a window capture for exact change detection; this
  work does not claim zero capture cost while unchanged.

Visual-only geometry without measured viewport/composer evidence remains
unverified. Unsupported bubble backgrounds, clipped bubbles, and uncertain OCR
may omit text. Automated fixtures do not establish full WeChat 4.x compatibility
or complete real transcript coverage.
