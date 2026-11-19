# The panel on the router, and the site doctor.
#
# "sites doctor DOMAIN": why a site does not open, step by step, in plain words: the internet, the site's
# address (DNS), the way devices at home go now, the tunnel; then what fixes it (events doc_fix: the ways
# for "sites add"). The bot (/diag DOMAIN) and the panel ask the same doctor.
#
# "panel on|off|status|link|token": a page in the home network (any phone) that shows whether YouTube,
# Telegram, Instagram, ChatGPT/Claude and own sites work and which way they go, switches the tunnel and asks
# the doctor. Off by default. The web server (busybox httpd, or uhttpd on OpenWrt) listens on the router's
# home address only; the page logs in with a token made here (not the router's password); see
# docs/panel-plan.md. The page's own program (panel/sb.cgi) only checks the visitor and calls
#   panel state            the services and tunnels (events svc, tun, tun_switch)
#   panel next             move Telegram and Meta to the next tunnel (wg-failover --force)
#   panel fix DOMAIN WAY   add the site the way the doctor said (an own site with another way is replaced)
#   sites doctor DOMAIN
# Files: $SB_DIR/panel/ (www/, token, sessions, conf); job $CRON1/sb-panel starts the server when it is not
# running (after a reboot). Journal: "panel IP:PORT" (stops the server), "appdir $SB_DIR/panel", the job.

PANEL_PORT=${SB_PANEL_PORT:-8088}

# doc_open URL [CURL ARGS]: ok | slow | cut | down. "ok": the whole page came (redirects followed) in 4 s;
# "slow": it came, slowly; "cut": it answered but stopped at under 100 KB (the provider cuts by size)
doc_open() {
  du=$1; shift
  dr=$(curl "$@" -s -L --max-redirs 3 -o /dev/null --max-time 12 -w '%{http_code} %{time_total} %{size_download}' "$du" 2>/dev/null); de=$?
  set -- $dr
  dc=${1:-000}; dt=${2:-0}; ds=${3:-0}; ds=${ds%%.*}; case $ds in ''|*[!0-9]*) ds=0 ;; esac
  if [ "$dc" = 000 ]; then echo down
  elif [ "$de" = 28 ] && [ "$ds" -le 100000 ]; then echo cut
  elif [ "$de" != 0 ] && [ "$de" != 28 ]; then echo down
  elif [ "$de" = 28 ] || awk -v t="$dt" 'BEGIN { sub(",", ".", t); exit !(t + 0 > 4) }'; then echo slow
  else echo ok; fi
}

