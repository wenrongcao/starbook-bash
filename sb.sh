#!/bin/bash
# Control the Vixen Starbook (original) over HTTP from a Raspberry Pi; INDI is optional.
# Settings (Starbook address, site, ...): see "settings" below and ~/.config/starbook.conf.
#
#   sb.sh indi-start       start the INDI server + Starbook driver (only for KStars/Ekos/PHD2)
#   sb.sh status           show state, RA/Dec, Alt/Az, constellation, encoders, clock, firmware, meridian flip
#   sb.sh settime          set Starbook clock from the Pi (Starbook must be at INIT screen)
#   sb.sh homed            confirm the mount is at home (after a power cut during a slew)
#   sb.sh unpark           leave INIT/park and enter Scope mode        (no motion)
#   sb.sh goto NAME|RA DEC slew to an object from sky_objects.txt (goto Vega, goto M4), a
#                          constellation centre (goto Lyr, goto Ursa_Major), or to
#                          coordinates (goto 00:42:44 +41.2692); watched; auto meridian flip  (MOVES)
#   sb.sh objects [TEXT]   list objects (173 stars to mag 3, all Messier, 88 constellations); TEXT filters
#   sb.sh meridian [on|off|MIN]  auto meridian flip after goto: on (default), off, or MIN after (default 5)
#   sb.sh nudge N|S|E|W SEC [SPEED]  short move to centre a star (1-8, default 3)  (MOVES)
#   sb.sh align            last GoTo target is now centred -> add alignment star
#   sb.sh zoom N           chart zoom 0 (closest) .. 8 (whole sky); also the manual-move speed
#   sb.sh init [-y]        start clean: INIT (motors stop), flags cleared, clock check; mount must be home
#   sb.sh screen [COLS]    show the Starbook screen in the terminal (24-bit colour)
#   sb.sh watch [SEC]      redraw the Starbook screen every SEC seconds (default 5), Ctrl-C quits
#   sb.sh abort            stop all motion
#   sb.sh park             go to home position and watch the slew       (MOVES)
#   sb.sh indi-stop        disconnect and shut down the INDI server

SELF=$(readlink -f "$0")               # absolute path, so "bash sb.sh" can call itself
DIR=${SB_DIR:-$(dirname "$SELF")}      # where sky_objects.txt / constellations.txt live

# ---- settings -------------------------------------------------------------------------
# Defaults below. Override any SB_* in ~/.config/starbook.conf (KEY=value lines) or in the
# environment (the environment wins). The site (latitude, longitude, time zone) is read from
# the Starbook itself (GETPLACE) and cached; set SB_LAT/SB_LON/SB_TZ to override it.
SB_CONF=${SB_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/starbook.conf}
if [ -r "$SB_CONF" ]; then
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^SB_[A-Z_]+$ ]] || continue          # only SB_* keys; no code is executed
    v=${v%%#*}; v=${v%"${v##*[![:space:]]}"}; v=${v#\"}; v=${v%\"}
    [ -z "${!k+x}" ] && printf -v "$k" '%s' "$v"
  done <"$SB_CONF"
fi
SB_HOST=${SB_HOST:-169.254.1.1}        # the Starbook's address
SB_PI_ADDR=${SB_PI_ADDR:-169.254.1.2}  # this computer's address on the Starbook's network
SB_IFACE=${SB_IFACE:-}                 # network interface to the Starbook (optional; checked by indi-start)
SB_STATE=${SB_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/starbook}   # flags, target, meridian log
SB=http://$SB_HOST
DEV=Starbook
LOG=/tmp/indiserver-starbook.log
OBJECTS=${SB_OBJECTS:-$DIR/sky_objects.txt}   # named targets for "goto NAME"
CONST=$DIR/constellations.txt          # IAU constellation boundaries (B1875), names, centres
NOTHOME=$SB_STATE/not_at_home          # set when the Starbook no longer knows the mount is at home
TARGET=$SB_STATE/target                # last GoTo target "RA_hours DEC_deg"
MERIDIAN=$SB_STATE/meridian            # meridian-flip setting: "on MIN" (default "on 5") or "off MIN"
FLIPPID=$SB_STATE/meridian.pid         # background meridian-flip watcher
FLIPLOG=$SB_STATE/meridian.log         # its log
SITE=$SB_STATE/site                    # cached site from the Starbook: "lat lon tz"
mkdir -p "$SB_STATE"
# one-time move of the state files from the old location (the script's own folder)
for f in not_at_home target meridian meridian.pid meridian.log; do
  old=$DIR/.$f; [ "$f" = meridian.log ] && old=$DIR/$f
  [ -e "$old" ] && [ ! -e "$SB_STATE/$f" ] && mv "$old" "$SB_STATE/$f"
done

now() { echo "${SB_NOW:-$(date +%s)}"; }   # Unix time (SB_NOW fixes it, for testing)

# Site: "lat lon tz" (degrees north, degrees east, hours from UTC). From SB_LAT/SB_LON/SB_TZ,
# else the cache, else the Starbook's GETPLACE ("longitude=W119+49&latitude=N39+28&timezone=-7").
site() {
  if [ -n "$SB_LAT" ] && [ -n "$SB_LON" ] && [ -n "$SB_TZ" ]; then echo "$SB_LAT $SB_LON $SB_TZ"; return; fi
  if [ ! -s "$SITE" ] || [ "$1" = refresh ]; then
    local p; p=$(sbq GETPLACE.ASP)
    echo "$p" | awk '{
      if (!match($0, /longitude=[EW][0-9]+\+[0-9]+/)) exit 1; lo = substr($0, RSTART + 10, RLENGTH - 10)
      if (!match($0, /latitude=[NS][0-9]+\+[0-9]+/)) exit 1;  la = substr($0, RSTART + 9, RLENGTH - 9)
      if (!match($0, /timezone=-?[0-9.]+/)) exit 1;            tz = substr($0, RSTART + 9, RLENGTH - 9)
      split(substr(lo, 2), a, "+"); lon = (substr(lo, 1, 1) == "W" ? -1 : 1) * (a[1] + a[2] / 60)
      split(substr(la, 2), b, "+"); lat = (substr(la, 1, 1) == "S" ? -1 : 1) * (b[1] + b[2] / 60)
      printf "%.4f %.4f %s\n", lat, lon, tz }' >"$SITE.new" 2>/dev/null && mv "$SITE.new" "$SITE" || rm -f "$SITE.new"
  fi
  local lat lon tz; read -r lat lon tz 2>/dev/null <"$SITE"
  echo "${SB_LAT:-${lat:-0}} ${SB_LON:-${lon:-0}} ${SB_TZ:-${tz:-0}}"
  [ -n "$lat$SB_LAT" ] || echo "warning: site unknown (Starbook not answering, no cache) - set SB_LAT/SB_LON/SB_TZ" >&2
}
lat() { local a _; read -r a _ <<<"$(site)"; echo "$a"; }
lon() { local _ b _c; read -r _ b _c <<<"$(site)"; echo "$b"; }
tzh() { local _ _b c; read -r _ _b c <<<"$(site)"; echo "$c"; }
# Local time on the Starbook's time zone: local_date FORMAT [UNIX_TIME]
local_date() { date -u -d "@$(awk -v t="${2:-$(now)}" -v z="$(tzh)" 'BEGIN { printf "%d", t + z * 3600 }')" "$1"; }

