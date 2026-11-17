# Platform adapter: Keenetic / Netcraze (KeeneticOS + Entware on USB).
# Router settings go through `ndmc -c`, packages through Entware's opkg in /opt.

PKG_ROOT=$OPT
ETC_DIR=$OPT/etc
VAR_DIR=$OPT/var
BOT=$OPT/etc/watchdog/bot.conf
NFQ=$OPT/etc/nfqws2
NFQ_CONF=$NFQ/nfqws2.conf
NFQ_LIST=$NFQ/lists/user.list
NFQ_INIT=$OPT/etc/init.d/S51nfqws2
CRON5=$OPT/etc/cron.5mins
CRONW=$OPT/etc/cron.weekly
CRON1=$OPT/etc/cron.1min
OWN_HOOK=$OPT/etc/ndm/netfilter.d/101-switchback-own.sh   # after 100-nfqws2.sh: the router's own connections go past zapret
QUIC_HOOK=$OPT/etc/ndm/netfilter.d/102-switchback-noquic.sh   # devices at home do not use QUIC (the rule comes back after a firewall rebuild)
pf_noquic_on() { quic_hook_install; }
SCRIPT_PATH=$OPT/sbin:$OPT/bin:/usr/sbin:/usr/bin:/sbin:/bin   # PATH of the scripts switchback installs
DNS_LIMIT=8
DNS_REPLACE=1      # mod_dns may move a domain to another DoT server (pf_dns_srv_of + pf_dns_del + pf_dns_add)

# running-config, read once in the main shell (inside $(...) the cache would be lost)
RC=""
rc_load()  { RC=$(ndmc -c "show running-config" 2>/dev/null); }
rc_has()   { printf '%s\n' "$RC" | grep -qF -- "$1"; }
ndm() {
  if [ "$DRY" = 1 ]; then dry "ndmc: $*"; return 0; fi
  log "ndmc: $*"
  ndmc -c "$*" >/dev/null
}

pf_init() {
  [ -d "$OPT/etc" ] || fail "не найден Entware ($OPT/etc). Его нужно поставить заранее: docs/01-entware.md"
  command -v opkg >/dev/null || fail "нет opkg: Entware установлен не полностью"
  rc_load
  [ -n "$RC" ] || fail "роутер не отдал свои настройки (ndmc -c \"show running-config\")"
}

pf_describe() {
  sv=$(ndmc -c "show version" 2>/dev/null)
  ver=$(printf '%s\n' "$sv" | awk -F': *' '$1 ~ /^ *title$/ {print $2; exit}')
  model=$(printf '%s\n' "$sv" | awk -F': *' '$1 ~ /^ *(description|device|model)$/ && $2 != "" {print $2; exit}')
  [ -n "$model" ] || model=$(printf '%s\n' "$RC" | awk -F'Model: *' 'NF > 1 {print $2; exit}' | tr -d '\r')
  ok "модель: ${model:-?}, KeeneticOS ${ver:-?}"
  ev fw keenetic "${ver:-?}" "${model:-?}"
  case $ver in [0-3].*)
    note "  К сведению: с KeeneticOS 4.x роутер сам пускает сайты через VPN по имени домена; на ${ver} свои сайты через VPN"
    note "  идут по их адресам (switchback обновляет их каждые 5 минут). Обновление — в веб-интерфейсе, если для модели есть 4.x." ;;
  esac
  arch=$(opkg print-architecture 2>/dev/null | awk '$2!="all"{a=$2} END{print a}')
  ok "Entware: пакеты $arch"
}

