# starbook-bash

Bash control for a **Vixen Starbook (original, fw 2.7B50)** driving a Vixen Sphinx mount, from a Raspberry Pi 5.

The Starbook is controlled only over LAN, through URL commands to its built-in web server
(`GETSTATUS.ASP`, `GOTORADEC?RA=..&DEC=..`, `MOVE`, `STOP`, `SETTIME`, `GOHOME`, `RESET`, ...).
`sb.sh` sends those directly with `curl`, and can also start the INDI driver
(`indi_starbook_telescope`) for KStars/Ekos or PHD2.

![Starbook screen captured with sb.sh screen: Scope mode, pointing at Sirius](docs/starbook-screen.png)

*The Starbook's screen as `bash sb.sh screen` shows it in the terminal (TUI) over SSH, after
`bash sb.sh goto Sirius`: the real 320x240 image, fetched over the LAN and drawn with the Kitty
graphics protocol in Ghostty.*

What the TUI view needs:

- **On the Pi:** nothing beyond the required packages below: `curl` (fetches `getscreen.bin`),
  `gawk`/`mawk` (decodes the 12-bit colour) and `coreutils` (`od`, `base64`, `fold`, `stat`, `mktemp`).
  No image library or Python.
- **On your computer:** a terminal that supports the Kitty graphics protocol, which works through SSH:
  [Ghostty](https://ghostty.org), [kitty](https://sw.kovidgoyal.net/kitty/), WezTerm or Konsole.
  Any other terminal with 24-bit colour gets a half-block rendering instead (blurry below ~160 columns);
  force either with `SB_SCREEN=kitty` or `SB_SCREEN=blocks`.

## Requirements

Tested on Ubuntu 24.04 (Raspberry Pi 5).

**Required.** Most are already on a standard Ubuntu install:

| Package | Provides | Used for |
|---|---|---|
| `curl` | `curl` | every command sent to the Starbook |
| `gawk` or `mawk` (any awk), `sed`, `grep`, `coreutils` | text handling, `readlink`, `date`, `seq`; awk also formats GoTo coordinates | throughout |
| `procps` | `pgrep`, `pkill` | checking/stopping `indiserver` |
| `iproute2` | `ip` | `indi-start`: checks the adapter's address (only if `SB_IFACE` is set) |
| `coreutils` (`base64`, `fold`, `od`) | | `screen`/`watch`: decoding and sending the screen image |

```
sudo apt install curl gawk procps iproute2
```

**Optional: INDI.** The mount does not need INDI: every command that controls it talks to the
Starbook directly over HTTP. INDI is only needed so that **KStars/Ekos or PHD2** can drive the mount,
because those programs only talk through an INDI server.

| Command | Needs INDI? |
|---|---|
| `status`, `settime`, `init`, `homed` | No |
| `unpark`, `goto`, `objects`, `nudge`, `align` | No |
| `park`, `abort` | No |
| `indi-start`, `indi-stop` | **Yes**, they only start and stop the INDI server itself |

| Package | Provides |
|---|---|
| `indi-bin` | `indiserver`, `indi_getprop`, `indi_setprop` |
| `indi-starbook` | `indi_starbook_telescope` (the Starbook driver) |

```
sudo apt install indi-bin indi-starbook
```

Both are in Ubuntu's `universe` repository; newer builds come from the INDI PPA
(`sudo add-apt-repository ppa:mutlaqja/ppa`). If you use KStars from that PPA
(`kstars-bleeding`) and it fails with `libstellarsolver.so.2: cannot open shared object file`,
install Ubuntu's `libstellarsolver2` alongside the PPA's `libstellarsolver`.

## Setup

- Connect the Starbook through a **USB-Ethernet adapter**. The Pi 5's built-in Ethernet lost
  ~97% of packets with the Starbook's 10BASE-T half-duplex port.
- Give the adapter an address on the Starbook's subnet (the Starbook uses `169.254.1.1/16`):

  ```
  sudo ip addr add 169.254.1.2/16 dev <adapter>
  ```

- **Install** (optional): `./install.sh` links the script as `sb` in `~/.local/bin` and adds bash
  tab completion, so you can type `sb goto Ve<Tab>` (commands, object and constellation names in any
  case, `meridian on/off`, `nudge N/S/E/W`, ...). `./install.sh --uninstall` removes both.
  Without installing, run `bash sb.sh <command>`.

### Settings

Nothing is specific to one site. **The location and time zone are read from the Starbook itself**
(its own Location and Local Time settings, via `GETPLACE`) and cached; `sb status` shows them, and
`sb init` re-reads them. Everything else has a default that you can change in
`~/.config/starbook.conf` (see [`starbook.conf.example`](starbook.conf.example)) or with environment
variables, which take priority:

| Setting | Default | Meaning |
|---|---|---|
| `SB_HOST` | `169.254.1.1` | the Starbook's address |
| `SB_PI_ADDR` | `169.254.1.2` | this computer's address on the Starbook's network |
| `SB_IFACE` | (none) | network interface to the Starbook; `indi-start` checks `SB_PI_ADDR` is on it |
| `SB_LAT`, `SB_LON`, `SB_TZ` | from the Starbook | override the site: latitude, longitude (east +), time zone (hours from UTC) |
| `SB_STATE` | `~/.local/state/starbook` | the not-at-home flag, last target, meridian setting and log |
| `SB_OBJECTS` | `sky_objects.txt` | a different list of named targets |

The config file is only read as `SB_*=value` lines; nothing in it is executed.

## Usage

```
sb <command> [arguments]          # after ./install.sh
bash sb.sh <command> [arguments]  # without installing
```

Run `sb` with no arguments to print this list.

**Status and setup** (no motion)

| Command | What it does |
|---|---|
| `status` | Show state (INIT/SCOPE/CHART/USER, and "slewing" during a GoTo), RA/Dec, altitude and azimuth (computed on the Pi from RA/Dec, clock and site; azimuth from north, with the Starbook screen's from-south value alongside), the constellation it points at, encoder counts, the Starbook's clock next to the Pi's, firmware, the not-at-home flag, and whether INDI is running. Also the meridian flip: setting, current target and its distance from the meridian, whether the watcher is running with a countdown and the clock time of the flip, and the last flip result |
| `settime` | Set the Starbook's clock from the Pi. Only works in INIT (the startup screen), so run it after `init` and before `unpark`. Make sure the Pi's own clock is right first (`date`), e.g. if it has no internet |
| `init [-y]` | Start clean: stop INDI and any meridian watcher, wait for the Starbook, reset it to INIT (both motors stop), clear the not-at-home flag. Asks you to confirm the mount is at home; `-y` skips the question. Does **not** change the clock: it prints the Starbook's and the Pi's clocks (and whether the Pi is internet-synced) and reminds you to run `settime` if they differ |
| `objects [TEXT]` | List the targets in `sky_objects.txt` and the 88 constellation centres, with notes; TEXT filters names and notes, e.g. `objects galaxy`, `objects Orion`, `objects M4`, `objects constellation` |
| `homed` | Confirm the mount is at home after moving it there by hand (clears the not-at-home flag) |
| `unpark` | Leave INIT and enter Scope mode (`START`), then set chart zoom 6. The RA motor starts tracking; nothing slews. Assumes the mount is at home |
| `zoom N` | Set the Starbook's chart zoom: 0 (closest) to 8 (whole sky), 6 is normal. The same setting is the speed of manual moves (`nudge` changes it). No motion |
| `screen [COLS]` | Show the Starbook's screen in the terminal, e.g. over SSH. In terminals with the Kitty graphics protocol (Ghostty, kitty, WezTerm, Konsole) it is the real image, pixel-perfect; elsewhere 24-bit colour half blocks (readable from ~160 columns). Force one with `SB_SCREEN=kitty` or `SB_SCREEN=blocks`. Width defaults to fitting the terminal |
| `watch [SEC]` | Redraw the Starbook's screen every SEC seconds (default 5) as a live view; Ctrl-C quits |

**Motion** (the mount moves)

| Command | What it does |
|---|---|
| `goto NAME` / `goto RA DEC` | Slew to a named object from `sky_objects.txt` (`goto Vega`, `goto M4`; case-insensitive), to the centre of a constellation (`goto Lyr`, `goto Lyra`, `goto Ursa_Major`), or to coordinates: RA in hours as `hh:mm:ss`, Dec in decimal degrees (`goto 00:42:44 +41.2692`). Unparks if needed, watches the slew until it arrives (aborts after 180 s; says so if already on target) and arms the automatic meridian flip (see `meridian`) |
| `meridian [on\|off\|MIN]` | Automatic meridian flip for `goto`: `on` (default) re-sends the GoTo MIN minutes after the target crosses the meridian (default 5, 1-15), from a background watcher that logs to `~/.local/state/starbook/meridian.log`; `off` leaves the flip to you (press Yes on the Starbook). No argument shows the setting and any running watcher. No motion by itself |
| `nudge N\|S\|E\|W SEC [SPEED]` | Short manual move to centre a star: up to 10 s, speed 1-8 (default 3) |
| `park` | Slew to the home position and watch the slew. Tracking continues at home; follow with `init` to stop the motors |
| `abort` | Stop all motion (slews and manual moves) |

**Alignment**

| Command | What it does |
|---|---|
| `align` | After a GoTo and centring the star (e.g. with `nudge`), tell the Starbook the last GoTo target is now centred. Repeat on 2-4 stars |

**INDI** (only for KStars/Ekos or PHD2)

| Command | What it does |
|---|---|
| `indi-start` | Start the INDI server with the Starbook driver and connect it (then point KStars/Ekos or PHD2 at `localhost:7624`) |
| `indi-stop` | Disconnect and shut down the INDI server |

Commands that slew refuse to run while the not-at-home flag is set (after a power cut during a slew).
Move the mount home by hand, then run `homed` or `init`.

**Named objects (`sky_objects.txt`)**

`goto NAME` looks targets up in `sky_objects.txt`, next to `sb.sh`. It ships with **all 173 stars brighter
than magnitude 3.0** (Yale Bright Star Catalogue, CDS V/50; IAU star names, Bayer names otherwise) and
**all 110 Messier objects** (OpenNGC; M102 as NGC 5866). Edit it to add or change targets: one per
line, `NAME  RA  DEC` (J2000), with RA in hours as `hh:mm:ss` and Dec in decimal degrees; text after
`#` is a note shown by `sb.sh objects`.

```
# NAME             RA (h:m:s)    DEC (deg)   # comment
Vega               18:36:56.3    +38.7836   # mag +0.03, Alpha Lyr, Lyra
M31                00:42:44.4    +41.2691   # Andromeda Galaxy, galaxy, NGC 224, Andromeda
```

Names are one word (use `_` for spaces) and are matched without regard to case (`goto m31`).
To use a different file: `SB_OBJECTS=/path/to/list.txt bash sb.sh goto NAME`.

**Constellation (`constellations.txt`)**

`status` names the constellation the scope points at. `constellations.txt` holds the official IAU
boundaries (Delporte 1930) as 357 RA/Dec boxes for equinox B1875.0, from N. G. Roman (1987),
*Identification of a Constellation From a Position*, PASP 99, 695
([CDS catalogue VI/42](https://cdsarc.cds.unistra.fr/viz-bin/cat/VI/42)), plus the 88 names.
The script precesses the position to B1875.0 in awk (IAU 1976 precession) and takes the first box
that contains it.

`goto Lyr` (or `goto Lyra`, `goto Ursa_Major`) slews to the centre of a constellation. The centres are
in the same file, computed from these boundaries: the centre of area of each constellation (mean
direction of an equal-area 0.2° grid; the resulting areas match the IAU values, e.g. Ursa Major 1278 deg²,
Lyra 286 deg², total 41253 deg²), precessed to J2000, and each checked to lie inside its constellation.
Serpens has two parts: `goto Ser` / `goto Serpens` goes to Serpens Caput, `goto Serpens_Cauda` to Cauda.

**Typical session**

```
sb init           # after power-up, mount at home: INIT, flag cleared, clock check printed
sb settime        # only if init says the Starbook clock is off
sb unpark         # enter Scope mode (RA starts tracking, no slew)
sb goto Vega      # slew to Vega (or goto M31, or goto 18:36:56 +38.78)
sb park           # back to home
sb init           # at home again: both motors stop
```

## Starbook behaviour worth knowing

- **Home** is counterweight down with the tube level (Dec 0°, HA ≈ +6h), not pointing at the pole.
- Leaving INIT (`START`) assumes the mount is at home. After a power cut during a slew,
  move the mount home by hand and run `sb.sh homed`; until then the script refuses to slew.
- In Scope/Chart mode the RA motor always tracks; `STOP` only stops slews. Only `RESET`
  (-> INIT, ~2 min restart) stops both motors.
- The clock resets to 2000-01-01 at every power-up (weak backup battery); `SETTIME` only works in INIT.
  The Starbook refuses GoTos below its horizon (`ERROR:BELOW HORIZONE`), but that check uses its own
  clock, so after every power-up check it (`sb.sh init` prints it) and run `sb.sh settime` if needed.
- `ALIGN` ignores coordinates and only syncs to the last GoTo target.
- **Azimuth note:** `sb.sh status` prints azimuth **from north** (N 0°, E 90°, S 180°, W 270°), the usual
  convention, and the Starbook screen's value in brackets. The Starbook's own screen counts azimuth **from south** (S 0°, W 90°, N 180°, E 270°),
  so its Az differs by 180° (e.g. status 85.4° = Starbook screen 265.4°). `GETSTATUS` reports only
  RA/Dec; `status` computes Alt/Az from them, the Pi's clock and the site.
- **Meridian:** the Starbook tracks about 21 min past the meridian, then stops tracking and shows
  "Telescope will REVERSE!!" (Yes/No). While that prompt is up it refuses every LAN command
  (`ERROR:ILLEGAL STATE`), so it can't be answered remotely. A GoTo sent after the meridian but before
  that limit makes the Starbook flip by itself, since it picks the pier side from the target's hour
  angle. So after a GoTo to a target east of the meridian, `sb.sh` starts a background watcher that
  re-sends the GoTo 5 min after the meridian (tested on the mount: RA axis 180°, no prompt).
  `park`, `init`, `abort` and a new GoTo stop the watcher.
- Speed and chart zoom are the same setting (`SETSPEED` 0-8: 0 closest/slowest, 8 whole sky/fastest;
  the Starbook also answers OK to out-of-range values). After a restart the chart is garbled (labels
  stacked on top of each other, no stars) until the first `SETSPEED`; `unpark` sets zoom 6 to fix it.
  `getscreen.bin` returns the 320x240 12-bit screen with no HTTP header (`curl --http0.9`).

## License

MIT, see [LICENSE](LICENSE). The script drives real hardware: use it at your own risk and keep
a hand near the mount's power switch.
