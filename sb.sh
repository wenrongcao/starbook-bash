#!/bin/bash
# Control the Vixen Starbook (original) over HTTP from a Raspberry Pi; INDI is optional.
# Link: Pi -> TP-Link USB-LAN (enx6c5ab0b3b739, 169.254.1.2/16) -> Starbook 169.254.1.1
#
#   sb.sh indi-start       start the INDI server + Starbook driver (only for KStars/Ekos/PHD2)
#   sb.sh status           show state, RA/Dec, encoders, clock, firmware
#   sb.sh settime          set Starbook clock from the Pi (Starbook must be at INIT screen)
#   sb.sh homed            confirm the mount is at home (after init away from home, or a power cut)
#   sb.sh unpark           leave INIT/park and enter Scope mode        (no motion)
#   sb.sh goto RA DEC      slew; RA hh:mm:ss (hours), DEC decimal degrees, e.g. goto 00:42:44 +41.2692  (MOVES)
#   sb.sh star NAME        slew to a star from stars.txt (e.g. Vega), watch it, auto-abort  (MOVES)
#   sb.sh stars            list the stars in stars.txt
#   sb.sh nudge N|S|E|W SEC [SPEED]  short move to centre a star (1-8, default 3)  (MOVES)
#   sb.sh align            last GoTo target is now centred -> add alignment star
#   sb.sh zoom N           chart zoom 0 (closest) .. 8 (whole sky); also the manual-move speed
#   sb.sh init             reset to INIT where it is: both motors stop     (no motion)
#   sb.sh reset [-y]       reset everything: INDI off, INIT, clock set, not-at-home flag cleared (mount must be home)
#   sb.sh screen [COLS]    show the Starbook screen in the terminal (24-bit colour)
#   sb.sh watch [SEC]      redraw the Starbook screen every SEC seconds (default 5), Ctrl-C quits
#   sb.sh abort            stop all motion
#   sb.sh park             go to home position and watch the slew       (MOVES)
#   sb.sh indi-stop        disconnect and shut down the INDI server

SELF=$(readlink -f "$0")               # absolute path, so "bash sb.sh" can call itself
DEV=Starbook
IFACE=enx6c5ab0b3b739
SB=http://169.254.1.1
LOG=/tmp/indiserver-starbook.log
NOTHOME=$HOME/starbook/.not_at_home   # set when the Starbook no longer knows the mount is at home
STARS=${SB_STARS:-$(dirname "$SELF")/stars.txt}   # star list for "star NAME"; override with SB_STARS=file

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

# Watch a GoTo/GoHome until the Starbook reports it finished; abort after 180 s.
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