site_doctor() {
  sites_files
  d=$(site_norm "$1")
  site_valid "$d" || { bad "«$1» не похоже на адрес сайта (нужно вроде example.com)"; ev doc_end bad; return 1; }
  hr "Проверяю $d"
  if [ "$(doc_open https://ya.ru)" = down ] && [ "$(doc_open https://www.google.com)" = down ]; then
    bad "Интернета нет: даже обычные сайты не открываются"; ev doc net bad
    doc_say nonet "Похоже, сбой у провайдера или с кабелем — роутер и обход тут ни при чём. Если не пройдёт за полчаса — звоните провайдеру."
    return 0
  fi
  ok "Интернет есть"; ev doc net ok
  way=$(site_way "$d")
  # the way devices at home go now: through zapret when it is on the list, through the tunnel when routed
  now=$(doc_open "https://$d/" $ZCURL)
  case $now in
    ok)   ok "$d открывается с роутера"; ev doc now ok
          doc_say device "Значит, дело в устройстве: выключите и включите на нём Wi-Fi или перезапустите браузер, выключите VPN-приложения и «Частный DNS», если они есть."
          return 0 ;;
    slow) warn "$d открывается, но медленно"; ev doc now slow ;;
    cut)  bad "$d начинает открываться и обрывается: провайдер режет его"; ev doc now cut ;;
    *)    bad "$d сейчас не открывается"; ev doc now down ;;
  esac
  dnsok=""; for c in claude.ai chatgpt.com; do pf_dns_has "$c" && dnsok=1; done
  if [ -z "$(site_ips "$d")" ]; then
    bad "Адрес сайта не находится"; ev doc dns bad
    if [ -n "$dnsok" ]; then
      doc_say dns "Проверьте, нет ли опечатки. Если адрес верный, его может скрывать DNS провайдера — помогает спросить другой DNS-сервер." dns
    else doc_say dns "Проверьте, нет ли опечатки. Если адрес верный, сайт, возможно, закрылся."; fi
    return 0
  fi
  ok "Адрес сайта находится"; ev doc dns ok
  [ -n "$way" ] && skip "он уже в своих сайтах (способ: $(way_word "$way"))"
  zfree=""
  if pf_zapret_installed && [ "$way" != zapret ] && ! grep -qx "$d" "$NFQ_LIST" 2>/dev/null; then
    zfree=1; skip "zapret к нему пока не применяется — может помочь"; ev doc zapret maybe
  fi
  t=$(sites_tunnel); tun=""
  if [ -n "$t" ]; then
    case $(doc_open "https://$d/" --interface "$(pf_wg_dev "$t")") in
      ok|slow) ok "Через туннель открывается"; ev doc vpn ok; tun=1 ;;
      *)       bad "Через туннель тоже не открывается"; ev doc vpn bad ;;
    esac
  else skip "работающего туннеля нет — через него не проверить"; ev doc vpn none; fi
  if [ -n "$tun" ] && [ "$way" != vpn ]; then
    if [ -n "$zfree" ]; then doc_say vpn "Через туннель сайт работает — пустим его туда. Можно сначала попробовать zapret: он быстрее, но помогает не всегда." vpn zapret
    else doc_say vpn "Через туннель сайт работает — пустим его туда." vpn; fi
  elif [ -n "$zfree" ]; then
    doc_say zapret "Попробуем zapret: он обходит замедление и блокировку у провайдера." zapret
  elif [ "$now" = slow ]; then
    doc_say slow "Сайт работает, но медленно. Чаще всего это сам сайт или загрузка сети — подождите немного."
  else
    doc_say down "Сайт не открывается ни так, ни через туннель: похоже, не работает сам сайт. Попробуйте позже."
  fi
  return 0
}
way_word() { case $1 in zapret) echo zapret ;; vpn) echo "через туннель" ;; dns) echo DNS ;; *) echo "$1" ;; esac; }
# doc_say KIND TEXT [WAY...]: the conclusion, and the fixes (the first is the main one)
doc_say() {
  dk=$1; dtx=$2; shift 2
  say ""; say "→ $dtx"
  ev doc_say "$dtx"
  [ $# -gt 0 ] && ev doc_fix "$@"
  ev doc_end "$dk"
}

# panel fix DOMAIN WAY: what the doctor offered. An own site added another way before is taken out first.
panel_fix() {
  sites_files
  d=$(site_norm "$1")
  site_valid "$d" || { bad "«$1» не похоже на адрес сайта"; return 2; }
  case $2 in zapret|vpn|dns) ;; *) bad "способ должен быть zapret, vpn или dns"; return 2 ;; esac
  w=$(site_way "$d")
  [ "$w" = "$2" ] && { skip "$d уже идёт этим способом"; return 0; }
  : > "$RUN_JOURNAL"
  [ -n "$w" ] && { site_del "$d" || return 1; }
  site_add "$d" "$2"
}

