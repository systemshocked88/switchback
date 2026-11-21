# Module "failover": automatic switch of the VPN tunnel. Based on the user's wg-failover script
# (Keenetic, 2026-11-07), with fixes: a lock left by a reboot no longer stops it for good, a pause when
# no standby answers, never "switches on" a tunnel that does not exist (on Keenetic that would create an
# empty one), moves only the dead tunnel's routes, the log is trimmed on every run.
# The installed script = common logic (below) + the platform's fo_* functions (pf_failover_funcs).

mod_failover() {
  hr "Автосмена VPN-туннеля"
  command -v pf_failover_funcs >/dev/null 2>&1 || { mod_skip "на этой прошивке автосмена пока не поддерживается"; return 0; }
  ifs=$(pf_vpn_ifaces)
  n=$(echo $ifs | wc -w)
  if [ "$n" -lt 2 ]; then
    mod_skip "нужно хотя бы два подключения WireGuard (основное и запасное), найдено: $n"; pf_vpn_hint; return 0
  fi
  say "  Если основной туннель перестанет пропускать трафик, маршруты (Telegram, Meta и др.) сами"
  say "  переедут на первый работающий запасной. Запасные держатся выключенными: VPN-сервисы часто"
  say "  обрывают одновременные подключения."
  first=$(tg_via); def=$first; for w in $ifs; do [ "$w" = "$first" ] || def="$def $w"; done
  ask "  Туннели по порядку (через пробел; Enter — все):" "$(echo $def)" failover_tunnels
  list=""
  for t in $REPLY; do echo "$ifs" | grep -qx "$t" && list="$list $t" || warn "нет подключения $t, пропускаю"; done
  list=$(echo $list)
  [ -n "$list" ] || { warn "список туннелей пуст, автосмена не поставлена"; return 0; }
  pf_cron_setup || fail "не удалось поставить curl/cron"
  sb_conf "$SB_DIR/failover.conf" "автосмены" "туннели: $list" <<EOF
# switchback: automatic VPN tunnel switch. Edit and it applies on the next minute.
TUNNELS="$list"
UP_WAIT=25
MAX_HS=180
DEAD_RUNS=3
COOLDOWN=10
RETRY=15
EOF
  tmp=/tmp/switchback.new.$$
  failover_script > "$tmp"
  install_file "$CRON1/wg-failover" "автосмена (проверка каждую минуту)" "$tmp" replace_failover
}

# sb_conf FILE "what" "ok text": write a settings file from stdin if it changed (journaled as ours)
sb_conf() {
  t=/tmp/switchback.conf.$$
  cat > "$t"
  if [ -f "$1" ] && cmp -s "$t" "$1"; then skip "настройки $2 не изменились"
  else
    [ -f "$1" ] || remember "file $1"
    write_file "$1" < "$t"
    ok "$3"
  fi
  rm -f "$t"
}

# placeholders in the installed scripts
script_subst() {
  sed -e "s|__PATH__|$SCRIPT_PATH|g" -e "s|__STATE__|$VAR_DIR|g" -e "s|__CONF__|$SB_DIR|g" \
      -e "s|__BOT__|$BOT|g" -e "s|__ROOT__|$ROOT|g" -e "s|__OWN__|$OWN_HOOK|g"
}

