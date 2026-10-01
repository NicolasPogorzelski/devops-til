# Game Streaming Stutter: Measure Every Hop

Streaming games from the Bazzite gaming PC to a TV through [Sunshine and Moonlight](../glossary.md#sunshine-and-moonlight)
stuttered, while every overlay said "60 FPS". It took one evening and five independent
causes to get a clean stream. The lesson is not any single fix - it is that an average
at one point in a pipeline says nothing about the hops before or after it.

Official documentation used:

- Sunshine: <https://docs.lizardbyte.dev/projects/sunshine> - "Configuration" (`capture`,
  `encoder`, `global_prep_cmd`, `system_tray`) and the GitHub release notes.
- Moonlight Android: <https://github.com/moonlight-stream/moonlight-android> - settings
  and the performance overlay.
- MangoHud: <https://github.com/flightlessmango/MangoHud> - README, config table
  (`fps_limit`, `fps_limit_method`, `log_interval`, `autostart_log`).
- Sunshine source, tag `v2026.914.233613`: `src/platform/linux/misc.cpp` (RTKit, `setpriority`),
  `src/platform/linux/graphics.cpp` (`CAP_SYS_NICE` for high-priority GPU contexts),
  `src/platform/linux/pipewire.cpp` (HDR over PipeWire), `docs/troubleshooting.md`.
- GNOME 50 release notes: HDR screen sharing (BT.2020 + PQ over PipeWire).
- `man 5 systemd.service` (`ExecStartPre=`, the `-` prefix), `man 7 capabilities`, `man 8 setcap`,
  `man 8 ld.so` (`LD_LIBRARY_PATH`).

---

## The pipeline, and where each hop can be measured

```
game -> display output -> Sunshine (capture + encode) -> network -> Shield (decode + display) -> TV
```

