# starbook-bash

Bash control for a **Vixen Starbook (original, fw 2.7B50)** driving a Vixen Sphinx mount, from a Raspberry Pi 5.

The Starbook is controlled only over LAN, through URL commands to its built-in web server
(`GETSTATUS.ASP`, `GOTORADEC?RA=..&DEC=..`, `MOVE`, `STOP`, `SETTIME`, `GOHOME`, `RESET`, ...).
`sb.sh` sends those directly with `curl`, and can also start the INDI driver
(`indi_starbook_telescope`) for KStars/Ekos or PHD2.

## Requirements

Tested on Ubuntu 24.04 (Raspberry Pi 5).

**Required** (all commands except `start`/`stop`). Most are already on a standard Ubuntu install:

| Package | Provides | Used for |
|---|---|---|
| `curl` | `curl` | every command sent to the Starbook |
| `gawk` or `mawk` (any awk), `sed`, `grep`, `coreutils` | text handling, `readlink`, `date`, `seq`; awk also does the floating-point maths (star altitude, coordinate formatting) | throughout |
| `procps` | `pgrep`, `pkill` | checking/stopping `indiserver` |
| `iproute2` | `ip` | `start`: checks the adapter's 169.254 address |

```
sudo apt install curl gawk procps iproute2
```

**Optional: INDI**, only for `sb.sh start` / `sb.sh stop` and for driving the mount from
KStars/Ekos or PHD2. Without it, `unpark` and `abort` still work (they fall back to direct commands).

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

  Set `IFACE` in `sb.sh` to the adapter's name.

## Usage

```
bash sb.sh reset          # after power-up, mount at home: INIT, clock set, flags cleared
bash sb.sh star Vega      # slew to a bright star, watched, auto-abort after 180 s
bash sb.sh park           # back to home
bash sb.sh init           # reset to INIT: both motors stop
bash sb.sh status         # state, RA/Dec, encoders, clock
```

Run `bash sb.sh` with no arguments for all commands.

## Starbook behaviour worth knowing

- **Home** is counterweight down with the tube level (Dec 0°, HA ≈ +6h), not pointing at the pole.
- Leaving INIT (`START`) assumes the mount is at home. After a power cut or an `init` away from
  home, move the mount home by hand and run `sb.sh homed`; until then the script refuses to slew.
- In Scope/Chart mode the RA motor always tracks; `STOP` only stops slews. Only `RESET`
  (-> INIT, ~2 min restart) stops both motors.
- The clock resets to 2000-01-01 at every power-up (weak backup battery); `SETTIME` only works in INIT.
- `ALIGN` ignores coordinates and only syncs to the last GoTo target.