pf_doctor() {
  sub "Keenetic / Netcraze"
  if ls /lib/modules/*/xt_NFQUEUE.ko >/dev/null 2>&1 || lsmod 2>/dev/null | grep -q NFQUEUE; then
    ok "модули Netfilter есть (нужны zapret)"
  else
    warn "не вижу модуля NFQUEUE: включите компонент «Модули ядра подсистемы Netfilter» (для zapret)"
  fi
  for w in $(printf '%s\n' "$RC" | sed -n 's/^interface \(Wireguard[0-9]*\)$/\1/p'); do
    if pf_vpn_is_global "$w"; then
      warn "$w включён «для выхода в интернет»: через VPN идёт ВЕСЬ трафик. Для схемы «только Telegram» это не нужно"
    elif pf_vpn_alive "$w"; then ok "$w: подключено, только для выбранных адресов"
    else skip "$w: сейчас не подключено"; fi
  done
  tg=$(tg_via)
  [ -n "$tg" ] && skip "Telegram уже идёт через $tg (маршруты не тронутся)"
  if printf '%s\n' "$RC" | grep -qE '^[[:space:]]+ipv6 prefix auto' && ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    warn "работает IPv6: маршруты VPN и DNS-обход сделаны для IPv4, часть трафика может идти мимо"
  else ok "IPv6 не мешает"; fi
  if wget -q -T 8 -O /dev/null https://bin.entware.net/ 2>/dev/null || wget -q -T 8 -O /dev/null http://bin.entware.net/ 2>/dev/null; then
    ok "репозиторий Entware доступен"
  else
    warn "репозиторий Entware недоступен: установка пакетов не пройдёт"
  fi
  printf '%s\n' "$RC" | grep -q '^no ppe software' && skip "программное ускорение уже выключено"
  # Auto-update is on by default and then absent from running-config; "auto-update disable" when off.
  # (syntax assumed from the CLI reference: confirm on a router with it turned off)
  if printf '%s\n' "$RC" | grep -q 'auto-update disable'; then
    ok "автообновление KeeneticOS выключено: после ручного обновления запустите анализ ещё раз"
  else
    skip "включено автообновление KeeneticOS: новая версия может поставиться сама и иногда ломает zapret. После обновления запустите анализ ещё раз; время установки можно выбрать: Общие настройки -> Автоматическое обновление"
  fi
}

# ---------- backup ----------
pf_backup() {   # pf_backup DIR
  ndmc -c "show running-config" > "$1/router-config.txt" 2>/dev/null
  echo "etc/watchdog/bot.conf" > /tmp/switchback.exclude
  tar czf "$1/entware-etc.tar.gz" -C "$OPT" -X /tmp/switchback.exclude etc 2>/dev/null
  opkg list-installed > "$1/packages.txt" 2>/dev/null
  chmod 600 "$1"/* 2>/dev/null
  [ -s "$1/router-config.txt" ]
}

pf_restore_help() {   # pf_restore_help DIR
  cat <<EOF
  Как вернуть всё как было, если что-то сломается:
    1) Роутер доступен по SSH:   sh install.sh uninstall
    2) Вернуть настройки роутера из снимка:
         веб-интерфейс -> Общие настройки -> Конфигурация -> startup-config -> загрузить файл
         $1/router-config.txt  (сначала скачайте его на компьютер, команда ниже)
    3) Скачать снимок на компьютер (PowerShell на ПК):
         ssh root@192.168.1.1 cat $1/router-config.txt > router-config.txt
    Подробно: docs/recovery.md
EOF
}

# ---------- packages ----------
pf_pkg_installed() { opkg list-installed 2>/dev/null | grep -q "^$1 "; }
pf_pkg_install()   { run opkg install "$@"; }
pf_pkg_remove()    { run opkg remove "$1"; }

pf_feeds_https() {
  grep -q 'http://bin.entware.net' "$OPT/etc/opkg.conf" 2>/dev/null || return 2   # nothing to do
  [ -f "$OPT/etc/opkg.conf.orig" ] || run cp "$OPT/etc/opkg.conf" "$OPT/etc/opkg.conf.orig"
  run sed -i 's#http://bin.entware.net#https://bin.entware.net#' "$OPT/etc/opkg.conf"
  [ "$DRY" = 1 ] && return 0
  opkg update >/dev/null 2>&1
}
pf_feeds_restore() { [ -f "$OPT/etc/opkg.conf.orig" ] && run cp "$OPT/etc/opkg.conf.orig" "$OPT/etc/opkg.conf"; }

# ---------- zapret ----------
pf_zapret_installed() { [ -x "$NFQ_INIT" ]; }
pf_zapret_install() {
  run mkdir -p "$OPT/etc/opkg"
  printf 'src/gz nfqws2-keenetic https://nfqws.github.io/nfqws2-keenetic/all\n' | write_file "$OPT/etc/opkg/nfqws2-keenetic.conf"
  run opkg update >/dev/null && run opkg install nfqws2-keenetic
}
pf_zapret_conf_backup()  { [ -f "$NFQ_CONF.orig" ] || run cp "$NFQ_CONF" "$NFQ_CONF.orig"; }
pf_zapret_conf_restore() { [ -f "$NFQ_CONF.orig" ] && run cp "$NFQ_CONF.orig" "$NFQ_CONF"; }
pf_zapret_restart()      { run "$NFQ_INIT" restart >/dev/null 2>&1; }
pf_zapret_running()      { pidof nfqws2 >/dev/null 2>&1; }
pf_list_del() { run sed -i "/^$(printf '%s' "$1" | sed 's/\./\\./g')\$/d" "$NFQ_LIST"; }
pf_zapret_prepare() { :; }      # KeeneticOS: nothing extra (acceleration is handled by the package)
EXCLUDE_BY_POLICY=1             # exclusion of a PC works through a Keenetic access policy
pf_exclude_hint() {
  say "  Как исключить компьютер: веб-интерфейс -> Сетевые правила -> Политики доступа ->"
  say "  создать политику (например, nfqws) с вашим интернет-подключением и перенести туда компьютер."
}

# ---------- DNS per domain ----------
pf_dns_intro() { say "  Нужен DNS-over-TLS сервер сервиса-прокси (IP и имя возьмите на его сайте)."; }
pf_dns_ask() {   # pf_dns_ask SERVICE -> DNS_SRV="IP SNI", DNS_LABEL
  k=dns_$(echo "$1" | tr 'A-Z' 'a-z')
  ask "    IP DoT-сервера для $1:" "" "${k}_ip"; ip=$REPLY
  ask "    Имя (SNI) DoT-сервера:" "" "${k}_sni"; sni=$REPLY
  case $ip in *[!0-9.]*|"") warn "это не IPv4-адрес, $1 пропускаю"; return 1 ;; esac
  [ -n "$sni" ] || { warn "без имени DoT не работает, $1 пропускаю"; return 1; }
  DNS_SRV="$ip $sni"; DNS_LABEL=$sni
}
pf_dns_count() { printf '%s\n' "$RC" | grep -c 'tls upstream .* domain '; }
pf_dns_has()   { rc_has "domain $1"; }
pf_dns_add()   { ndm "dns-proxy tls upstream $1 sni $2 domain $3"; }
# KeeneticOS removes a DoT server by its address only, together with every domain it serves (with
# "sni ... domain ..." it answers "argument parse error": seen on 3.8.7). So: remove the address, then put
# its other domains back. $RC is the picture from the start of the run, so the domains removed earlier in
# this run are kept in DNS_GONE.
DNS_GONE=" "
pf_dns_del() {
  DNS_GONE="$DNS_GONE$3 "
  ndm "no dns-proxy tls upstream $1" || return 1
  for pair in $(printf '%s\n' "$RC" | awk -v ip="$1" '$1=="tls" && $2=="upstream" && $3==ip && $4=="sni" && $6=="domain" {print $5 "|" $7}'); do
    case "$DNS_GONE" in *" ${pair#*|} "*) continue ;; esac
    ndm "dns-proxy tls upstream $1 sni ${pair%|*} domain ${pair#*|}" || return 1
  done
  return 0
}
# plain DNS server for a domain (Meta via VPN). Never with "on WireguardN": the DNS proxy then fails and
# silently falls back to the provider's DNS (seen on a real Keenetic)
pf_ns_has() { printf '%s\n' "$RC" | grep -qxF "ip name-server $1 $2"; }
pf_ns_add() { ndm "ip name-server $1 $2"; }
pf_ns_del() { ndm "no ip name-server $1 $2"; }
pf_dns_srv_of() {   # pf_dns_srv_of DOMAIN -> "IP SNI" of its DoT server (the words pf_dns_add takes before the domain)
  printf '%s\n' "$RC" | awk -v d="$1" '$1=="tls" && $2=="upstream" && $4=="sni" && $6=="domain" && $7==d {print $3, $5; exit}'
}

# ---------- VPN routes ----------
pf_vpn_ifaces()    { printf '%s\n' "$RC" | sed -n 's/^interface \(Wireguard[0-9]*\)$/\1/p'; }
pf_vpn_is_global() { printf '%s\n' "$RC" | sed -n "/^interface $1\$/,/^!/p" | grep -qE '^[[:space:]]+ip global'; }
pf_vpn_hint()      { say "  Импортируйте конфиг: Интернет -> Другие подключения -> WireGuard -> Загрузить из файла (docs/04)"; }
pf_route_has()     { [ "$(pf_route_via "$1" "$2")" = "$3" ]; }
pf_route_via() {   # pf_route_via NET MASK -> the interface this network is routed through (any route, not only ours)
  # a route to one address is shown without its mask: "ip route 1.2.3.4 Wireguard0 auto"
  printf '%s\n' "$RC" | awk -v n="$1" -v m="$2" '$1=="ip" && $2=="route" && $3==n {
    if ($4 ~ /^[0-9.]+$/) { if ($4 == m) { print $5; exit } } else if (m == "255.255.255.255") { print $4; exit } }'
}
pf_vpn_alive() {   # connected and a handshake with the server in the last 5 minutes
  s=$(ndmc -c "show interface $1" 2>/dev/null)
  printf '%s\n' "$s" | grep -q 'connected: yes' || return 1
  h=$(printf '%s\n' "$s" | awk -F': *' '$1 ~ /last-handshake/ {print $2; exit}')
  case $h in ''|*[!0-9]*) return 1 ;; esac
  [ "$h" -lt 300 ]
}
pf_route_add()     { ndm "ip route $1 $2 $3 auto"; }
pf_route_del()     { ndm "no ip route $1 $2 $3"; }

pf_uci_restore()    { :; }   # OpenWrt-only journal kinds, never written on Keenetic
pf_crontab_remove() { :; }
pf_keep_files()     { :; }   # Entware lives on the USB stick: a KeeneticOS update does not touch it
pf_keep_del()       { :; }
pf_uci_list_del()   { :; }

# ---------- WireGuard from a .conf ----------
# The same commands the user's wg-import.sh used to add six tunnels on a Keenetic Extra, KeeneticOS 3.8.7
# (2026-11-07): security-level public, adjust-mss, keepalive 25 by default, no routes, no "use for internet".
pf_wg_free_name() {
  n=0
  while [ $n -lt 50 ]; do
    printf '%s\n' "$RC" | grep -qx "interface Wireguard$n" || { echo "Wireguard$n"; return; }
    n=$((n+1))
  done
}
ndm_secret() {   # ndm_secret "shown text" "command": the command holds a key
  if [ "$DRY" = 1 ]; then dry "ndmc: $1"; return 0; fi
  log "ndmc: $1"
  ndmc -c "$2" >/dev/null
}
pf_wg_create() {   # pf_wg_create NAME (WG_* from wg_parse; WG_STANDBY=1: leave it switched off)
  i=$1; ip=${WG_ADDR%/*}; mask=$(cidr2mask "${WG_ADDR#*/}"); ka=${WG_KA:-25}
  ndm "interface $i" || return 1
  remember "wg $i"
  ndm "interface $i description switchback-$WG_EP_HOST" &&
  ndm "interface $i security-level public" &&
  ndm "interface $i ip address $ip $mask" &&
  ndm "interface $i ip tcp adjust-mss pmtu" &&
  { [ -z "$WG_MTU" ] || ndm "interface $i ip mtu $WG_MTU"; } &&
  ndm_secret "interface $i wireguard private-key <скрыто>" "interface $i wireguard private-key $WG_PRIV" &&
  ndm "interface $i wireguard peer $WG_PUB" &&
  ndm "interface $i wireguard peer $WG_PUB endpoint $WG_EP_HOST:$WG_EP_PORT" &&
  ndm "interface $i wireguard peer $WG_PUB keepalive-interval $ka" &&
  ndm "interface $i wireguard peer $WG_PUB allow-ips 0.0.0.0 0.0.0.0" &&
  { [ -z "$WG_PSK" ] || ndm_secret "interface $i wireguard peer $WG_PUB preshared-key <скрыто>" "interface $i wireguard peer $WG_PUB preshared-key $WG_PSK"; } || return 1
  if [ "$WG_STANDBY" = 1 ]; then skip "$i оставлен выключенным (запасной: включит автосмена)"
  else ndm "interface $i up" || return 1; fi
  CLI_CHANGED=1
}
pf_wg_delete() { ndm "no interface $1"; }
pf_wg_up()   { ndm "interface $1 up"; }       # not saved: a standby goes back down after its check
pf_wg_down() { ndm "interface $1 down"; }
pf_wg_dev() { echo "nwg${1#Wireguard}"; }   # WireguardN -> the kernel device nwgN (curl --interface)
pf_save()   { ndm "system configuration save"; }
pf_reboot_cmd() { echo "ndmc -c 'system reboot'"; }   # for the night reboot (lib/heal.sh)
pf_reload() { [ "$DRY" = 1 ] || rc_load; }

