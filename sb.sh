#!/bin/bash
# Control the Vixen Starbook (original) through INDI, without KStars.
# Link: Pi -> TP-Link USB-LAN (enx6c5ab0b3b739, 169.254.1.2/16) -> Starbook 169.254.1.1
#
#   sb.sh start            start indiserver + Starbook driver and connect
#   sb.sh status           show state, RA/Dec, firmware
#   sb.sh settime          set Starbook clock from the Pi (Starbook must be at INIT screen)
#   sb.sh homed            confirm the mount is at home (after init away from home, or a power cut)
#   sb.sh unpark           leave INIT/park and enter Scope mode        (no motion)
#   sb.sh goto RA DEC      slew; RA in hours, DEC in degrees, e.g. goto 0.712 41.27   (MOVES)
#   sb.sh star NAME        slew to a bright star (e.g. Vega), watch it, auto-abort  (MOVES)
#   sb.sh nudge N|S|E|W SEC [SPEED]  short move to centre a star (1-8, default 3)  (MOVES)
#   sb.sh align            last GoTo target is now centred -> add alignment star
#   sb.sh init             reset to INIT where it is: both motors stop     (no motion)
#   sb.sh reset [-y]       reset everything: INDI off, INIT, clock set, flags cleared (mount must be home)
#   sb.sh abort            stop all motion
#   sb.sh park             go to home position and watch the slew       (MOVES)
#   sb.sh stop             disconnect and shut down indiserver

SELF=$(readlink -f "$0")               # absolute path, so "bash sb.sh" can call itself
DEV=Starbook
IFACE=enx6c5ab0b3b739
SB=http://169.254.1.1
LOG=/tmp/indiserver-starbook.log
NOTHOME=$HOME/starbook/.not_at_home   # set when the Starbook no longer knows the mount is at home

get() { indi_getprop -t 3 -1 "$DEV.$1" 2>/dev/null; }
set_() { indi_setprop "$DEV.$1"; }
sbq() { curl -s -m 3 "$SB/$1" | sed 's/<[^>]*>//g' | tr -d '\r\n' | sed 's/^ *//; s/ *$//'; }   # direct HTTP command
st() { sbq GETSTATUS.ASP; }
xy() { sbq GETXY.ASP | sed -E 's/X=(-?[0-9]+)&Y=(-?[0-9]+)/\1 \2/'; }  # prints "X Y"
guard() { [ -e "$NOTHOME" ] && { echo "REFUSED: mount may not be at home ($(cat "$NOTHOME")). Move it home by hand, then: $0 homed"; exit 1; }; }
move() { sbq "MOVE?NORTH=${1:-0}&SOUTH=${2:-0}&EAST=${3:-0}&WEST=${4:-0}" >/dev/null; }

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

case "$1" in
  start)
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
    "$SELF" status ;;
  goto)
    guard
    [ $# -eq 3 ] || { echo "usage: $0 goto RA_hours DEC_degrees"; exit 1; }
    # Direct HTTP, same format as the INDI driver: RA=HH+MM.t&DEC=[-]DDD+MM (works without indiserver)
    q=$(awk -v ra="$2" -v dec="$3" 'BEGIN{
      ra = ra % 24; if (ra < 0) ra += 24; rm = int(ra * 600 + 0.5); rh = int(rm / 600) % 24; rm = rm % 600
      s = (dec < 0) ? "-" : ""; d = (dec < 0) ? -dec : dec; dm = int(d * 60 + 0.5)
      printf "RA=%02d+%02d.%d&DEC=%s%03d+%02d", rh, int(rm / 10), rm % 10, s, int(dm / 60), dm % 60 }')
    r=$(sbq "GOTORADEC?$q")
    echo "GOTORADEC?$q -> $r  (abort: $0 abort)"
    [[ "$r" == OK* ]] ;;
  star)
    # Slew to a named bright star and watch the slew; aborts after 180 s.   (MOVES)
    [ $# -eq 2 ] || { echo "usage: $0 star NAME   (Vega Deneb Altair Arcturus Capella Polaris Sirius Betelgeuse Rigel Aldebaran Antares Spica Regulus Fomalhaut)"; exit 1; }
    # RA (hours) and Dec (degrees), J2000
    case "$(echo "$2" | tr A-Z a-z)" in
      vega) radec="18.6156 38.7837" ;;       deneb) radec="20.6905 45.2803" ;;
      altair) radec="19.8464 8.8683" ;;      arcturus) radec="14.2610 19.1824" ;;
      capella) radec="5.2782 45.9980" ;;     polaris) radec="2.5302 89.2641" ;;
      sirius) radec="6.7525 -16.7161" ;;     betelgeuse) radec="5.9195 7.4071" ;;
      rigel) radec="5.2423 -8.2016" ;;       aldebaran) radec="4.5987 16.5093" ;;
      antares) radec="16.4901 -26.4320" ;;   spica) radec="13.4199 -11.1613" ;;
      regulus) radec="10.1395 11.9672" ;;    fomalhaut) radec="22.9608 -29.6222" ;;
      *) radec="" ;;
    esac
    [ -n "$radec" ] || { echo "unknown star: $2"; exit 1; }
    read -r ra dec <<<"$radec"
    guard
    echo "$2: RA $ra h, DEC $dec deg  (the Starbook refuses targets below its horizon)"
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
    # clock from the Pi, clear the script's flags. The mount must be at home.
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
  stop)
    set_ 'CONNECTION.DISCONNECT=On' 2>/dev/null; sleep 1; pkill -x indiserver; echo "indiserver stopped" ;;
  *)
    sed -n '2,19p' "$SELF" | sed 's/^# \{0,1\}//' ;;
esac
