# CodemanNative — Architecture

A native Swift 6 / SwiftUI client for Codeman on iOS and iPadOS 18+. No web view, no Capacitor,
no HTML terminal. The terminal is Ghostty rendering through Metal.

Read [`API-Audit.md`](API-Audit.md) first — it is the contract this design is built against.

---

## 1. Layering

```
              ┌──────────────────────────── SwiftUI views (@MainActor) ─────────────────────────────┐
              │  RootView · SidebarView · TerminalPane · SettingsView · DirectoryBrowser · …        │
              └──────────────────────────────────────┬──────────────────────────────────────────────┘
                                                     │ observes @Observable models
              ┌──────────────────────────────────────┴──────────────────────────────────────────────┐
              │  AppModel (@MainActor @Observable)   — the single view-facing state tree             │
              │    ├── ServerRegistry   (saved servers, active server)                               │
              │    ├── NodeRegistry     (local + federated nodes, health)                            │
              │    ├── SessionStore     (sessions, ordering, selection, badges)                      │
              │    └── TerminalRegistry (one TerminalSession per open tab)                           │
              └──────────────────────────────────────┬──────────────────────────────────────────────┘
                                                     │ awaits actors
   ┌──────────────┬──────────────┬───────────────────┴──────────┬──────────────┬────────────────────┐
   │ AuthStore    │ APIClient    │ EventStream                  │ Terminal     │ PersistenceStore   │
   │ (actor)      │ (actor)      │ (actor)                      │ Transport    │ (actor)            │
   │ Keychain     │ typed REST   │ SSE byte-stream + reconnect  │ (actor)      │ SwiftData          │
   └──────────────┴──────────────┴──────────────────────────────┴──────────────┴────────────────────┘
                                                     │
                                        URLSession / URLSessionWebSocketTask
```

Everything below `AppModel` is protocol-oriented (`APIClientProtocol`, `EventStreaming`,
`TerminalTransporting`, `CredentialStoring`, `ServerPersisting`) with one real implementation and
one test implementation. There are **no mocks in production paths** — the test transports live in
the test target only.

Swift 6 strict concurrency is on (`SWIFT_STRICT_CONCURRENCY=complete`, `-warnings-as-errors`).
Views and models are `@MainActor`; networking and persistence are actors; every model that
crosses an isolation boundary is `Sendable`.

---

## 2. Actor responsibilities and task ownership

| Actor | Owns | Cancellation |
| --- | --- | --- |
| `AuthStore` | Keychain reads/writes, credential resolution per server | n/a (no long tasks) |
| `APIClient` | one `URLSession`, request construction, envelope decoding, node scoping | per-request `Task`; callers use structured `async let` / `withThrowingTaskGroup` |
| `EventStream` | the SSE byte stream, incremental UTF-8 parsing, backoff, `Last-Event-ID` | owns exactly one `Task`; `stop()` cancels and awaits it |
| `TerminalTransport` | one `URLSessionWebSocketTask` per session, the send pipeline, generations | owns a receive `Task` and a send `Task`; both cancelled on `disconnect()` |
| `PersistenceStore` | SwiftData `ModelContainer` for non-secret server/node/action config | n/a |

Rule: **an actor that starts a `Task` stores it and cancels it in its own teardown.** No detached
tasks, no fire-and-forget outside `Task { }` blocks whose handle is retained. `AppModel` holds a
`[SessionID: Task<Void, Never>]` for per-session streams and cancels on tab close.

---

## 3. Networking

### 3.1 `APIClient`

Typed `Codable` request/response models throughout — no `[String: Any]`. Each endpoint is a
method returning a decoded value or throwing `APIError`.

Envelope handling (`APIEnvelope.swift`) implements the three shapes the server actually emits
(API-Audit §1.1): `{success:true,data}`, `{success:false,error,errorCode}`, and a bare JSON body
that the `preSerialization` hook wrapped or that a raw route returned unwrapped. `204` is decoded
as `Void` without touching the body.

