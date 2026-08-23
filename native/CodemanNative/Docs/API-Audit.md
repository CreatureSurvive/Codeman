# Codeman API Audit — for the native iOS/iPadOS client

Audited against this fork's source, not against `docs/api-reference.md`. Every claim below
cites the file and symbol it was read from. Where the checked-in prose and the code disagree,
**the code wins** and the disagreement is called out.

Audit date: 2026-08-22 · Server version at audit: `1.19.3` (`package.json`).

---

## 1. Transport shape

### 1.1 The response envelope is applied centrally, not per-handler

`src/web/server.ts` → `WebServer.setupRoutes`, `preSerialization` hook:

```ts
if (!req.url.startsWith('/api')) return done(null, payload);
if (payload === null || typeof payload !== 'object') return done(null, payload);
if (Buffer.isBuffer(payload) || typeof payload.pipe === 'function') return done(null, payload);
if (p.success === false) {
  if (reply.statusCode === 200 && typeof p.errorCode === 'string') {
    reply.code(httpStatusForErrorCode(p.errorCode));
  }
  return done(null, payload);
}
if (p.success === true) return done(null, payload);
return done(null, { success: true, data: payload });
```

Consequences the client must encode:

| Situation | Wire body |
| --- | --- |
| Handler returns bare `{ sessionId, casePath, caseName }` | `{"success":true,"data":{ sessionId, … }}` |
| Handler returns `{ success: true, data: … }` itself | passed through **unwrapped again** — never double-nested |
| Handler returns `createErrorResponse(...)` | `{"success":false,"error":"…","errorCode":"…"}` + mapped HTTP status |
| Handler returns a Buffer / stream | raw, **no envelope** (`file-raw`, attachment `/raw`, SSE) |
| Handler returns `null` or a scalar | raw, **no envelope** |
| Unknown `/api` route | `404` + `{"success":false,"error":"Route GET:/api/x not found","errorCode":"NOT_FOUND"}` |
| Unknown non-`/api` route | `404` + `{message,error,statusCode}` (Fastify default shape) |

**Client rule (implemented in `APIEnvelope.swift`):** decode `{success,data}` first; if `success`
is absent from a JSON object body, treat the whole body as `data`. Both shapes occur in
practice — e.g. `GET /api/sessions` returns a bare array that the hook wraps, while
`POST /api/cases` hand-builds `{success:true,data:{case:…}}`.

`204 No Content` is returned by `POST /api/events/subscribe`, `DELETE /api/nodes/:id`,
`DELETE /api/node/tokens/:id`, and `POST /api/crash-diag`. The client must not attempt to
decode an envelope from an empty body.

### 1.2 `ApiErrorCode` (`src/types/api.ts`)

`NOT_FOUND`, `INVALID_INPUT`, `UNAUTHORIZED`, `SESSION_BUSY`, `CONFLICT`, `ALREADY_EXISTS`,
`RATE_LIMITED`, `OPERATION_FAILED`, `FORBIDDEN`, `PASSWORD_CHANGE_REQUIRED`, `USER_EXISTS`,
`USER_NOT_FOUND`, `LAST_ADMIN`, `INTERNAL_ERROR`.

The native client models these as a `String`-backed enum with an `unknown(String)` case so a
newer server cannot break decoding.

### 1.3 `/api/v1/*` alias

`server.ts` rewrites `/api/v1/...` → `/api/...`. The native client uses the **unversioned**
paths, matching the web client, because `/api/v1` covers only the documented-stable subset and
this app legitimately uses internal surfaces (`/api/nodes`, `/api/native/connect`).

---

## 2. Authentication — three accepted credentials

`src/web/middleware/auth.ts` → `registerAuthMiddleware`. Auth is **inactive entirely** when
single-user mode is on and `CODEMAN_PASSWORD` is unset; in multi-user mode it is always active.

The single-user `onRequest` hook accepts, in this order:

1. **Federation bearer** — `await verifyFederationBearer(req.headers.authorization)`. On success
   the request is decorated `{ username: 'admin', role: 'admin' }` and **auth is finished**.
   This is the token minted by `POST /api/node/pair/claim` / `POST /api/node/tokens`.
2. **Hook secret bypass** — loopback-only, `POST /api/hook-event` and `/api/status-telemetry`
   only. Not usable by the app.