| Hop | Tool | What it proves |
|---|---|---|
| Game | MangoHud log with `log_interval=0` (one row per frame) | Frame *pacing*, not just average FPS |
| Sunshine | `journalctl --user -u <sunshine unit>` | Requested frame rate, prep commands, crashes |
| PC network card | `ip -s -s link show <if>` (TX packets, drops) | What left the host |
| Shield network card | `adb shell cat /proc/net/dev` (RX packets) | What arrived |
| Shield app | `adb shell cat /proc/net/snmp` ([UDP](../glossary.md#udp) `RcvbufErrors`), `adb logcat` | Socket overflow, lost frames |
| What the viewer sees | Moonlight performance overlay via `adb exec-out screencap -p` | Host FPS vs received vs rendered |

[ADB](../glossary.md#adb-android-debug-bridge) turned the Shield from a black box into a
second measuring point. Without it, every hypothesis about the client side was a guess.

---

## Cause 1 - Wi-Fi instead of LAN

The Shield was assumed to be wired. `ip route get <lan-ip-gaming-pc>` on the Shield said
`dev wlan0`, and `eth0` reported `NO-CARRIER`. After re-plugging, `logcat` showed the link
flapping (`interfaceLinkStateChanged ... up: true`, one second later `up: false`) until the
cable was found loose **at the switch end**.

**Pattern:** a stated fact about the setup ("it is on LAN") is a claim; the routing table
is evidence. Same shape as
[Tailscale Exit Nodes](../networking/tailscale-exit-nodes.md): a stored belief about the
past versus what the system reports now.

## Cause 2 - packet loss where 2.5 Gbit/s meets 1 Gbit/s

With both ends wired, the overlay still showed 5-19 % of frames "dropped by the network".
Counting packets over the same 15 seconds at both network cards:

| | 2.5 Gbit/s link on the PC | PC forced to 1 Gbit/s |
|---|---|---|
| PC sent (TX) | 200 152 | 202 739 |
| Shield received (RX) | 190 748 | 202 762 |
| Missing | ~9 400 (~4.7 %) | 0 |

Neither card reported a single error or drop. The loss happened in between: the PC's port
is 2.5 Gbit/s, the Shield sits behind a 1 Gbit/s switch. Sunshine sends each video frame as
a burst at line rate, and the device that steps down from 2.5 to 1 Gbit/s has to buffer
what it cannot forward yet. A small buffer overflows and drops the tail of the burst -
a [microburst](../glossary.md#microburst) - silently, because dropping is correct behaviour
for a switch.

Test that confirmed it (non-persistent, reverts on reboot):

```bash
sudo ethtool -s enp14s0 speed 1000 duplex full autoneg on   # advertise only 1 Gbit/s
sudo ethtool -s enp14s0 speed 2500 duplex full autoneg on   # revert
```

`autoneg on` keeps negotiation and only restricts what is advertised; forcing a speed with
negotiation off can fail to link at all. Permanent fix: plug the PC into a 1 Gbit/s port,
ideally the same switch as the Shield, so no hop steps down.

**Pattern:** "no errors at either end" does not mean "no loss". Count at both ends of the
same interval and subtract - the difference locates the loss. Same layer-separation idea as
`tcpdump` in [Tailscale Debugging](../networking/tailscale-debugging.md).

## Cause 3 - 60 FPS average, uneven delivery

MangoHud showed a steady 60. The per-frame log did not:

| | Before | After `fps_limit=60`, `fps_limit_method=early` |
|---|---|---|
| Frames < 15.5 ms (too early) | 33.7 % | 0 % |
| Frames > 17.9 ms (missed the 60 Hz slot) | 27.4 % | 2.5 % |
| Frame-to-frame jump > 4 ms | 43.2 % | 0.9 % |

Frames alternated around 13 ms and 20 ms. On the monitor this was invisible: the monitor has
[VRR](../glossary.md#vrr-and-vsync), so it waits for each frame. The stream target is an
[HDMI dummy plug](../glossary.md#hdmi-dummy-plug) at a fixed 60 Hz without VRR, and Sunshine
captures it on its own clock - uneven frames become duplicated and skipped frames in the
stream. Frames arriving faster than 16.7 ms also proved the game's own VSync was not holding
the cadence on its way to the display. [Frame pacing](../glossary.md#frame-pacing) was the
problem, not frame rate.

`early` makes the limiter sleep before the frame is started, which gives the most even
intervals; `late` sleeps after rendering, which keeps latency lower. For a fixed-rate capture,
evenness wins.

**Pattern:** an average hides the distribution. A one-second FPS counter cannot show a
single 30 ms frame every few seconds, which is exactly what a viewer perceives as a hitch.

## Cause 4 - the client asked for 59 FPS

After the network was clean, Sunshine still sent 59 frames per second in every test - desktop
or game, either encoder, dummy at 60 or 120 Hz. Two tests aimed at the host (120 Hz on the
dummy, [portal capture](../glossary.md#xdg-desktop-portal-screencast) instead of
[KMS](../glossary.md#kms-capture)) changed nothing. The answer was in Sunshine's own log:

```bash
journalctl --user -u app-dev.lizardbyte.app.Sunshine.service --since today | grep "Minimum FPS"
```

Sunshine sets its minimum FPS target to half of what the client requests, rounded down.
`~30fps (33.3333ms)` means 60 was requested; `~29fps (34.4828ms)` means 59. From one reconnect onwards, Moonlight had requested 59.
The Shield's default display mode is 59.94 Hz (kept because other video apps on it need that mode);
when Moonlight does not switch the TV to 60.000 Hz before the stream, it rounds down, and a
59 FPS stream on a 60 Hz display repeats one frame per second. Reconnecting fixed it; the
check above detects it.

**Wrong assumption, stated:** "Sunshine sends 59, so Sunshine drops a frame" is intuitive and
was wrong. The first line of the Moonlight overlay (host FPS) and the requested rate in the
host log must be read together before blaming capture or encoder. Two changes (switching the encoder to
[VA-API](../glossary.md#va-api-and-vulkan-video), portal capture) were made on that wrong premise
and reverted. Portal capture came back later - for a different, measured reason (cause 5).

## Cause 5 - the capture itself costs display refreshes

With network, client and requested rate clean, the game still hitched about once every four
seconds, mostly in fast camera pans. The test that isolated it used the simplest possible
client - `mangohud vkcube --wsi wayland`, a spinning cube at 12 % GPU load - on the dummy
plug while streaming, and paused Sunshine for five seconds twice with `kill -STOP` /
`kill -CONT` (the process freezes, it is not killed; the stream freezes and resumes):

| vkcube, missed refreshes (> 20 ms) per second | |
|---|---|
| KMS capture, Sunshine with `cap_sys_nice` | 0.80 |
| KMS capture, `cap_sys_nice` removed | 0.41 |
| Sunshine paused (no capture at all) | 0.25 |
| **Portal capture** | **0.28** |

Misses came in pairs (~30 + 33 ms): the [compositor](../glossary.md#compositor) skipped two
refreshes in a row, a ~50-65 ms freeze. [KMS capture](../glossary.md#kms-capture) reads the
scanout buffer on Sunshine's own clock and converts it on the same GPU. With `cap_sys_nice`,
Sunshine creates that GPU context at **high priority** (source: `graphics.cpp`), while GNOME's
compositor runs at normal priority - the capture preempts the compositor right before a
refresh. The Sunshine docs only need `CAP_SYS_NICE` for EGL-based encoders; with Vulkan
encoding it is not required.

[Portal capture](../glossary.md#xdg-desktop-portal-screencast) reverses the direction: GNOME
pushes each finished frame through PipeWire ("variable rate capture"), and Sunshine re-paces it
to the stream rate ("Sunshine frame pacing: enabled (16.666666ms)"). The residual 0.25/s exists
without Sunshine too - it is GNOME on the dummy plug, not the capture.

In the game: 0.25/s with KMS, 0.12/s with portal, 0.10/s with the dummy at 120 Hz (within
noise of 60 Hz, no extra GPU load, subjectively smoother). At 120 Hz a missed refresh costs
8.3 ms instead of 16.7 ms, so a 60 FPS frame is usually still in place for the next capture.
The game stays capped at 60 FPS.

**Wrong assumption, stated:** "the game drops frames" was measured and wrong. A trivial client
on the same output missed more refreshes than the game. Before tuning an application, run a
known-good one through the same path.

### What portal capture needs here

The first attempt failed: the consent dialog lists only active monitors, the grant is bound to
the monitor chosen, and the prep command then disabled that monitor (`RemoteDesktop Start
failed`, `Could not find display with name: ''`). The fix is structural - **the dummy plug
exists in every layout**:

| Layout | Monitors |
|---|---|
| desk | `DP-1` primary + dummy at 60 Hz left of it, shifted down (invisible second monitor) |
| stream | dummy only, 4K 120 Hz, HDR (`bt2100`) |

Only `DP-1` comes and goes; the granted monitor never disappears, so the grant (stored in
`~/.config/sunshine/portal_token`) survives every switch. GNOME 50 shares HDR over PipeWire
when the shared monitor is in HDR mode, and Sunshine reports `Color coding: HDR (Rec. 2020 +
SMPTE 2084 PQ)`. Trade-off: at the desk the pointer and windows can wander onto the invisible
dummy.

---

## Making it hands-off

### Per-context FPS limit

| Context | Display | Limit | Why |
|---|---|---|---|
| Streaming | dummy plug, 120 Hz, no VRR | 60, `early` | Even delivery for a fixed 60 FPS stream |
| Desk | 75 Hz monitor with VRR | 72, `late` | VRR absorbs uneven frames; stay below the VRR ceiling; lowest latency |

Two scripts in `dotfiles/scripts/workstation/sunshine/`: `sunshine-display-mode.sh` holds every
display layout, `mangohud-fps-mode.sh` rewrites `fps_limit`/`fps_limit_method` in every
MangoHud config. Sunshine runs both through `global_prep_cmd`:

```json
[{"do":"sunshine-display-mode stream","undo":"sunshine-display-mode desk"},
 {"do":"mangohud-fps-mode stream","undo":"mangohud-fps-mode desk"}]
```

Games that do not load MangoHud are not covered and would run at 120 FPS on the 120 Hz dummy;
cap those in-game.

Prep commands run in order on connect and in reverse order on session end. They are
executed directly, not through a shell, so `&&` chaining does not work - add a second entry
instead. MangoHud watches its config file, so a running game picks up the new limit live.

### The undo that never runs

Sunshine beta 2026.611 crashed six times in one day (`coredumpctl list sunshine`), always while stopping or ending a
session - before `undo` ran. The desk monitor stayed dark and the limit stayed at 60. Two
layers fixed it:

1. **Safety net** - a [systemd drop-in](../glossary.md#drop-in-systemd) restores the desk
   state on every Sunshine start, because at start no client can be connected:
   ```ini
   [Service]
   ExecStartPre=-%h/.local/bin/sunshine-display-mode desk
   ExecStartPre=-%h/.local/bin/mangohud-fps-mode desk
   ```
   The `-` prefix makes a failing command non-fatal: a restore that cannot run (monitor off)
   must never stop the streaming host from starting. That is a deliberate fail-open gate,
   the opposite choice to the readiness gates in
   [systemd Service Hardening](../linux/systemd-service-hardening.md). `%h` expands to the
   user's home in user units. The crash itself is recovered by `Restart=` in the unit;
   this drop-in makes the restart also restore state.

   **The first version never worked, and the `-` hid it.** `gdctl` is a Python script run by
   `/usr/bin/python3`. The unit exports [`LD_LIBRARY_PATH`](../glossary.md#ld_library_path)
   pointing at Homebrew's `lib/`, so the system interpreter loaded Homebrew's
   `libpython3.14.so` and lost the system `gi` module (`ModuleNotFoundError: No module named
   'gi'`). Reproduced with `env LD_LIBRARY_PATH=<homebrew>/lib gdctl show`, confirmed with
   `ldd /usr/bin/python3`. The script now calls `env -u LD_LIBRARY_PATH /usr/bin/gdctl`. A
   fail-open gate needs its own check that it actually ran - here `journalctl --user` showed
   the traceback under the script's name.
2. **Root cause** - move from the pinned beta to stable 2026.914 (also a high-severity Linux
   security fix). The full connect -> gamepad -> quit cycle then ran without a crash.

### Upgrading Sunshine from Homebrew on an immutable desktop

- The beta was [pinned](../glossary.md#homebrew-pin) because Vulkan encoding once existed
  only there. The reason was never written down; the release notes showed stable had carried
  Vulkan encoding for four months. **A pin is a decision with an expiry date - write the
  reason next to it.**
- Portal capture needs no [capabilities](../glossary.md#capabilities-and-cap_dac_override).
  Only KMS capture (kept as rollback) needs `cap_sys_admin`, and every `brew upgrade` installs
  a new file without it:
  ```bash
  sudo setcap cap_sys_admin+p "$(readlink -f /home/linuxbrew/.linuxbrew/opt/sunshine/bin/sunshine)"
  ```
  `readlink -f` because capabilities attach to the real file in `Cellar/`, not to the
  `opt/` symlink. Do not add `cap_sys_nice` - see cause 5.
- The stable build aborted at start: the tray icon could not load its display plugin and the
  error said it searched `""`. A background service needs no tray icon: `system_tray = disabled`.
- The unit had hard-coded `Cellar/qtbase/6.11.1`; the upgrade pulled 6.11.2. Reference
  Homebrew's version-less `opt/<formula>` paths in units, never `Cellar/<formula>/<version>`.

---

## Checklist for the next "it stutters"

1. `journalctl --user -u <sunshine unit> | grep "Minimum FPS"` - was 60 requested?
2. Moonlight overlay: host FPS, received FPS, network-dropped %. Host < 60 with a 60 request
   points at the host; received < host points at the network.
3. Packet counters at both network cards over the same interval.
4. MangoHud per-frame log: distribution, not average.
5. A known-good client on the same output (`mangohud vkcube --wsi wayland`), with and without
   the capture running (`kill -STOP` / `kill -CONT` on Sunshine for a few seconds). If the
   trivial client stutters too, the application is not the cause.
6. Only then change capture, encoder or display settings - one at a time, measured before
   and after.