# ---------- scheduler ----------
pf_cron_setup() {
  need=""
  command -v curl >/dev/null || need="$need curl"
  [ -x "$OPT/etc/init.d/S10cron" ] || need="$need cron"
  if [ -n "$need" ]; then pf_pkg_install $need || return 1; for p in $need; do remember "pkg $p"; done; fi
  run "$OPT/etc/init.d/S10cron" start >/dev/null 2>&1
  return 0
}

pf_backup_job() {
cat <<'EOF'
#!/bin/sh
# Weekly backup (switchback): router config + Entware settings, without the bot token.
export PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
B=/opt/backup
mkdir -p "$B"; chmod 700 "$B"
d=$(date +%Y-%m-%d)
ndmc -c "show running-config" > "$B/router-$d.txt"
echo "etc/watchdog/bot.conf" > /tmp/backup.exclude
tar czf "$B/entware-$d.tar.gz" -C /opt -X /tmp/backup.exclude etc
chmod 600 "$B"/*
ls -t "$B"/router-*.txt      | tail -n +9 | xargs -r rm -f
ls -t "$B"/entware-*.tar.gz  | tail -n +9 | xargs -r rm -f
if [ ! -s "$B/router-$d.txt" ] || [ ! -s "$B/entware-$d.tar.gz" ]; then
  [ -f /opt/etc/watchdog/bot.conf ] || exit 1
  TOKEN=""; NTFY=""; . /opt/etc/watchdog/bot.conf
  # Telegram first; the reserve channel ntfy if Telegram does not answer
  { [ -n "$TOKEN" ] && curl -s -o /dev/null --max-time 20 -w '%{http_code}' "https://api.telegram.org/bot$TOKEN/sendMessage" \
      -d chat_id="$CHAT" --data-urlencode text="[роутер] Не удалось сделать еженедельный бэкап настроек ($d). Проверьте флешку: она могла заполниться или сломаться." | grep -q 200; } ||
    { [ -n "$NTFY" ] && curl -s -o /dev/null --max-time 20 -H "Title: router" -d "Не удалось сделать еженедельный бэкап настроек ($d). Проверьте флешку: она могла заполниться или сломаться." "$NTFY"; }
fi
EOF
}
# ---------- failover: platform part of the installed script (see lib/failover.sh) ----------
pf_failover_funcs() {
cat <<'EOF'
fo_load()    { CFG=$(ndmc -c 'show running-config'); }
fo_tunnels() { echo "$CFG" | sed -n 's/^interface \(Wireguard[0-9]*\)$/\1/p'; }
fo_exists()  { echo "$CFG" | grep -qx "interface $1"; }   # "interface X up" on a missing X creates it
# routes through a tunnel: "ip route NET MASK WireguardN auto" (host routes print without a mask)
fo_routes()  { echo "$CFG" | awk '$1=="ip" && $2=="route" && $NF=="auto" && $(NF-1) ~ /^Wireguard[0-9]+$/ {
                 if (NF == 6) print $3, $4, $5, "-"; else print $3, "255.255.255.255", $4, "-" }'; }
fo_hs() {    # seconds since the last handshake, 99999 if none / tunnel down
  ndmc -c "show interface $1" 2>/dev/null | awk '/connected:/ {c=$2} /last-handshake:/ {h=$2}
    END { if (c != "yes" || h == "" || h+0 > 86400) print 99999; else print h+0 }'
}
fo_desc()    { ndmc -c "show interface $1" 2>/dev/null | awk '/description:/ {print $2; exit}'; }
fo_works() { # a request bound to that tunnel reaches Telegram (a handshake alone proves nothing)
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 --interface "nwg${1#Wireguard}" https://api.telegram.org/)
  [ -n "$c" ] && [ "$c" != "000" ]
}
fo_was_on()  { echo "$CFG" | sed -n "/^interface $1\$/,/^!/p" | grep -qE '^[[:space:]]+up$'; }
fo_up()      { ndmc -c "interface $1 up" >/dev/null 2>&1; }
fo_down()    { ndmc -c "interface $1 down" >/dev/null 2>&1; }
fo_move()    { ndmc -c "ip route $1 $2 $4 auto" >/dev/null 2>&1; ndmc -c "no ip route $1 $2 $3" >/dev/null 2>&1; }
fo_commit()  { ndmc -c 'system configuration save' >/dev/null 2>&1; }   # "down" of the old one is saved too
EOF
}

# ---------- Claude nodes: pins ("ip host") and QUIC rules (access list of the Home segment) ----------
# A QUIC rule: "    deny udp 0.0.0.0 0.0.0.0 IP 255.255.255.255 port eq 443" inside an access-list; its
# attribute lines follow it ("    deny description ...", "    deny disable" = switched off).
# quic_state IP < running-config -> on | off | none
QUIC_AWK='/^[[:space:]]+(deny|permit) (udp|tcp|ip|icmp|ipip|gre|esp) / {
    if (found) exit; found = ($1=="deny" && $2=="udp" && $3=="0.0.0.0" && $5==ip && $7=="port" && $9=="443"); next }
  found && /^[[:space:]]+deny disable/ { dis = 1; next }
  found && /^[^[:space:]]/ { exit }
  END { print (found ? (dis ? "off" : "on") : "none") }'
pf_quic_state()   { printf '%s\n' "$RC" | awk -v ip="$1" "$QUIC_AWK"; }
pf_quic_blocked() {
  s=$(pf_quic_state "$1")
  [ "$s" = off ] && warn "правило QUIC для $1 есть, но выключено: включите его в веб-интерфейсе (Сетевые правила -> Межсетевой экран)"
  [ "$s" != none ]       # an existing rule (even switched off) is the user's: never add a second one
}
home_acl() { printf '%s\n' "$RC" | sed -n '/^interface Bridge0$/,/^!/p' | awk '$1=="ip" && $2=="access-group" && $4=="in" {print $3; exit}'; }
pf_quic_block() {   # pf_quic_block IP: deny UDP 443 from the home network to IP
  acl=$(home_acl)
  if [ -z "$acl" ]; then   # no firewall rules on the Home segment yet: make its list and bind it
    acl=_WEBADMIN_Home
    ndm "interface Bridge0 ip access-group $acl in" || return 1
    remember "acl_bind Bridge0 $acl"
    RC="$RC
interface Bridge0
    ip access-group $acl in
!"
  fi
  ndm "access-list $acl deny udp 0.0.0.0 0.0.0.0 $1 255.255.255.255 port eq 443" || return 1
  remember "quic $1 $acl"
}
# Checked on a Keenetic Extra, KeeneticOS 3.8.7 (2026-11-07): "Rule deleted", "access group deleted from ...".
pf_quic_unblock() { ndm "access-list $2 no deny udp 0.0.0.0 0.0.0.0 $1 255.255.255.255 port eq 443"; }
pf_acl_unbind()   { ndm "interface $1 no ip access-group $2 in"; }
pf_host_pinned()  { printf '%s\n' "$RC" | awk -v h="$1" '$1=="ip" && $2=="host" && $3==h {print $4; exit}'; }
pf_host_pin() {     # pf_host_pin DOMAIN IP: the router's DNS answers IP for DOMAIN
  old=$(pf_host_pinned "$1")
  [ -n "$old" ] && { ndm "no ip host $1" || return 1; }
  ndm "ip host $1 $2" || return 1
  remember "host $1 ${old:--}"
}
pf_host_restore() { ndm "no ip host $1"; [ "$2" = - ] || ndm "ip host $1 $2"; }

# platform part of the installed claude-nodes script (see lib/nodes.sh)
pf_nodes_funcs() {
printf "QUIC_AWK='%s'\n" "$QUIC_AWK"
cat <<'EOF'
nd_load()    { CFG=$(ndmc -c 'show running-config'); }
nd_pinned()  { echo "$CFG" | awk -v h="$1" '$1=="ip" && $2=="host" && $3==h {print $4; exit}'; }
nd_quic_ok() { [ "$(echo "$CFG" | awk -v ip="$1" "$QUIC_AWK")" = on ]; }   # a switched-off rule does not count
nd_pin()     { ndmc -c "no ip host $1" >/dev/null 2>&1; ndmc -c "ip host $1 $2" >/dev/null 2>&1; }
nd_commit()  { ndmc -c 'system configuration save' >/dev/null 2>&1; }
EOF
}

# ---------- report: the parts of running-config worth showing (never the whole of it) ----------
pf_report_config() {
  sub "из running-config: туннели, маршруты, закрепления, DNS, правила, обновления"
  printf '%s\n' "$RC" | awk '
    /^(interface Wireguard[0-9]+|access-list |dns-proxy|components|ip policy )/ { blk = 1 }
    blk || /^ip (route|host|name-server) / || /^(no )?ppe / { print "    " $0 }
    blk && /^!/ { blk = 0 }'
}