3. **Session cookie** `codeman_session` — re-issued (sliding) on every authenticated request.
4. **HTTP Basic** — `CODEMAN_USERNAME` (default `admin`) + `CODEMAN_PASSWORD`, timing-safe
   compared against a precomputed header string. On success a `codeman_session` cookie is minted.

Failure: `401` + `WWW-Authenticate: Basic realm="Codeman"`. Ten failures per IP inside 15 min →
`429` + `Retry-After` (`AUTH_FAILURE_MAX`, `AUTH_FAILURE_WINDOW_MS` in `config/auth-config.ts`).

**Native decision.** The client sends `Authorization: Basic …` on **every** request and lets
`URLSession`'s cookie store carry `codeman_session` opportunistically. Reason: the sliding-cookie
path is an optimisation, not a requirement, and re-presenting Basic is what makes a cold launch,
a background relaunch, and a WebSocket upgrade all behave identically. A saved server may
instead hold a **bearer token**, which takes the federation path and also yields admin — required
for `/api/nodes`.

Credentials live in the Keychain (`kSecClassInternetPassword`, `kSecAttrAccessibleAfterFirstUnlock`),
keyed by server id. `UserDefaults`/SwiftData hold only non-secret server config.

### 2.1 Rate limiting is per-IP and shared

A burst of 401s from the app will lock out the login path for 15 minutes. The client therefore
**stops retrying after the first 401** and surfaces a re-authenticate state instead.

---

## 3. Host allowlist and the cross-site guards — why URLSession works unmodified

This was the single highest-risk item for a native client and it needs **no backend change**.

### 3.1 Host guard (`registerHostGuard`, always on)

`isAllowedRequestHost(req.headers.host, policy)` → `matchesHost` in
`src/web/network-auth-policy.ts`:

```ts
if (hostname === 'localhost') return true;
if (isIP(hostname) !== 0) return true;              // ANY IP literal passes
if (bind && hostname === bind) return true;
if (policy.tunnelHost && hostname === policy.tunnelHost) return true;
if (DOCKER_HOST_GATEWAY_ALIASES.includes(hostname)) return true;
for (const suffix of ['.ts.net', '.trycloudflare.com', '.cfargotunnel.com']) …
for (const entry of policy.allowedHosts) …          // CODEMAN_ALLOWED_HOSTS
```

`URLSession` derives `Host` from the request URL and **does not allow it to be overridden**
(it is on the reserved-header list). That is fine: every address a user can actually type —
a LAN IP literal, `localhost`, a `*.ts.net` MagicDNS name, a Cloudflare tunnel host — already
matches. A custom reverse-proxy domain needs `CODEMAN_ALLOWED_HOSTS` on the server, exactly as
it does for a browser. **No `Host` spoofing is required and none is attempted.**

### 3.2 CSRF Origin guard

```ts
export function isAllowedRequestOrigin(originHeader, policy) {
  if (originHeader === undefined || originHeader === '') return true;   // ← non-browser clients
  if (originHeader === 'null') return false;
  …
}
```

A missing `Origin` is **allowed by design** so curl and Claude Code hooks keep working.
`URLSession` sends no `Origin` on ordinary requests, so every state-changing call passes.
The client deliberately **does not** synthesize an `Origin` header — doing so could only make
it fail (an opaque or mismatched value is rejected).

### 3.3 CSWSH guard on the WebSocket upgrade

`src/web/routes/ws-routes.ts`, first statement in the handler:

```ts
if (!isAllowedRequestHost(req.headers.host, policy) || !isAllowedRequestOrigin(req.headers.origin, policy)) {
  socket.close(4003, 'Forbidden');
  return;
}
```

Same two functions. `URLSessionWebSocketTask` sends no `Origin`, so the upgrade passes.
`Authorization` **is** settable on the underlying `URLRequest` (it is not a reserved WebSocket
header), so Basic/Bearer auth reaches the global `onRequest` hook that runs on the upgrade.

### 3.4 The one genuine exception: `POST /api/sessions/:id/paste-image`

`session-routes.ts` line ~4014 has a **hand-rolled** CSRF check that does *not* share the
`isAllowedRequestOrigin` semantics:

```ts
if (origin)        csrfOk = new URL(origin).host === reqHost;
else if (referer)  csrfOk = new URL(referer).host === reqHost;
else               csrfOk = !!req.headers['x-codeman-csrf'];
```

