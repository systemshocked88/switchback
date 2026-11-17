# Self-healing at night and after a reboot (installed with the watchdog).
# - At 04:30, if less than 20% of the memory is left (a slow kernel leak was seen on a real Keenetic: free
#   memory goes down over the weeks until zapret is killed), the router is rebooted while everyone sleeps.
#   Not twice in a row: only when it has run for more than 20 hours. NIGHT_REBOOT=0 in bot.conf turns it off.
# - A few minutes after any reboot, a message: why (the night one, or unknown — a power cut, an update) and
#   whether zapret came back. Telegram may still be waiting for the tunnel: then ntfy, or the next minute.

heal_job() {
  { cat <<'EOF'
#!/bin/sh
# Self-healing (switchback): night reboot when the memory runs low, a message after any reboot.
export PATH=__PATH__
V=__STATE__
BOT=__BOT__
NIGHT_REBOOT=1; TOKEN=""; CHAT=""; NTFY=""; [ -f "$BOT" ] && . "$BOT"
up=$(awk '{printf "%d", $1}' "${SB_UPTIME:-/proc/uptime}")
F=${SB_HEAL_FLAG:-/tmp/switchback-booted}      # /tmp is memory: gone after every reboot
zapret() { pidof nfqws2 >/dev/null || pidof nfqws >/dev/null; }
free_pct() {
  awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} /^MemFree:/ {f=$2}
       END {if (!a) a=f; if (t) printf "%d %d", a * 100 / t, a / 1024; else print "100 0"}' "${SB_MEMINFO:-/proc/meminfo}"
}
EOF
  notify_func
  cat <<'EOF'

# after a reboot: give the services 3 minutes, then report once (until 30 minutes, if nothing answers)
if [ ! -f "$F" ]; then
  if [ "$up" -lt 1800 ]; then
    [ "$up" -lt 180 ] && exit 0
    why="причина неизвестна (пропадало питание, обновление или перезагрузка вручную)"
    if [ -f "$V/heal.reboot" ]; then why="ночная перезагрузка: $(cat "$V/heal.reboot")"; fi
    if zapret; then z="zapret работает"; else z="zapret НЕ работает (сторож попробует запустить)"; fi
    sb_send "Роутер перезагрузился — $why. $z." || exit 0
    echo "$(date '+%F %H:%M') BOOT ${why%%:*}" >> "$V/heal.log"
    rm -f "$V/heal.reboot"
  fi
  : > "$F"
fi

# at night: reboot only when the memory is running out
[ "${SB_HEAL_TIME:-$(date +%H%M)}" = 0430 ] || exit 0
[ "$NIGHT_REBOOT" = 0 ] && exit 0
[ "$up" -gt 72000 ] || exit 0
[ "$(cat "$V/heal.night" 2>/dev/null)" = "$(date +%F)" ] && exit 0
date +%F > "$V/heal.night"
set -- $(free_pct)
[ "$1" -lt 20 ] || exit 0
echo "свободно ${2} МБ памяти (${1}%)" > "$V/heal.reboot"
echo "$(date '+%F %H:%M') REBOOT free=${2}MB ${1}%" >> "$V/heal.log"
sb_send "Ночная перезагрузка: памяти осталось ${2} МБ (${1}%). Вернусь через пару минут."
sync
if [ -n "$SB_REBOOT" ]; then $SB_REBOOT
elif [ -d /opt/etc ] || [ -f /etc/openwrt_release ]; then __REBOOT__     # only on a router
fi
exit 0
EOF
  } | script_subst | sed "s|__REBOOT__|$(pf_reboot_cmd)|g"
}

heal_install() {
  [ -n "$CRON1" ] || return 0
  [ -f "$CRON1/sb-heal" ] && return 0
  t=/tmp/switchback.heal.$$; heal_job > "$t"
  install_file "$CRON1/sb-heal" "самолечение: ночная перезагрузка, если мало памяти; сообщение после перезагрузки" "$t"
}
