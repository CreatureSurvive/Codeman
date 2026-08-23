# Feature parity — web client → CodemanNative

Derived by reading the fork's frontend (`src/web/public/*.js`) and route modules, not from the
README. Each row names the web-side source of truth and the native implementation.

Status legend: **✅ shipped** · **🔸 shipped, reduced** (scope deliberately narrowed for a phone
form factor, noted why) · **⛔ not applicable** (with the reason).

---

## 1. Server onboarding and connection

| Capability | Web source | Native | Notes |
| --- | --- | --- | --- |
| URL entry, scheme inference | `index.html` login | ✅ `OnboardingView` | accepts `host`, `host:port`, full URL; defaults `https` for non-private hosts, `http` for RFC1918/`.local` |
| Connection test | — (browser just navigates) | ✅ | `GET /api/node/info`, the one non-admin node route (API-Audit §4); reports name + version |
| Basic auth | `middleware/auth.ts` | ✅ | username defaults to `admin`, matching `CODEMAN_USERNAME` |
| Bearer / federation token | `verifyFederationBearer` | ✅ | alternative credential; grants admin, which node management needs |
| Keychain storage | ⛔ browser cookie jar | ✅ `KeychainCredentialStore` | `kSecClassInternetPassword`, `AfterFirstUnlock` |
| QR quick-connect | `GET /api/native/connect` (`native-routes.ts`) | ✅ | scans `codeman://connect?url=…&name=…`; also registered as a URL scheme so the link works from Camera/Messages |
| Saved servers, switching | ⛔ | ✅ | SwiftData `ServerRecord`; switching tears down streams and rebuilds cleanly |
| Self-signed HTTPS | ⛔ | ✅ | explicit per-server leaf-cert SHA-256 pin, user-confirmed once |
| Logout | `POST /api/logout` | ✅ | clears cookie + Keychain item |

## 2. Nodes (this fork's federation)

| Capability | Web source | Native | Notes |
| --- | --- | --- | --- |
| List local + remote nodes | `GET /api/nodes` | ✅ | admin-gated; hidden entirely on `FORBIDDEN` |
| Node health / online / reconnecting / offline | `POST /api/nodes/:id/test`, `GET /api/node/info` | ✅ | 3-state machine with a bounded probe timer |
| Add / edit / remove node | `POST/PUT/DELETE /api/nodes` | ✅ | |
| Pair by code | `POST /api/nodes/pair` | ✅ | |
| Node selection scopes every API call | `api-client.js` `_shouldProxyNodePath` | ✅ `NodeScope` | one type owns `/api/nodes/<id>/proxy/...` and `/ws/nodes/<id>/...` |
| Node-scoped recent sessions / actions | `session-ui.js` `currentNodeId` | ✅ | session list, case list, and custom-action launch all re-scope on switch |
| Terminal over a node bridge | `/ws/nodes/:nodeId/sessions/:id/terminal` | ✅ | identical frame protocol |

## 3. Sessions

| Capability | Web source | Native | Notes |
| --- | --- | --- | --- |
| Create (7 modes) | `POST /api/sessions`, `/api/quick-start` | ✅ | quick-start is the default path (handles case creation, remote + docker cases) |
| Custom action launch | `session-ui.js` `runCustomAction` | ✅ | including the sensitive-env refusal on old remote nodes |
| Restore / resume | `GET /api/history/sessions`, `resumeSessionId` | ✅ | |
| Rename | `PUT /api/sessions/:id` | ✅ | |
| Stop / delete | `DELETE /api/sessions/:id?killMux=` | ✅ | confirm sheet distinguishes detach vs kill for attached remote sessions |
| Pin | `POST /api/sessions/:id/pin` | ✅ | |
| Terminal input | `/ws` `{"t":"i"}` | ✅ | with `(cid,seq)` reliable delivery + ACK |
| Composed prompt send | `POST /api/sessions/:id/input` | ✅ | always `\r`-terminated (API-Audit §5.4) |
| Newline insert | `POST /api/sessions/:id/send-key` `S-Enter` | ✅ | the only two keys that endpoint accepts |
| Resize | `/ws` `{"t":"z"}` | ✅ | coalesced, viewport-classed |
| Reconnect | `GET …/terminal?full=1` | ✅ | generation-guarded, see Architecture §4.3 |
| Full-history load | `?full=1` | ✅ | pull-to-load-history at the top of the pane |
| Session order (cross-device) | `PUT /api/session-order` | ✅ | |
| Backend / model badges | `SessionState.backend`, `cliModel`, `cliVersion`, `cliAccountType` | ✅ | rendered from authoritative session metadata only; the web client's local `_inferBackendFromText` guess is used **only** as the same post-launch fallback it is used for there |

## 4. Custom launch actions