`APIError` carries the HTTP status **and** the `ApiErrorCode`, so callers can distinguish
`SESSION_BUSY` (retryable, show a spinner) from `FORBIDDEN` (hide the feature) from
`INVALID_INPUT` (show the server's message verbatim — the server writes better messages than we
could, e.g. the exact `npm install -g` line for a missing CLI).

### 3.2 Headers

Set on every request:

- `Authorization: Basic …` or `Bearer …`, resolved per server from the Keychain.
- `Accept: application/json`.
- `X-Codeman-CSRF: codeman-native` on **every non-GET**. Only `paste-image` requires it
  (API-Audit §3.4), but sending it unconditionally is free, matches what the server's own node
  proxy does, and means a future hand-rolled check cannot surprise us.

Never set: `Host` (reserved by URLSession, and unnecessary — API-Audit §3.1) and `Origin`
(a missing Origin is explicitly the allowed case; sending one can only fail).

### 3.3 Node scoping

`NodeScope` is the only place that knows the proxy path shape:

```swift
enum NodeScope: Sendable, Hashable {
    case local
    case remote(id: String)

    func restURL(base: URL, path: String, query: [URLQueryItem]) -> URL
    func webSocketURL(base: URL, sessionID: String, cid: String) -> URL
}
```

`.remote` prefixes `/api/nodes/<id>/proxy` for REST and swaps to `/ws/nodes/<id>/sessions/<sid>/terminal`
for the socket. Because it is one type, a node switch cannot leave a half-scoped call behind.

Node admin routes are probed once per server; on `FORBIDDEN` the node UI is hidden entirely
(multi-user non-admin) rather than showing a broken panel. `GET /api/node/info` is the
non-admin-gated reachability probe and drives the online / reconnecting / offline state machine.

### 3.4 ATS and local networking

`Info.plist` declares, narrowly:

- `NSAppTransportSecurity.NSAllowsLocalNetworking = true` — permits cleartext HTTP to
  `.local`, link-local, and RFC1918 addresses **only**. This is what makes `http://192.168.1.x:3000`
  work for a LAN/VPN Codeman without disabling ATS globally. Public HTTP remains blocked;
  `NSAllowsArbitraryLoads` is **not** set.
- `NSLocalNetworkUsageDescription` — required from iOS 14 for local-network access.
- `NSBonjourServices` is **not** declared: the app does no Bonjour discovery, so requesting it
  would be an unjustified permission.

A self-signed HTTPS Codeman is supported through an explicit, per-server, user-confirmed
certificate pin (`ServerTrustEvaluator.swift`): the SHA-256 of the leaf certificate is stored with
the server record after the user accepts it once. Blanket `serverTrust` acceptance is never used.

---

## 4. Terminal: Ghostty integration and the ordering contract

Package: `https://github.com/Lakr233/libghostty-spm.git`, pinned to **exact version `1.4.0`**
(`.exact("1.4.0")` in `project.yml`, resolved into `Package.resolved`). Products used:
`GhosttyTerminal` and `GhosttyTheme`.

### 4.1 Why a custom representable

`GhosttyTerminal` ships `TerminalSurfaceView(context: TerminalViewState)`, and its representable
assigns `view.delegate = context`. `TerminalViewState` conforms to the title / grid-resize /
focus / close / bell / pwd / scrollbar / lifecycle / text-selection delegates — but **not** to
`TerminalSurfaceOpenURLDelegate`. Link taps would therefore never reach the host.

Since `UITerminalView` exposes `delegate`, `controller`, `configuration`, `inputAccessoryItems`,
and `fitToSize()` as `open`/`public`, `GhosttyTerminalView.swift` is a thin
`UIViewRepresentable` whose `Coordinator` is the delegate and conforms to:

`TerminalSurfaceTitleDelegate`, `TerminalSurfaceGridResizeDelegate`, `TerminalSurfaceFocusDelegate`,
`TerminalSurfaceCloseDelegate`, `TerminalSurfaceOpenURLDelegate`, `TerminalSurfaceTextSelectionRequestDelegate`.

