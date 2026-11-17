# Pre-install analysis ("doctor"). Generic checks here, platform checks in pf_doctor.
# Ends with a verdict: 0 = ready, 1 = ready with warnings, 2 = not recommended.

mem_mb() { awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null; }
# one lost ping is not "no internet": try several hosts, then a plain HTTP request
internet_ok() {
  for h in 8.8.8.8 1.1.1.1 ya.ru; do ping -c2 -W3 "$h" >/dev/null 2>&1 && return 0; done
  wget -q -T 8 -O /dev/null http://ya.ru 2>/dev/null && return 0
  command -v curl >/dev/null 2>&1 && curl -s -o /dev/null --max-time 8 http://ya.ru && return 0
  return 1
}
free_mb() { df -k "$1" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024}'; }

doctor() {
  WARNINGS=0; PROBLEMS=0
  hr "Анализ роутера перед установкой"

  sub "Устройство"
  ok "прошивка: $(platform_title "$PLATFORM")"
  pf_describe

  m=$(mem_mb)
  if [ -z "$m" ]; then warn "не удалось узнать объём памяти"
  elif [ "$m" -lt 100 ]; then bad "памяти ${m} МБ: мало, zapret и VPN могут не уместиться"
  elif [ "$m" -lt 200 ]; then warn "памяти ${m} МБ: хватит, но запас небольшой (не ставьте ещё AdGuard и т.п.)"
  else ok "памяти ${m} МБ"; fi

  f=$(free_mb "$PKG_ROOT")
  if [ -z "$f" ]; then warn "не удалось узнать свободное место в $PKG_ROOT"
  elif [ "$f" -lt "${MIN_FREE_MB:-20}" ]; then bad "свободно ${f} МБ в $PKG_ROOT: нужно хотя бы ${MIN_FREE_MB:-20} МБ"
  else ok "свободно ${f} МБ в $PKG_ROOT"; fi

  ok "процессор: $(uname -m 2>/dev/null), ядро $(uname -r 2>/dev/null)"
  # seen on a real Keenetic: /dev/null turned into a plain file; daemons (zapret too) then exit at start
  [ -n "$SB_TEST" ] || [ -c /dev/null ] || bad "системный файл /dev/null испорчен: zapret и другие службы не смогут запуститься. Перезагрузите роутер"

  sub "Сеть"
  if internet_ok; then ok "интернет есть"; else bad "нет интернета (не отвечают 8.8.8.8, 1.1.1.1 и ya.ru)"; fi
  if nslookup example.com >/dev/null 2>&1 || ping -c1 -W3 example.com >/dev/null 2>&1; then ok "DNS работает"
  else warn "имена сайтов не открываются: проблемы с DNS"; fi

  sub "Конфликты"
  others=""
  for p in tpws dpi byedpi ciadpi goodbyedpi AdGuardHome sing-box xray; do
    pidof "$p" >/dev/null 2>&1 && others="$others $p"
  done
  if [ -n "$others" ]; then warn "уже работает:$others. Два обхода или DNS-фильтра на одном трафике часто ломают сеть"
  else ok "посторонних обходов и DNS-фильтров не найдено"; fi
  [ -d "$PKG_ROOT/zapret" ] && warn "найден $PKG_ROOT/zapret: похоже, zapret уже ставили другим способом"
  if [ -s "$STATE" ]; then
    iv=$(installed_version)
    skip "этот установщик уже запускался (повторный запуск безопасен), на роутере версия ${iv:-до 0.6.0}"
    ev installed "${iv:-old}" "$VERSION"
    # packages vanish after a firmware upgrade (OpenWrt sysupgrade keeps settings, not packages)
    missing=""
    for p in $(sed -n 's/^pkg //p' "$STATE"); do pf_pkg_installed "$p" || missing="$missing $p"; done
    [ -n "$missing" ] && warn "пропали пакеты, которые ставил switchback:$missing. Так бывает после обновления прошивки: запустите установку ещё раз — она их доставит, настройки сохранились"
  fi

  pf_doctor   # platform-specific: modules, acceleration, VPN-for-all, IPv6, repositories...
  # the program offers these for Telegram: name, up/down; and which one Telegram already uses
  for w in $(pf_vpn_ifaces); do if pf_vpn_alive "$w"; then ev vpn "$w" up; else ev vpn "$w" down; fi; done
  tg=$(tg_via); [ -n "$tg" ] && ev tgvia "$tg"
  # the reserve channel already on the router: the program shows it instead of making a new one
  n=$(sed -n 's/^NTFY=//p' "$BOT" 2>/dev/null); [ -n "$n" ] && ev ntfy "$n"
  grep -q '^TOKEN=.' "$BOT" 2>/dev/null && ev bot yes

  say ""
  if [ "$PROBLEMS" -gt 0 ]; then v=2; elif [ "$WARNINGS" -gt 0 ]; then v=1; else v=0; fi
  ev doctor "$v" "$WARNINGS" "$PROBLEMS"
  if [ "$PROBLEMS" -gt 0 ]; then
    verdict 2 "НЕ РЕКОМЕНДУЮ ставить, пока не исправлены пункты, отмеченные как проблемы ($PROBLEMS)"
    return 2
  elif [ "$WARNINGS" -gt 0 ]; then
    verdict 1 "можно ставить, но прочитайте предупреждения ($WARNINGS)"
    return 1
  fi
  verdict 0 "всё готово к установке"
  return 0
}
