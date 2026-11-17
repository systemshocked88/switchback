# Weekly digest: on Saturday at 11:00 the bot sends what happened during the week (also "/week" any time).
# Something happened -> the detailed one: load by day, tunnel and node switches, outages with their length,
# actions done through the bot, free space, days without a reboot. A quiet week -> one line.
# It reads the logs the other jobs keep: load (sb-load), wg-failover, claude-nodes, the watchdog's events,
# the bot's actions. The watchdog writes its DOWN/BACK to watchdog-events.log for this.

digest_job() {
  { cat <<'EOF'
#!/bin/sh
# Weekly digest (switchback): Saturday 11:00 to Telegram (ntfy if Telegram does not answer). "--now" prints it.
export PATH=__PATH__
V=__STATE__
BOT=__BOT__
MODE=$1
if [ "$MODE" != --now ]; then
  [ "$(date +%u%H%M)" = 61100 ] || exit 0
  [ "$(cat "$V/digest.sent" 2>/dev/null)" = "$(date +%F)" ] && exit 0
fi
now=$(date +%s)
since=$(date -d "@$((now - 604800))" '+%F %H:%M' 2>/dev/null)
[ -n "$since" ] || since=0000
week() { [ -f "$1" ] && awk -v s="$since" '($1 " " substr($2, 1, 5)) >= s' "$1"; }
dm() { echo "$1" | awk '{split($1, d, "-"); printf "%s.%s %s", d[3], d[2], substr($2, 1, 5)}'; }   # 2026-11-09 04:44:10 -> 09.11 04:44
wd() { case $(date -d "$1" +%u 2>/dev/null) in 1) echo пн ;; 2) echo вт ;; 3) echo ср ;; 4) echo чт ;; 5) echo пт ;; 6) echo сб ;; 7) echo вс ;; *) echo "$1" ;; esac; }

# load: average, highest 5 minutes (when), lowest free memory, the busiest day
load=$(week "$V/switchback-load.log" | awk '{ for (i = 3; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
  n++; s += v["cpu"]; if (v["cpu"] >= mx) { mx = v["cpu"]; at = $1 " " $2 }
  if (mf == "" || v["free"] < mf) mf = v["free"]; ds[$1] += v["cpu"]; dn[$1]++ }
  END { if (!n) exit; bd = ""; for (d in ds) if (bd == "" || ds[d] / dn[d] > ds[bd] / dn[bd]) bd = d
        printf "%d %d %s %d %s %d", s / n, mx, at, mf, bd, ds[bd] / dn[bd] }')
switches=$(week "$V/wg-failover/log" | grep SWITCHED)
nodes=$(week "$V/claude-nodes/log" | grep -E 'SWITCHED|PINNED by hand')
nodedead=$(week "$V/claude-nodes/log" | grep -E 'dead, scanning')
offline=$(week "$V/claude-nodes/log" | grep -c 'the internet is down')
events=$(week "$V/watchdog-events.log")
actions=$(week "$V/sb-bot/log" | grep ' action ')
reboots=$(week "$V/heal.log" | grep -E ' (REBOOT|BOOT) ')

set -- $load
quiet=1
[ -n "$switches$nodes$nodedead$actions$reboots" ] && quiet=0
echo "$events" | grep -q ' DOWN ' && quiet=0
[ "$offline" -gt 0 ] && quiet=0
[ -n "$2" ] && [ "$2" -ge 90 ] && quiet=0
[ -n "$5" ] && [ "$5" -lt 15 ] && quiet=0

if [ $quiet = 1 ]; then
  text="Неделя без происшествий."
  [ -n "$1" ] && text="$text Нагрузка в среднем $1%, памяти не меньше $5 МБ."