That buys native selection, hover/opened links, grid-resize reporting, and the keyboard accessory
bar, with the same `InMemoryTerminalSession` backend the package intends for host-driven I/O.

### 4.2 The byte path

```
WS {"t":"o","d":"…"}  ──▶ TerminalTransport (actor)
                             │  no parsing, no trimming, no reordering
                             ▼
                       TerminalSession.ingest(Data)      @MainActor
                             │  generation check
                             ▼
                    InMemoryTerminalSession.receive(_:)  ──▶ Ghostty ──▶ Metal
```

`InMemoryTerminalSession.receive` buffers bytes that arrive before a surface attaches (1 MiB cap,
oldest dropped) and flushes on attach, and processes writes on a per-session serial queue in
order. So the client does **not** need to hold the connection until the first viewport report —
it just must not reorder.

Input flows the other way through the session's `write:` closure into a single actor-owned
`AsyncStream` continuation, so **every** terminal write — typed keys, accessory keys, paste,
programmatic sends — is serialized through one pipeline in `TerminalTransport`. There is exactly
one `send` loop per socket.

### 4.3 Generations — the anti-interleave mechanism

Terminal output must never interleave across sessions, nodes, or connection epochs. Each
`TerminalSession` holds a monotonically increasing `generation: UInt64`. It is bumped on:

- connect / reconnect of the WebSocket,
- switching the session's node,
- an authoritative snapshot reload (`{"t":"r"}`, foreground restore, first attach).

Every frame carries the generation captured when its socket was opened. `ingest` drops any frame
whose generation is not the current one. The snapshot path is:

1. bump generation → `g`
2. `GET /api/sessions/:id/terminal?full=1` (API-Audit §5.6)
3. still `g`? → reset the Ghostty grid, `receive(snapshot)`, mark `snapshotApplied`
4. frames tagged `g` that arrived during (2) were held in a bounded buffer; replay them in order
5. frames tagged `< g` are discarded

Step 4 is what prevents the classic "reconnect wipes the last two seconds of output" bug. Step 5
is what prevents a slow response from a *previous* session's socket painting into the current tab.

`?full=1` is used rather than `?tail=`, because a repaint-mode CLI pane keeps no tmux history and
a tail would be a strictly worse snapshot. The response's `source` field is checked: if it comes
back `history` (no live pane), the grid is reset anyway — that is a legitimately empty pane.

### 4.4 Resize

Ghostty reports grid metrics through the `InMemoryTerminalSession` resize closure and the
`terminalDidResize(columns:rows:)` delegate. The client forwards
`{"t":"z","c":cols,"r":rows,"v":<class>,"f":false}` where `<class>` is `mobile` / `tablet` /
`desktop` derived from the horizontal size class **and** the pane's own width (a split pane on
iPad is not a desktop viewport). Resizes are coalesced at 100 ms trailing so a rotation or a
Stage Manager drag does not flood the socket; the final size always lands.

`suppressesPixelOnlyResizes: true` is set on the in-memory session — the client consumes only
columns and rows, and a live drag is ~78 % pixel-only updates per the package's own measurement.

### 4.5 Background / foreground

On `scenePhase == .background`: sockets are **not** torn down immediately (iOS gives a short
grace period and a quick app switch should not lose the pane), but the SSE stream is stopped and
each terminal's `isSurfaceVisible` is set false so Metal stops drawing. If the app is suspended,
the sockets die on their own.

On return to `.active`: for each visible session, generation is bumped and an authoritative
snapshot is pulled *before* the socket is re-established, so no stale frame can land first.
The SSE stream restarts with `Last-Event-ID`. Nothing is duplicated because the stream objects
are singletons owned by their actors and `start()` is idempotent — a second call returns the
existing task.

### 4.6 Links

`terminalDidRequestOpenURL(_:kind:)` → `http`/`https` only → `SFSafariViewController` presented
over the terminal. Any other scheme is ignored. No `WKWebView` is created anywhere in the app;
`SafariServices` is the only web surface and it is out-of-process.

---

## 5. State, persistence, secrets

