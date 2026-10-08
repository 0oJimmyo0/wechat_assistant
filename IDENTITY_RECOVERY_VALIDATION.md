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

The user reported **wrong or missing contact/text** while the installed app was
still from the earlier branch. PR #4 plus the preservation fix was subsequently
installed and relaunched. A new visual comparison on that installed version is
pending. Therefore **P0 is not accepted**, and P1–P5 changes are deferred.

No private contact or message text was printed or written by these probes, and
no screenshots were saved. No WeChat messages were sent. Diagnostic probe
sources/binaries remain in ignored `.build`; only synthetic tests are tracked.

## Live gates still required

- User verifies exact contact and Chinese/English/multiline content in the
  installed app, then repeats three sidebar Refresh actions.
- Reproduce a transient title/capture failure and verify visible trusted history
  survives and analysis remains disabled until identity is confirmed again.
- Test auxiliary focused windows, repeated pending recovery, and contact
  switching with full session clearing and no cross-contact context.
- Complete live historical scrolling, incoming-message, local position,
  Follow latest, and selected-analysis-context checks before merging.

Keep PR #4 draft and unmerged. Passing synthetic tests and a probe's internal
identity confirmation do not establish that the displayed contact is correct.
