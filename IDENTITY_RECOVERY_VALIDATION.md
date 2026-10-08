# PR #4 identity recovery validation — 2026-10-07

Base: `fix/stuck-chat-identity-recovery` at `e9eadd1`, draft
[PR #4](https://github.com/0oJimmyo0/wechat_assistant/pull/4).
Target Mac currently reports WeChat **3.3.1**, so these results do not establish
WeChat 4.x compatibility.

## P0 change

A title-pending observation could replace `MessageMonitor.messages` with
unverified candidates even after a contact and trusted history had been locked.
The trusted store survived, but the displayed timeline changed. The monitor now
uses `PendingIdentityPolicy` to retain the complete validated timeline for a
locked contact and explicitly marks candidate changes unverified. Initial
unlocked detection may still present at most 50 local candidates; they never
enter the trusted store or analysis. Focused tests preserve ordering, metadata,
and occurrence IDs across different and empty pending snapshots.

PR #4's existing AX identity reassessment, auxiliary-window handling,
three-pending-capture cache invalidation, and explicit Retry detection remain
intact. No timestamp, merging, scrolling, or AI feature development was added.

## Automated checks

All passed after the P0 change:

- `bash test-wechat-parsing.sh`, including pending-identity preservation tests.
- `bash test-wechat-vision.sh`, with screenshot OCR enabled and public fixtures.
- `bash test-transcript-ui.sh`: native resize, history position during incoming
  rows, unread persistence, prepend restoration (0 px error), and 200-row render.
- `./build.sh` and strict verification of the installed signed app.

The existing CoreGraphics screenshot API deprecation warning remains.

## Actual WeChat observations

A read-only ten-attempt bridge probe on PR #4 produced eight validated
observations and two identity-pending observations. Eight Chinese messages were
accepted, with no accepted Latin/multiline text or separators in that view.
Validated capture P50/P95: **135/438 ms**. One early history equality comparison
was false; the next six were true. This is not proof of a completely unchanged
conversation across all ten attempts.

After the P0 change, a probe using the actual `MessageMonitor` start/Refresh/stop
paths observed pending identity first, then confirmed identity and eight trusted
messages. Three Refresh comparisons preserved the entire message array,
including occurrence IDs and metadata. Capture P50/P95: **357/674 ms**, four
validated observations out of five. Deactivation cleared contact and both
published and trusted histories. These timings measure capture rather than
end-to-end sidebar latency. No model callback was installed in this probe.

The user initially reported wrong or missing contact/text while the installed
app was still from the earlier branch. After PR #4 plus the preservation fix
was installed and relaunched, the user confirmed **correct contact, correct
content**. Basic live detection is now confirmed; transient-failure and switch
acceptance remain incomplete. Existing P1–P4 functionality was regression
checked rather than rewritten.

A further actual-monitor run captured nine messages, preserved the full array
through three Refresh comparisons, and loaded one older message. It retained
the original nine occurrence IDs in order, emitted zero incoming flags and
zero analysis callbacks during manual backfill, and verified return to the live
tail. Loading stopped with "History overlap found, but no unseen older rows
were added" rather than claiming 20 messages. This proves limited real backfill
and return behavior, not complete historical coverage. Capture P50/P95:
**150/1343 ms**, six validated observations out of seven. Deactivation again
cleared contact and histories.

## P1–P5 regression status

| Stage | Evidence | Remaining live limit |
| --- | --- | --- |
| P1 | Store tests: ordered 200-row cap, repeated occurrences, unique overlap, retained separator events; live original IDs preserved after one older row. | Full 20-row historical retrieval and repeated identical real messages remain unverified. |
| P2 | Native UI tests: stationary local history on append, unread persistence, 0 px prepend error; live backfill/return produced no false arrivals. | Receiving an actual new message while browsing local history and checking Jump to latest is pending. |
| P3 | Existing asynchronous serial captures/caches retained; all measured validated P95 values below 2 seconds in these small samples; resizable transcript tests pass. | These are capture timings, not full UI latency/CPU benchmarks across all conversations. |
| P4 | Context tests verify latest/selected limit 20, chronological sender/separator serialization, and stale-session rejection. | No model request was made; user review of actual preview and request flow remains a live check. |
| P5 | Actual monitor start, three Refresh actions, limited backfill, return, and stop tested; user confirmed correct contact/content. | Actual incoming event, switch clearing, and forced transient capture failure remain incomplete. |

No private contact or message text was printed or written by these probes, and
no screenshots were saved. No WeChat messages were sent. Diagnostic probe
sources/binaries remain in ignored `.build`; only synthetic tests are tracked.

## Live gates still required

- Correct contact/content is user-confirmed and three actual-monitor Refresh
  comparisons passed. Explicit mixed-language/multiline comparison and three
  user-operated sidebar Refresh actions remain to be confirmed.
- Reproduce a transient title/capture failure and verify visible trusted history
  survives and analysis remains disabled until identity is confirmed again.
- Test auxiliary focused windows, repeated pending recovery, and contact
  switching with full session clearing and no cross-contact context.
- Complete live historical scrolling, incoming-message, local position,
  Follow latest, and selected-analysis-context checks before merging.

Keep PR #4 draft and unmerged. Passing synthetic tests and a probe's internal
identity confirmation do not establish that the displayed contact is correct.