get() { indi_getprop -t 3 -1 "$DEV.$1" 2>/dev/null; }
set_() { indi_setprop "$DEV.$1"; }
sbq() { curl -s -m 3 "$SB/$1" | sed 's/<[^>]*>//g' | tr -d '\r\n' | sed 's/^ *//; s/ *$//'; }   # direct HTTP command
st() { sbq GETSTATUS.ASP; }
xy() { sbq GETXY.ASP | sed -E 's/X=(-?[0-9]+)&Y=(-?[0-9]+)/\1 \2/'; }  # prints "X Y"
guard() { [ -e "$NOTHOME" ] && { echo "REFUSED: mount may not be at home ($(cat "$NOTHOME")). Move it home by hand, then: $0 homed"; exit 1; }; }
move() { sbq "MOVE?NORTH=${1:-0}&SOUTH=${2:-0}&EAST=${3:-0}&WEST=${4:-0}" >/dev/null; }

# Convert "hh:mm:ss" / "±dd:mm:ss" (or "hh:mm", or decimal) to decimal. $1 value, $2 max (24 or 90).
# Prints the decimal value, or nothing if the value is malformed or out of range.
todec() {
  awk -v v="$1" -v max="$2" 'BEGIN {
    if (v !~ /^[+-]?[0-9]+(\.[0-9]+)?(:[0-9]+(\.[0-9]+)?(:[0-9]+(\.[0-9]+)?)?)?$/) exit
    neg = (v ~ /^-/); sub(/^[+-]/, "", v); n = split(v, p, ":")
    if ((n >= 2 && p[2] >= 60) || (n >= 3 && p[3] >= 60)) exit
    x = p[1] + (n >= 2 ? p[2] / 60 : 0) + (n >= 3 ? p[3] / 3600 : 0)
    if (neg) x = -x
    if (max == 24 && (x < 0 || x >= 24)) exit
    if (max == 90 && (x < -90 || x > 90)) exit
    printf "%.6f\n", x }'
}

# True if the Starbook's reported position ($1 = GETSTATUS reply) is within ~0.1 deg of RA $2 h / DEC $3 deg.
near_target() {
  echo "$1" | awk -v ra="$2" -v dec="$3" '{
    if (!match($0, /RA=[0-9]+\+[0-9.]+/)) exit 1; split(substr($0, RSTART + 3, RLENGTH - 3), r, "+")
    if (!match($0, /DEC=-?[0-9]+\+[0-9]+/)) exit 1; dd = substr($0, RSTART + 4, RLENGTH - 4); split(dd, d, "+")
    cr = r[1] + r[2] / 60; cd = (dd ~ /^-/ ? -1 : 1) * ((d[1] < 0 ? -d[1] : d[1]) + d[2] / 60)
    dra = cr - ra; if (dra > 12) dra -= 24; if (dra < -12) dra += 24
    k = atan2(0, -1) / 180; x = dra * 15 * cos(dec * k); y = cd - dec
    exit !(x * x + y * y < 0.01) }'
}

# Watch a GoTo/GoHome until the Starbook reports it finished; abort after 180 s.
# Optional $1 $2 = target RA/DEC: if no slew starts because the scope is already there, say so.
watch_slew() {
  local t0=$SECONDS started=0 lost=0 s
  while [ $((SECONDS - t0)) -lt 180 ]; do
    s=$(st)
    if [ -z "$s" ]; then
      lost=$((lost + 1)); echo "$((SECONDS - t0))s  (no reply)"
      [ $lost -ge 3 ] && { echo "LOST CONTACT - Starbook may have lost power"; echo "lost contact mid-slew $(date +%T)" >"$NOTHOME"; return 2; }
    else
      lost=0; echo "$((SECONDS - t0))s  $s"
      [[ $s == *STATE=INIT* ]] && { echo "STARBOOK RESET (power loss?) - mount position is now unknown"; echo "reset mid-slew $(date +%T)" >"$NOTHOME"; return 2; }
      [[ $s == *GOTO=1* ]] && started=1
      [[ $started = 1 && $s == *GOTO=0* ]] && { echo "arrived"; return 0; }
      [[ $started = 0 && -n "$1" && $((SECONDS - t0)) -ge 4 ]] && near_target "$s" "$1" "$2" && { echo "already on target"; return 0; }
      [[ $started = 0 && $((SECONDS - t0)) -gt 15 ]] && { echo "slew never started"; return 1; }
    fi
    sleep 2
  done
  echo "TIMEOUT - aborting"; "$SELF" abort; return 1
}