With neither `Origin` nor `Referer`, a **non-empty `X-Codeman-CSRF` header is mandatory** or
the upload is `403`. `URLSession` sends neither header, so the native client **must** set
`X-Codeman-CSRF`. The value is unchecked — any non-empty string works. The client sends
`X-Codeman-CSRF: codeman-native`.

This is a real, undocumented requirement discovered only by reading the handler; a client that
assumed the global guard's "missing Origin is fine" rule would see every image upload 403.

Also enforced there: 30 uploads/min per `(IP, sessionId)` → `429`; field name must be `image`;
extension allowlist `.png .jpg .jpeg .gif .webp .bmp .heic .heif`; **magic-byte sniffing** —
declared type must match the actual bytes or `415`. HEIC is detected from bytes regardless of
declared MIME and converted server-side to JPEG.

---

## 4. Node federation (this fork's multi-node support)

`src/web/routes/node-routes.ts`.

| Method | Path | Admin? | Notes |
| --- | --- | --- | --- |
| GET | `/api/node/info` | no | `{id,name,version,headless,baseUrl,capabilities[]}` — the health probe |
| POST | `/api/node/pair/start` | **yes** | mints a pairing code on *this* node |
| POST | `/api/node/pair/claim` | no | `{code,name}` → `{token,…,nodeName,nodeId,version}` |
| POST/GET | `/api/node/tokens` | **yes** | long-lived federation tokens |
| DELETE | `/api/node/tokens/:id` | **yes** | `204`/`404` |
| GET | `/api/nodes` | **yes** | `{local:{id:'local',…}, nodes:[…]}` |
| POST/PUT/DELETE | `/api/nodes[/:id]` | **yes** | CRUD |
| POST | `/api/nodes/:id/test` | **yes** | `{ok,status,checkedAt,message?,info?}` |
| POST | `/api/nodes/pair` | **yes** | dashboard-side claim against a remote `baseUrl` |
| ALL | `/api/nodes/:nodeId/proxy/*` | **yes** | server-to-server proxy, `compress:false` |
| GET | `/ws/nodes/:nodeId/sessions/:id/terminal` | — | WS bridge to the remote node |

**Critical for the client:** every node-management route is behind `requireAdmin(req, reply)`.
In single-user mode `getAuthUser` returns a synthetic admin, so they all work. In multi-user
mode a non-admin gets `403 FORBIDDEN` and the app must hide the node UI rather than error.
`GET /api/node/info` is the one node route that is *not* admin-gated — the client uses it as the
node-reachability probe and as the "is this URL a Codeman server?" connection test.

### 4.1 The proxy preserves the envelope and SSE

`proxyFetch` copies the upstream status, strips `content-encoding`/`content-length`/
`transfer-encoding`, and **specially handles `text/event-stream`** by re-writing the head and
piping chunks. So `GET /api/nodes/<id>/proxy/api/events` is a working remote SSE stream, and
`/api/nodes/<id>/proxy/api/sessions` returns the remote node's normal envelope.

It also sets `X-Codeman-CSRF: node-proxy` on non-GET/HEAD upstream requests — confirming the
paste-image finding in §3.4 from a second, independent call site.

**Node-scoped URL construction (client):**

- local node → `<base>/api/sessions`
- remote node → `<base>/api/nodes/<nodeId>/proxy/api/sessions`
- local terminal WS → `<wsBase>/ws/sessions/<id>/terminal?cid=<cid>`
- remote terminal WS → `<wsBase>/ws/nodes/<nodeId>/sessions/<id>/terminal?cid=<cid>`

This is implemented once in `NodeScope.swift`; no call site builds a node URL by hand.

### 4.2 Node-scoped limitation, faithfully reproduced

`runCustomAction` in `session-ui.js` shows the web client already handles a real remote-node
gap: a remote node running an older Codeman rejects `envOverrides`, and the web UI retries with
the env folded into the launch command — but **refuses to do so when any key name matches
`/(?:TOKEN|KEY|SECRET|PASSWORD|AUTH)/i`**, because that would put a secret on a command line.
The native client reproduces this rule exactly (`CustomActionLauncher.swift`).

---

## 5. Sessions