- **Keychain** (`KeychainCredentialStore`): passwords and bearer tokens, one
  `kSecClassInternetPassword` item per server keyed by server UUID, with
  `kSecAttrAccessibleAfterFirstUnlock` so a background refresh after a reboot still works.
  Secrets are never written to `UserDefaults`, never logged, and never placed in a URL.
- **SwiftData** (`PersistenceStore`): `ServerRecord`, `NodeRecord`, `TerminalPreferences`.
  Non-secret only. The store is an actor wrapping a `ModelContainer`; views never touch it
  directly.
- **`UserDefaults`**: per-device UI preferences only (font size, theme choice, accessory layout,
  last selected server) — the same "per-device by client policy" split the web client uses.
- **Server-synced settings** (`customRunActions`, `runMode`, `respawnPresets`, …) live on the
  server via `GET/PUT /api/settings` so the native app and the web UI stay in sync.

### 5.1 Logging

`OSLog` with subsystem `cloud.creature.codeman.native` and categories `net`, `sse`, `ws`,
`terminal`, `auth`, `ui`. Every interpolation of a URL, host, session id, prompt, or environment
value is marked `privacy: .private`; only enum-like values (HTTP status, close code, event name,
byte counts) are `.public`. `Logger` is never handed a credential in any privacy mode.

---

## 6. Adaptive UI

| Idiom | Layout |
| --- | --- |
| iPad regular | `NavigationSplitView(sidebar:content:detail:)` — sidebar = nodes + sessions, content = terminal (optionally two resizable panes), detail = inspector |
| iPad compact / Slide Over | collapses to the iPhone layout automatically via size class |
| iPhone | terminal-first `NavigationStack`; the session list is a drawer presented as a sheet with `.presentationDetents`, so switching sessions is one thumb-reach |

Side-by-side terminal panes on iPad are a `HSplitContainer` with a draggable divider whose ratio
is persisted; each pane owns its own `TerminalSession` and generation, which is exactly why
cross-pane interleaving is structurally impossible.