# RESET the Starbook to INIT (motors stop) and wait for it to come back. ~2 min.
do_reset() {
  local try xy1 xy2
  sleep 5                                          # a RESET sent right after a slew is ignored
  for try in 1 2 3; do
    echo "RESET -> $(sbq 'RESET?reset')"
    sleep 10
    [ -z "$(st)" ] && break                        # stopped answering = restarting
    echo "still answering after RESET (try $try) - resending"
  done
  echo -n "waiting for restart"
  for _ in $(seq 1 60); do [[ "$(st)" == *STATE=INIT* ]] && break; echo -n "."; sleep 3; done; echo
  xy1=$(xy); sleep 5; xy2=$(xy)
  echo "$(st)  encoders ($xy1) -> ($xy2)"
  [ -n "$xy1" ] && [ "$xy1" = "$xy2" ] && { echo "INIT: motors stopped"; return 0; }
  echo "WARNING: encoders changed or no reply"; return 1
}

# Hour angle (hours, -12..12) of RA $1 (hours) now, at the site's longitude.
hour_angle() {
  awk -v t="$(now)" -v ra="$1" -v lon="$(lon)" 'BEGIN {
    d = t / 86400 + 2440587.5 - 2451545.0
    lst = (18.697374558 + 24.06570982441908 * d + lon / 15) % 24
    ha = lst - ra; if (ha > 12) ha -= 24; if (ha < -12) ha += 24
    printf "%.4f\n", ha }'
}

# Send one GoTo (RA hours, DEC degrees) and remember it as the target. Same format as the INDI
# driver: RA=HH+MM.t&DEC=[-]DDD+MM (works without indiserver). Returns 0 if the Starbook accepted.
goto_send() {
  local q r
  q=$(awk -v ra="$1" -v dec="$2" 'BEGIN{
    ra = ra % 24; if (ra < 0) ra += 24; rm = int(ra * 600 + 0.5); rh = int(rm / 600) % 24; rm = rm % 600
    s = (dec < 0) ? "-" : ""; d = (dec < 0) ? -dec : dec; dm = int(d * 60 + 0.5)
    printf "RA=%02d+%02d.%d&DEC=%s%03d+%02d", rh, int(rm / 10), rm % 10, s, int(dm / 60), dm % 60 }')
  r=$(sbq "GOTORADEC?$q")
  echo "GOTORADEC?$q -> $r  (abort: $0 abort)"
  [[ "$r" == OK* ]] || return 1
  echo "$1 $2" >"$TARGET"
}

# Meridian flip. The Starbook tracks ~21 min past the meridian, then stops and shows
# "Telescope will REVERSE!!" (Yes/No), and refuses every LAN command until someone presses Yes.
# A GoTo sent after the meridian but before that limit makes it flip by itself, so after a GoTo
# to a target east of the meridian a background watcher re-sends it MIN minutes after the
# meridian (default 5). "meridian off" leaves the flip to you (press Yes on the Starbook).
meridian_get() {   # prints "on|off MIN"
  local m n; read -r m n 2>/dev/null <"$MERIDIAN"
  [[ "$m" == on || "$m" == off ]] || m=on; [[ "$n" =~ ^[0-9]+$ ]] || n=5
  echo "$m $n"
}
flip_stop() {   # stop a running watcher (new target, park, init, abort)
  local pid; [ -r "$FLIPPID" ] && read -r pid <"$FLIPPID"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null && echo "meridian flip watcher stopped"
  rm -f "$FLIPPID"
}
flip_start() {   # $1 RA hours, $2 DEC deg: start the watcher if the target is still east of the meridian
  local m n ha; read -r m n <<<"$(meridian_get)"
  [ "$m" = on ] || { echo "meridian flip: off (press Yes on the Starbook when it asks)"; return; }
  ha=$(hour_angle "$1")
  if awk "BEGIN{exit !($ha >= 0)}"; then echo "meridian flip: not needed (target already west of the meridian)"; return; fi
  # run from a private copy: bash reads a running script from disk, so editing sb.sh (or git pull)
  # while the watcher waits would otherwise break it
  cp "$SELF" "$SB_STATE/watcher.sh"
  SB_DIR="$DIR" setsid bash "$SB_STATE/watcher.sh" _flipwatch "$1" "$2" "$n" >>"$FLIPLOG" 2>&1 </dev/null &
  echo $! >"$FLIPPID"
  echo "meridian flip: automatic, $n min after the meridian (in $(awk "BEGIN{printf \"%.0f\", ($n / 60 - $ha) * 60}") min); log: $FLIPLOG"
}

meridian_status() {   # meridian-flip lines for "status"
  local m n tra tdec ha pid run=0 at stop
  read -r m n <<<"$(meridian_get)"
  if [ "$m" = on ]; then echo "meridian: auto flip on, $n min after the meridian"; else echo "meridian: auto flip off (press Yes on the Starbook when it asks)"; fi
  [ -r "$FLIPPID" ] && read -r pid <"$FLIPPID" && kill -0 "$pid" 2>/dev/null && run=1
  if [ -r "$TARGET" ]; then
    read -r tra tdec <"$TARGET"; ha=$(hour_angle "$tra")
    echo "  target:  RA $tra h, DEC $tdec deg - $(awk -v h="$ha" 'BEGIN { m = h * 60; if (m < 0) printf "%.1f min before the meridian (east)", -m; else printf "%.1f min after the meridian (west)", m }')"
    at()   { local_date +%H:%M "$(awk -v h="$ha" -v k="$1" -v t="$(now)" 'BEGIN { printf "%d", t + (k / 60 - h) * 3600 }')"; }
    if [ $run = 1 ]; then
      echo "  watcher: running - flip in $(awk -v h="$ha" -v k="$n" 'BEGIN { printf "%.1f", k - h * 60 }') min (at $(at "$n"))"
    elif [ "$m" = on ] && awk "BEGIN{exit !($ha < 0)}"; then
      echo "  watcher: NOT running although the target is east - re-send the GoTo (star/goto) to arm it"
    elif [ "$m" = off ] && awk "BEGIN{exit !($ha < 21 / 60)}"; then
      echo "  the Starbook will stop and ask to reverse ~21 min after the meridian (at $(at 21))"
    else
      echo "  watcher: not running (no flip pending)"
    fi
  else
    echo "  target:  none yet (star/goto)"
  fi
  [ -r "$FLIPLOG" ] && grep -qE 'flip done|FLIP FAILED' "$FLIPLOG" && echo "  last:    $(grep -E 'flip done|FLIP FAILED' "$FLIPLOG" | tail -1)"
  return 0
}