### 5.1 Create — `POST /api/sessions` (`CreateSessionSchema`, `schemas.ts:325`)

```
workingDir?         safePathSchema
mode?               'claude'|'shell'|'opencode'|'codex'|'gemini'|'antigravity'|'pi'
name?               ≤100
parentSessionId?    ≤100
envOverrides?       safeEnvOverridesSchema  (see §5.5)
effort?             effortLevelSchema
modelOverride?      ≤50   (written to <case>/.claude/settings.local.json; '' clears)
statusLineTelemetry? bool
openCodeConfig? codexConfig? geminiConfig? antigravityConfig? piConfig?
resumeSessionId?    ≤100, /^[a-f0-9-]+$/
attachRemoteSession? { hostId, remoteSessionName: /^codeman-[a-zA-Z0-9._-]+$/ }
```

Returns `{ session: <light SessionState> }` (then enveloped). Note: creation **does not start**
the session — `pid` is `null` until `/interactive` or `/shell`.

### 5.2 Quick start — `POST /api/quick-start` (`QuickStartSchema`, `schemas.ts:740`)

```
caseName?      /^[a-zA-Z0-9_-]+$/
sessionName?   ≤128
mode?          same 7-value enum
launchCommand? ≤2000, single line  — shell mode ONLY (400 otherwise)
modelOverride? envOverrides? effort? parentSessionId?
openCodeConfig? codexConfig? geminiConfig? antigravityConfig? piConfig?
```

Returns `{ sessionId, casePath, caseName }`. **This endpoint creates the case if missing, starts
the session, and broadcasts `session:created` + `session:interactive`.** It is the correct entry
point for remote-SSH and Docker cases; `POST /api/sessions` stat-validates `workingDir` locally
and would reject them.

Rejections worth surfacing in UI:
- remote/docker case + any of `envOverrides`/`effort`/`modelOverride`/per-CLI config → `INVALID_INPUT`
  with an explanatory message (they do not cross ssh / the container boundary).
- `launchCommand` with `mode !== 'shell'` → `INVALID_INPUT`.
- Docker config drift → `CONFLICT`.
- Missing CLI → `OPERATION_FAILED` with the exact install command in the message. The native
  client shows the server's message verbatim rather than inventing one.

### 5.3 Lifecycle & I/O

| Method | Path | Body / notes |
| --- | --- | --- |
| GET | `/api/sessions` | array of light `SessionState`; owner-filtered in multi-user |
| GET | `/api/sessions/:id` | light `SessionState` + respawn |
| GET | `/api/sessions/unified` | merged live + persisted + transcript history |
| GET | `/api/history/sessions` | past Claude conversations for resume |
| POST | `/api/sessions/:id/interactive` | `{clearBreaker?}` — body optional |
| POST | `/api/sessions/:id/shell` | no body |
| POST | `/api/sessions/:id/input` | see §5.4 |
| POST | `/api/sessions/:id/send-key` | `{key}` — **only `S-Enter` and `C-Enter` are allowed**, both mapping to hex `0a` (LF = insert newline, vs `0d` = submit). Anything else is `INVALID_INPUT`. Requires a tmux session. Not a general key-injection endpoint; arbitrary keys go over the WebSocket. |
| POST | `/api/sessions/:id/resize` | `{cols 1-500, rows 1-200, viewportType?, force?}` |
| GET | `/api/sessions/:id/terminal` | `?tail=<bytes>` \| `?full=1` — see §5.6 |
| PUT/PATCH | `/api/sessions/:id` | rename |
| DELETE | `/api/sessions/:id` | `?killMux=` |
| POST | `/api/sessions/:id/pin` | pin to top |
| GET | `/api/sessions/:id/last-response` | parsed transcript answer |
| GET | `/api/sessions/:id/active-tools` | liveness signal |
| GET | `/api/sessions/:id/subagents` | (in `system-routes.ts`) |

### 5.4 Input — `SessionInputWithLimitSchema` (`schemas.ts:1133`)

```
input       ≤100000
useMux?     bool
seq?        int ≥0        ┐ reliable delivery: (clientId,seq) applied at-most-once
clientId?   ≤128          ┘
wait?       bool | string | string[]   (.nullish() — explicit null is accepted)
waitTimeout? int > 0      (.nullish())
```