else
  text=$( {
    echo "Неделя на роутере (с $(dm "$since")):"
    [ -n "$1" ] && echo "Нагрузка: в среднем $1%, наибольшая $2% ($(wd "$3") $(echo "$4" | cut -c1-5)); памяти не меньше $5 МБ. Самый загруженный день — $(wd "$6") (в среднем $7%)."
    n=$(echo "$switches" | grep -c SWITCHED)
    if [ "$n" -gt 0 ]; then
      echo ""; echo "Туннель переключался: $n"
      echo "$switches" | while read -r d t _ from rest; do
        to=$(echo "$rest" | sed -n 's/.*-> \([^ ]*\).*/\1/p'); why=""
        case $rest in *"by hand"*) why=" (вручную)" ;; *handshake*) why=" (не отвечал)" ;; esac
        echo "• $(dm "$d $t") $from → $to$why"
      done
    fi
    n=$(echo "$nodes" | grep -c .)
    if [ "$n" -gt 0 ] || [ -n "$nodedead" ]; then
      echo ""; echo "Узлы Claude: переключений $n"
      echo "$nodes" | grep . | while read -r d t g rest; do
        echo "• $(dm "$d $t") ${g%:} $(echo "$rest" | sed -e 's/SWITCHED //' -e 's/PINNED by hand -> /вручную → /' -e 's/->/→/' -e 's/ms/мс/g')"
      done
      m=$(echo "$nodedead" | grep -c .); [ "$m" -gt 0 ] && echo "• узел не отвечал: $m раз"
    fi
    [ "$offline" -gt 0 ] && echo "• пропадал интернет (узлы и обычные сайты разом): $offline раз"
    if echo "$events" | grep -q ' DOWN '; then
      echo ""; echo "Сбои:"
      echo "$events" | awk '$3 == "DOWN" { c[$4]++ } $3 == "BACK" { m[$4] += $5; if ($5 > lm[$4]) { lm[$4] = $5; ld[$4] = $1 " " $2 } }
        END { for (s in c) { line = "• " s " — " c[s] " раз"; if (m[s]) line = line ", всего ~" m[s] " мин (самый долгий " substr(ld[s], 9, 2) "." substr(ld[s], 6, 2) " " substr(ld[s], 12, 5) ", ~" lm[s] " мин)"; print line } }'
    fi
    if [ -n "$actions" ]; then
      echo ""; echo "Действия через бота:"
      echo "$actions" | while read -r d t _ a; do echo "• $(dm "$d $t") $a"; done
    fi
    if [ -n "$reboots" ]; then
      echo ""; echo "Перезагрузки:"
      echo "$reboots" | while read -r d t k rest; do
        case $k in
          REBOOT) echo "• $(dm "$d $t") ночная, мало памяти ($(echo "$rest" | sed 's/free=\([0-9]*\)MB/\1 МБ,/'))" ;;
          BOOT) case $rest in ночная*) ;; *) echo "• $(dm "$d $t") без плана (питание, обновление или вручную)" ;; esac ;;
        esac
      done
    fi
    echo ""
    up=$(awk '{printf "%d", $1 / 86400}' /proc/uptime)
    fr=$(df -m __PKGROOT__ 2>/dev/null | awk 'NR == 2 {printf "%.1f", $4 / 1024}')
    echo "Флешка: свободно ${fr:-?} ГБ. Без перезагрузки: $up дн."
  } )
fi
if [ "$MODE" = --now ]; then echo "$text"; exit 0; fi
EOF
  notify_func
  cat <<'EOF'
TOKEN=""; CHAT=""; NTFY=""; [ -f "$BOT" ] && . "$BOT"
sb_send "$text" && date +%F > "$V/digest.sent"
exit 0
EOF
  } | script_subst | sed "s|__PKGROOT__|$PKG_ROOT|g"
}

digest_install() {
  [ -n "$CRON1" ] || return 0
  [ -f "$CRON1/sb-digest" ] && return 0
  t=/tmp/switchback.digest.$$; digest_job > "$t"
  install_file "$CRON1/sb-digest" "сводка за неделю (суббота 11:00, и по команде /week)" "$t"
}