# Centre of a constellation by abbreviation or full name (Lyr, Lyra, UMa, Ursa_Major; any case).
# Serpens: Ser / Serpens = Serpens Caput (Ser1); Serpens_Cauda = Ser2. Prints "RA DEC Full name".
const_centre() {
  [ -r "$CONST" ] || return 1
  awk -v q="$1" '
    BEGIN { q = tolower(q); gsub(/ /, "_", q); if (q == "ser" || q == "serpens") q = "ser1" }
    { sub(/\r$/, "") }
    /^= / { ab = $2; $1 = ""; $2 = ""; sub(/^  */, ""); full[ab] = $0; next }
    /^c / { cra[$2] = $3; cdec[$2] = $4 }
    END { for (ab in cra) { f = tolower(full[ab]); gsub(/ /, "_", f)
            if (q == tolower(ab) || q == f) { print cra[ab], cdec[ab], full[ab]; found = 1; exit } }
          exit !found }' "$CONST"
}

# Constellation containing RA $1 (hours) / DEC $2 (degrees) of date: precess to B1875.0
# (IAU 1976 angles zeta, z, theta) and take the first boundary box in constellations.txt with
# RA_low <= RA < RA_up and DEC >= DEC_low (Roman 1987). Prints "Full name (Abr)".
constellation() {
  [ -r "$CONST" ] || { echo "?"; return; }
  awk -v ra="$1" -v dec="$2" -v t="$(now)" '
    BEGIN {
      k = atan2(0, -1) / 180; as = k / 3600
      T = (t / 86400 + 2440587.5 - 2451545.0) / 36525            # now, centuries from J2000
      tt = (2405889.258550475 - 2451545.0) / 36525 - T           # now -> B1875.0 (negative)
      zeta  = ((2306.2181 + 1.39656 * T - 0.000139 * T * T) * tt + (0.30188 - 0.000344 * T) * tt * tt + 0.017998 * tt ^ 3) * as
      z     = ((2306.2181 + 1.39656 * T - 0.000139 * T * T) * tt + (1.09468 + 0.000066 * T) * tt * tt + 0.018203 * tt ^ 3) * as
      theta = ((2004.3109 - 0.85330 * T - 0.000217 * T * T) * tt - (0.42665 + 0.000217 * T) * tt * tt - 0.041833 * tt ^ 3) * as
      a0 = ra * 15 * k; d0 = dec * k
      A = cos(d0) * sin(a0 + zeta)
      B = cos(theta) * cos(d0) * cos(a0 + zeta) - sin(theta) * sin(d0)
      C = sin(theta) * cos(d0) * cos(a0 + zeta) + cos(theta) * sin(d0)
      r = (atan2(A, B) + z) / k / 15; if (r < 0) r += 24; if (r >= 24) r -= 24
      d = atan2(C, sqrt(1 - C * C)) / k
    }
    { sub(/\r$/, "") }
    /^= / { ab = $2; $1 = ""; $2 = ""; sub(/^  */, ""); name[ab] = $0; next }
    /^ *[0-9]/ && !found && d >= $3 && r >= $1 && r < $2 { found = $4 }
    END { print (found ? name[found] " (" found ")" : "?") }' "$CONST"
}

# ---- Starbook screen in the terminal -------------------------------------------------
# getscreen.bin: 320x240, 12-bit colour, 2 pixels per 3 bytes, low nibble first:
#   byte0 = G1<<4|R1, byte1 = R2<<4|B1, byte2 = B2<<4|G2 (4 bits each),
# sent with no HTTP header (needs curl --http0.9).
# Two ways to draw it:
#   kitty  - real pixels via the Kitty graphics protocol (Ghostty, kitty, WezTerm, Konsole): sharp
#   blocks - 24-bit colour half blocks (any terminal): blurry below ~160 columns
# Picked from $TERM / $TERM_PROGRAM; force one with SB_SCREEN=kitty or SB_SCREEN=blocks.

fetch_screen() {   # $1 = output file; fails unless a full 115200-byte frame arrives
  curl -s --http0.9 -m 30 -o "$1" "$SB/getscreen.bin"
  [ "$(stat -c %s "$1" 2>/dev/null)" = 115200 ] || { echo "could not read the Starbook screen"; return 1; }
}

screen_mode() {
  case "${SB_SCREEN:-}" in kitty|blocks) echo "$SB_SCREEN"; return ;; esac
  case "$TERM:${TERM_PROGRAM:-}" in *kitty*|*ghostty*|*:WezTerm|*konsole*) echo kitty ;; *) echo blocks ;; esac
}

# Kitty graphics: send raw RGB (f=24) in base64, 4096-byte chunks; the terminal scales it to $2 columns.
draw_kitty() {   # $1 = frame file, $2 = columns
  od -An -v -tu1 "$1" | LC_ALL=C awk '
    { for (i = 1; i <= NF; i++) b[n++] = $i }
    END { for (k = 0; k < n; k += 3) {
            printf "%c%c%c", (b[k] % 16) * 17, int(b[k] / 16) * 17, (b[k+1] % 16) * 17
            printf "%c%c%c", int(b[k+1] / 16) * 17, (b[k+2] % 16) * 17, int(b[k+2] / 16) * 17 } }' |
    base64 -w0 | fold -w 4096 | awk -v c="$2" '
      function send(chunk, more) {
        if (first) printf "\033_Gf=24,s=320,v=240,a=T,q=2,c=%d,m=%d;%s\033\\", c, more, chunk
        else       printf "\033_Gm=%d;%s\033\\", more, chunk
        first = 0 }
      BEGIN { first = 1 }
      NR > 1 { send(prev, 1) }
      { prev = $0 }
      END { send(prev, 0); print "" }'
}

