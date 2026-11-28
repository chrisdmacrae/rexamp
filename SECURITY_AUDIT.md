# rexnotch security audit

Date: 2026-11-28 · Commit audited: `c55f57c` (main) · Scope: the whole repository (Go CLI `rex-hud`, the macOS
RexNotch app, the Amp plugin, `init.lua`, `install.sh`, `notch/build.sh`, `.github/workflows/release.yml`, `go.mod`).

I read all of the source code. I checked each finding below against the code and gave its preconditions. Ideas
that did not lead to a concrete attack are listed under [Hardening ideas](#hardening-ideas), not as findings.
This report changes no code.

## Executive summary

The local attack surface is small. The notch app and `rex-hud` talk only over a private stdin/stdout pipe
(`Bridge.swift:123-140`). Every external command runs through `exec.Command` / `Process` with an argument
vector, never a shell. The `/bin/sh -c` script in the updater gets its values as positional parameters. SwiftUI
shows agent text with `Text(String)`, which does not parse Markdown. The screen parsers can't be made to
panic or index out of range by hostile input. OAuth tokens go only to fixed HTTPS endpoints and never reach logs
or error text.

The main risk is the **software supply chain**. The self-updater installs automatically, every hour, with no
prompt. It trusts whatever is attached to the latest GitHub release: the SHA-256 manifest comes from the same
release, and the app has only an ad-hoc signature, so `codesign --verify` proves nothing about who built it. As
a result, anyone who can publish a release (a compromised maintainer account or token, any collaborator with
write access who pushes a `v*` tag, or a compromised third-party action in the release workflow) gets code
execution on every installed copy within an hour, with no user action.

Other issues: notification and notch approvals are tied to a pane and an option index, not to the prompt the
user actually saw, so they can approve a different permission request. The Amp bridge plugin serves thread data
on localhost with no authentication and no `Host` check, so a website can read it through DNS rebinding.
Released binaries are built with Go 1.26.1, which has 24 known standard-library vulnerabilities on paths the
code actually calls.

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 1 |
| Medium | 3 |
| Low | 3 |

## Findings

| ID | Severity | Title | Location |
|---|---|---|---|
| RN-01 | High | Silent auto-update trusts any GitHub release; no signature independent of GitHub | `notch/Sources/RexNotch/Updater.swift:56-88,186-239`, `Settings.swift:21`, `install.sh:45-70`, `release.yml` |
| RN-02 | Medium | Allow/Deny binds to pane + option index, not to the prompt shown, so it can approve a different request | `Notifier.swift:21-24,104-105`, `Bridge.swift:252-264,396-403`, `stream.go:190-237` |
| RN-03 | Medium | Amp bridge serves thread IDs, titles and paths unauthenticated on 127.0.0.1:7789, readable through DNS rebinding and spoofable by any local process | `plugin/amp-hud-bridge.ts:31-38`, `bridge.go:23-50` |
| RN-04 | Medium | Releases are built with Go 1.26.1, which has 24 reachable stdlib vulnerabilities (x509, TLS, HTTP/2 client) | `go.mod:3`, `release.yml:36-38,71-73` |
| RN-05 | Low | TUI prints terminal escape sequences from pane titles, program status and thread titles without filtering | `view.go:285-297,378,404,444`, `main.go:544-555` |
| RN-06 | Low | Release workflow hardening: actions not pinned to a SHA, no protected environment, installer served from `main` | `.github/workflows/release.yml:33-107`, `README.md:14,31` |
| RN-07 | Low | Window between verification and install: another admin user can swap the staged bundle in a shared `/Applications` | `Updater.swift:69-89,111-145` |

---

### RN-01 (High): Silent auto-update trusts any GitHub release; no signature independent of GitHub

**Where**
- `Settings.swift:21`: `automaticUpdates = true` by default.
- `Updater.swift:184-188`: checks at launch and then every 3600 s.
- `Updater.swift:213-239`: downloads `releases/latest`, then stages and installs the update and relaunches, with no user prompt.
- `Updater.swift:56-64`: the checksum is compared against `checksums.txt` **from the same release**.
- `Updater.swift:81-88`: the only authenticity checks are the bundle ID, the version string, and
  `codesign --verify --deep --strict`. The app is ad-hoc signed (`notch/build.sh:56`, `codesign --sign -`), so any
  self-consistent ad-hoc signature passes. The signer's identity is never pinned.
- `install.sh:45-52,70`: same model. It also downloads `install.sh` from `main` (`README.md:14`).
- `release.yml:3-6,90-107`: anyone who can push a `v*` tag, or run `workflow_dispatch`, publishes a release.

**Attack scenario.** An attacker gets the ability to create a release on `chrisdmacrae/rexnotch`: a phished or
leaked maintainer token, a collaborator account, a malicious `v*` tag pushed by any writer, or a compromised
action (`actions/download-artifact@v4` runs with `contents: write` in the release job). They publish `v99.0.0`
with a `RexNotch_macos_universal.zip` that has bundle ID `com.chrisdmacrae.rexnotch`, version `99.0.0`, an ad-hoc
signature, and a matching `checksums.txt`. Within an hour every running RexNotch downloads it, passes every
check, swaps itself out and launches the attacker's binary as the user. That binary can read the Claude and
Codex OAuth tokens that `subs.go` already reads, the keychain item `Claude Code-credentials`, SSH keys, and so on.
No user action is needed. `isNewer` also blocks a later legitimate rollback, because the attacker's version
number is the highest.

The SHA-256 manifest protects against a corrupted download, but not against a malicious one, because it comes
from the same publisher channel as the archive.

**Preconditions.** The ability to publish a release, or to tamper with one, on the GitHub repository. No access to
the victim's machine is needed.

**Recommended fix**
1. Sign releases with a key that GitHub does not hold, and verify that signature in the app before staging:
   - either a Developer ID certificate, notarization, and
     `codesign --verify --deep --strict -R='anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>"'`;
   - or an Ed25519/minisign signature over `checksums.txt`, with the public key compiled into the app and
     checked with `CryptoKit.Curve25519.Signing.PublicKey.isValidSignature`.

   Do the same in `install.sh` (for example `minisign -V` or `cosign verify-blob`).
2. Until then, consider making automatic updates *notify and ask* rather than install silently, or default
   `automaticUpdates` to `false`.
3. Protect the release path: a tag ruleset limiting who can create `v*` tags, and a GitHub Environment with
   required reviewers on the `release` job (see RN-06).
4. Pin the bundle's designated requirement or the signing-key fingerprint across updates, so an update must be
   signed by the same identity as the installed app.

---

### RN-02 (Medium): Allow/Deny binds to pane + option index, not to the prompt shown, so it can approve a different request

**Where**
- `Notifier.swift:21-24`: permission notifications get **Allow** and **Deny** action buttons.
- `Notifier.swift:102-105`: on response, the agent is looked up **again** by block ID in the current model, and
  `choose(a, option: 0)` or `choose(a, option: count-1)` is sent.
- `Bridge.swift:252-264`: a notification is posted, and an old one removed (`notifier.remove`), only when the pane's
  *state* changes. A move from blocked to blocked with a different prompt leaves the old notification in place.
- `Bridge.swift:396-397`, `stream.go:190-237`: the command sent to `rex-hud` carries only `block` and `option`.
  `rex-hud` resolves it against **its own latest** capture of the screen and sends arrow keys and Enter based on
  the *current* `Prompt.Selected`.
- With `notificationText = false` (`Notifier.swift:71-72`), the notification shows only "An agent needs your
  attention." alongside an **Allow** button.

**Attack scenario.** Claude Code asks permission for a harmless command (say `ls`), and a notification appears.
Before the user reacts, the agent's prompt changes. For example, the user approves the first prompt in the
terminal, or it is answered some other way, and the agent (possibly steered by prompt injection from content it
read) immediately asks for a second, dangerous action such as `curl … | sh` or an edit to `~/.zshrc`. Rex events
are coalesced and the HUD also polls every 15 s (`main.go:480`), so the HUD can go straight from one blocked
snapshot to the next. The stale "ls" notification stays on screen. The user clicks **Allow** on it, and
`rex-hud` approves the second request. The notch's `AskCard` has the same race over a shorter window: its buttons
send an index, and Go applies it to whatever prompt is current.

**Preconditions.** The user uses notification or notch approvals. The pane's prompt changes between display and
click without a state change being seen. Making that happen on purpose takes some influence over the agent, such
as prompt injection.

**Recommended fix.** Bind every approval to what was shown. Put a prompt fingerprint (a hash of question, options,
and preview, or the existing `askKey`) in the notification's `userInfo` and in the `choose` command. Have
`stream.go` capture the screen again and refuse the command if the fingerprint differs. When the prompt changes,
remove or replace the notification, even if the state didn't change. Don't offer **Allow** when
`notificationText` is off, and consider `UNNotificationActionOptions.authenticationRequired` for Allow.

---

### RN-03 (Medium): Amp bridge serves thread IDs, titles and paths unauthenticated on 127.0.0.1:7789, readable through DNS rebinding and spoofable by any local process

**Where**
- `plugin/amp-hud-bridge.ts:31-38`: `Bun.serve({ hostname: '127.0.0.1', port: 7789, fetch() { return Response.json({...threads}) } })`.
  The handler ignores the request entirely: no `Host` check, no token, any method or path.
- The response includes the plugin's `pid`, the 20 most recent thread IDs and titles, `tree` (the `file://`
  workspace path), and the last error text.