# script lock: a lock left by a run killed by a reboot or power cut (older than 15 min) is cleared
script_lock() {
cat <<'EOF'
mkdir -p "$S"
now=$(date +%s)
if ! mkdir "$S/lock" 2>/dev/null; then
  t=$(cat "$S/lock/t" 2>/dev/null || date -r "$S/lock" +%s 2>/dev/null || echo 0)   # no stamp: the lock's own time
  if [ $((now - t)) -gt 900 ]; then rm -rf "$S/lock"; mkdir "$S/lock" || exit 0
  elif [ -n "$1" ]; then
    # run by hand or by the bot (--pin, --force, ...): wait for the every-minute run to end. Leaving silently
    # here looked like "the command did nothing" (seen on a real router)
    w=0
    until mkdir "$S/lock" 2>/dev/null; do
      w=$((w+1)); [ "$w" -gt ${SB_LOCK_WAIT:-90} ] && { echo "занято: идёт плановая проверка, повторите через минуту"; exit 1; }
      sleep 1
    done
  else exit 0
  fi
fi
echo "$now" > "$S/lock/t"
trap 'rm -rf "$S/lock"' EXIT
trap 'exit 1' INT TERM HUP
# (never in --dry: LOG is /dev/null there, and "mv" over it once turned it into a plain file on a real router)
[ "$LOG" != /dev/null ] && [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 400 ] && tail -n 300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; [ $DRY = 1 ] && echo "$*"; }
send() {
  [ $DRY = 1 ] && { echo "ALERT: $1"; return; }
  [ -f "$BOT" ] || return 0
  TOKEN=""; CHAT=""; NTFY=""; . "$BOT"
  sb_send "$1"
}
EOF
notify_func
}

