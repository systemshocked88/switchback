# "install.sh report": a diagnostic report safe to show someone. Changes nothing on the router.
# Only chosen parts of the settings go in (never the whole configuration: it holds password hashes and
# the Wi-Fi password), everything passes sanitize, and the result is checked again: if anything still
# looks like a key, token or hash, the report is not given out at all.

do_report() {
  out=$VAR_DIR/switchback-report.txt
  tmp=/tmp/switchback-report.$$
  p=$PROGRESS; PROGRESS=0          # the report is plain text, no event lines inside
  {
    echo "switchback $VERSION — отчёт для диагностики, $(date '+%F %T')"
    echo "Секреты (пароли, ключи, токены, MAC-адреса) вырезаны."
    hr "Роутер"
    say "  прошивка: $(platform_title "$PLATFORM")"
    pf_describe
    say "  работает без перезагрузки: $(awk '{printf "%d ч %d мин", $1/3600, ($1%3600)/60}' /proc/uptime 2>/dev/null)"
    say "  нагрузка: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
    say "  память: $(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} /^MemFree:/ {f=$2} END {if (!a) a=f; printf "%d МБ, свободно %d МБ", t/1024, a/1024}' /proc/meminfo 2>/dev/null)"
    doctor
    do_status
    hr "VPN-подключения"
    for w in $(pf_vpn_ifaces); do
      if pf_vpn_alive "$w"; then st="подключено"; else st="не подключено"; fi
      g=""; pf_vpn_is_global "$w" && g=", ВЕСЬ трафик через него"
      say "  $w: $st$g"
    done
    tg=$(tg_via); say "  Telegram идёт через: ${tg:-никакое (маршрутов нет)}"
    if command -v curl >/dev/null 2>&1; then
      hr "Связь сейчас (код ответа, время)"
      for u in https://api.telegram.org https://claude.ai https://api.anthropic.com https://chatgpt.com \
               https://www.youtube.com https://www.instagram.com https://discord.com; do
        say "  $u  $(curl $ZCURL -s -o /dev/null --max-time 10 -w '%{http_code} %{time_total}s' "$u" 2>/dev/null)"
      done
    fi
    hr "Настройки (только нужное)"
    pf_report_config
    if [ -f "$NFQ_CONF" ]; then
      sub "zapret"
      grep -E '^[A-Z_]+=' "$NFQ_CONF" | grep -E 'MODE|ARGS|PORTS|POLICY|IFACE|INTERFACE|LOG' | sed 's/^/    /'
      [ -f "$NFQ_LIST" ] && say "    сайтов в списке: $(grep -cv '^[[:space:]]*\(#\|$\)' "$NFQ_LIST")"
    fi
    for f in "$SB_DIR/failover.conf" "$SB_DIR/nodes.conf" "$SB_DIR/sites"; do
      [ -f "$f" ] && { sub "${f##*/}"; grep -v '^#' "$f" | sed 's/^/    /'; }
    done
    hr "Журналы (последние строки)"
    for f in "$LOG" "$VAR_DIR/wg-failover/log" "$VAR_DIR/claude-nodes/log" "$VAR_DIR/sb-bot/log" "$VAR_DIR/switchback-load.log"; do
      [ -s "$f" ] && { sub "$f"; tail -n 25 "$f" | sed 's/^/    /'; }
    done
    [ -s "$STATE" ] && { sub "журнал изменений switchback"; sed 's/^/    /' "$STATE"; }
  } 2>&1 | sanitize > "$tmp"
  PROGRESS=$p
  if leaks=$(report_leaks "$tmp"); then
    rm -f "$tmp"
    # line numbers only: the suspicious text itself is never shown
    bad "в отчёте осталось что-то похожее на пароль или ключ (строки: $(echo "$leaks" | cut -d: -f1 | tr '\n' ' ')) — отчёт не выдан. Сообщите разработчику switchback."
    ev fail "отчёт не выдан: в нём осталось похожее на секрет"
    return 1
  fi
  mkdir -p "${out%/*}"; mv "$tmp" "$out"; chmod 600 "$out"
  cat "$out"
  say ""
  note "Отчёт сохранён на роутере: $out"
  ev report "$out"
  return 0
}