Safe areas, `keyboardLayoutGuide`, orientation, and Stage Manager resizes are respected by
constraining the terminal to the keyboard guide (mirroring the package's own example) rather than
by observing keyboard notifications.

**Keyboard accessory.** `view.inputAccessoryItems` is set to a compact set —
`esc · tab · ctrl · alt · | · ← ↑ ↓ → · | · paste`, plus user-configured command shortcuts
rendered as `.symbol("…")` items. The package's sticky-modifier machinery
(`toggleStickyModifier`, `stickyActivation`, `resetStickyModifiers`) provides the one-shot Ctrl
behaviour natively, so the app does not reimplement it. The main toolbar is hidden while the
keyboard is up (`@FocusState` drives `.toolbar(.hidden, for: .navigationBar)` on compact), so the
two bars never stack.

Accessibility: every control has a label; the terminal surface is an accessibility element with a
value that reads the viewport (`InMemoryTerminalSession.readViewportText()`); Dynamic Type applies
to all chrome, and the terminal font size is a separate explicit control (a terminal grid must not
reflow with the system text size).

---

## 7. Error, empty, offline, reconnecting states

Each is a real, actionable view — never a spinner that never resolves and never a silently
swallowed failure:

| State | Surface |
| --- | --- |
| No servers | onboarding with URL entry, "Test connection", and QR scan |
| Connection test failed | the underlying `URLError`/`APIError` message + a retry button |
| Auth failed (401) | inline re-authenticate; **no automatic retry** (API-Audit §2.1 — retries burn the per-IP rate limit) |
| Rate limited (429) | shows `Retry-After` as a countdown |
| Node offline | node row shows offline with the last probe error; its sessions are listed read-only |
| SSE reconnecting | non-blocking banner with the attempt count; the terminal stays readable |
| WS reconnecting | per-pane badge; input is queued, not dropped, and flushed after the snapshot |
| Session terminated (`4009`) | pane shows the exit state with a Restart action |
| Too many connections (`4008`) | explains the 5-per-session cap and offers to close another view |

---

## 8. Testing

- **Unit** (Swift Testing): envelope decoding for all three wire shapes, URL construction for
  local and proxied nodes, auth header selection, SSE incremental parsing (including a UTF-8
  character split across chunk boundaries and CRLF frames), WS frame encode/decode, reconnect
  ordering with generations, node scoping, custom-action env flattening and the sensitive-key
  refusal, and the SSE-registry parity check against `src/web/sse-events.ts`.
- **Integration**: boots a real `tsx src/index.ts web` on a unique port with `CODEMAN_PASSWORD`
  set, then exercises create → input → snapshot → delete against it.
- **UI** (XCUITest): onboarding, node switching, session launch, action editing, directory
  selection, terminal reconnect, image attachment, rotation.

`test/` port allocation follows the repo rule (unique, ≥3150, never 3000).

---

## 9. Build progress ledger

Maintained during implementation so work can resume after a context reset. On resume: read this
section, find the first unchecked item, continue from there. Do not ask whether to continue.

- [x] Discovery: backend audit (`Docs/API-Audit.md`)
- [x] Discovery: feature parity (`Docs/Feature-Parity.md`)
- [x] Discovery: architecture (this file)
- [x] `Sources/Support/` — Logging, Backoff
- [x] `Sources/Models/` — APIEnvelope, Session, Node, Case, Filesystem, Settings, SSEEventName
- [x] `Sources/Networking/` — ServerConfiguration/NodeScope, Keychain, APIClient, SSEClient,
      TerminalTransport, ServerTrustEvaluator
- [x] `Sources/Terminal/` — TerminalSession, GhosttyTerminalView, theme
- [x] `Sources/Features/` — AppModel + views
- [x] `Sources/App/` — app entry, Info.plist, assets
- [x] `project.yml` + generated `CodemanNative.xcodeproj`
- [x] Unit tests (`Tests/`) — 106 passing
- [x] UI tests (`UITests/`) — 10 layout/onboarding passing; server-backed suite runs under Scripts/
- [x] `xcodebuild` iPhone (Debug) + iPad (Release, warnings-as-errors) — both clean
- [x] Phone screenshots captured (9), terminal renders real PTY output at 38x16
- [x] Keychain save defect (see below) — fixed, covered by a live-Keychain unit test and a UI test
- [x] `ios-build` archive/install — Release IPA, OTA at https://ota.creaturecloud.xyz/
- [ ] Tablet screenshots — one ambiguous-match fix applied, needs a rerun
- [ ] Repo backend tests (targeted only)
- [ ] Setup + Troubleshooting docs, final parity/audit pass

### Deployment

**Always deploy with `ios-build`** (`ios-build . -c Release` from `native/CodemanNative/`). It
reads the bundle id, team and version from the generated project, archives, exports the IPA and
publishes it OTA. Do not hand-roll `xcodebuild archive`/`exportOptions.plist` in its place.

### Post-ship defect: Save did nothing on Add Server (fixed)

Worth keeping because two independent faults stacked into one symptom, and the test suite was
green through both.

1. `KeychainCredentialStore` used `kSecClassInternetPassword` with `kSecAttrService`. That
   attribute is not in the internet-password schema, so **every** Security call — `SecItemAdd`,
   `SecItemDelete`, `SecItemCopyMatching` — returned `errSecNoSuchAttr` (-25303), measured
   directly. Saving threw on its first line for all three auth modes, `None` included: that path
   stores nothing but still calls `SecItemDelete` to clear a stale item. Now
   `kSecClassGenericPassword` keyed by `service` + `account`.
2. The resulting alert was bound to `RootView`, which **cannot present while a sheet is up** —
   UIKit refuses to present on a controller that is already presenting. Every error-raising
   surface in this app lives in a sheet, so the failure was invisible. `AppAlertHost` now presents
   from the front-most controller.

Why the suite missed it: the Keychain test covered only the pure blob encoding, and UI tests swapped
in an in-memory credential store — a double cannot reproduce a framework rejection. The store is now
exercised for real in both (UI tests isolate by service name instead of substituting the type), and
`InMemoryCredentialStore` is deleted.