failover_script() {
  { cat <<'EOF'
#!/bin/sh
# WireGuard failover (switchback): every minute. The active tunnel is the one most VPN routes point to.
# If it has no handshake for MAX_HS s or passes no traffic, DEAD_RUNS runs in a row, the standby
# tunnels (kept OFF: VPN providers drop parallel connections) are switched on one by one in TUNNELS
# order; the first with a handshake AND traffic gets the dead tunnel's routes, the old one goes off.
# Test, changing nothing:  sh wg-failover --dry      Move by hand:  sh wg-failover --force NAME
export PATH=__PATH__
TUNNELS=""; UP_WAIT=25; MAX_HS=180; DEAD_RUNS=3; COOLDOWN=10; RETRY=15
[ -f __CONF__/failover.conf ] && . __CONF__/failover.conf
S=__STATE__/wg-failover
LOG=$S/log
BOT=__BOT__
DRY=0; [ "$1" = "--dry" ] && { DRY=1; S=/tmp/wg-failover-dry; LOG=/dev/null; }
FORCE=""; [ "$1" = "--force" ] && FORCE=$2
STANDBY_NOW=""; [ "$1" = "--standby" ] && STANDBY_NOW=1     # check the standby tunnels now (the bot's button)
EOF
  script_lock
  echo "# ---- platform part ----"
  pf_failover_funcs
  cat <<'EOF'
# ---- common part ----
# try_up NAME -> switch on, wait up to UP_WAIT s for a handshake and traffic; 0 = works (left on)
try_up() {
  fo_exists "$1" || { log "$1 is not on the router, skipped"; return 1; }   # switching it on could create it
  if fo_was_on "$1"; then was_on=1; else was_on=0; fi
  fo_up "$1"
  w=0
  while [ $w -lt "$UP_WAIT" ]; do
    sleep 5; w=$((w+5))
    [ "$(fo_hs "$1")" -le "$MAX_HS" ] && fo_works "$1" && return 0
  done
  [ "$was_on" = 0 ] && fo_down "$1"
  return 1
}

# standby_check: once a day at 05:00 (or "--standby"), while the active tunnel works: which standbys answer.
# Free tunnels die one by one and the failover switches silently: warn while there is still time to add one.
standby_check() {
  live=""; dead=""; total=0
  for t in $TUNNELS; do
    [ "$t" = "$ACTIVE" ] && continue
    fo_exists "$t" || continue
    total=$((total+1))
    if try_up "$t"; then live="$live $t"; [ "$was_on" = 0 ] && fo_down "$t"; else dead="$dead $t"; fi
  done
  printf 'date %s\nlive%s\ndead%s\n' "$(date '+%F %H:%M')" "$live" "$dead" > "$S/standby"
  n=$(echo $live | wc -w | tr -d ' ')
  log "standby check: live:${live:- none}, silent:${dead:- none}"
  [ -n "$STANDBY_NOW" ] && echo "запасные туннели: отвечают:${live:- нет}; не отвечают:${dead:- нет}"
  if [ "$n" -le 1 ] && [ "$total" -gt 0 ]; then
    # repeated every 3 days until a new tunnel is added
    if [ ! -f "$S/fewstandby.sent" ] || [ $((now - $(cat "$S/fewstandby.sent"))) -gt 259200 ]; then
      if [ "$n" = 0 ]; then w="Запасных туннелей VPN не осталось: ни один из $total не отвечает."
      else w="Запасной туннель VPN остался один ($(echo $live)) из $total."; fi
      send "! $w Если основной ($ACTIVE) умрёт, Telegram и Instagram пропадут. Что делать: добавьте новый конфиг WireGuard (программа switchback → «WireGuard из файла»), пока всё работает." &&
        echo "$now" > "$S/fewstandby.sent"
    fi
  elif [ -f "$S/fewstandby.sent" ]; then
    rm -f "$S/fewstandby.sent"; send "✓ Запас туннелей VPN восстановлен: отвечают $n из $total."
  fi
}

# the last path (lib/vless.sh, "vless sos"): with every tunnel dead, Telegram, Meta and the VPN sites go through VLESS
# for a while (unless the owner said no); back on WireGuard as soon as any tunnel answers
SOS=__CONF__/vless.sos
sos_on() {
  [ $DRY = 0 ] && [ -f __CONF__/xray.json ] && [ ! -f "$SOS" ] && [ ! -f "$SOS.no" ] && [ -f __CONF__/app/install.sh ] || return 1
  sh __CONF__/app/install.sh vless sos on --plain >/dev/null 2>&1; [ -f "$SOS" ]
}
sos_back() {
  [ $DRY = 0 ] || return 0
  rm -f "$SOS.no"; [ -f "$SOS" ] || return 0
  sh __CONF__/app/install.sh vless sos off auto --plain >/dev/null 2>&1
  log "a tunnel works again: Telegram, Meta and VPN sites back from VLESS"
}

fo_load
ALL=$(fo_routes)                                 # lines: NET MASK TUNNEL KEY
ACTIVE=$(echo "$ALL" | awk 'NF {print $3}' | sort | uniq -c | sort -rn | awk 'NR==1 {print $2}')
[ -z "$ACTIVE" ] && { log "no tunnel routes found, nothing to do"; exit 0; }
ROUTES=$(echo "$ALL" | awk -v a="$ACTIVE" '$3 == a')     # only the active tunnel's routes move
[ -n "$TUNNELS" ] || TUNNELS=$(fo_tunnels)

AH=$(fo_hs "$ACTIVE")
[ "$AH" -le "$MAX_HS" ] && ! fo_works "$ACTIVE" && AH=99998     # handshake but no traffic
if [ $DRY = 1 ]; then
  echo "active: $ACTIVE ($(fo_desc "$ACTIVE")) handshake ${AH}s, routes: $(echo "$ROUTES" | wc -l)"
  for t in $TUNNELS; do [ "$t" != "$ACTIVE" ] && echo "  standby $t ($(fo_desc "$t")) handshake $(fo_hs "$t")s"; done
fi

bad=$S/bad
if [ -n "$FORCE" ]; then
  [ "$FORCE" = "$ACTIVE" ] && { echo "$FORCE is already active"; exit 0; }
  echo "$TUNNELS" | grep -qw "$FORCE" || { echo "$FORCE is not in TUNNELS"; exit 1; }
  [ $DRY = 1 ] && { echo "WOULD try $FORCE"; exit 0; }
  try_up "$FORCE" || { echo "$FORCE: no handshake or traffic within ${UP_WAIT}s, not switching"; exit 1; }
  best=$FORCE
elif [ "$AH" -le "$MAX_HS" ]; then
  [ -f "$bad" ] && log "$ACTIVE ok again (handshake ${AH}s), was bad $(cat "$bad") runs"
  rm -f "$bad" "$S/last_try"
  sos_back
  if [ -n "$STANDBY_NOW" ] || { [ "${SB_FO_TIME:-$(date +%H%M)}" = 0500 ] && [ "$(sed -n 's/^date \([^ ]*\).*/\1/p' "$S/standby" 2>/dev/null)" != "$(date +%F)" ]; }; then
    [ $DRY = 1 ] || standby_check
  fi
  exit 0
else
  n=$(( $(cat "$bad" 2>/dev/null || echo 0) + 1 ))
  [ $DRY = 0 ] && echo $n > "$bad"
  if [ $n -lt "$DEAD_RUNS" ] && [ $DRY = 0 ]; then log "$ACTIVE no handshake/traffic ${AH}s ($n/$DEAD_RUNS, wait)"; exit 0; fi
  if [ -f "$S/last_switch" ] && [ $((now - $(cat "$S/last_switch"))) -lt $((COOLDOWN * 60)) ]; then
    log "$ACTIVE dead but the last switch was less than $COOLDOWN min ago, wait"; exit 0
  fi
  # nothing answered last time: do not flip every standby on and off every few minutes
  if [ -f "$S/last_try" ] && [ $((now - $(cat "$S/last_try"))) -lt $((RETRY * 60)) ]; then
    log "$ACTIVE dead, no standby answered less than $RETRY min ago, wait"; exit 0
  fi
  [ $DRY = 1 ] && { echo "WOULD try standbys in order:" $(echo $TUNNELS | tr ' ' '\n' | grep -vx "$ACTIVE"); exit 0; }
  best=""; tried=""
  for t in $TUNNELS; do
    [ "$t" = "$ACTIVE" ] && continue
    if try_up "$t"; then best=$t; break; fi
    tried="$tried $t"
  done
  [ -n "$tried" ] && log "no answer from:$tried"
  if [ -z "$best" ]; then
    echo "$now" > "$S/last_try"
    log "$ACTIVE dead (handshake ${AH}s) and no standby answers"
    if [ -f "$SOS" ]; then :
    elif sos_on; then log "every tunnel dead: Telegram, Meta and VPN sites through VLESS until one answers"; touch "$S/nostandby.sent"
    else [ -f "$S/nostandby.sent" ] || { send "✗ Туннель VPN $ACTIVE не отвечает, и ни один запасной тоже. Telegram и Instagram сейчас не работают. Что делать: добавьте новый конфиг WireGuard (программа switchback → «WireGuard из файла»). Пробую снова каждые $RETRY мин."; touch "$S/nostandby.sent"; }
    fi
    exit 0
  fi
fi

# move the routes (new one first, then the old one goes), switch the old tunnel off, save
echo "$ROUTES" | while read -r net mask from key; do fo_move "$net" "$mask" "$ACTIVE" "$best" "$key"; done
fo_down "$ACTIVE"
fo_commit "$ACTIVE" "$best"
date +%s > "$S/last_switch"; rm -f "$bad" "$S/nostandby.sent" "$S/last_try"
sos_back
fo_load
left=$(fo_routes | awk -v a="$ACTIVE" '$3 == a' | wc -l)
why="handshake ${AH}s"; [ -n "$FORCE" ] && why="by hand"
log "SWITCHED $ACTIVE ($(fo_desc "$ACTIVE"), $why) -> $best ($(fo_desc "$best")), routes left on old: $left"
sleep 5
# how many standbys are left: the last daily check's live ones, without the new active one and today's silent ones
reserve=""
if [ -f "$S/standby" ]; then
  n=0; for t in $(sed -n 's/^live //p' "$S/standby"); do
    [ "$t" = "$best" ] && continue; case " $tried " in *" $t "*) continue ;; esac; n=$((n+1)); done
  reserve=" Запасных туннелей, отвечавших при последней проверке: $n."
  [ "$n" -le 1 ] && reserve="$reserve Запас кончается — добавьте новый конфиг WireGuard."
fi
if [ -n "$FORCE" ]; then send "Туннель сменён вручную: $ACTIVE ($(fo_desc "$ACTIVE")) → $best ($(fo_desc "$best")). Telegram и Instagram идут через него."
else send "Туннель VPN $ACTIVE ($(fo_desc "$ACTIVE")) перестал отвечать — переключил на $best ($(fo_desc "$best")). Telegram и Instagram идут через него, делать ничего не нужно.$reserve"; fi
echo "switched $ACTIVE -> $best, routes left on old: $left"
exit 0
EOF
  } | script_subst
}
