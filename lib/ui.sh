# Terminal look: colours and icons on a real terminal, plain ASCII markers everywhere else
# (pipes, files, chat copies, tests), so escape codes never leak into logs.
# Loaded after common.sh and replaces its plain output helpers.

ui_init() {
  if [ -t 1 ] && [ -z "$NO_COLOR" ] && [ "$TERM" != dumb ] && [ "$PLAIN" != 1 ]; then UI_FANCY=1; else UI_FANCY=0; fi
  [ "$SB_COLOR" = 1 ] && [ "$PLAIN" != 1 ] && UI_FANCY=1   # force colours (previews, tests)
  if [ "$UI_FANCY" = 1 ]; then
    e=$(printf '\033')
    C0="$e[0m"; CB="$e[1m"; CD="$e[2m"; CR="$e[31m"; CG="$e[32m"; CY="$e[33m"; CC="$e[36m"
    I_OK="${CG}✓${C0}"; I_SKIP="${CD}·${C0}"; I_WARN="${CY}!${C0}"; I_BAD="${CR}✗${C0}"; I_DRY="${CC}»${C0}"
    LINE="──────────────────────────────────────────────────────"
    ARROW="→"
  else
    C0=""; CB=""; CD=""; CR=""; CG=""; CY=""; CC=""
    I_OK="[ok]"; I_SKIP="[--]"; I_WARN="[!!]"; I_BAD="[XX]"; I_DRY="[dry]"
    LINE="------------------------------------------------------"
    ARROW="->"
  fi
}

say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s %s\n' "$I_OK" "$*"; ev item ok "$*"; }
skip() { printf '  %s %s%s%s\n' "$I_SKIP" "$CD" "$*" "$C0"; ev item skip "$*"; }
warn() { printf '  %s %s%s%s\n' "$I_WARN" "$CY" "$*" "$C0"; WARNINGS=$((WARNINGS+1)); ev item warn "$*"; }
bad()  { printf '  %s %s%s%s\n' "$I_BAD" "$CR" "$*" "$C0"; PROBLEMS=$((PROBLEMS+1)); ev item bad "$*"; }
dry()  { printf '  %s %s\n' "$I_DRY" "$*"; ev item dry "$*"; }
note() { printf '  %s%s%s\n' "$CD" "$*" "$C0"; }

# Section header. During installation STEP/STEPS give "[2/5]".
hr() {
  ev section "$*"
  if [ -n "$STEP" ]; then n="[$STEP/$STEPS] "; else n=""; fi
  if [ "$UI_FANCY" = 1 ]; then printf '\n%s━━ %s%s ━━%s\n' "$CB$CC" "$n" "$*" "$C0"
  else printf '\n=== %s%s ===\n' "$n" "$*"; fi
}
sub() { printf '\n  %s%s%s\n' "$CB" "$*" "$C0"; ev group "$*"; }   # small heading inside a section

banner() {   # banner TITLE LINE...  (no right border: Cyrillic width would break alignment)
  if [ "$UI_FANCY" = 1 ]; then top="╭${LINE}╮"; bottom="╰${LINE}╯"; else top=$LINE; bottom=$LINE; fi
  printf '\n%s%s%s\n' "$CC" "$top" "$C0"
  printf '  %s%s%s\n' "$CB" "$1" "$C0"; shift
  for l in "$@"; do printf '  %s%s%s\n' "$CD" "$l" "$C0"; done
  printf '%s%s%s\n' "$CC" "$bottom" "$C0"
}

menu_item() {   # menu_item NUM TITLE [DESCRIPTION] [recommended]
  tag=""; [ "$4" = recommended ] && tag=" ${CG}(рекомендуется)${C0}"
  printf '  %s%s)%s %s%s\n' "$CB$CC" "$1" "$C0" "$2" "$tag"
  [ -n "$3" ] && printf '     %s%s%s\n' "$CD" "$3" "$C0"
  return 0
}

verdict() {   # verdict 0|1|2 TEXT
  [ "$UI_FANCY" = 1 ] || { printf '\nИтог: %s\n' "$2"; return; }
  case $1 in
    0) printf '\n  %s✓ %s%s\n' "$CB$CG" "$2" "$C0" ;;
    1) printf '\n  %s! %s%s\n' "$CB$CY" "$2" "$C0" ;;
    *) printf '\n  %s✗ %s%s\n' "$CB$CR" "$2" "$C0" ;;
  esac
}

# Final table: one line per module with what happened to it.
summary_add() { SUMMARY="$SUMMARY
$1|$2|$3"; ev result "$1" "$2" "$3"; }   # icon-kind|title|detail
summary_show() {
  hr "Итог"
  printf '%s\n' "$SUMMARY" | while IFS='|' read -r k t d; do
    [ -n "$t" ] || continue
    case $k in ok) i=$I_OK ;; skip) i=$I_SKIP ;; warn) i=$I_WARN ;; *) i=$I_BAD ;; esac
    printf '  %s %s %s— %s%s\n' "$i" "$t" "$CD" "$d" "$C0"   # no column padding: Cyrillic is 2 bytes
  done
}
