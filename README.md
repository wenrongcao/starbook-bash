# starbook-bash

Bash control for a **Vixen Starbook** (original, fw 2.7B50) and its mount, from a Raspberry Pi or any
Linux computer. The Starbook is driven over its LAN port through the URL commands of its built-in web
server; INDI is optional (only for KStars/Ekos or PHD2).

![The Starbook's screen shown in the terminal by "sb screen": Scope mode, pointing at Sirius](docs/starbook-screen.png)

*The Starbook's own screen in the terminal over SSH (`sb screen`), after `sb goto Sirius`.*

## Install

```
sudo apt install curl gawk            # usually already there, plus coreutils, procps, iproute2
git clone https://github.com/wenrongcao/starbook-bash.git
cd starbook-bash && ./install.sh      # links "sb" into ~/.local/bin + bash tab completion
```

`./install.sh --uninstall` removes it again; without installing, run `bash sb.sh <command>`.

**Connect the Starbook** with a network cable, through a **USB-Ethernet adapter** on a Raspberry Pi 5
(its built-in port loses most packets with the Starbook's 10 Mb/s half-duplex port). Give that
interface an address on the Starbook's network (the Starbook is `169.254.1.1`):

```
sudo ip addr add 169.254.1.2/16 dev <interface>
```

Then check it answers: `sb status`.

## Typical session

```
sb init           # after power-up, mount at home: INIT, motors stopped; prints a clock check
sb settime        # only if init says the Starbook clock is off
sb unpark         # Scope mode: RA starts tracking, nothing slews
sb goto Vega      # or: sb goto M31, sb goto Lyr, sb goto 18:36:56 +38.78
sb park           # back home
sb init           # motors off
```

The meridian flip is automatic, see `meridian` below. `sb` with no arguments lists all commands;
Tab completes commands and target names.

## Commands

| Command | What it does |
|---|---|
| **No motion** | |
| `status` | State, RA/Dec, Alt/Az, constellation, encoders, clocks, site, meridian-flip countdown |
| `init [-y]` | Clean start: Starbook to INIT (both motors stop), flags cleared, clock check printed. Asks if the mount is at home (`-y` skips) |
| `settime` | Set the Starbook's clock from the computer (only in INIT, i.e. before `unpark`) |
| `unpark` | Enter Scope mode (assumes the mount is at home); sets chart zoom 6 |
| `homed` | Confirm the mount is at home after moving it there by hand |
| `objects [TEXT]` | List targets and constellation centres; TEXT filters, e.g. `objects galaxy`, `objects Orion` |
| `zoom N` | Chart zoom 0 (closest) to 8 (whole sky); also the speed of manual moves |
| `meridian [on\|off\|MIN]` | Automatic meridian flip: on (default), off, or flip MIN minutes after the meridian (default 5) |
| `screen [COLS]` / `watch [SEC]` | Show the Starbook's screen in the terminal; `watch` refreshes it every SEC s |
| `align` | After a GoTo and centring the star, sync the Starbook to it (repeat on 2-4 stars) |
| **Motion** | |
| `goto NAME` | Slew to an object (`Vega`, `M31`) or a constellation centre (`Lyr`, `Lyra`, `Ursa_Major`); any case |
| `goto RA DEC` | Slew to coordinates: RA `hh:mm:ss` (hours), Dec in decimal degrees (J2000) |
| `nudge N\|S\|E\|W SEC [SPEED]` | Short manual move to centre a star (up to 10 s, speed 1-8) |
| `park` | Slew home (tracking continues; `init` then stops the motors) |
| `abort` | Stop all motion |
| **INDI** | |
| `indi-start` / `indi-stop` | Start/stop the INDI server with the Starbook driver (`localhost:7624`) |

`goto` unparks if needed, watches the slew (auto-abort after 180 s) and arms the meridian flip.
Slewing commands refuse to run after a power cut during a slew, until the mount is moved home by
hand and `homed` (or `init`) is run.

## Settings

Nothing is site-specific: **location and time zone are read from the Starbook** (its own settings)
and cached; `sb init` re-reads them. Other defaults can be changed in `~/.config/starbook.conf`
(see [`starbook.conf.example`](starbook.conf.example); only `SB_*=value` lines are read) or with
environment variables, which win:

| Setting | Default | Meaning |
|---|---|---|
| `SB_HOST` | `169.254.1.1` | the Starbook's address |
| `SB_PI_ADDR`, `SB_IFACE` | `169.254.1.2`, none | this computer's address and interface (`indi-start` checks them if `SB_IFACE` is set) |
| `SB_LAT`, `SB_LON`, `SB_TZ` | from the Starbook | override the site: latitude, longitude (east +), hours from UTC |
| `SB_STATE` | `~/.local/state/starbook` | not-at-home flag, last target, meridian setting and log |
| `SB_OBJECTS` | `sky_objects.txt` | a different target list |
| `SB_SCREEN` | automatic | `kitty` or `blocks`: how `screen` draws |

## Targets and constellations

**`sky_objects.txt`**: all **173 stars brighter than magnitude 3** (Yale Bright Star Catalogue, CDS V/50;
IAU names, else Bayer) and all **110 Messier objects** (OpenNGC; M102 as NGC 5866). Add your own, one
per line; names are one word (`_` for spaces), text after `#` is a note:

```
# NAME             RA (h:m:s)    DEC (deg)   # note
Vega               18:36:56.3    +38.7836   # mag +0.03, Alpha Lyr, Lyra
M31                00:42:44.4    +41.2691   # Andromeda Galaxy, galaxy, NGC 224, Andromeda
```

**`constellations.txt`**: the IAU boundaries (Roman 1987,
[CDS VI/42](https://cdsarc.cds.unistra.fr/viz-bin/cat/VI/42)), used by `status` to name the
constellation, and the centre of each of the 88 constellations for `goto Lyr` (centre of area computed
from those boundaries; `Ser` = Serpens Caput, `Serpens_Cauda` for the other part).

## Screen in the terminal

`sb screen` fetches the Starbook's 320x240 screen (`getscreen.bin`) and draws it with no extra software
on the computer. Terminals with the Kitty graphics protocol ([Ghostty](https://ghostty.org),
[kitty](https://sw.kovidgoyal.net/kitty/), WezTerm, Konsole) show the real image, also over SSH; others
get 24-bit-colour half blocks (readable from about 160 columns).

## Optional: INDI

Only needed for KStars/Ekos or PHD2: `sudo apt install indi-bin indi-starbook`, then `sb indi-start`
and connect the program to `localhost:7624`. If KStars from the INDI PPA fails with
`libstellarsolver.so.2: cannot open shared object file`, also install Ubuntu's `libstellarsolver2`.

## Starbook notes

- **Home** is counterweight down, tube level (Dec 0°, HA ≈ +6h), not pointing at the pole. Leaving INIT
  assumes the mount is there.
- **Motors:** in Scope/Chart mode RA always tracks and `STOP` only stops slews; only `RESET` (INIT,
  ~2 min restart) stops both motors, which is what `sb init` does.
- **Clock:** resets to 2000-01-01 at power-up if the backup battery is weak, and can only be set in INIT.
  The Starbook's horizon limit (`ERROR:BELOW HORIZONE`) uses this clock.
- **Meridian:** about 21 min past the meridian the Starbook stops tracking and asks "Telescope will
  REVERSE!!", refusing every LAN command until someone presses Yes. A GoTo sent after the meridian but
  before that makes it flip by itself, so `goto` re-sends the target 5 min after the meridian.
- **Chart zoom** and move speed are one setting (`SETSPEED` 0-8). After a restart the chart is garbled
  and the Starbook sluggish until the first `SETSPEED`; `unpark` sends one.
- **Azimuth:** `status` counts from north; the Starbook screen counts from south (180° different).
- `ALIGN` ignores coordinates and syncs to the last GoTo target.

## License

MIT, see [LICENSE](LICENSE). This drives real hardware: use it at your own risk and keep a hand near
the mount's power switch.