# ---- Starbook screen in the terminal -------------------------------------------------
# getscreen.bin: 320x240, 12-bit colour, 2 pixels per 3 bytes [R1 G1][B1 R2][G2 B2] (4 bits each),
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
            printf "%c%c%c", int(b[k] / 16) * 17, (b[k] % 16) * 17, int(b[k+1] / 16) * 17
            printf "%c%c%c", (b[k+1] % 16) * 17, int(b[k+2] / 16) * 17, (b[k+2] % 16) * 17 } }' |
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
        if (p % 2 == 0) { r = int(b[k] / 16); g = b[k] % 16; bl = int(b[k+1] / 16) }
        else            { r = b[k+1] % 16; g = int(b[k+2] / 16); bl = b[k+2] % 16 }
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
    ip -br addr show "$IFACE" 2>/dev/null | grep -q 169.254.1.2 \
      || { echo "169.254.1.2 is not on $IFACE - run: sudo ip addr add 169.254.1.2/16 dev $IFACE"; exit 1; }
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
    echo "encoders: $(sbq GETXY.ASP)"
    echo "clock:    $(sbq GETTIME.ASP)   (Pi: $(TZ=Etc/GMT+7 date '+%Y %-m %-d %-H %-M %-S'))"
    echo "firmware: $(sbq VERSION.ASP | sed 's/version=//')"
    [ -e "$NOTHOME" ] && echo "flag:     NOT AT HOME - $(cat "$NOTHOME")"
    pgrep -x indiserver >/dev/null && echo "indi:     running" || echo "indi:     not running (only needed for KStars/PHD2)" ;;
  settime)
    t=$(TZ=Etc/GMT+7 date '+%Y+%m+%d+%H+%M+%S')
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
    guard
    [ $# -eq 3 ] || { echo "usage: $0 goto RA DEC   (RA hh:mm:ss hours, DEC decimal degrees)"; exit 1; }
    ra=$(todec "$2" 24); dec=$(todec "$3" 90)
    [ -n "$ra" ] && [ -n "$dec" ] || { echo "bad coordinates: RA=$2 DEC=$3 (RA hh:mm:ss 0-24 h, DEC decimal degrees -90..90)"; exit 1; }
    set -- "$1" "$ra" "$dec"
    # Direct HTTP, same format as the INDI driver: RA=HH+MM.t&DEC=[-]DDD+MM (works without indiserver)
    q=$(awk -v ra="$2" -v dec="$3" 'BEGIN{
      ra = ra % 24; if (ra < 0) ra += 24; rm = int(ra * 600 + 0.5); rh = int(rm / 600) % 24; rm = rm % 600
      s = (dec < 0) ? "-" : ""; d = (dec < 0) ? -dec : dec; dm = int(d * 60 + 0.5)
      printf "RA=%02d+%02d.%d&DEC=%s%03d+%02d", rh, int(rm / 10), rm % 10, s, int(dm / 60), dm % 60 }')
    r=$(sbq "GOTORADEC?$q")
    echo "GOTORADEC?$q -> $r  (abort: $0 abort)"
    [[ "$r" == OK* ]] ;;
  stars)
    # List the targets in the star file
    [ -r "$STARS" ] || { echo "star file not found: $STARS"; exit 1; }
    echo "targets in $STARS:"
    awk '{ sub(/\r$/, "") } !/^[[:space:]]*(#|$)/ { printf "  %-16s RA %-12s DEC %s\n", $1, $2, $3 }' "$STARS" ;;
  star)
    # Slew to a target from the star file and watch the slew; aborts after 180 s.   (MOVES)
    [ -r "$STARS" ] || { echo "star file not found: $STARS"; exit 1; }
    [ $# -eq 2 ] || { echo "usage: $0 star NAME   (see '$0 stars' for the list in $STARS)"; exit 1; }
    radec=$(awk -v n="$2" '{ sub(/\r$/, "") } !/^[[:space:]]*(#|$)/ && tolower($1) == tolower(n) { print $2, $3; exit }' "$STARS")
    [ -n "$radec" ] || { echo "unknown star: $2 (not in $STARS - see '$0 stars')"; exit 1; }
    read -r ra_s dec_s <<<"$radec"
    ra=$(todec "$ra_s" 24); dec=$(todec "$dec_s" 90)
    [ -n "$ra" ] && [ -n "$dec" ] || { echo "bad coordinates for $2 in $STARS: RA=$ra_s DEC=$dec_s (RA hh:mm:ss 0-24 h, DEC decimal degrees -90..90)"; exit 1; }
    guard
    echo "$2: RA $ra_s  DEC $dec_s  (the Starbook refuses targets below its horizon)"
    [[ "$(st)" == *STATE=SCOPE* ]] || "$SELF" unpark >/dev/null
    [[ "$(st)" == *STATE=SCOPE* ]] || { echo "Starbook not in SCOPE mode - not slewing"; exit 1; }
    "$SELF" goto "$ra" "$dec" || { echo "Starbook rejected the GoTo - not slewing"; exit 1; }
    watch_slew ;;
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
    # RESET the Starbook to its INIT screen where the mount is now: both motors stop (no motion).
    # INIT forgets the position. If the mount is not at home (encoders > 1 deg from home),
    # unpark/goto are blocked until it is moved home by hand and "homed" is run.
    [[ "$(st)" == *STATE=INIT* ]] && { echo "already in INIT"; exit 0; }
    read -r x y <<<"$(xy)"
    [ -n "$x" ] || { echo "could not read encoders - not resetting"; exit 1; }
    if [ ${x#-} -gt 24000 ] || [ ${y#-} -gt 24000 ]; then
      echo "not at home (X=$x Y=$y counts from home) - after INIT move it home by hand, then: $0 homed"
      echo "init away from home at $(date +%T), encoders X=$x Y=$y" >"$NOTHOME"
    else
      echo "at home (X=$x Y=$y, within 1 deg)"
    fi
    do_reset ;;
  reset)
    # Reset everything to a clean start: stop INDI, Starbook to INIT (motors stop),
    # clock from the Pi, clear the not-at-home flag. The mount must be at home.
    if [ "$2" != -y ]; then
      read -r -p "Is the mount physically at home (counterweight down, tube level)? [y/N] " a
      [[ "$a" == [yY]* ]] || { echo "not reset - move the mount home by hand first"; exit 1; }
    fi
    pkill -x indiserver && echo "indiserver stopped"
    echo -n "waiting for the Starbook"
    for _ in $(seq 1 60); do [ -n "$(st)" ] && break; echo -n "."; sleep 3; done; echo
    [ -n "$(st)" ] || { echo "Starbook not answering - check its power and the LAN cable"; exit 1; }
    [[ "$(st)" == *STATE=INIT* ]] || do_reset || { echo "reset to INIT failed"; exit 1; }
    "$SELF" settime
    rm -f "$NOTHOME"
    echo "reset done: $(st)  clock $(sbq GETTIME.ASP)" ;;
  abort)
    set_ 'TELESCOPE_ABORT_MOTION.ABORT=On' 2>/dev/null
    sbq STOP >/dev/null; move      # belt and braces
    echo "abort sent" ;;
  park)
    guard
    echo "GOHOME -> $(sbq 'GOHOME?HOME=0' | cut -c1-2)"
    watch_slew ;;
  indi-stop)
    set_ 'CONNECTION.DISCONNECT=On' 2>/dev/null; sleep 1; pkill -x indiserver; echo "indiserver stopped" ;;
  *)
    sed -n '2,22p' "$SELF" | sed 's/^# \{0,1\}//' ;;
esac
