# bash completion for sb / sb.sh (installed by install.sh)
# Completes commands, then arguments: goto names (objects and constellations, any case), meridian
# on/off/minutes, nudge directions, zoom levels, init -y.
_sb_complete() {
  local cur=${COMP_WORDS[COMP_CWORD]} prog=${COMP_WORDS[0]} words
  command -v "$prog" >/dev/null 2>&1 || prog=sb          # e.g. "sb.sh" typed but not on PATH
  if [ "$COMP_CWORD" -eq 1 ]; then
    words=$("$prog" _complete commands 2>/dev/null)
    mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
  elif [ "$COMP_CWORD" -eq 2 ]; then
    case ${COMP_WORDS[1]} in
      goto) mapfile -t COMPREPLY < <("$prog" _complete goto "$cur" 2>/dev/null) ;;   # matched case-insensitively
      meridian|nudge|zoom|init)
        words=$("$prog" _complete "${COMP_WORDS[1]}" 2>/dev/null)
        mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur") ;;
    esac
  fi
}
complete -F _sb_complete sb sb.sh