**The `\r` rule.** `sendInput` only issues `send-keys Enter` when the payload contains a carriage
return. A `\r`-less POST still returns `200` (and `delivered:true` on the wait path) while the
text sits unsubmitted on the composer. The native client's `sendPrompt` therefore always appends
`\r`, and strips embedded newlines first (they are stripped server-side anyway, joining lines).

The native terminal does **not** use this endpoint for keystrokes — it uses the WebSocket. This
endpoint is used for: sending a composed prompt, answering an approval, and the "Insert/Send"
actions, all of which want server-side submission semantics rather than local echo.

### 5.5 Env override allowlist — **wider in this fork than `CLAUDE.md` documents**

`schemas.ts:125` `ALLOWED_ENV_PREFIXES`:

```
ANTHROPIC_  CLAUDE_CODE_  CODEX_  GEMINI_  GOOGLE_  OPENAI_  OPENCODE_  OPENCLAW_  ANTIGRAVITY_  PI_
```

`schemas.ts:144` `ALLOWED_ENV_KEYS` (exact match): `API_TIMEOUT_MS`, `CLAUDE_CONFIG_DIR`.

`CLAUDE.md` lists neither `ANTHROPIC_`, `OPENAI_`, `OPENCLAW_`, nor `API_TIMEOUT_MS`. **The code
is authoritative** and the native environment-variable editor validates against the code's list,
with the "common presets" drawn from it (`EnvironmentPresets.swift`). A `BLOCKED_ENV_KEYS` set
also exists and is enforced server-side; the client surfaces the server's rejection message
rather than duplicating that list.

### 5.6 Terminal snapshot — the authoritative reconnect source

`GET /api/sessions/:id/terminal` returns:

```ts
{ terminalBuffer, status, fullSize, truncated, truncationReason: 'capped'|'tail'|null,
  retainedBytes, source: 'history'|'mux-visible'|'mux-full-history' }
```

- `?full=1` → captures the **entire** tmux scrollback and returns it **alone** (`mux-full-history`).
  The byte history is deliberately not prepended: `\x1b[2J` clears the viewport, not scrollback,
  so concatenating would replay the conversation twice.
- `?tail=<n>` → last *n* bytes of the stripped buffer, cut at the first newline within 4 KB so
  the payload never starts mid-escape-sequence.
- no param → visible tmux frame prepended by the byte history with `\x1b[H\x1b[2J` between.

The client's reconnect contract: on first attach to a session and on every reconnect/foreground
restore, fetch `?full=1`, **reset** the Ghostty grid, write the snapshot, and only then start
applying WS frames buffered since the request was issued. Implemented in
`TerminalTransport.swift` as an explicit generation counter — see Architecture §4.

### 5.7 The wait primitives

`GET /api/sessions/:id/wait`, `GET /api/sessions/:id/wait-output`, and `wait` on `POST …/input`.
A timeout is a **`200`** with `wait.timedOut === true`, never an error. `stop`/`blocked` signals
come from Claude Code hooks and exist for `claude` mode only; requesting one explicitly on
another mode is a `400`. The native app does not drive agents, so it uses these only for the
"send and wait for the turn to finish" affordance in the composer, with the default signal set.

---

## 6. SSE — `GET /api/events`

`server.ts:809`. Not a route module; registered on the server directly.

- Query: `?sessions=id1,id2` (narrows **only** `session:terminal` batches) and
  `?clientId=<token>` matching `/^[A-Za-z0-9_-]{8,64}$/`, which enables
  `POST /api/events/subscribe {clientId, sessions}` → `204`/`404` to change the filter without
  reconnecting.
- `503 Too many SSE connections` past `MAX_SSE_CLIENTS` (100).
- The first frame is always `event: init` carrying `computeLightState()`:
  `{version, sessions[], scheduledRuns[], respawnStatus{}, globalStats, subagents[],
    workflowRuns[], timestamp, inputCjkForm, planUsage, sessionOrder}`.
- Keepalive is a **named `sse:heartbeat` event**, not an SSE comment — a comment is invisible to
  `EventSource` by spec, which is why it was changed. The native parser treats any frame
  (heartbeat included) as a liveness stamp.
- Headers are inherited from the security hook then overwritten with
  `text/event-stream`, `no-cache`, `keep-alive`, `X-Accel-Buffering: no`.

