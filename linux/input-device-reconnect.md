# Input-Device Reconnects: Reused `eventX`, Renumbered `inputN`

A userspace daemon that grabs a game controller (or any hot-pluggable input device)
and reacts to reconnects has to answer one question correctly: **"is this the same
device I already knew?"** Getting the identity model wrong produces bugs that only
show up after a few Bluetooth off/on cycles — exactly the state that is hard to
reproduce on demand.

## The trap: two device "numbers" that behave differently

When a Bluetooth controller disconnects and reconnects, Linux exposes it through
several sysfs/dev names that do **not** all change together:

| Name | Where | Behaviour on reconnect |
|---|---|---|
| `/dev/input/eventX` | the evdev char device | number is **reused** — the kernel hands back the lowest free minor, often the same one |
| `/sys/class/input/inputN` | the input *class* device | `N` is a **monotonic counter** — it bumps on every (re)connect and never reuses |
| `…:rgb:indicator` LED, other class nodes | named after `inputN` | **renumbered** with `inputN` (`input38` → `input47` → …) |
| `uhid/0005:VVVV:PPPP.000N` | the HID instance (Steam Input etc.) | new instance each reconnect (`.000B` → `.000D`) |

So `eventX` can stay `event25` across a reconnect while the LED node jumps
`input38 → input47`. A daemon that keys "did it reconnect?" on the **evdev path**
therefore *misses* the reconnect entirely: the path looks unchanged, so it never
re-binds — but the device underneath is new, its old `EVIOCGRAB` grab is dead, and
any cached child-node name (the LED) now points at a **removed** node.

## Consequences of tying state to path stability

- Writes to the cached (renumbered-away) LED node succeed at the syscall level but
  land on a dead node — the hardware never changes. Symptom: "the mode switch runs
  but nothing visibly changes."
- The remapper/grab thread died with the disconnect and is never restarted, so the
  device comes back **un-remapped** until the user does something manual.
- Device firmware often **resets its own state** on power-cycle (a controller's
  lightbar returns to a firmware default), so even a correct cached node needs a
  *re-assert*, not just a "no change needed" check.

## The fix pattern

1. **Never trust a cached child-node name.** Re-resolve the LED (or any `inputN`-
   derived node) from the *live* evdev path on every write. A cached name is a
   time-bomb across reconnects.
2. **Detect a reconnect by presence, not by path.** Track a per-device "was absent
   last poll" flag keyed on a *stable* identity (Bluetooth MAC / serial, not the
   path). Absent→present is the reconnect signal, even when `eventX` is reused.
3. **Re-assert the whole device state on reconnect**, one poll *after* it is stably
   present — re-grab, re-apply any privileged setup, repaint hardware. Doing it one
   tick later (not at the exact reconnect instant) lets the device/Steam finish
   bringing itself up, so your write is the last word instead of racing theirs.
4. **Accept a residual race.** If another owner (Steam Input) drives the same
   hardware, a single write at connect time can still be overwritten. Re-assert
   after settle is best-effort, not a hard guarantee — document it.

## Debugging method that paid off

- **Bisect daemon vs. desktop host with a direct call.** When a tray click "did
  nothing", sending the same `com.canonical.dbusmenu.Event` over `dbus-send`
  *worked* — proving the daemon logic was fine and the fault was the Plasma
  StatusNotifierItem host not delivering the click. One command split the problem in
  half.
- **Test which layer is authoritative before theorising.** Writing a distinctive
  colour (red) straight to the resolved kernel LED node and asking "what colour is
  it now?" confirmed the kernel node — not Steam — drove the hardware, which
  pinned the root cause to a *stale node name* rather than a lost-ownership problem.
- **`inputN` in the journal is a reconnect fingerprint.** A rising node number
  across log lines (`input60` → `input66` → `input71`) is direct evidence that each
  off/on created a fresh device — worth grepping for.

**One-liner:** on a reconnect the `eventX` path may be reused while `inputN`-derived
nodes renumber — key device identity on a stable id and re-assert on presence, never
on path stability.