# ---------- what the page shows ----------
panel_state() {
  sites_files
  tmp=/tmp/sb-panel.$$; rm -rf "$tmp"; mkdir -p "$tmp"
  n=0
  padd() { n=$((n+1)); printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$tmp/s$n"; }   # NAME HOW URLS
  if pf_zapret_installed; then padd YouTube zapret https://www.youtube.com; else padd YouTube "напрямую" https://www.youtube.com; fi
  if [ -n "$(tg_via)" ]; then padd Telegram "туннель" https://api.telegram.org; else padd Telegram "напрямую" https://api.telegram.org; fi
  if meta_on; then padd Instagram "туннель" https://www.instagram.com
  elif grep -qx instagram.com "$NFQ_LIST" 2>/dev/null; then padd Instagram zapret https://www.instagram.com
  else padd Instagram "напрямую" https://www.instagram.com; fi
  padd "ChatGPT и Claude" "напрямую" "https://chatgpt.com https://claude.ai"
  k=0
  [ -f "$SITES" ] && while read -r w d; do
    [ -n "$d" ] && [ "$w" != rescue ] || continue
    k=$((k+1)); [ $k -le 8 ] || break
    case $w in vpn) h="туннель" ;; zapret) h=zapret ;; *) h="напрямую" ;; esac
    n=$((n+1)); printf '%s\t%s\t%s\n' "сайт $d" "$h" "https://$d/" > "$tmp/s$n"
  done < "$SITES"
  # all at once: one curl per address, ~10 s at most
  for f in "$tmp"/s*; do
    ( IFS='	' read -r nm h urls < "$f"; r=ok
      for u in $urls; do x=$(doc_open "$u" $ZCURL)
        case $x in down) r=down ;; slow|cut) [ $r = ok ] && r=$x ;; esac
      done
      echo "$r" > "$f.r" ) &
  done
  wait
  i=0; while [ $i -lt $n ]; do i=$((i+1)); f=$tmp/s$i
    IFS='	' read -r nm h urls < "$f"; r=$(cat "$f.r" 2>/dev/null)
    case $r in ok) c=green; x="работает" ;; slow) c=yellow; x="медленно" ;; cut) c=yellow; x="обрывается" ;; *) c=red; x="не открывается" ;; esac
    ev svc "$nm" "$c" "$h" "$x"
  done
  rm -rf "$tmp"
  a=$(tg_via); list=""
  [ -f "$SB_DIR/failover.conf" ] && list=$(sed -n 's/^TUNNELS="\(.*\)"$/\1/p' "$SB_DIR/failover.conf")
  [ -n "$list" ] || list=$(pf_vpn_ifaces)
  for w in $list; do
    if pf_vpn_alive "$w"; then s=up; else s=down; fi
    r=standby; [ "$w" = "$a" ] && r=active
    ev tun "$w" "$s" "$r"
  done
  if [ -n "$CRON1" ] && [ -x "$CRON1/wg-failover" ] && [ "$(echo $list | wc -w)" -ge 2 ]; then ev tun_switch yes; else ev tun_switch no; fi
  return 0
}

# panel next: Telegram and Meta to the next tunnel after the one in use, in the failover's order
panel_next() {
  [ -n "$CRON1" ] && [ -x "$CRON1/wg-failover" ] || { bad "Автосмена туннеля не установлена: переключать нечем."; return 1; }
  list=$(sed -n 's/^TUNNELS="\(.*\)"$/\1/p' "$SB_DIR/failover.conf" 2>/dev/null)
  a=$(tg_via); nx=""; seen=""
  for w in $list $list; do
    [ -n "$seen" ] && [ "$w" != "$a" ] && { nx=$w; break; }
    [ "$w" = "$a" ] && seen=1
  done
  [ -n "$nx" ] || nx=$(for w in $list; do [ "$w" != "$a" ] && { echo "$w"; break; }; done)
  [ -n "$nx" ] || { bad "Запасного туннеля нет: добавьте конфиг WireGuard."; return 1; }
  say "Переключаю на $nx, это до минуты…"
  out=$(sh "$CRON1/wg-failover" --force "$nx" 2>&1 | tail -n 3)
  pf_reload
  if [ "$(tg_via)" = "$nx" ]; then ok "Telegram и Instagram теперь идут через $nx"; ev next "$nx" ok; log "panel: tunnel -> $nx"
  else bad "$nx не заработал, остался прежний туннель${out:+ ($out)}"; ev next "$nx" fail; return 1; fi
}