155 event names are registered in `src/web/sse-events.ts` (`SseEvent`). The native client models
them as a `String`-backed enum with an `unknown` case and handles the ~40 it acts on; the rest
are decoded and dropped without error. The registry is mirrored verbatim in `SSEEventName.swift`
and pinned by a unit test that reads `sse-events.ts` at test time, so drift fails the suite.

**Client parsing requirements** (all implemented in `SSEClient.swift`):
- `URLSession.bytes(for:)` byte streaming, **not** `lines` — a multi-byte UTF-8 character can
  straddle a chunk boundary, so decoding is incremental with a carry buffer.
- Frame separator is a blank line; `event:`, `data:` (repeatable, joined with `\n`), `id:`,
  `retry:` are honoured. `:`-leading comments are ignored but still stamp liveness.
- `Last-Event-ID` is re-sent on reconnect when the server has ever supplied an `id:`.
- Reconnect uses bounded exponential backoff with jitter, capped at 30 s, and is cancelled
  deterministically on `Task` cancellation.

---

## 7. WebSocket terminal — `GET /ws/sessions/:id/terminal`

`src/web/routes/ws-routes.ts`. **All frames are JSON text frames.** There is no binary framing
on this channel; the client must send `.string(...)` and must tolerate receiving `.data(...)`
(URLSession can surface a text frame either way) by UTF-8 decoding it.

Server → client:

| Frame | Meaning |
| --- | --- |
| `{"t":"o","d":"…"}` | terminal output, micro-batched at 8 ms / 16 KiB, wrapped in DEC 2026 sync markers `\x1b[?2026h` … `\x1b[?2026l` |
| `{"t":"c"}` | clear terminal |
| `{"t":"r"}` | needs refresh — re-pull the snapshot |
| `{"t":"ia","seq":N}` | input ACK |

Client → server:

| Frame | Meaning |
| --- | --- |
| `{"t":"i","d":"…","seq":N,"cid":"…"}` | input; `d` ≤ `MAX_INPUT_LENGTH`; `(cid,seq)` applied at-most-once and ACKed regardless |
| `{"t":"z","c":cols,"r":rows,"v":"mobile"\|"tablet"\|"desktop","f":bool}` | resize; `1≤c≤500`, `1≤r≤200` |

Close codes: `4003` forbidden (host/origin/ownership), `4004` session not found, `4008` too many
connections (cap 5 per session), `4009` session terminated, `4010` superseded by a same-`cid`
reconnect.

**`cid` semantics.** `WsConnectionRegistry` supersedes only the *same* `cid`. A stable per-device
`cid` means a reconnect reclaims its own slot instead of consuming a new one — without it, a
flaky link burns through the cap of 5 and starts getting `4008`. The native client derives one
stable `cid` per (device install, session) pair and persists it.

Heartbeat: server pings every 30 s and terminates after a 10 s pong timeout. `URLSessionWebSocketTask`
answers pings automatically.

**Ordering guarantee the client must uphold:** the `d` payload of `{"t":"o"}` is a byte-exact
slice of the PTY stream. It is fed to Ghostty **in receive order, unmodified, with no re-encoding
beyond UTF-8 → `Data`**. Escape sequences are routinely split across frames, so no frame may be
parsed, trimmed, or reordered.

---