- `plugin/amp-hud-bridge.ts:39-41`: if the port is already taken, the plugin silently gives up.
- `bridge.go:30-50`: `rex-hud` trusts whatever answers on that port.

**Attack scenarios**
1. *DNS rebinding (remote attacker).* The user visits `attacker.example`, which first resolves to the attacker
   and then to `127.0.0.1`. Script on the page fetches `http://attacker.example:7789/`. The browser treats it as
   same-origin, and the server answers because it ignores `Host`. The page reads thread titles (often a summary of
   the user's prompt or code), local repository paths, and Amp thread IDs. If any of those threads is shared as
   unlisted or within a workspace, the ID is enough to open it on `ampcode.com`. Chrome's Private/Local Network
   Access checks reduce this in current Chrome. Safari and other browsers vary.
2. *Port squatting (local, any user).* Any process, including one from another macOS user account on the same
   machine, can bind 7789 before Amp starts. It can then feed `rex-hud` and the notch fake threads (fake "Amp
   needs you" notifications with attacker-chosen titles), and hide real ones.

**Recommended fix.** Reject requests whose `Host` header is not `127.0.0.1:<port>` or `localhost:<port>`. Require
a random bearer token written to a `0600` file under `~/Library/Application Support` (or `~/.config/amp`), and
have `rex-hud` send it. Better still, serve on a Unix domain socket in a `0700` directory. Have `rex-hud` reject
responses that don't present the token.

---

### RN-04 (Medium): Releases are built with Go 1.26.1, which has 24 reachable stdlib vulnerabilities

**Where.** `go.mod:3` says `go 1.26.1`. `release.yml:36-38,71-73` use `go-version-file: go.mod`, so release
binaries, including the `rex-hud` inside RexNotch.app, are built with exactly 1.26.1.

**Evidence.** `govulncheck ./...` (v1.10.0, with `GOOS=darwin` and default) reports **24 vulnerabilities in the
standard library that the code reaches**, through the HTTPS client in `subs.go:getJSON` and `bridge.go:fetchBridge`.
Relevant ones include:
- GO-2026-6809: distrust of compromised intermediate certificates (crypto/x509).
- GO-2026-4866: auth bypass through case-sensitive excludedSubtrees name constraints (crypto/x509).
- GO-2026-4918: infinite loop in the HTTP/2 transport (net/http).
- GO-2026-4870, GO-2026-6090: TLS 1.3 KeyUpdate and post-handshake DoS (crypto/tls).

The highest fix needed is `go1.26.11` (net/http). The scan found no reachable vulnerabilities in third-party
modules. `golang.org/x/sys v0.36.0` and `golang.org/x/text v0.3.8` have known issues, but the code doesn't call
the affected functions.

**Impact.** `rex-hud` sends the user's Claude and ChatGPT OAuth bearer tokens to `api.anthropic.com` and
`chatgpt.com`. Weaknesses in certificate validation matter most to a network attacker positioned to intercept that
traffic (hostile Wi-Fi, a corporate proxy). The DoS issues can hang the HUD.

**Recommended fix.** Set `go 1.26.11` (or the latest patch) or add a `toolchain go1.26.x` line. Run `govulncheck`
in CI, and run `go get -u golang.org/x/sys golang.org/x/text` while you're at it.

---

### RN-05 (Low): TUI prints terminal escape sequences from pane titles, program status and thread titles without filtering

**Where.** `view.go:285-297` prints `paneTask(p)` (the pane title, which any program in the pane sets with OSC 0/2)
and `p.Msg` (the program-status message, which programs set with OSC 7501 and which is **base64-encoded**, so it
can hold raw `ESC` bytes; see the encoder at `main.go:548`). `view.go:378,444,404` print Amp thread titles
(including ones from the bridge, RN-03, and from remote orbs) and Claude Desktop session names. Nothing removes
C0/C1 control characters, and `lipgloss`/`bubbletea` pass them through to the terminal.

**Attack scenario.** Something running in any Rex pane (a malicious `README` the user `cat`s, a dependency's
postinstall script, an agent tool printing attacker text), a pane on a *remote* Rex host, or a spoofed bridge
thread title sets a status message or title containing `ESC ] 52 ; c ; <base64> BEL` or other control sequences.
`rex-hud`, running in its own pane, writes those bytes to its terminal as active sequences. Depending on what Rex
supports, that can overwrite the clipboard (OSC 52), forge the HUD tab's alert state (OSC 7501), rewrite the HUD's
screen to misrepresent which agent is asking for what, or plant misleading OSC 8 hyperlinks. The impact depends on
Rex's escape handling; text that was only metadata becomes live sequences in a different pane, and can cross hosts.

**Recommended fix.** Remove control characters (`unicode.IsControl`, plus U+0080–U+009F and `\x1b`) from every
external string before rendering. `ansi.Strip` from `charmbracelet/x/ansi`, followed by a control-character filter,
works. Apply the same filter in `notify` (also see hardening item H-1).

---

### RN-06 (Low): Release workflow hardening

**Where.** `.github/workflows/release.yml`
- Lines 33, 36, 58, 68, 71, 84, 96: `actions/checkout@v4`, `actions/setup-go@v5`, `actions/upload-artifact@v4`, and
  `actions/download-artifact@v4` are pinned to movable tags, not commit SHAs. `download-artifact` runs in the job
  that holds `contents: write` and publishes the assets that RN-01 then installs automatically.
- Lines 90-95: the `release` job has no `environment:` with required reviewers. Any `v*` tag push publishes.
- `setup-go@v5` enables the Go module/build cache by default (lines 36, 71). Cache entries are shared across refs
  of the repository, so a poisoned cache would flow into release builds.
- `README.md:14,31`: users run `install.sh` from the `main` branch, so a push to `main` changes what new installs run.

Good: top-level `permissions: contents: read`, `contents: write` only on the job that publishes, and no
`pull_request_target`. `${{ inputs.tag }}` reaches scripts only through `env:` and quoted `"$RELEASE_TAG"`, so a
crafted tag can't inject shell code.

**Recommended fix.** Pin all actions to full commit SHAs (Dependabot can keep them updated). Put the release job in
a protected environment. Add a tag ruleset for `v*`. Set `cache: false` on setup-go in the release workflow. Point
the README at `install.sh` from a release asset or tag, or publish its checksum.

---

### RN-07 (Low): Window between verification and install in a shared `/Applications`

**Where.** `Updater.swift:74-89` creates the staging directory `.rexnotch-update-<UUID>` next to the installed app,
extracts the archive and verifies it there. Then `replacementProcess` (`Updater.swift:115-145`) waits for the app to
exit and runs `mv "$work/RexNotch.app" "$target"`. The bundle is verified once and moved later, from a location
writable by others.

**Attack scenario.** When RexNotch is in `/Applications` (`root:admin`, mode `0775`, no sticky bit), *another*
admin-group user on the same Mac can watch for the staging directory. After `codesign --verify` succeeds, they
rename it away and put their own directory, with their own `RexNotch.app`, at the same path. The victim's helper
then moves the attacker's bundle into place and launches it as the victim. In `~/Applications` this is not
possible.

**Preconditions.** A shared Mac with a second, hostile, admin-group account, and the app installed in
`/Applications`.

**Recommended fix.** Stage in a private directory created with `0700` (for example `FileManager.url(for:
.itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)`). Check ownership and
mode before the move. Better, have the helper verify the bundle's code signature (with the pinned requirement
from RN-01) immediately before `mv`.

---

## Hardening ideas

None of these led to a concrete attack in my review. They are worth doing for defence in depth.

- **H-1 Notification AppleScript built by formatting a string (`main.go:553`).** `display notification %q …`
  relies on Go's `%q` quoting matching AppleScript's string syntax. Go escapes `"` and `\`, so I found no way to
  break out of the string. But Go writes `\x..` / `\u....` escapes for non-printable characters, which AppleScript
  rejects, so notifications with such characters are silently dropped. Pass the values as arguments instead:
  `osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title (item 2 of argv) subtitle (item 3 of argv)' -e 'end run' -- body title subtitle`.
- **H-2 Empty `PATH` element (`main.go:44-47`).** When `REX_BIN_DIR` is unset, the joined `PATH` contains `::`,
  which means the current directory. Go ≥1.19's `exec.ErrDot` stops this from running a binary in the current
  directory, but drop empty entries anyway.
- **H-3 `AMP_HUD_BRIDGE_PORT` is pasted into a URL (`bridge.go:24-26`).** A value like `1@evil.example` turns the
  URL into `http://127.0.0.1:1@evil.example`. Parse the value as an integer.
- **H-4 Updater URL checks (`Updater.swift:35-44`).** `url.path.hasPrefix(...)` does not normalize `..` or
  percent-encoded slashes. Compare standardized path components instead. The `/chrisdmacrae/rexamp/` allowance is
  unnecessary, since the API is queried under the current name. Also check `resp.url` after redirects (GitHub
  redirects to `objects.githubusercontent.com`; pin that host too).
- **H-5 `install.sh` curl flags.** Use `curl --proto '=https' --tlsv1.2` so a redirect can never fall back to
  plain HTTP.
- **H-6 Remote Rex hosts supply IDs that become argv (`rex.go:292,318,470-477`, `stream.go:216-230`).** A
  malicious remote host could return a `block_id` starting with `-`. Most uses follow `-s` or `-b` and are consumed
  as values, but `rex focus -s <sid> <block>` takes the block as a positional argument. Insert `--` or reject IDs
  that start with `-`.
- **H-7 Force-unwrapped URL (`Bridge.swift:412`).** `URL(string: "https://ampcode.com/threads/\(t.id)")!` with a
  bridge-supplied ID (RN-03). Percent-encode the ID, restrict it to `^T-[0-9a-f-]{36}$`, and don't force-unwrap.
- **H-8 Choosing a menu option with relative arrow keys (`stream.go:475-484`).** Which keys get sent depends on
  the *parsed* highlighted row. If parsing ever picks up a numbered list from agent output instead of the real menu,
  "Deny" could turn into "Enter on the default (Yes)". Before sending, check that the highlighted label matches the
  expected option, or use digit keys where the agent supports them.
- **H-9 `REXNOTCH_HUD` environment override (`Bridge.swift:112`).** It runs any executable. This is acceptable
  for development, but consider honouring it only in debug builds.
- **H-10 Notch panel and keyboard default action (`Views.swift:685-691`, `main.swift:36-38`).** The panel can
  become key and **Allow** is `.defaultAction`, so Return approves. Make sure a newly shown AskCard never takes key
  focus while the user is typing elsewhere, or require a click for permission prompts.

## Checked and found OK

- **Bridge between the app and the CLI.** It is a private pipe to a child process (`Bridge.swift:123-140`), with
  no socket, file or port. Commands are JSON, and `rex-hud` acts only on agent panes it found itself
  (`stream.go:190-199`). `reply` turns newlines into spaces and passes the text after `--` in argv.
- **Command execution.** Every `exec.Command`/`Process` call uses an argument vector. The updater's `sh -c`
  script uses only positional parameters, all quoted. The sqlite query in `desktop.go` is a constant apart from an
  integer.
- **Secrets.** OAuth tokens are read from the keychain or files and sent only to fixed HTTPS hosts. `cmdError`
  contains argv and stderr, never stdout, so `security … -w` output never reaches error text.
- **Parsers** (`stream.go`, `fm.go`, `amp.go`, `subs.go`, `desktop.go`, `proctree.go`): no panics on hostile
  input. Indexing is guarded, scanners have bounded buffers, and rollouts are read from the last 512 KiB.
- **UI rendering.** SwiftUI `Text(String)` is verbatim, with no Markdown or link parsing of agent text.
- **Temp files.** `install.sh` and `build.sh` use `mktemp -d` with trap cleanup. The updater uses a UUID-named
  directory (see RN-07 for the shared-directory case).
- **CI.** No `pull_request_target`, minimal token permissions, no `${{ }}` inside `run:` scripts.
