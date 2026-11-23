# RexNotch and amp-rex-hud

RexNotch is a macOS notch HUD for coding-agent activity and usage. It bundles
the `amp-rex-hud` CLI, which can also run independently in a terminal.

## Install a release

On macOS (14 or newer), install both RexNotch and the CLI:

```sh
curl -fsSL https://raw.githubusercontent.com/chrisdmacrae/rexamp/main/install.sh | sh
```

The same command installs only the CLI on Linux. On Windows, run it in Git Bash,
or download and extract the appropriate CLI ZIP from
[GitHub Releases](https://github.com/chrisdmacrae/rexamp/releases). Windows
PowerShell alone cannot run this POSIX shell installer.

The installer selects arm64 or amd64 (x64) automatically, verifies SHA-256
checksums, and installs without sudo to `~/.local/bin` and `~/Applications`.
Add `~/.local/bin` to your PATH if it is not already there. Open the Mac app
with `open ~/Applications/RexNotch.app`; it is not launched or registered to
start at login automatically.

To select a release or change the install directories:

```sh
curl -fsSL https://raw.githubusercontent.com/chrisdmacrae/rexamp/main/install.sh | \
  VERSION=v0.1.0 BIN_DIR="$HOME/.local/bin" APP_DIR="$HOME/Applications" sh
```

Rerunning updates the CLI. To update the app, quit RexNotch and remove the old
`~/Applications/RexNotch.app` first; the installer will not delete an existing app.
Checksums detect damaged downloads, not a compromised release publisher.

### macOS signing

The app is **ad-hoc signed**, with no Apple developer account or certificate
required. It is **not notarized**, so Gatekeeper may block its first launch.
If you trust the download, attempt to open it, then use **System Settings →
Privacy & Security → Open Anyway**. The installer verifies the signature but
does not bypass Gatekeeper or remove quarantine attributes.

## Settings and automatic updates

Right-click the notch and choose **Settings…** to open the native settings
window. Preferences save immediately. General controls login startup, display
selection, idle visibility, automatic question cards, and activity previews.
Notifications controls completion, failure, and input alerts, sounds, and
notification text privacy. Sources controls which agents, sessions, and usage
appear; hiding a source also silences its alerts but does not stop collection.

Automatic updates are enabled by default. RexNotch checks this repository's
latest stable GitHub Release at startup and hourly, then downloads, verifies,
replaces, and relaunches itself when a newer version is available. During the
check and update, a **download icon replaces the dinosaur on the left** and an
**activity spinner replaces the count on the right**. Settings → Updates offers
an off switch, **Check Now**, and check/error status.

Updates verify the archive's SHA-256 against `checksums.txt`, the app's bundle
identity and version, and its code signature before replacing anything. The
old app is restored if replacement or the launch command fails. These releases
are still ad-hoc signed, not notarized: checksums and signature validation
detect corruption, not a compromised GitHub release publisher. The app must
be in a writable location, not running from a disk image. Only RexNotch and
its bundled CLI update; a separate `~/.local/bin/amp-rex-hud` is unchanged.

## Rex actions

`init.lua` adds Rex actions that call `~/.local/bin/amp-rex-hud`. Load it from
`~/.config/rex/init.lua` with `dofile(os.getenv("HOME") .. "/path/to/rexamp/init.lua")`
and run `rex config reload`.

- **Shift+Cmd+H, Toggle Amp HUD** opens or closes the live HUD in a split.
- **Shift+Cmd+A, Switch to Agent…** lists agent panes in the command palette,
  with the ones that need you first, and shows the one you pick.
- **Shift+Cmd+R, Reply to Agent…** picks an agent, then offers its on-screen
  menu (such as a permission prompt) or asks for a reply and sends it.

The last two are also buttons at the bottom of the HUD.

They use `amp-rex-hud -once -json`, which reads Rex once without checking usage,
and `-cmd` to focus, choose, or reply. Showing a pane needs Remote Control on.

## Build locally

The CLI requires the Go version specified in `go.mod`:

```sh
go build -o amp-rex-hud .
go test ./...
```

The Mac app also requires Xcode command-line tools (Swift 5.9 or newer):

```sh
./notch/build.sh             # Native app, including the CLI
./notch/build.sh --universal # Apple Silicon + Intel, including a universal CLI
./notch/build.sh --install   # Native build, install, open, enable launch at login
swift test --package-path notch # Native settings and updater tests
```

## Publish a release

Push a version tag such as `v0.1.0` to run `.github/workflows/release.yml`.
To retry an unpublished release without moving its tag, use **Actions → Release →
Run workflow** on `main` and enter the existing tag. The workflow builds the
tagged source using the current workflow and `macos-latest` runner.
After all builds succeed, it creates a GitHub release with generated notes and:

- `RexNotch_macos_universal.zip` — ad-hoc signed Apple Silicon + Intel app.
- `amp-rex-hud_{darwin,linux}_{arm64,amd64}.tar.gz` — macOS and Linux CLIs.
- `amp-rex-hud_windows_{arm64,amd64}.zip` — Windows CLIs.
- `checksums.txt` — SHA-256 checksums for every archive.

The workflow needs no signing secrets; only its built-in `GITHUB_TOKEN` gets
release write access in the publishing job. Cross-platform CLI builds do not
make macOS-only integrations (desktop apps, AppleScript notifications) available
on Windows or Linux; those features still depend on the host and installed tools.
