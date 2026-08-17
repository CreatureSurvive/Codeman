# Native iOS and Android App

Codeman's native apps are Capacitor shells around a reachable Codeman server.
They do not run the Node/tmux backend on the phone.

## Development

Install dependencies, then sync native projects:

```bash
npm install
npm run mobile:sync
```

Open the platform project:

```bash
npm run mobile:ios
npm run mobile:android
```

The bundled shell in `mobile/www/` stores one or more server profiles on the
device. Selecting a profile navigates the WebView to that Codeman server. The
server dashboard loads `native-bridge.js`, which exposes Capacitor helpers as
`window.CodemanNative` when the page is running inside the app.

## Quick Connect

On any Codeman server, open Settings -> System -> Nodes -> Native app quick
connect. The QR code encodes a `codeman://connect?...` deep link containing the
server URL and display name.

The mobile app can also add a server manually. HTTP URLs are supported for
trusted LAN or VPN hosts in internal builds; use HTTPS for internet-facing
servers.

## Native Features

The initial wrapper includes:

- server profile storage with manual entry and QR/deep-link setup
- trusted HTTP LAN access for internal builds
- native camera/photo image attachment through the existing paste-image API
- native notification permission and local notification scheduling
- native URL handling for `codeman://connect`
- Capacitor keyboard, safe-area, status-bar, splash, haptics, share, browser,
  filesystem, push-notification, and camera plugin registration

Biometric unlock is intentionally a capability placeholder until a Capacitor
8-compatible plugin is selected for both iOS SPM and Android.
