# "install.sh status": what switchback installed on this router and whether it works now. Changes nothing.

# link_checks: the sites "Связь сейчас" asks, "name|address" words, only for what is set up on this router
# (by switchback or by hand). "lists put" asks the same before and after new lists (lib/app.sh).
link_checks() {
  lc=""
  [ -n "$(tg_via)" ] && lc="Telegram|https://api.telegram.org"
  pf_dns_has claude.ai && lc="$lc claude.ai|https://claude.ai"
  pf_dns_has chatgpt.com && lc="$lc chatgpt.com|https://chatgpt.com"
  meta_on && lc="$lc Instagram|https://www.instagram.com"
  echo "$lc"
}

do_status() {
  WARNINGS=0; PROBLEMS=0
  hr "Что установлено"
  if [ ! -s "$STATE" ]; then
    skip "switchback на этом роутере ещё ничего не ставил"
    ev status none 0 0       # nothing installed: neither "works" nor "broken"
    return 0
  fi
  if grep -q '^nfqws_conf\|^pkg nfqws2' "$STATE"; then
    sub "zapret"
    if pf_zapret_installed && pf_zapret_running; then ok "zapret работает"
    elif pf_zapret_installed; then bad "zapret установлен, но не запущен"
    else bad "zapret не установлен (пропал после обновления прошивки?): запустите установку ещё раз"; fi
  fi
  if grep -q '^dns ' "$STATE"; then
    sub "DNS для ChatGPT и Claude"
    n=0; lost=""
    for d in $(sed -n 's/^dns .* \([^ ]*\)$/\1/p' "$STATE"); do
      if pf_dns_has "$d"; then n=$((n+1)); else lost="$lost $d"; fi
    done
    ok "доменов настроено: $n"
    [ -n "$lost" ] && warn "пропали записи для:$lost"
  fi
  if grep -q '^route ' "$STATE"; then
    if grep -q '^ns ' "$STATE"; then sub "Telegram и Instagram/Facebook/WhatsApp через VPN"; else sub "Telegram через VPN"; fi
    n=0; lost=""; ifc=""
    while read -r kind net mask ifc_; do
      [ "$kind" = route ] || continue
      ifc=$ifc_
      if pf_route_has "$net" "$mask" "$ifc_"; then n=$((n+1)); else lost="$lost $net"; fi
    done < "$STATE"
    ok "маршрутов через $ifc: $n"
    [ -n "$lost" ] && warn "пропали маршруты:$lost"
    if grep -q '^ns ' "$STATE"; then
      nl=""; for d in $(sed -n 's/^ns [^ ]* //p' "$STATE"); do pf_ns_has "$META_DNS" "$d" || nl="$nl $d"; done
      if [ -n "$nl" ]; then warn "пропал DNS через $META_DNS для:$nl"; else ok "домены Meta спрашивают $META_DNS через туннель"; fi
    fi
  fi
  if grep -q '^wg ' "$STATE" || grep -q '^uci network\.[^.]* __unset__' "$STATE"; then
    for w in $(sed -n 's/^wg //p' "$STATE"); do ok "подключение WireGuard $w создано switchback"; done
  fi
  if grep -q '^bot_conf\|^file .*watchdog\|^replaced .*watchdog' "$STATE" || [ -x "$CRON5/watchdog" ]; then
    sub "Сторож и бэкап"
    if [ -x "$CRON5/watchdog" ]; then ok "сторож на месте (проверка каждые 5 минут)"; else warn "сторожа нет"; fi
    if [ -x "$CRONW/backup" ]; then ok "еженедельный бэкап на месте"; else warn "еженедельного бэкапа нет"; fi
    if grep -q '^TOKEN=.' "$BOT" 2>/dev/null; then ok "бот для уведомлений настроен"; fi
    if grep -q '^NTFY=.' "$BOT" 2>/dev/null; then ok "запасной канал ntfy настроен (если Telegram не отвечает)"; fi
    grep -q '^TOKEN=.\|^NTFY=.' "$BOT" 2>/dev/null || warn "ни бота, ни ntfy: уведомлений не будет"
  fi
  if [ -n "$CRON1" ] && [ -x "$CRON1/wg-failover" ]; then
    sub "Автосмена VPN-туннеля"
    ok "стоит, проверка каждую минуту"
    [ -f "$SB_DIR/failover.conf" ] && ok "туннели: $(sed -n 's/^TUNNELS="\(.*\)"$/\1/p' "$SB_DIR/failover.conf")"
    last=$(grep "SWITCHED" "$VAR_DIR/wg-failover/log" 2>/dev/null | tail -n 1)
    if [ -n "$last" ]; then skip "последнее переключение: $(echo "$last" | cut -c1-16) — $(echo "$last" | sed 's/.*SWITCHED \([^ ]*\).*-> \([^ ]*\).*/\1 → \2/')"
    else skip "переключений ещё не было"; fi
  fi
  if ai_on; then
    sub "Резерв для нейросетей: Claude, ChatGPT"
    ai_status
  fi
  if [ -n "$CRON1" ] && [ -x "$CRON1/claude-nodes" ]; then
    sub "Claude: быстрый узел и запрет QUIC"
    ok "автосмена узлов стоит, проверка каждую минуту"
    for g in $NODES_GROUPS; do d=${g#*:}; d=${d%%,*}; ip=$(pf_host_pinned "$d")
      if [ -n "$ip" ]; then ok "$d $ARROW $ip"; else warn "$d ни за каким узлом не закреплён"; fi
    done
    last=$(grep 'SWITCHED' "$VAR_DIR/claude-nodes/log" 2>/dev/null | tail -n 1)
    [ -n "$last" ] && skip "последнее переключение: $(echo "$last" | cut -c1-16) — $(echo "$last" | sed 's/.*: SWITCHED //')"
  fi
  if [ -n "$CRON1" ] && [ -x "$CRON1/sb-bot" ]; then
    sub "Команды боту"
    ok "/status /check /report /sites (или словами: статус, проверка, отчёт, сайты) — ответ в течение минуты"
  fi
  sites_files
  if [ -s "$SITES" ]; then
    sub "Свои сайты"
    while read -r w d; do
      [ -n "$d" ] || continue
      case $w in
        zapret) if grep -qx "$d" "$NFQ_LIST" 2>/dev/null; then ok "$d — zapret"; else warn "$d пропал из списка zapret"; fi ;;
        dns)    if pf_dns_has "$d"; then ok "$d — DNS"; else warn "$d: пропала DNS-запись"; fi ;;
        vpn)    n=$(awk -v d="$d" '$2 == d' "$SITES_ROUTES" 2>/dev/null | wc -l); ok "$d — через VPN (адресов: $(echo $n))" ;;
      esac
    done < "$SITES"
  fi
  set -- $(load_day)
  if [ -n "$4" ]; then
    sub "Нагрузка роутера за сутки"
    ok "процессор: в среднем $1%, наибольшая за 5 минут $2%; свободной памяти было не меньше $3 МБ (замеров: $4)"
    [ "$3" -lt 15 ] && warn "свободной памяти бывало меньше 15 МБ: на этом роутере лучше не ставить ничего тяжёлого"
  fi
  iv=$(installed_version)
  [ -n "$iv" ] && [ "$iv" != "$VERSION" ] && warn "на роутере switchback $iv, есть новее ($VERSION): обновите"
  ev installed "${iv:-old}" "$VERSION"
  missing=""
  for p in $(sed -n 's/^pkg //p' "$STATE"); do pf_pkg_installed "$p" || missing="$missing $p"; done
  [ -n "$missing" ] && warn "пропали пакеты:$missing — запустите установку ещё раз"

  # what is set up on the router now (by switchback or by hand), not only what switchback recorded
  checks=$(link_checks)
  if [ -n "$checks" ] && command -v curl >/dev/null 2>&1; then
    sub "Связь сейчас"
    for x in $checks; do
      c=$(curl $ZCURL -s -o /dev/null --max-time 12 -w '%{http_code}' "${x#*|}" 2>/dev/null)
      if [ -n "$c" ] && [ "$c" != 000 ]; then ok "${x%%|*} отвечает"; else warn "${x%%|*} не отвечает"; fi
    done
  fi
  if [ "$PROBLEMS" -gt 0 ]; then v=2; elif [ "$WARNINGS" -gt 0 ]; then v=1; else v=0; fi
  ev status "$v" "$WARNINGS" "$PROBLEMS"
  case $v in
    0) verdict 0 "всё на месте и работает" ;;
    1) verdict 1 "работает, но есть замечания ($WARNINGS)" ;;
    *) verdict 2 "есть неполадки ($PROBLEMS)" ;;
  esac
  return $v
}