# ---------- on / off ----------
panel_lan_ip() {
  if [ -n "$SB_LAN_IP" ]; then echo "$SB_LAN_IP"; return; fi
  case $PLATFORM in
    keenetic) ndmc -c 'show interface Bridge0' 2>/dev/null | sed -n 's/^ *address: *\([0-9.]*\).*/\1/p' | head -n 1 ;;
    *)        uci -q get network.lan.ipaddr 2>/dev/null | sed 's#/.*##' | awk '{print $1}' ;;
  esac
}
lan_private() {
  echo "$1" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || return 1
  case $1 in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;; esac
  return 1
}
# the web server: busybox httpd (Entware's busybox has it), else uhttpd (OpenWrt)
panel_server() {
  if busybox --list 2>/dev/null | grep -qx httpd; then echo "busybox httpd"
  elif command -v httpd >/dev/null 2>&1; then echo httpd
  elif command -v uhttpd >/dev/null 2>&1; then echo uhttpd
  else return 1; fi
}
panel_files() { PANEL=$SB_DIR/panel; }
panel_token_new() { rand_hex 16; }
panel_link() { echo "http://$(sed -n 's/^IP=//p' "$PANEL/conf"):$PANEL_PORT/#t=$(cat "$PANEL/token")"; }

panel_job() {
script_subst <<'EOF'
#!/bin/sh
# The panel's web server (switchback): started when it is not running (after a reboot). Every minute.
export PATH=__PATH__
P=__CONF__/panel
[ -f "$P/conf" ] && [ -x "$P/www/cgi-bin/sb" ] || exit 0
. "$P/conf"
netstat -ltn 2>/dev/null | grep -q " $IP:$PORT " && exit 0
case $SRV in
  uhttpd) uhttpd -p "$IP:$PORT" -h "$P/www" -x /cgi-bin -t 90 -n 3 ;;
  *)      $SRV -p "$IP:$PORT" -h "$P/www" ;;
esac
exit 0
EOF
}
panel_can_run() { [ "$DRY" != 1 ] && [ -z "$SB_TEST" ]; }
# panel_stop IP:PORT: the server listening there
panel_stop() {
  panel_can_run || return 0
  for p in $(netstat -ltnp 2>/dev/null | awk -v a="$1" '$4 == a { split($7, x, "/"); print x[1] }'); do
    case $p in ''|*[!0-9]*) ;; *) kill "$p" 2>/dev/null ;; esac
  done
  return 0
}

panel_install_files() {   # the page and its program, from this version
  [ -f "$SB_SRC/panel/index.html" ] && [ -f "$SB_SRC/panel/sb.cgi" ] || { bad "нет файлов панели (panel/): запускайте install.sh из папки проекта целиком"; return 1; }
  [ "$DRY" = 1 ] && return 0
  mkdir -p "$PANEL/www/cgi-bin" && cp "$SB_SRC/panel/index.html" "$PANEL/www/index.html" &&
    script_subst < "$SB_SRC/panel/sb.cgi" > "$PANEL/www/cgi-bin/sb" && chmod 755 "$PANEL/www/cgi-bin/sb"
}