# Half blocks: upper half = foreground, lower half = background; each cell averages a box.
draw_blocks() {   # $1 = frame file, $2 = columns (2..320)
  od -An -v -tu1 "$1" | awk -v cols="$2" '
    { for (i = 1; i <= NF; i++) b[n++] = $i }
    END {
      for (p = 0; p < 76800; p++) {                 # decode 12-bit pixels
        k = int(p / 2) * 3
        if (p % 2 == 0) { r = b[k] % 16; g = int(b[k] / 16); bl = b[k+1] % 16 }
        else            { r = int(b[k+1] / 16); g = b[k+2] % 16; bl = int(b[k+2] / 16) }
        R[p] = r * 17; G[p] = g * 17; B[p] = bl * 17
      }
      s = 320 / cols; h = int(240 / s); if (h % 2) h--  # image rows after scaling (even)
      for (y = 0; y < h; y += 2) {
        line = ""; last = ""
        for (x = 0; x < cols; x++) {
          for (half = 0; half < 2; half++) {
            x0 = int(x * s); x1 = int((x + 1) * s); if (x1 <= x0) x1 = x0 + 1
            y0 = int((y + half) * s); y1 = int((y + half + 1) * s); if (y1 <= y0) y1 = y0 + 1
            sr = sg = sb = cnt = 0
            for (yy = y0; yy < y1 && yy < 240; yy++) for (xx = x0; xx < x1 && xx < 320; xx++) {
              q = yy * 320 + xx; sr += R[q]; sg += G[q]; sb += B[q]; cnt++ }
            c[half] = int(sr / cnt) ";" int(sg / cnt) ";" int(sb / cnt)
          }
          col = c[0] "|" c[1]
          if (col != last) { line = line "\033[38;2;" c[0] "m\033[48;2;" c[1] "m"; last = col }
          line = line "\342\226\200"                # U+2580 upper half block
        }
        print line "\033[0m"
      }
    }'
}

# Width to draw at: $1 if given, else the terminal width; for kitty also keep the 4:3 image
# (about 3/8 as many rows as columns, cells being ~1:2) inside the terminal height.
screen_cols() {
  local c=${1:-$(tput cols 2>/dev/null || echo 80)} l
  l=$(tput lines 2>/dev/null || echo 30)
  if [ "$(screen_mode)" = kitty ] && [ -z "$1" ] && [ $(( c * 3 / 8 )) -gt $(( l - 2 )) ]; then c=$(( (l - 2) * 8 / 3 )); fi
  [ "$c" -gt 320 ] && c=320; [ "$c" -lt 2 ] && c=2
  echo "$c"
}

draw_screen() {   # $1 = columns
  local tmp; tmp=$(mktemp) || return 1
  fetch_screen "$tmp" || { rm -f "$tmp"; return 1; }
  if [ "$(screen_mode)" = kitty ]; then draw_kitty "$tmp" "$1"; else draw_blocks "$tmp" "$1"; fi
  rm -f "$tmp"
}

