# SSH via libghostty — Handover for the M1–M6 loop

Read this on M1 startup. It carries the audit findings + design context the `/loop`
prompt couldn't fit in 4000 chars. Source-of-truth for behavior is always the code;
this doc captures the *why* and points at the right file:lines.

## Goal (recap)

Make `cmux ssh user@host` actually use libghostty's native SSH path:
ghostty-daemon uploaded on first connect, persistent remote sessions, new terminals
attach via SSH channels (not local PTY), browser proxy works end-to-end, cmux relaunch
reattaches by `groupID`. Concretely: M1–M6 (tasks #10–#15) → M6 smoke test passes.

## Root cause of every symptom

`ghostty_ssh_open` in `ghostty/src/apprt/embedded/ssh_capi.zig:1096` acquires the
`SshConnectionManager.Entry` and registers `onStateListener` — **but never spawns
the SSH I/O thread**. The GTK path spawns it inside `attachRemoteSurface` at
`ghostty/src/session/client.zig:916`. Without that thread, the connection state
machine never reaches `.connected`, so `onStateListener` (at `ssh_capi.zig:800-836`)
never calls `wireMuxTransport`, so `SshHandle.client_mux` stays nil forever.

Everything downstream then dies at the "no mux → SERVICE_ERROR" guards:
- `ghostty_ssh_open_channel:1448` — browser proxy + port forward channels.
- `ghostty_ssh_attach_surface:1618` — terminal session channels (separately stubbed; needs M3).

Net: **no daemon upload, no remote PTY, no working browser proxy**. The "remote shell"
you see today is system `/usr/bin/ssh` running in a bash `initial_command` — the
libghostty SSH path is dead-on-arrival.

## Architecture map

- **GTK path** (`ghostty/src/apprt/gtk/`): functional. Spec: `ghostty/SSH_REMOTE_SESSIONS.md`.
  Calls `session.client.attachRemoteSurface` directly — that helper does
  auth + daemon provisioning + opens mux channel + sets up pipes + spawns ssh_thread.
- **Embedded path** (`ghostty/src/apprt/embedded/ssh_capi.zig`): partially stubbed.
  Designed for non-blocking C API (cmux/macOS). Needs worker-thread spawn for any
  call that would otherwise block the embedder.
- **Reference pattern for worker spawns**: `ghostty_ssh_list_sessions` at
  `ssh_capi.zig:1666` (active_workers counter, defer-extract-alloc-before-fetchSub).
- **cmux Swift bridge** (built but idle until embedded path works):
  `Sources/WorkspaceSSHIntegration.swift`, `SessionBridge.swift`,
  `RemoteProxyTunnel.swift`, `PortForwardHandle.swift`, `Workspace.swift`
  (`configureRemoteConnection`, `handleSSHConnectionState`, `restoreSessionSnapshot`).

## Per-milestone notes

### M1 (task #10) — SSH thread spawn in ghostty_ssh_open

**Design (locked):** extract `setupConnection` from `attachRemoteSurface` at
`ghostty/src/session/client.zig:782-918`. Move out:
- `connectWithAuth` loop (lines 796-846)
- `ensureRemoteGhostty` (848-851)
- `ensureRemoteDaemon` (857-866)
- `openMultiplexChannel` (873-880)
- session.setBlocking(0) + entry.channel assignment (882-888)
- reconnect knob stamping (890-895) — but ssh_capi.zig already does this; pick one source of truth
- 3× `posix.pipe2` (899-913)
- `std.Thread.spawn(.{}, SshConnectionManager.sshThreadMain, .{entry})` (916-917)

Keep `attachRemoteSurface` calling `setupConnection` when `entry.ssh_thread == null`,
then doing the surface-attach part — **GTK signature/behavior unchanged**.

In `ghostty_ssh_open` (ssh_capi.zig:1096-1203), after `entry` is acquired
and listener is registered (line 1187 area), spawn a worker that calls
`setupConnection`. Use the active_workers pattern from `ghostty_ssh_list_sessions`.

Verify: `ghostty_ssh_open` returns immediately; embedder sees `.connecting` →
`.uploading` → `.connected` via the state stream within ~10–30s on a real host.

### M2 (task #11) — open_channel after M1

Once M1 lands, `client_mux` is populated on `.connected`. The early-return at
`ssh_capi.zig:1448` either becomes unnecessary or needs to handle "not yet connected"
cleanly. Options:
- Remove the guard if mux is guaranteed (it isn't — embedder could call before .connected).
- Keep the guard but distinguish "not connected yet" (a retryable error) from a true
  service error. Recommend a new ChannelCloseReason variant or surface via state.
- Queue the open until `.connected`. Probably overkill — embedders should wait for
  state themselves.

Cleanest: keep the guard but document it. Embedder discipline (cmux already waits for
`.connected` in `handleSSHConnectionState`).

### M3 (task #12) — attach_surface implementation

`ghostty_ssh_attach_surface:1618` currently ignores all params and emits
SERVICE_ERROR. Per the in-file TODO, spawn a worker that calls
`session.client.attachRemoteSurface(alloc, mgr, entry, null, cfg)`. Build
`AttachConfig` from the C params (rows, cols, width_px, height_px, label, plus
the connection-level knobs already on the Entry).

If M1 already extracted `setupConnection`: `attachRemoteSurface` will see
`entry.ssh_thread != null` and skip the setup, going straight to the surface-attach
part. So M3 worker is much simpler than the pre-refactor version.

Verify: `attachSurface` returns a handle that fires `onReady` (channel open), then
`onOutput` deliveries when remote echoes input. `on_close` only fires on real channel
close, not immediately.

### M4 (task #13) — cmux surface integration

Three independent sub-pieces. Pick PTY-relay for terminals (Section 6 audit decision):

1. **Terminal**: when creating a terminal surface in a remote workspace, instead of
   letting Ghostty spawn a local PTY, do:
   - `openpty()` to get master+slave FDs.
   - Pass slave FD path as the surface's `command` (or a noop command bound to that pty).
   - Wire `SessionBridge.onOutput` → `write(masterFd, bytes)`.
   - Wire terminal resize → SIGWINCH on master + `SessionBridge.resize(size)`.
   - Wire keystrokes: today Ghostty surfaces send to their PTY; the slave being the
     pty we control means our master read loop forwards bytes via `SessionBridge.send`.
   - Hook into `Workspace.newTerminalSurface(...)` at `Sources/Workspace.swift:5282`.

   Alternative we explicitly rejected (Section 6): extend the libghostty C API with
   `ghostty_surface_inject_bytes` to skip the PTY pair. Larger upstream change for
   a smaller cmux footprint. Revisit if PTY-relay quirks emerge.

2. **Browser**: `RemoteProxyTunnel.acceptConnection` already opens
   `Ghostty.SSHChannel<BrowserProxyService>`. Once M2 returns live channels, the
   byte-pump loop in `RemoteProxyTunnel.swift:152-470` should already work — verify
   with `curl --socks5 localhost:<port> https://ifconfig.me`.

3. **Port forward**: `PortForwardHandle` already opens
   `Ghostty.SSHChannel<PortListenerService>` and exposes inbound `tcp_accepted`
   channels via `connection.inboundChannels`. Pump each accepted channel to a local
   `NWConnection`. Should already work after M2.

### M5 (task #14) — session restore

`SessionRemoteWorkspaceSnapshot` at `Sources/WorkspaceRemoteConfiguration.swift:63`
already has `groupID: UUID?`. But `SessionTerminalPanelSnapshot` at
`Sources/SessionPersistence.swift:~1039` has **no per-surface remote ID**. Steps:

1. Add `remoteSurfaceID: UUID?` to `SessionTerminalPanelSnapshot` (the daemon-side
   surface UUID — same one passed to `attachSurface` originally).
2. At terminal creation, capture the `surfaceID` you passed to `attachTerminal` and
   store it in the panel snapshot when persisting.
3. In `Workspace.createPanel(from: snapshot, ...)` (`Sources/Workspace.swift:863`),
   after `newTerminalSurface` returns the new panel, if `isRemoteWorkspace` and
   `snapshot.terminal?.remoteSurfaceID != nil`, call `sshIntegration?.attachTerminal(
   groupID: remoteConfiguration.groupID, surfaceID: stored, ...)` to reattach.
4. The daemon recognizes the groupID+surfaceID pair and replays the layout + VT
   scrollback. cmux just renders the bytes that come back.

Also wire `RemoteSessionSyncCoordinator` (`Sources/RemoteSessionSyncCoordinator.swift`)
to update tab labels/colors from daemon-side session metadata.

### M6 (task #15) — smoke test

Detailed checklist already in the /loop prompt and task description. Key checks
that catch regressions:
- `ps -ef | grep -i ssh` shows NO child `/usr/bin/ssh` under `cmux DEV` (rules out
  the bash-bootstrap fallback).
- `ghostty +ssh-session --list --ssh dev@atlas-dev` shows the session "attached".
- After relaunch, same groupID present and "attached" again (proves reattach, not
  fresh session).

## Design unknowns / escalation points (audit Section 7)

If you hit any of these, pause the loop and ask:

1. **Password retry policy.** When `attachRemoteSurface` returns `password_required`
   and the embedder doesn't provide a password within reasonable time — fail or
   wait indefinitely? GTK auto-cancels on overlay close; embedded has no overlay.
2. **Scrollback rendering on reattach.** Daemon streams full scrollback as
   ESC sequences on attach. Does cmux render the whole stream (visible flicker) or
   skip it (lose history)? GTK renders it. Probably right call.
3. **Connection-only workspaces.** If user creates a remote workspace with only a
   browser panel (no terminals), should the connection still come up? With the
   M1-locked design (eager setupConnection from `ghostty_ssh_open`): yes
   automatically. With "lazy on first attach": no. Confirms eager is right.
4. **PTY-relay quirks.** TTY ioctls Ghostty expects on its PTY (TIOCGWINSZ, termios
   raw mode, signal forwarding) may not pass through cleanly when cmux owns the
   master. If terminal weirdness shows up in M4 verification, this is the first
   suspect.

## File:line index (quick reference)

| What | Where |
|---|---|
| Embedded SSH C API exports | `ghostty/src/apprt/embedded/ssh_capi.zig` |
| `ghostty_ssh_open` | `ssh_capi.zig:1096` |
| `ghostty_ssh_open_channel` (SERVICE_ERROR guard at :1448) | `ssh_capi.zig:1424` |
| `ghostty_ssh_attach_surface` (SERVICE_ERROR stub at :1654) | `ssh_capi.zig:1618` |
| Worker-spawn reference (active_workers pattern) | `ssh_capi.zig:1666` |
| `onStateListener` (wires `client_mux` on `.connected`) | `ssh_capi.zig:800-836` |
| ChannelHandle definition + mux fields | `ssh_capi.zig:435-628` |
| `attachRemoteSurface` (the GTK helper to refactor for M1) | `ghostty/src/session/client.zig:782-918` |
| `sshThreadMain` | `ghostty/src/termio/SshConnectionManager.zig:552` |
| `ClientMux` | `ghostty/src/session/channel_mux.zig` |
| Daemon binary provisioning | `ghostty/src/session/client.zig:268-328` |
| cmux SSH workspace creation | `cmux/Sources/Workspace.swift:5282` (`newTerminalSurface`) |
| cmux `configureRemoteConnection` | `cmux/Sources/Workspace.swift:4531` |
| cmux `handleSSHConnectionState` | `cmux/Sources/Workspace.swift:4620` |
| cmux `restoreSessionSnapshot` | `cmux/Sources/Workspace.swift:212` |
| cmux SessionBridge (consumer of attachSurface) | `cmux/Sources/SessionBridge.swift` |
| cmux WorkspaceSSHIntegration (owns SSHConnection) | `cmux/Sources/WorkspaceSSHIntegration.swift` |
| cmux SessionRemoteWorkspaceSnapshot (has groupID) | `cmux/Sources/WorkspaceRemoteConfiguration.swift:63` |
| cmux SessionTerminalPanelSnapshot (needs remoteSurfaceID for M5) | `cmux/Sources/SessionPersistence.swift:~1039` |
| Spec | `ghostty/SSH_REMOTE_SESSIONS.md` |

## Build commands

```sh
# ghostty macOS embedded
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast

# ghostty GTK (regression check — must keep passing)
cd ghostty && zig build -Dapp-runtime=gtk

# ghostty SSH tests
cd ghostty && zig build test -Dtest-filter=ssh

# cmux tagged debug build
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" ./scripts/reload.sh --tag ssh-loop --launch
```

zig 0.15.2 lives at `/opt/homebrew/opt/zig@0.15/bin/zig` (keg-only).
Plain `zig` on PATH is 0.16.0 which fails the build-script version check.

## Pre-loop session deliverables (already on disk)

Work landed in the session that spawned this loop, not part of M1–M6:
- SSH connect modal sheet + color picker + ⌘⇧S shortcut
- bonsplit `onTabCloseRequest` 3-arg signature fix (`Workspace.swift:2925`)
- `CmuxSSHConfigDefinition` schema in cmux.json + `CmuxResolvedSSHConfig.builtIn`
- `maxReconnectAttempts` default flipped 0 → 5 (auto-reconnect now active)

Do **not** revert any of those. The loop's API additions should layer on top.
