# WeChat Reply Copilot Implementation Plan

## Repository inspection

The project is based on `JunxiBao/WeChatAutoReply`. It is a small macOS app built by `build.sh`, with its Swift sources under `Sources/` and app metadata/assets under `Resources/`. The Accessibility bridge already locates the WeChat process and reads the current window, contact name, and visible message rows. `AutoReplyEngine.swift` owns polling and burst aggregation, but currently couples monitoring to automated replies, delays, skip probability, work hours, conversation memory, and logging. `WeChatBridge.swift` also contains the input-field lookup and keyboard sending code that must be removed.

The `gentleleaf/WeChatReplyAssistant` reference uses SwiftUI for a narrow side-by-side assistant and has useful layout patterns in `Sources/WeChatReplyAssistant/ContentView.swift`, `AppModel.swift`, and `KeychainStore.swift`. Its history service, local database backend, OCR, screenshot capture, and API-key provider flow are outside this V1 design and will not be copied.

## Source mapping

| Current source | V1 destination / action |
| --- | --- |
| `Sources/WeChatBridge.swift` | Keep the Accessibility traversal; extract message/contact types into `Sources/WeChat/ChatMessage.swift`; retain read-only discovery in `Sources/WeChat/WeChatBridge.swift`; remove input-field mutation, simulated typing, and all send methods. |
| `Sources/AutoReplyEngine.swift` | Replace with `Sources/WeChat/MessageMonitor.swift` for polling, active-chat tracking, recent-message snapshots, deduplication, and a two-second restartable burst debounce. Remove automatic reply/sending behavior, random delay, skip probability, work hours, and raw-text logging. |
| `Sources/DeepSeekClient.swift` | Replace with `Sources/AI/ChatGPTClient.swift` for account-specific model discovery and streaming public Responses API calls (`store: false`); add `ChatGPTModels.swift` and `ChatGPTAuthManager.swift`. No API-key fallback. |
| `Sources/SettingsView.swift` | Rework as `Sources/UI/SettingsView.swift` for ChatGPT sign-in/account/model state and local relationship-profile settings. |
| `Sources/main.swift` | Retain app/menu-bar lifecycle, remove auto-reply/proactive-send controls, create and manage a narrow SwiftUI sidebar. |
| `Sources/Localization.swift` | Update strings to suggestion-only terminology, or replace where simpler with user-facing copy in the new views. |
| `Resources/Info.plist` | Keep Accessibility prompting metadata and app identity; add callback URL/network settings only if needed by the chosen loopback OAuth implementation. |
| `build.sh`, `package.sh` | Keep the lightweight source build and packaging flow; update app name/output and entitlements only as needed for loopback OAuth and Keychain. |
| `.gitignore` | Exclude local build output, per-machine OAuth/profile data, and other private artifacts. |
| New `Sources/AI/SuggestionEngine.swift` | Construct the bounded Chinese prompt from recent in-memory context, profile, and optional per-request instruction; parse and validate exactly three labeled candidates plus summary/caution. |
| New `Sources/Profile/RelationshipProfile.swift` and `RelationshipProfileStore.swift` | Define requested defaults and persist only the local profile in app preferences. |
| New `Sources/UI/ReplySidebarView.swift` and `CandidateReplyCard.swift` | Narrow sidebar with contact/latest incoming message, assessment/caution, exactly three copy-only cards, regenerate, special instruction, monitor control, and ChatGPT status. |

## Implementation stages

1. Establish a baseline build of the upstream app and record its build constraints.
2. Isolate Accessibility monitoring and remove every message-send path and sending-oriented setting/control.
3. Add structured chat messages, recent-context snapshots, active-contact changes, and a restartable ~2-second incoming-message burst debounce.
4. Add the suggestion-only SwiftUI sidebar and clipboard-only candidate actions.
5. Implement Sign in with ChatGPT using OAuth/OIDC, PKCE, a persisted `ext_agent_host_id`, validated state/nonce, loopback callback, account registration IDs, and Keychain-only credentials.
6. Discover the selected account's visible models and call the public Responses API with streaming, `store: false`, and no API-key fallback.
7. Add the local relationship profile and prompt/output constraints for exactly three distinct replies.
8. Add privacy-safe errors and diagnostics; avoid logging conversation text or credentials.
9. Document build/install steps, permissions, limitations, and a manual acceptance checklist.

## Key constraints and verification

- No Accessibility action may write to WeChat; candidate actions only copy text to the system clipboard.
- Conversation snapshots stay in memory and are submitted only for the current inference request.
- OAuth access/refresh/ID tokens and PKCE secrets are kept in Keychain or transient memory, never preferences or logs.
- ChatGPT-plan inference uses the account's available model catalog and the documented public Responses endpoint with streaming and `store: false`.
- Build and manual runtime behavior require Apple Silicon macOS 14+ with WeChat installed and Accessibility permission. This repository can compile locally, but live WeChat/OAuth acceptance checks require that desktop setup and a signed-in ChatGPT account.