panel_on() {
  panel_files
  hr "Панель на роутере"
  ip=$(panel_lan_ip)
  lan_private "$ip" || { bad "не нашёл адрес роутера в домашней сети — панель не включена"; return 1; }
  srv=$(panel_server)
  if [ -z "$srv" ] && [ "$PLATFORM" = keenetic ]; then
    pf_pkg_install busybox && remember "pkg busybox"; srv=$(panel_server)
  fi
  [ -n "$srv" ] || { bad "на роутере нет веб-сервера (busybox httpd или uhttpd) — панель не включена"; return 1; }
  if [ "$DRY" = 1 ]; then dry "панель на http://$ip:$PANEL_PORT/ (сервер: $srv)"; return 0; fi
  self_install
  old=$(sed -n 's/^IP=//p' "$PANEL/conf" 2>/dev/null)
  [ -n "$old" ] && [ "$old" != "$ip" ] && panel_stop "$old:$PANEL_PORT"
  mkdir -p "$PANEL" && chmod 700 "$PANEL"
  remember "appdir $PANEL"
  panel_install_files || return 1
  umask_was=$(umask); umask 077
  [ -s "$PANEL/token" ] || { panel_token_new > "$PANEL/token"; : > "$PANEL/sessions"; }
  printf 'IP=%s\nPORT=%s\nSRV="%s"\n' "$ip" "$PANEL_PORT" "$srv" > "$PANEL/conf"
  umask "$umask_was"
  pf_cron_setup || { bad "не удалось включить планировщик"; return 1; }
  t=/tmp/switchback.new.$$; panel_job > "$t"
  install_file "$CRON1/sb-panel" "запуск панели (проверка каждую минуту)" "$t"
  remember "panel $ip:$PANEL_PORT"
  panel_can_run && sh "$CRON1/sb-panel"
  pf_keep_files
  ok "панель включена: откройте с телефона или компьютера дома"
  say "     $(panel_link)"
  note "Ссылка — это и есть вход: не пересылайте её чужим. Новая ссылка (старые перестанут работать): sh install.sh panel token"
  ev panel on "$(panel_link)"
  log "panel on: $ip:$PANEL_PORT ($srv)"
}

panel_off() {
  panel_files
  hr "Панель на роутере"
  [ -d "$PANEL" ] || { skip "панель не включена"; return 0; }
  ip=$(sed -n 's/^IP=//p' "$PANEL/conf" 2>/dev/null)
  [ "$DRY" = 1 ] && { dry "выключить панель"; return 0; }
  run rm -f "$CRON1/sb-panel"
  [ -n "$ip" ] && panel_stop "$ip:$PANEL_PORT"
  rm -rf "$PANEL" /tmp/sb-panel.state
  grep -v -e "^panel " -e "^appdir $PANEL\$" -e "^file $CRON1/sb-panel\$" "$STATE" > "$STATE.tmp" 2>/dev/null; mv "$STATE.tmp" "$STATE"
  ok "панель выключена"; ev panel off
  log "panel off"
}

do_panel() {
  panel_files
  set -- $SITES_ARGS
  case ${1:-status} in
    on)     : > "$RUN_JOURNAL"; panel_on ;;
    off)    panel_off ;;
    status) if [ -f "$PANEL/conf" ]; then ok "панель включена: $(panel_link)"; ev panel on "$(panel_link)"
            else skip "панель выключена (включить: sh install.sh panel on)"; ev panel off; fi ;;
    link)   [ -f "$PANEL/conf" ] || { bad "панель выключена"; return 1; }; say "$(panel_link)" ;;
    token)  [ -f "$PANEL/conf" ] || { bad "панель выключена"; return 1; }
            [ "$DRY" = 1 ] && return 0
            (umask 077; panel_token_new > "$PANEL/token"; : > "$PANEL/sessions")
            ok "новая ссылка (прежние больше не пускают): $(panel_link)"; ev panel on "$(panel_link)" ;;
    state)  panel_state ;;
    next)   panel_next ;;
    fix)    [ -n "$3" ] || { say "Нужно: panel fix example.com zapret|vpn|dns"; return 2; }
            panel_fix "$2" "$3" ;;
    *)      say "Нужно: panel on | off | status | link | token"; return 2 ;;
  esac
}

# module "panel" (only when chosen: not in any profile)
mod_panel() { panel_on || warn "панель не включена, остальное это не задевает"; }
