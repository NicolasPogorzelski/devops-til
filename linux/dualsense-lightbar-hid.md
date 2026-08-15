# DualSense Lightbar: Kernel LED Class vs. Raw HID, and the Firmware Light-Out Latch

Driving a game controller's LED from userspace looks trivial - write a colour, done.
On a Sony DualSense over Bluetooth it is a two-layer problem: there are **two** ways to
send the colour, they are **not** equivalent, and the pad's firmware has a latch that
makes one of them silently do nothing. This bit a tray daemon that remaps controllers
([controller-manager](https://github.com/NicolasPogorzelski/controller-manager)):
the lightbar stayed dark whenever Steam was running, and "worked yesterday" - the
classic firmware-state bug.

## Two ways to set the lightbar (and why it matters)

| Path | How | Clears the light-out latch? |
|---|---|---|
| **Kernel LED class** | `echo` to `/sys/class/leds/inputN:rgb:indicator/{multi_intensity,brightness}` | **No** (on the affected kernel/firmware) |
| **Raw HID output report** | `write()` a report to `/dev/hidrawN` | **Yes** |

The hid-playstation driver exposes the lightbar as a multicolor LED class device, which
is the *obvious* interface - no report crafting, no CRC. It works fine on a freshly
powered pad. It does **not** clear the firmware latch once something sets it.

## The trap: sysfs says lit, the hardware is dark

The DualSense firmware has a **"light out" latch** (an output-report setup flag). Once
set, the pad ignores all lightbar colour in normal reports until it is explicitly
re-enabled. The tell-tale symptom:

```
$ cat /sys/class/leds/input45:rgb:indicator/multi_intensity   # 0 0 255  <- your value
$ cat /sys/class/leds/input45:rgb:indicator/brightness        # 255      <- stored fine
# ...and the physical bar is off.
```

The LED-class write **succeeds** - sysfs reads back exactly what you wrote - but the
hardware never changes. Anytime "the write succeeds but the device does nothing," suspect
a state that lives **below** the interface you're writing (here: in the pad's firmware,
not in the kernel).

Who sets it: **Steam Input**. With PlayStation support enabled, the Steam client opens
every pad's hidraw the moment it connects (even idle in the tray) and sets light-out via
raw HID. What does **not** clear it:

- Rewriting the LED class (sysfs) - no-op while latched.
- A **driver rebind** (unbind/bind hid-playstation, or an `EVIOCREVOKE` gate). A rebind
  re-probes the driver but does **not** power-cycle the pad, so the firmware latch
  survives. (This disproved the daemon's original assumption that "rebind -> fresh
  lightbar setup" recovers the colour. Field-checked on kernel 7.0.14.)

What **does** clear it: a **raw HID colour report** with the lightbar-control flag, or a
controller power-cycle. "Worked yesterday" = the pad was freshly powered then.

## The DualSense output report (what the raw path actually sends)

Same `output_report_common` payload, two transport framings:

| Transport | Report id | Framing | CRC |
|---|---|---|---|
| USB (`HID_ID` bus `0003`) | `0x02` | `[0x02][47-byte common]` | none |
| Bluetooth (bus `0005`) | `0x31` | `[0x31][seq_tag][0x10 tag][47-byte common][24 reserved][crc32]` | CRC32, seed byte `0xA2` prepended |

Relevant offsets inside the 47-byte common block:

| Offset | Field | Value used |
|---|---|---|
| 1 | `valid_flag1` | `0x04` = LIGHTBAR_CONTROL |
| 38 | `valid_flag2` | `0x02` = LIGHTBAR_SETUP_CONTROL_ENABLE |
| 41 | `lightbar_setup` | `0x00` = normal (`0x02` = LIGHT_OUT turns it off) |
| 44-46 | `lightbar_red/green/blue` | 0-255 each |

Building the Bluetooth report in Python (stdlib only):

```python
import zlib
common = bytearray(47)
common[1]  = 0x04                       # valid_flag1: LIGHTBAR_CONTROL
common[38] = 0x02                       # valid_flag2: LIGHTBAR_SETUP_CONTROL_ENABLE
common[41] = 0x00                       # lightbar_setup: normal / on
common[44], common[45], common[46] = r, g, b
rep = bytearray(78)
rep[0], rep[1], rep[2] = 0x31, 0x00, 0x10          # report id, seq_tag, DS_OUTPUT_TAG
rep[3:3+47] = common
crc = zlib.crc32(bytes([0xA2]) + bytes(rep[0:74])) & 0xffffffff   # seed 0xA2 over data
rep[74:78] = crc.to_bytes(4, "little")
open("/dev/hidraw0", "wb").write(bytes(rep))       # needs root / hidraw access
```

The BT report needs a valid CRC32 (seed `0xA2` prepended to the data, standard IEEE
`zlib.crc32`); an output report with a wrong CRC is dropped by the pad. `seq_tag` can
stay `0` - the controller processes repeated reports fine.

## The two-firmware gotcha (the part that cost the most time)

Two *identical-model* DualSense pads, same kernel, behaved differently:

- Pad A lit up on **`LIGHTBAR_CONTROL` alone** (`valid_flag1 = 0x04` + RGB).
- Pad B **ignored** a plain colour report while latched and only obeyed it when the
  **setup flag** was also set (`valid_flag2 = 0x02`, `lightbar_setup = 0x00`).

Symptom: on a two-controller setup, one bar worked and the other stayed dark - with
`write()` returning success (`exit 0`) for both. **Always send both flags.** The setup
flag re-enables the stricter firmware and is harmless on the lenient one. Never assume
two units of the "same" device share firmware behaviour.

## Coexisting with a permanent raw-HID owner (Steam Input)

Steam holds the pad's hidraw **permanently** and re-latches within ~1 s of any rebind,
so you cannot out-rebind it. What works:

- **Native mode**: raw colour report clears the latch and paints; Steam may stomp its
  own slot colour once on a mode switch, so a delayed re-assert (~6 s later) gets the
  last word. Brief wrong-colour flash, then correct - accepted.
- **Remap mode** (pad presented as a virtual Xbox pad): a hidraw **gate**
  (`EVIOCREVOKE` + node born `MODE 0000` via udev) revokes and blocks Steam entirely,
  so the daemon owns the bar exclusively - instant, no fight. A **root** helper can
  still `write()` a `0000` node (root bypasses file perms), so the raw path stays
  usable behind the gate.

## Debugging method that paid off

The fault could have been in the daemon, the helper, sudo, the kernel driver, the
firmware, or the hardware. Each experiment split the space in half:

- **Write the sysfs node by hand and read it back.** Value sticks, bar dark -> the
  software path is fine; the fault is below the LED-class interface.
- **Remove the suspected external actor cleanly.** Gate Steam out (`EVIOCREVOKE`),
  confirm `lsof /dev/hidrawN` shows no holder, *then* write -> isolates "is it Steam?"
  from "is it the mechanism?" (Here: still dark without Steam -> not just Steam.)
- **Bypass the abstraction.** LED-class dark but **raw HID** lit -> the LED-class ->
  hardware path is the broken layer, not the pad.
- **Reproduce the villain yourself.** Sending the LIGHT_OUT report by hand reproduced
  Steam's exact effect, turning an intermittent field bug into an on-demand toggle.
- **Differential test across units.** Same report to pad A (lit) and pad B (dark)
  localised the difference to *firmware*, not code.
- **Design tests for a colour-blind observer.** Verify with **on/off** transitions and
  primary colours (blue/green/red), not hue pairs (magenta/cyan) - the human in the
  loop has to be able to report the result reliably.
- **Trust the user's ground truth over your model.** "It worked at the last start"
  reframed a suspected hardware fault into a firmware-state regression and pointed
  straight at the latch.

## The privileged-helper pattern (raw HID needs root)

Writing `/dev/hidrawN` needs root. Don't run the daemon as root - use a tiny, tightly
scoped helper behind `NOPASSWD` sudo that **validates its target** before writing:
refuse anything whose `/sys/class/hidraw/<node>/device/uevent` `HID_ID` vendor isn't
Sony `054C`, validate the node name (`^/dev/hidraw[0-9]+$`, no path traversal) and the
channels (0-255). Same principle as any setuid-adjacent tool: the capability is narrow,
the input is validated, the blast radius is one device class.

## Related

- [Input-Device Reconnects](input-device-reconnect.md) - why the `inputN`-derived LED
  node renumbers on every BT reconnect, so you must re-resolve it from the live path.
- [systemd Service Hardening](systemd-service-hardening.md) - running the daemon as a
  user service with a scoped privileged helper instead of as root.