## 8. Files, attachments, images

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/api/filesystem/browse` | `?sessionId&path&showHidden` → `{path,parent,root,roots[],entries[],truncated}` |
| GET | `/api/filesystem/preview` | tapped file |
| GET | `/api/sessions/:id/files` | workspace listing |
| GET | `/api/sessions/:id/file-content` | `?edit=1` for the non-truncating read |
| PUT | `/api/sessions/:id/file-content` | optimistic concurrency via sha256 `baseHash` → `409` |
| GET | `/api/sessions/:id/file-raw` | range-aware, `Accept-Ranges: bytes`, `206` |
| POST | `/api/sessions/:id/attachments` | `{path, notify?}` → registers an external path |
| GET | `/api/sessions/:id/attachments[/:aid[/raw\|/preview\|/thumbnail]]` | |
| POST | `/api/sessions/:id/paste-image` | multipart, field `image`, **`X-Codeman-CSRF` required** (§3.4) |

`FilesystemBrowseEntry = {name, path, type:'file'|'directory', size?, symlink?, previewKind?}`.
`FilesystemBrowseRoot = {label, path}`. The `roots[]` array is server-computed and already
multi-user-scoped — the client renders exactly what it is given and never assumes `Home` exists.

The browse endpoint takes `sessionId` as an ownership-scoped hint; passing a session id the
caller cannot access is a `404`. The native directory browser therefore always passes the
session id when one is in context, and omits it (rather than guessing a path) when not.

---

## 9. Settings — and where `customRunActions` lives

`GET/PUT /api/settings`. `SettingsUpdateSchema` is `.strict()`, so an unknown key is a
validation error. Keys the native client writes are limited to ones present in the schema.

**Custom launch actions** (`schemas.ts:1070`) are a *synced* setting:

```ts
customRunActions: z.array(z.object({
  id: z.string().max(64),
  label: z.string().min(1).max(40),
  command: z.string().min(1).max(2000).refine(noNewlines),
  env: z.array(z.object({
    key: z.string().max(128).regex(/^[A-Za-z_][A-Za-z0-9_]*$/),
    value: z.string().max(2000).refine(noNewlines),
  })).max(50).optional(),
})).max(20).optional()
```

The web client mirrors them into `localStorage['codeman_customRunActions']` and PUTs on change
(`session-ui.js` `getCustomRunActions`/`setCustomRunActions`). **The server copy is the shared
source of truth**, so the native app reads and writes the same `customRunActions` key and the
two clients stay in sync. Launch is `POST /api/quick-start` with
`{caseName, mode:'shell', launchCommand: action.command, envOverrides, sessionName}` — the env
array is flattened to an object, dropping keys that fail `/^[A-Za-z_][A-Za-z0-9_]*$/`.

Note the env-key regex here allows any name, while `safeEnvOverridesSchema` on the launch call
enforces the §5.5 prefix allowlist. So an action can *store* `FOO=1` but launching it will be
rejected. The native editor warns at edit time, showing the allowlist, instead of letting the
user discover it at launch.

Other settings read by the client: `runMode`, `respawnPresets`, `voiceSettings`,
`notificationPreferences`, plus the `show*` display keys. Per the fork's own rule, several
display keys are **per-device by client policy** and are intentionally kept device-local in the
native app too (`SettingsStore.swift` documents which).

---

## 10. Other surfaces used

| Path | Use |
| --- | --- |
| `GET /api/status` | full app state; server reachability + version |
| `GET /api/native/connect` | **`native-routes.ts`** — `{name, baseUrl, connectUrl, webConnectUrl, svg}` where `connectUrl` is `codeman://connect?url=…&name=…`. This is the QR quick-connect contract, and the app registers `codeman://` to consume it. |
| `GET /api/cases` | `CaseInfo[]` |
| `POST /api/cases` | `{name, description?}` |
| `GET /api/approvals`, `POST /api/approvals/:id/answer` | approvals inbox |
| `GET /api/subagents`, `GET /api/sessions/:id/subagents` | subagent list |
| `GET /api/away-digest` | returns `{success:true,digest}` — legacy raw-ish shape, read as `.digest` |
| `GET/POST /api/sessions/:id/respawn*` | respawn config |
| `GET /api/search` | cross-session search |
| `POST /api/logout` | clears the auth cookie |

`GET /api/away-digest` is the one endpoint whose envelope is hand-built with a non-`data` key;
the client special-cases it and a unit test pins that.

---

## 11. Backend changes required

**None.** Every capability the native client needs is reachable over the audited surface with
`URLSession` and `URLSessionWebSocketTask` as-is:

- `Host` is never overridden — IP literals, `localhost`, `.ts.net`, and tunnel hosts all pass the
  allowlist unmodified (§3.1).
- A missing `Origin` is explicitly allowed on both the HTTP CSRF guard and the WebSocket CSWSH
  guard (§3.2, §3.3).
- The one route with a stricter, hand-rolled check (`paste-image`) already provides the
  `X-Codeman-CSRF` escape hatch that the node proxy itself uses (§3.4).
- Node management needs admin, which single-user mode grants and multi-user mode gates — the
  client adapts rather than the server relaxing (§4).

No authentication, origin validation, or node authorization was weakened, and no route or schema
was modified. The `git diff` for this work touches only `native/` (plus this doc set).