| Capability | Web source | Native | Notes |
| --- | --- | --- | --- |
| CRUD from Settings | `session-ui.js` `showCustomRunActionEditor`, `saveCustomRunActionFromEditor` | ✅ `CustomActionEditorView` | |
| Available at session creation | run-mode menu `custom:<id>` | ✅ | in the launch sheet and the run menu |
| Name, launch command | `label`, `command` (≤40 / ≤2000, single line) | ✅ | validated client-side to the same limits |
| Individual env variables | `env: [{key,value}]`, ≤50 | ✅ | key regex `^[A-Za-z_][A-Za-z0-9_]*$` |
| Common variable presets | ⛔ (web has none) | ✅ `EnvironmentPresets` | derived from the **code's** allowlist (API-Audit §5.5), which is wider than `CLAUDE.md` states |
| Arbitrary custom variables | ✅ | ✅ | with an inline warning when a key falls outside the launch-time prefix allowlist, instead of a launch-time surprise |
| Secret-safe UI | ⛔ | ✅ | values matching `TOKEN\|KEY\|SECRET\|PASSWORD\|AUTH` are masked by default, excluded from logs, and never rendered in a share sheet |
| Sync with the web client | `PUT /api/settings {customRunActions}` | ✅ | same server key; edits appear in both clients |

## 5. Files, directories, attachments

| Capability | Web source | Native | Notes |
| --- | --- | --- | --- |
| Directory browser | `GET /api/filesystem/browse` | ✅ `DirectoryBrowserView` | renders the server-supplied `roots[]` verbatim; never assumes Home exists |
| Remote-node browsing | via node proxy | ✅ | same view, node-scoped |
| Pre-session directory selection | `quickStartCase` + Browse | ✅ | |
| Case list / create | `GET/POST /api/cases` | ✅ | |
| Image attach from library | `paste-image` multipart | ✅ | `PhotosPicker` — **no** `NSPhotoLibraryUsageDescription`, because PhotosPicker runs out of process and needs no library permission |
| Camera capture | | ✅ | only on explicit tap; `NSCameraUsageDescription` declared |
| File import | | ✅ | `fileImporter` |
| Paste image | | ✅ | from the pasteboard |
| Upload progress / retry | | ✅ | per-item progress, explicit retry on failure, `429` surfaces the 30/min cap |
| Preview | attachment routes | ✅ | |
| Remote-session support | | ✅ | uploads route through the node proxy |
| HEIC | server converts from magic bytes | ✅ | uploaded as-is; the server does the conversion |
| File viewer / edit | `file-content`, `PUT file-content` | 🔸 read-only | editing is a desktop-shaped task and the `baseHash` conflict flow needs a real diff UI; reading, previewing, and range-aware media playback are shipped |

## 6. Monitoring

| Capability | Web source | Native | Notes |
| --- | --- | --- | --- |
| Current sessions | `GET /api/sessions` + SSE | ✅ | |
| Past sessions | `GET /api/sessions/unified`, `/api/history/sessions` | ✅ | |
| Activity / idle state | `session:idle`, `session:working`, `status` | ✅ | same ranking as the web home screens |
| Token usage / cost | `inputTokens`, `outputTokens`, `totalCost`, `globalStats` | ✅ | |
| Subagents | `GET /api/subagents`, `subagent:*` | ✅ | inspector list with live tool calls |
| Orchestrator relationships | `orchestrator:*`, `parentSessionId` | ✅ | lineage shown as an indent in the sidebar |
| Telemetry / plan usage | `planUsage` in SSE init, `session:status_telemetry` | ✅ | |
| Approvals inbox | `GET /api/approvals`, `POST /api/approvals/:id/answer` | ✅ | red "needs you" rows, answered inline |
| Notifications | hook events over SSE | ✅ | local notifications while backgrounded; Web Push is browser-only, so the native app uses `UNUserNotificationCenter` driven by the SSE stream and by approval state on foreground |
| Away digest | `GET /api/away-digest` | ✅ | `.digest` key special-cased |
| Search | `GET /api/search` | ✅ | |
| Respawn config | `/api/sessions/:id/respawn*` | ✅ | presets + custom |
| Ralph | `/api/sessions/:id/ralph-*` | 🔸 status only | full Ralph authoring is a long-form desktop workflow; the native app shows loop state, todos, and circuit-breaker state, and can start/stop and reset the breaker |
| Cron | `/api/cron/*` | ✅ | list, enable/disable, run now |

## 7. Settings

Native controls with the same semantics, split exactly as the web client splits them:
server-synced keys go through `PUT /api/settings`; per-device display keys stay in
`UserDefaults`. Terminal font family/size and theme are native (`GhosttyTheme` catalog) because
the web client's xterm palette has no native analogue.

## 8. Deliberately not ported

| Web feature | Why |
| --- | --- |
| Gesture control (camera hand tracking) | opt-in `CODEMAN_GESTURE=1` desktop experiment; needs MediaPipe/WASM |
| Web tabs (dashboard URLs as tabs) | its entire purpose is proxying arbitrary HTML into an iframe; a native client would need the `WKWebView` this project forbids |
| Multi-monitor / span displays | desktop window management |
| Voice dictation via the Deepgram/Claude relay | the relay is a browser-PCM bridge; iOS has first-party dictation on the system keyboard, which the composer uses instead |
| Read My Mind, ultracode floating windows, gesture overlay | desktop-canvas features with no phone/tablet analogue |

Each of these is a platform or product decision, not unfinished work.
