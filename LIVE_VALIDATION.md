# WeChat capture validation — 2026-10-07

**Merge gate remains closed.** Code checks do not establish the live WeChat 4.x
acceptance criteria, correct contact/content, or the under-two-second Refresh target.

## Checkout and PR #2

Implementation changes are in the user's existing `fix/wechat-process-detection`
checkout, based on `46940c9`. PR #2 has a different head, `621daa42b81f3fa11a72805c355a8994806bc4fe`.
That exact PR head was fetched and separately built in a detached worktree at
`.build/pr2-validation`. No branch was merged, pushed, or published. These local
implementation changes have not been applied to PR #2.

## Available verification

- The macOS application builds and signs locally. The existing ScreenCaptureKit
  migration warning for `CGWindowListCreateImage` is unrelated to these changes.
- Parsing/source-selection/store regression suites cover direct and descendant
  text filtering, sender uncertainty, distinct repeated-message IDs, stable
  overlap identities, historical overlap taking priority over repeated tail
  text, memory limits, exact AX punctuation/case, and missing/negative live-edge
  evidence blocking automatic arrival classification.
- PR #2's exact head builds and signs on this Mac. A temporary read-only capture
  harness reported Accessibility trusted, no contact, no message list, and zero
  bubbles/messages. This is an unavailable capture, not a successful live test.
- The current app's content-free live diagnostic reported the official WeChat
  process, Accessibility permission, zero AX windows, and an unavailable main
  conversation window. Screen Recording permission was granted.
- Ten capture attempts reported `WeChat window unavailable`. There are **zero
  validated latency samples**. Their durations do not demonstrate faster loading.
- `/Applications/WeChat.app` reports `CFBundleShortVersionString` **3.3.1**. No
  real WeChat 4.x conversation was available for this run.

## Implementation limits to check live

The message source requires the semantic `chat_message_list` identifier. It
never substitutes a geometrically plausible unrelated AX list. Known bubble
rows read batched title/value attributes; fallback text remains inside those
rows, excluding metadata identifiers, timestamp labels, and controls. Wrapped
bubble rows are inspected within bounded list-row descendants. AX text keeps
case, whitespace, and punctuation for overlap comparison; each retained message
occurrence owns a UUID. A session stores at most 200 messages and is cleared on
stop or confirmed conversation change, preserving the existing privacy control.

Automatic analysis requires identified senders, multiple distinct ordered
anchors, unique overlap, continuous live monitoring, and readable scrollbar
minimum/maximum/value evidence of the latest viewport. Missing scrollbar evidence
or unreadable bubbles keep arrival uncertain; manual analysis remains available
for validated context. Refresh, Follow latest, and loading history cannot trigger
automatic analysis themselves. Confirm that WeChat 4.x exposes this scrollbar
evidence; if it does not, automatic analysis intentionally remains disabled.

The structural diagnostic never outputs AXTitle/AXValue/AXDescription contents
or contact identifiers. It lists supported attribute names and bounded sampled
row counts. Capture metrics keep at most 200 attempts and compute P50/P95 from
validated captures only. The ten-attempt benchmark does not scroll, send messages,
or call a model. Existing local Vision support is preserved; no new OCR or
WeChat database access was introduced.

## Required live WeChat 4.x checks before merge

1. Open a direct chat on WeChat 4.x, activate, and compare the contact and each
   captured message with the visible conversation. Check a group chat as well.
2. Inspect the AX diagnostic: confirmed list/bubble identifiers, hierarchy, roles,
   row counts, text attribute support, no message/contact text in the report.
3. Place distinctive text in a sidebar preview/contact details and confirm it
   never appears in captured context. Check dates, recalls, notices, attachments,
   and virtual placeholders. Verify exact failure stages when text is unavailable.
4. Have a participant send identical messages twice. Confirm two distinct
   occurrences and stable IDs on Refresh. No app restart should be required.
5. Scroll backward through repeats and previously unseen history, then Refresh.
   Confirm context updates with stable ordering and no automatic analysis.
6. Test new arrivals at the bottom, missing sender information, an unavailable
   scrollbar, an ambiguous overlap, and returning from history. Only arrivals
   with all identity/sender/direction evidence may trigger opted-in analysis.
7. Change chat/window, reopen a window, and resize it. Confirm cache invalidation,
   session isolation, and that suggestions use only the active validated chat.
8. Check the 5/20 display toggle, actual captured count, Refresh status/duration,
   and that stopping/closing clears all retained messages and suggestions.
9. Run `--capture-benchmark` on representative open chats and measure Refresh in
   the UI. Record initial capture and warm P50/P95, scanned nodes, and extracted
   counts without saving chat text. Typical validated Refresh must be under 2 s;
   compare the same conversation/window/version with the baseline build.
10. Re-run `bash test-wechat-parsing.sh` and `./build.sh` on the final change, then
    mark these live checks complete before considering merge.
