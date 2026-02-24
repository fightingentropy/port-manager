# Port Manager

Native macOS SwiftUI app for:

- Scanning and managing local listening ports
- Starting/stopping dev servers
- Routing named `.localhost` hosts to your running dev servers (portless-style)
- HTTP local proxying

## Features

- Stable route names via proxy host routing
- Per-server dynamic backend port assignment (`4000-4999`)
- Built-in HTTP reverse proxy on `:1355` (no sudo needed)
- Dev server manager with start/stop and quick-open links
- Port scanner + process termination tools
- Menu bar mode support
- Update checker (manual + auto-check on launch)

## Requirements

- macOS
- Xcode command line tools (`swiftc`, `iconutil`)

## Build

```bash
cd /Users/erlinhoxha/Developer/port-manager
./build.sh
```

Build output: `build/PortManager.app`

## Run

Run normally (no root required in current default mode):

```bash
open /Users/erlinhoxha/Developer/port-manager/build/PortManager.app
```

## Install to Applications

```bash
sudo rm -rf /Applications/PortManager.app
sudo cp -R /Users/erlinhoxha/Developer/port-manager/build/PortManager.app /Applications/PortManager.app
open /Applications/PortManager.app
```

## Usage

1. Open **Dev Servers** tab.
2. Add a server:
   - `Name`
   - `Route name` (for example `netflix`)
   - `Working directory`
   - `Command` (for example `bun run dev`)
3. Start proxy.
4. Start server.
5. Access your app at:
   - `http://<name>.localhost:1355`

Example:

- `http://netflix.localhost:1355`

## No-Port URLs (Optional)

By default, browser requests without a port go to `:80`, while PortManager listens on `:1355`.

You can add a one-time macOS `pf` redirect so this works:

- `http://netflix.localhost` (no port) -> redirected to `127.0.0.1:1355`

### Enable

```bash
sudo cp /etc/pf.conf /etc/pf.conf.backup.portmanager-np

sudo sed -i '' '/portmanager/d' /etc/pf.conf

sudo awk '
BEGIN { inserted=0 }
{
  print
  if (!inserted && $0 ~ /^rdr-anchor "com.apple\/\*"/) {
    print "rdr pass on lo0 inet proto tcp from any to any port 80 -> 127.0.0.1 port 1355"
    print "rdr pass on lo0 inet6 proto tcp from any to any port 80 -> ::1 port 1355"
    inserted=1
  }
}
' /etc/pf.conf | sudo tee /etc/pf.conf >/dev/null

sudo pfctl -nf /etc/pf.conf
sudo pfctl -f /etc/pf.conf
sudo pfctl -e
```

### Verify

```bash
lsof -nP -iTCP:1355 -sTCP:LISTEN
curl -I http://localhost
curl -I http://netflix.localhost
```

Expected:

- `localhost` may return `404` from PortManager (normal if no `localhost` route exists)
- Your named host should return your app response

### Undo

```bash
sudo cp /etc/pf.conf.backup.portmanager-np /etc/pf.conf
sudo pfctl -f /etc/pf.conf
```

Notes:

- The app injects these vars into started server processes:
  - `PORT`
  - `HOST=127.0.0.1`
  - `PORTLESS_PORT`
  - `PORTLESS_HOSTNAME`

## App Updates

Settings includes:

- `Check for Updates` button
- `Install Update` button (downloads release asset, replaces app in `/Applications`, relaunches)
- `Auto-check for updates` toggle (enabled by default)
- Configurable GitHub releases API URL

Default feed URL:

`https://api.github.com/repos/fightingentropy/port-manager/releases/latest`

## Menu Bar Mode

The app uses a shared dev-server manager instance to avoid duplicate proxy startup attempts between main window and menu bar popover.

## Troubleshooting

### `Address already in use`

Another process is bound to `:1355`.

```bash
lsof -nP -iTCP:1355 -sTCP:LISTEN
```

### App launches but dev server route fails

Check proxy is running and server status is `Running` in the Dev Servers tab.

### Want localhost without `:1355`

That requires binding `:80` (root) or OS-level redirecting. Current default mode is non-privileged `:1355`.

## Project Files

- `PortManager.swift`
- `build.sh`
- `Info.plist`
- `AppIcon.icns`