case "$1" in
  screen)
    # Show the Starbook's screen in the terminal. Optional width in columns (default: fit the terminal).
    [ -z "$2" ] || [[ "$2" =~ ^[0-9]+$ ]] || { echo "usage: $0 screen [COLUMNS]"; exit 1; }
    draw_screen "$(screen_cols "$2")" ;;
  watch)
    # Redraw the Starbook's screen every SEC seconds (default 5) until Ctrl-C.
    sec=${2:-5}; [[ "$sec" =~ ^[0-9]+$ ]] && [ "$sec" -ge 1 ] || { echo "usage: $0 watch [SECONDS]"; exit 1; }
    trap 'printf "\033[0m\033[?25h\n"; exit 0' INT TERM
    printf '\033[?25l\033[2J'
    while :; do
      out=$(draw_screen "$(screen_cols)")
      [ "$(screen_mode)" = kitty ] && printf '\033_Ga=d,d=A,q=2\033\\'   # drop the previous frame
      printf '\033[H%s\n\033[0m%s  (every %ss, Ctrl-C to quit)\033[K' "$out" "$(date +%T)" "$sec"
      sleep "$sec"
    done ;;
  indi-start)
    if [ -n "$SB_IFACE" ]; then
      ip -br addr show "$SB_IFACE" 2>/dev/null | grep -q "$SB_PI_ADDR" \
        || { echo "$SB_PI_ADDR is not on $SB_IFACE - run: sudo ip addr add $SB_PI_ADDR/16 dev $SB_IFACE"; exit 1; }
    fi
    if ! pgrep -x indiserver >/dev/null; then
      indiserver indi_starbook_telescope >"$LOG" 2>&1 &
      sleep 3
    fi
    set_ 'CONNECTION.CONNECT=On'
    for _ in $(seq 1 10); do
      [ "$(get CONNECTION.CONNECT)" = On ] && { echo "connected"; exec "$SELF" status; }
      sleep 1
    done
    echo "connect failed - see $LOG"; exit 1 ;;
  status)
    # read straight from the Starbook, so it works with or without indiserver
    s=$(st)
    [ -n "$s" ] || { echo "Starbook not answering - check its power and the LAN cable"; exit 1; }
    ra=$(echo "$s" | sed -E 's/.*RA=([0-9]+)\+([0-9.]+).*/\1h \2m/')
    dec=$(echo "$s" | sed -E 's/.*DEC=(-?[0-9]+)\+([0-9]+).*/\1 deg \2 min/')
    echo "state:    $(echo "$s" | sed -E 's/.*STATE=([A-Z]+).*/\1/')$(echo "$s" | grep -q 'GOTO=1' && echo '  (slewing)')"
    echo "RA:       $ra"
    echo "DEC:      $dec"
    # Alt/Az aren't in GETSTATUS: compute them from RA/Dec, the Pi's clock and the site.
    # Azimuth from north (N 0, E 90, S 180, W 270). Note: the Starbook screen counts from south (S 0, W 90).
    # RA (hours) and Dec (degrees) from the reply, e.g. RA=18+36.9&DEC=038+46 or DEC=-00+30
    read -r cra cdec <<<"$(echo "$s" | awk '{
      match($0, /RA=[0-9]+\+[0-9.]+/);  split(substr($0, RSTART + 3, RLENGTH - 3), r, "+")
      match($0, /DEC=-?[0-9]+\+[0-9]+/); dd = substr($0, RSTART + 4, RLENGTH - 4); split(dd, d, "+")
      printf "%.6f %.6f\n", r[1] + r[2] / 60, (dd ~ /^-/ ? -1 : 1) * ((d[1] < 0 ? -d[1] : d[1]) + d[2] / 60) }')"
    read -r slat slon _ <<<"$(site)"
    awk -v t="$(now)" -v ra="$cra" -v dec="$cdec" -v lat="$slat" -v lon="$slon" 'BEGIN {
      pi = atan2(0, -1); k = pi / 180
      j = t / 86400 + 2440587.5 - 2451545.0; lst = (18.697374558 + 24.06570982441908 * j + lon / 15) % 24
      ha = (lst - ra) * 15 * k; de = dec * k; la = lat * k
      x = sin(la) * sin(de) + cos(la) * cos(de) * cos(ha); alt = atan2(x, sqrt(1 - x * x)) / k
      az = atan2(-cos(de) * sin(ha), sin(de) * cos(la) - cos(de) * sin(la) * cos(ha)) / k; if (az < 0) az += 360
      s = az - 180; if (s < 0) s += 360
      printf "ALT:      %.1f deg%s\n", alt, (alt < 0 ? "  (below the horizon)" : "")
      printf "AZ:       %.1f deg from north  (Starbook screen, from south: %.1f)\n", az, s }'
    echo "CONST:    $(constellation "$cra" "$cdec")"
    echo "encoders: $(sbq GETXY.ASP)"
    echo "clock:    $(sbq GETTIME.ASP)   (Pi: $(local_date '+%Y %-m %-d %-H %-M %-S'))"
    read -r slat slon stz <<<"$(site)"; src="from the Starbook"; [ -n "$SB_LAT$SB_LON$SB_TZ" ] && src="SB_LAT/SB_LON/SB_TZ override"
    echo "site:     lat $slat, lon $slon, UTC$( [[ $stz == -* ]] || echo +)$stz  ($src)"
    echo "firmware: $(sbq VERSION.ASP | sed 's/version=//')"
    [ -e "$NOTHOME" ] && echo "flag:     NOT AT HOME - $(cat "$NOTHOME")"
    pgrep -x indiserver >/dev/null && echo "indi:     running" || echo "indi:     not running (only needed for KStars/PHD2)"
    meridian_status ;;
  settime)
    t=$(local_date '+%Y+%m+%d+%H+%M+%S')
    echo "SETTIME $t -> $(sbq "SETTIME?TIME=$t")" ;;
  homed)
    rm -f "$NOTHOME"; echo "ok - mount confirmed at home; unpark allowed" ;;
  unpark)
    guard
    # INDI loses its connection when the Starbook restarts (RESET, power loss): reconnect
    pgrep -x indiserver >/dev/null && [ "$(get CONNECTION.CONNECT)" != On ] && { set_ 'CONNECTION.CONNECT=On' 2>/dev/null; sleep 3; }
    set_ 'TELESCOPE_PARK.UNPARK=On' 2>/dev/null; sleep 2
    # the driver's UNPARK doesn't always leave INIT; START does the same thing directly
    [[ "$(st)" == *STATE=INIT* ]] && sbq START >/dev/null && sleep 2
    # after a restart the chart is garbled (labels stacked, no stars) until a zoom is set
    sbq "SETSPEED?speed=6" >/dev/null
    "$SELF" status ;;
  zoom)
    # Chart zoom = speed of manual moves: 0 (closest / slowest) .. 8 (whole sky / fastest). No motion.
    [[ "$2" =~ ^[0-8]$ ]] || { echo "usage: $0 zoom N   (0 = closest .. 8 = whole sky; 6 = normal)"; exit 1; }
    echo "zoom $2 -> $(sbq "SETSPEED?speed=$2")" ;;
  goto)
    # Slew to a named object (sky_objects.txt) or to coordinates, watch the slew (auto-abort after
    # 180 s) and arm the automatic meridian flip.   goto NAME  |  goto RA DEC   (MOVES)
    if [ $# -eq 2 ]; then
      [ -r "$OBJECTS" ] || { echo "object file not found: $OBJECTS"; exit 1; }
      radec=$(awk -v n="$2" '{ sub(/\r$/, "") } !/^[[:space:]]*(#|$)/ && tolower($1) == tolower(n) { print $2, $3; exit }' "$OBJECTS")
      if [ -n "$radec" ]; then
        read -r ra_s dec_s <<<"$radec"; label="$2"
      elif cc=$(const_centre "$2"); then                     # not an object: a constellation?
        read -r ra_s dec_s cname <<<"$cc"; label="$2 (centre of $cname)"
      else
        echo "unknown object: $2 (not in $OBJECTS or a constellation - see '$0 objects')"; exit 1
      fi
    elif [ $# -eq 3 ]; then
      ra_s=$2; dec_s=$3; label="target"
    else
      echo "usage: $0 goto NAME   |   $0 goto RA DEC   (RA hh:mm:ss hours, DEC decimal degrees)"; exit 1
    fi
    ra=$(todec "$ra_s" 24); dec=$(todec "$dec_s" 90)
    [ -n "$ra" ] && [ -n "$dec" ] || { echo "bad coordinates for $label: RA=$ra_s DEC=$dec_s (RA hh:mm:ss 0-24 h, DEC decimal degrees -90..90)"; exit 1; }
    guard
    echo "$label: RA $ra_s  DEC $dec_s  (the Starbook refuses targets below its horizon)"
    [[ "$(st)" == *STATE=SCOPE* || "$(st)" == *STATE=CHART* ]] || "$SELF" unpark >/dev/null
    [[ "$(st)" == *STATE=SCOPE* || "$(st)" == *STATE=CHART* ]] || { echo "Starbook not in Scope mode - not slewing"; exit 1; }
    flip_stop >/dev/null
    goto_send "$ra" "$dec" || { echo "Starbook rejected the GoTo - not slewing"; exit 1; }
    flip_start "$ra" "$dec"
    watch_slew "$ra" "$dec" ;;
  objects)
    # List the targets in sky_objects.txt; optional TEXT filters names and notes (e.g. galaxy, Orion)
    [ -r "$OBJECTS" ] || { echo "object file not found: $OBJECTS"; exit 1; }
    awk -v q="$2" '{ sub(/\r$/, "") } !/^[[:space:]]*(#|$)/ && (q == "" || index(tolower($0), tolower(q))) {
        c = ""; if ((k = index($0, "#")) > 0) c = substr($0, k + 1); sub(/^ */, "", c)
        printf "  %-18s RA %-11s DEC %+9.4f  %s\n", $1, $2, $3, c; n++ }
      END { printf "%d object(s)%s in %s\n", n, (q == "" ? "" : " matching \"" q "\""), FILENAME }' "$OBJECTS"
    # constellation centres ("goto Lyr" / "goto Lyra")
    awk -v q="$2" '{ sub(/\r$/, "") }
      /^= / { ab = $2; $1 = ""; $2 = ""; sub(/^  */, ""); full[ab] = $0; next }
      /^c / { k = index($0, "#"); c = substr($0, k + 2)
              if (q == "" || index(tolower($2 " " full[$2] " constellation"), tolower(q))) {
                if (!n++) print "constellation centres (goto ABBR or full name):"
                printf "  %-18s RA %-11s DEC %+9.4f  %s, %s\n", $2, $3, $4, full[$2], c } }
      END { if (n) printf "%d constellation(s)%s in %s\n", n, (q == "" ? "" : " matching \"" q "\""), FILENAME }' "$CONST" ;;
  meridian)
    # Automatic meridian flip for GoTo targets: meridian [on|off|MIN]
    read -r m n <<<"$(meridian_get)"
    case "$2" in
      "") ;;
      on)  m=on ;;
      off) m=off; flip_stop ;;
      *) [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] && [ "$2" -le 15 ] || { echo "usage: $0 meridian [on|off|MIN]   (MIN = minutes after the meridian, 1-15)"; exit 1; }
         m=on; n=$2 ;;
    esac
    [ -n "$2" ] && echo "$m $n" >"$MERIDIAN"
    if [ "$m" = on ]; then echo "meridian flip: on, $n min after the meridian"; else echo "meridian flip: off (press Yes on the Starbook when it asks)"; fi
    if [ -r "$FLIPPID" ] && read -r pid <"$FLIPPID" && kill -0 "$pid" 2>/dev/null && [ -r "$TARGET" ]; then
      read -r tra _ <"$TARGET"; ha=$(hour_angle "$tra")
      echo "watcher running for RA $tra h: target $(awk "BEGIN{printf \"%+.1f\", $ha * 60}") min from the meridian"
    fi ;;
  _complete)
    # (internal) words for bash tab completion: _complete commands | _complete CMD PREFIX
    case "$2" in
      commands) sed -n '2,/^$/p' "$SELF" | awk '/^#   sb\.sh [a-z]/ { print $3 }' | sed 's/|.*//' | sort -u ;;
      goto) awk -v q="$3" 'BEGIN { q = tolower(q) } { sub(/\r$/, "") }
              FILENAME ~ /constellations/ && /^= / { ab = $2; $1 = ""; $2 = ""; sub(/^  */, ""); f = $0; gsub(/ /, "_", f)
                                                    if (index(tolower(ab), q) == 1) print ab; if (index(tolower(f), q) == 1) print f; next }
              FILENAME !~ /constellations/ && !/^[[:space:]]*(#|$)/ && index(tolower($1), q) == 1 { print $1 }' "$OBJECTS" "$CONST" | sort -u ;;
      meridian) printf '%s\n' on off 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 ;;
      nudge) printf '%s\n' N S E W ;;
      zoom) printf '%s\n' 0 1 2 3 4 5 6 7 8 ;;
      init) echo -y ;;
    esac ;;
  _flipwatch)
    # (internal) background watcher started by goto: $2 RA, $3 DEC, $4 minutes after the meridian
    tra=$2; tdec=$3; flip=$4
    echo "$(date '+%F %T') watching RA $tra DEC $tdec: flip $flip min after the meridian"
    while :; do
      [ "$(cat "$TARGET" 2>/dev/null)" = "$tra $tdec" ] || { echo "$(date +%T) target changed - exiting"; break; }
      s=$(st); ha=$(hour_angle "$tra")
      case "$s" in
        "") ;;                                                      # no reply: try again
        *STATE=INIT*) echo "$(date +%T) Starbook restarted - exiting"; echo "restart while tracking $(date +%T)" >"$NOTHOME"; break ;;
        *STATE=USER*) echo "$(date +%T) Starbook is showing a prompt - press Yes on the Starbook" ;;
        *GOTO=0*)
          if awk "BEGIN{exit !($ha >= $flip / 60)}"; then
            read -r x0 _ <<<"$(xy)"
            echo "$(date +%T) HA $(awk "BEGIN{printf \"%+.1f\", $ha * 60}") min: re-sending the GoTo so the Starbook flips"
            if goto_send "$tra" "$tdec" && watch_slew; then
              read -r x1 _ <<<"$(xy)"
              if [ -n "$x0" ] && [ -n "$x1" ]; then
                echo "$(date +%T) flip done: RA axis moved $(( x1 - x0 )) counts ($(awk "BEGIN{printf \"%.0f\", ($x1 - $x0) / 24000}") deg)"
              else echo "$(date +%T) flip done (encoders not readable)"; fi
            else
              echo "$(date +%T) FLIP FAILED - check the mount (power? see messages above)"
            fi
            break
          fi ;;
      esac
      sleep 30
    done
    rm -f "$FLIPPID" ;;
  nudge)
    # Short manual move to centre a star: nudge N|S|E|W SECONDS [SPEED 1-8, default 3]   (MOVES)
    dir=$(echo "$2" | tr a-z A-Z); secs=$3; speed=${4:-3}
    case "$dir" in N|S|E|W) ;; *) echo "usage: $0 nudge N|S|E|W SECONDS [SPEED 1-8]"; exit 1;; esac
    awk "BEGIN{exit !($secs > 0 && $secs <= 10)}" || { echo "SECONDS must be 0-10"; exit 1; }
    [[ "$speed" =~ ^[1-8]$ ]] || { echo "SPEED must be 1-8"; exit 1; }
    [[ "$(st)" == *STATE=SCOPE* ]] || { echo "Starbook not in SCOPE mode"; exit 1; }
    sbq "SETSPEED?speed=$speed" >/dev/null
    case $dir in N) move 1 0 0 0;; S) move 0 1 0 0;; E) move 0 0 1 0;; W) move 0 0 0 1;; esac
    sleep "$secs"; move
    echo "nudged $dir for ${secs}s at speed $speed: $(st)" ;;
  align)
    # Tell the Starbook the last GoTo target is now centred (adds an alignment star).
    r=$(sbq ALIGN); echo "ALIGN -> $r"; [ "$r" = OK ] ;;
  init)
    # Start clean: stop INDI and any meridian watcher, Starbook to INIT (both motors stop),
    # clear the not-at-home flag. The mount must be at home. The clock is left alone: check the
    # reminder and run "settime" yourself if needed (the Pi may have no internet time).
    if [ "$2" != -y ]; then
      read -r -p "Is the mount physically at home (counterweight down, tube level)? [y/N] " a
      [[ "$a" == [yY]* ]] || { echo "not done - move the mount home by hand first"; exit 1; }
    fi
    flip_stop
    pkill -x indiserver && echo "indiserver stopped"
    echo -n "waiting for the Starbook"
    for _ in $(seq 1 60); do [ -n "$(st)" ] && break; echo -n "."; sleep 3; done; echo
    [ -n "$(st)" ] || { echo "Starbook not answering - check its power and the LAN cable"; exit 1; }
    [[ "$(st)" == *STATE=INIT* ]] || do_reset || { echo "reset to INIT failed"; exit 1; }
    rm -f "$NOTHOME"
    echo "init done: $(st)"
    site refresh >/dev/null                          # re-read the site from the Starbook
    # Reminder: compare the Starbook clock with the Pi's (both in the Starbook's time zone).
    sbt=$(sbq GETTIME.ASP)
    sbs=$(echo "$sbt" | awk '{ printf "%04d-%02d-%02d %02d:%02d:%02d", $1, $2, $3, $4, $5, $6 }')
    sbe=$(date -u -d "$sbs" +%s 2>/dev/null) && sbe=$(awk -v t="$sbe" -v z="$(tzh)" 'BEGIN { printf "%d", t - z * 3600 }')
    diff=$(( ${sbe:-0} - $(now) ))
    ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    echo
    echo "Reminder - the clock was NOT changed:"
    echo "  Starbook clock: $sbs"
    echo "  Pi clock:       $(local_date '+%F %T')   (internet time sync: ${ntp:-unknown}; Starbook time zone UTC$( [[ $(tzh) == -* ]] || echo +)$(tzh))"
    if [ -z "$sbe" ]; then
      echo "  Could not read the Starbook clock."
    elif [ ${diff#-} -le 60 ]; then
      echo "  They agree (${diff} s) - nothing to do."
    else
      off=$(awk -v d="${diff#-}" 'BEGIN { if (d >= 86400) printf "%.0f days", d / 86400; else if (d >= 3600) printf "%.1f hours", d / 3600; else printf "%.0f minutes", d / 60 }')
      [ "${sbs:0:4}" = 2000 ] && off="$off - it reset to 2000-01-01 at power-up"
      echo "  The Starbook clock is off by $off. Its horizon check and GoTo pointing use this clock."
      [ "$ntp" = yes ] || echo "  The Pi's clock is not internet-synced: check it (e.g. 'date') before copying it."
      echo "  To set it from the Pi, run now, before 'unpark' (it only works on the startup screen):"
      echo "    $0 settime"
    fi
    echo "Next: $0 unpark, then $0 goto NAME" ;;
  abort)
    flip_stop
    set_ 'TELESCOPE_ABORT_MOTION.ABORT=On' 2>/dev/null
    sbq STOP >/dev/null; move      # belt and braces
    echo "abort sent" ;;
  park)
    guard
    flip_stop
    echo "GOHOME -> $(sbq 'GOHOME?HOME=0' | cut -c1-2)"
    watch_slew ;;
  indi-stop)
    set_ 'CONNECTION.DISCONNECT=On' 2>/dev/null; sleep 1; pkill -x indiserver; echo "indiserver stopped" ;;
  *)
    sed -n '2,23p' "$SELF" | sed 's/^# \{0,1\}//' ;;
esac
