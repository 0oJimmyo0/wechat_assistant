# WeChat capture validation — 2026-10-07

**Merge gate remains closed.** The target Mac runs WeChat **3.3.1**, not 4.x.
Automated checks and the observations below do not establish all live acceptance criteria.

## Reproduction and correction

The initial read-only probe could not see an AX window while WeChat was hidden.
Bringing the existing WeChat conversation forward exposed the window and its
transcript scroll area. The window frame was `(127,73,1269,788)`, the transcript
frame `(447,164,950,486)`, and the composer frame `(453,726,938,129)` in AX screen
coordinates. The sidebar table contained 698 virtual rows; depth-first discovery
spent its budget traversing that unrelated table.

Discovery now walks breadth-first and inspects visible list/table children only.
Transcript geometry uses the measured viewport, with an aligned composer below
it as evidence for builds without the semantic message-list identifier. AX
screen coordinates are normalized into Vision coordinates without substituting
a calibrated crop. A measured native viewport reached validated geometry with
initial discovery of approximately 34 ms, compared with approximately 950 ms
of earlier probes. A representative initial capture took approximately 1.3 s.
These are diagnostic observations, not a controlled same-conversation benchmark.

The earlier fast OCR path accepted nonempty but suspicious mixed-language text.
It now retries accurately for Chinese, mixed, low-confidence, or unreadable
observations. Message OCR enables language detection with English and simplified/
traditional Chinese. Reconstruction requires a completely visible, filled bubble
background; it groups lines by that component rather than proximity. A rejected
low-confidence row makes its entire bubble unreadable. Cropped bubbles, centered
notices, timestamps, sidebar, header, and composer text cannot supply context.
Vision messages remain ineligible for automatic analysis.

## Live observations

A content-free, ten-attempt read-only harness observed one identity-pending
capture followed by nine captures with confirmed identity and verified native
scroll-area geometry. Three complete visible bubbles entered the trusted store;
a long top bubble crossed the viewport boundary and was excluded. The eight
subsequent observations preserved message text, count, order, and local IDs in
memory. No private message text or contact name was printed.

- Identity-pending capture: 1526 ms.
- First validated capture: 628 ms.
- Eight unchanged validated captures: 120–132 ms, reusing OCR after exact pixel
  fingerprints of the transcript and header matched.
- Validated P50/P95: **122/628 ms**, nine samples in one open conversation.
- Automatic-analysis eligibility: false for every observed Vision message.

A second ten-attempt run on a changed viewport retained two accepted bubbles
from 31 OCR observations. It again preserved eight subsequent trusted histories
and reported P50/P95 **137/980 ms**; the identity-pending cold attempt took
2358 ms. Cached attempts retained the original raw observation count in their
diagnostics. This confirms that cold activation can still exceed two seconds,
and conservative filtering can omit visible text. It does not establish complete
transcript coverage.

These timings demonstrate the warm capture path on this machine, not all UI
Refresh situations. The earlier and later previews used different conversations;
they cannot establish a same-chat before/after text comparison. The required
annotated previews were deliberately saved locally under ignored
`.build/diagnostics/` and inspected. Accepted boxes were inside the measured
transcript; sidebar, header, composer, timestamps, and a clipped top bubble were
excluded. These private previews are not part of the repository.

The live harness exercised capture and the conversation store, not the complete
sidebar workflow. Manual confirmation of all characters and the active contact,
new arrivals, scrolling, switching conversations, and real repeated identical
messages remains outstanding. No messages were sent, no chat was selected by the
harness, and no model request or database access was performed.

## Automated verification

`bash test-wechat-parsing.sh` covers parsing, source selection, measured geometry,
all-attempt diagnostics, distinct repeated occurrence IDs, exact AX punctuation,
ordered overlap, bounded history, OCR variation, three unchanged observations,
ambiguous tail overlap, historical scrolling, and uncertain arrival evidence.

`bash test-wechat-vision.sh` runs the production OCR/reconstruction path on a
synthetic, sanitized recreation of the observed layout, using only public test
text. It verifies Chinese, English punctuation, mixed multiline messages,
separate bubbles, identical occurrences, unreadable lines, and UI exclusions.
It does not load the user's private screenshot or establish accuracy for every
real screenshot, theme, attachment, or font.

The macOS app builds and signs with the existing stable local identity. The
existing `CGWindowListCreateImage` deprecation warning remains. Capture metrics
retain at most 200 attempts; P50/P95 use validated captures only. Every attempt,
including identity-pending and failed captures, updates source, geometry, OCR
mode, raw/candidate/accepted counts, duration, and rejection reason.

## Limits and remaining merge gate

Visual-divider geometry without measured AX viewport/composer evidence stays
unverified. Full visual-only header/composer boundary detection is unresolved;
the app deliberately refuses to trust a calibrated plausible crop. Pixel bubble
segmentation is bounded and conservative; unsupported backgrounds or partially
visible messages may be omitted rather than guessed.

AX text extraction still requires `chat_message_list` and confirmed
`chat_bubble_item_view` rows. WeChat 3.3.1 did not expose these semantic identifiers.
PR #2's exact head `621daa42b81f3fa11a72805c355a8994806bc4fe` was separately built
in `.build/pr2-validation`; it has not been merged. Fixes remain on
`fix/wechat-process-detection` in `0oJimmyo0/wechat_assistant`.

Before merging, manually verify on the intended WeChat version:

1. Correct contact and every readable Chinese/English/multiline message in direct
   and group conversations; no unrelated UI or system notices.
2. Two identical real messages remain distinct and three unchanged UI Refresh
   operations retain content, ordering, count, and identities.
3. Incoming messages appear without restarting; scrolling backward and returning
   to latest never creates false arrivals or automatic analysis.
4. Switching, resizing, reopening, and changing windows invalidates stale context
   and suggestions. Failed captures preserve the last trusted history.
5. Refresh, Follow latest, Load older to 20, the 5/20 display, status/counts, and
   stop/close privacy clearing work in the rebuilt sidebar.
6. Measure UI Refresh latency across representative conversations. Confirm AX
   diagnostics contain structure and attribute support only, with no private text.
7. Run both regression scripts and the macOS build on the final changes.

Read-only WeChat access and suggestion-only replies remain unchanged. Automatic
analysis requires identity, sender, reliable ordered overlap, and latest-viewport
arrival evidence; Vision or uncertain captures cannot trigger it.
