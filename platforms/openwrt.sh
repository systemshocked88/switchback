# Platform adapter: OpenWrt (and builds based on it: iStoreOS, x-wrt, ImmortalWrt).
# Settings through uci, packages through opkg (<= 24.10) or apk (25+).
# $ROOT is "" on a router; tests point it at a fake root.

ETC_DIR=$ROOT/etc
VAR_DIR=$ROOT/var
BOT=$ETC_DIR/switchback/bot.conf
NFQ=$ETC_DIR/nfqws2
NFQ_CONF=$NFQ/nfqws2.conf
NFQ_LIST=$NFQ/lists/user.list
NFQ_INIT=$ETC_DIR/init.d/nfqws2-keenetic
CRON5=$ETC_DIR/switchback/cron5
CRONW=$ETC_DIR/switchback/cronw
CRON1=$ETC_DIR/switchback/cron1   # run every minute by one crontab line
OWN_HOOK=""                        # the kernel leak behind it was seen on Keenetic only
QUIC_HOOK=""                       # "no QUIC" is a firewall rule here (pf_noquic_on), not a hook
pf_noquic_on() {   # lan -> wan, UDP 443, reject (undo: the uci journal)
  s=firewall.sb_noquic
  uci -q get "$s" >/dev/null && return 0
  uci_new_section "$s" rule || return 1
  run uci set "$s.name=switchback: no QUIC from home" && run uci set "$s.src=lan" && run uci set "$s.dest=wan" &&
  run uci set "$s.proto=udp" && run uci set "$s.dest_port=443" && run uci set "$s.target=REJECT" || return 1
  FW_CHANGED=1; pf_save
}
SCRIPT_PATH=$ROOT/usr/sbin:$ROOT/usr/bin:$ROOT/sbin:$ROOT/bin:/usr/sbin:/usr/bin:/sbin:/bin   # PATH of installed scripts
CRONTAB=$ETC_DIR/crontabs/root
DNS_LIMIT=999                 # dnsmasq has no practical limit
MIN_FREE_MB=3                 # small flash is normal on OpenWrt; nfqws2 takes about 1 MB
EXCLUDE_BY_POLICY=0
NFQ_FEED=https://nfqws.github.io/nfqws2-keenetic/openwrt
NET_CHANGED=0; DNS_CHANGED=0; FW_CHANGED=0

pf_init() {
  command -v uci >/dev/null || fail "нет uci: это точно OpenWrt?"
  if command -v apk >/dev/null 2>&1; then PKGMGR=apk; else PKGMGR=opkg; fi
  if [ -d "$ROOT/overlay" ]; then PKG_ROOT=$ROOT/overlay; else PKG_ROOT=$ROOT/; fi
  PKG_UPDATED=0
}

pf_describe() {
  [ -f "$ROOT/etc/openwrt_release" ] && . "$ROOT/etc/openwrt_release"
  model=$(cat "$ROOT/tmp/sysinfo/model" 2>/dev/null || tr -d '\0' 2>/dev/null < /proc/device-tree/model)
  ok "${DISTRIB_DESCRIPTION:-OpenWrt}, модель: ${model:-?}"
  # the program compares the version with the latest stable OpenWrt; board_name is the device's id there
  ev fw openwrt "${DISTRIB_RELEASE:-?}" "$(cat "$ROOT/tmp/sysinfo/board_name" 2>/dev/null)" "${model:-?}"
  if [ "$PKGMGR" = apk ]; then arch=$(apk --print-arch 2>/dev/null)
  else arch=$(opkg print-architecture 2>/dev/null | awk '$2!="all"{a=$2} END{print a}'); fi
  ok "пакеты: $PKGMGR, архитектура ${arch:-?}"
}

fw_offload_on() {
  [ "$(uci -q get firewall.@defaults[0].flow_offloading)" = 1 ] || [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = 1 ]
}

pf_doctor() {
  sub "OpenWrt"
  if fw_offload_on; then
    warn "включено ускорение (flow offloading): с ним zapret не работает. Установщик предложит его выключить"
  else ok "ускорение (flow offloading) выключено"; fi
  if ls /lib/modules/*/nft_queue.ko /lib/modules/*/xt_NFQUEUE.ko >/dev/null 2>&1; then ok "модуль очереди пакетов есть (нужен zapret)"
  else warn "не вижу модуля очереди пакетов (kmod-nft-queue): если zapret не запустится, поставьте его"; fi
  # nfqws2-keenetic for opkg depends on the legacy iptables stack (seen on 24.10: ~20 packages, ~2-3 MB)
  if [ "$PKGMGR" = opkg ] && ! pf_zapret_installed && ! pf_pkg_installed iptables-zz-legacy; then
    note "zapret на OpenWrt с opkg потянет старый iptables (около 20 пакетов, 2–3 МБ во флеше); откат их уберёт"
  fi
  for w in $(pf_vpn_ifaces); do
    if pf_vpn_is_global "$w"; then warn "$w пускает через VPN ВЕСЬ трафик (Route Allowed IPs). Для «только Telegram» это не нужно"
    else ok "$w: VPN только для выбранных адресов"; fi
    uci show firewall 2>/dev/null | grep -q "network=.*$w" || warn "$w не входит ни в одну зону межсетевого экрана: добавьте его в зону wan"
    uci show network 2>/dev/null | grep "wireguard_$w" | grep -q "allowed_ips=.*0\.0\.0\.0/0" ||
      warn "$w: в Allowed IPs нет 0.0.0.0/0 — трафик на адреса Telegram в туннель не пойдёт"
  done
  if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    warn "работает IPv6: маршруты VPN и DNS-обход сделаны для IPv4, часть трафика может идти мимо"
  else ok "IPv6 не мешает"; fi
  if wget -q -T 8 -O /dev/null "$NFQ_FEED/" 2>/dev/null || wget -q -T 8 -O /dev/null https://downloads.openwrt.org/ 2>/dev/null; then
    ok "репозитории доступны"
  else warn "репозитории недоступны: установка пакетов не пройдёт"; fi
}

# ---------- backup ----------
pf_backup() {   # pf_backup DIR
  sysupgrade -b "$1/openwrt-backup.tar.gz" >/dev/null 2>&1
  if [ "$PKGMGR" = apk ]; then apk info > "$1/packages.txt" 2>/dev/null; else opkg list-installed > "$1/packages.txt" 2>/dev/null; fi
  chmod 600 "$1"/* 2>/dev/null
  [ -s "$1/openwrt-backup.tar.gz" ]
}
pf_restore_help() {
  cat <<EOF
  Как вернуть всё как было, если что-то сломается:
    1) Роутер доступен по SSH:   sh install.sh uninstall
    2) Восстановить все настройки из снимка (роутер перезагрузится):
         sysupgrade -r $1/openwrt-backup.tar.gz
       или в веб-интерфейсе: System -> Backup / Flash Firmware -> Restore backup
    3) Скачать снимок на компьютер (в командной строке ПК):
         scp -O root@192.168.1.1:$1/openwrt-backup.tar.gz .
    Подробно: docs/recovery.md
EOF
}

# ---------- packages ----------
pkg_update_once() {
  [ "$PKG_UPDATED" = 1 ] && return 0
  if [ "$PKGMGR" = apk ]; then run apk update >/dev/null; else run opkg update >/dev/null; fi
  PKG_UPDATED=1
}
pf_pkg_installed() {
  if [ "$PKGMGR" = apk ]; then apk info -e "$1" >/dev/null 2>&1; else opkg list-installed 2>/dev/null | grep -q "^$1 "; fi
}
pf_pkg_install() {
  pkg_update_once
  if [ "$PKGMGR" = apk ]; then run apk add "$@"; else run opkg install "$@"; fi
}
pf_pkg_names() {   # installed package names, one per line
  if [ "$PKGMGR" = apk ]; then apk info 2>/dev/null; else opkg list-installed 2>/dev/null | awk '{print $1}'; fi
}
# pkg_track_begin / pkg_track_end: remember the packages an install brought in that were not there before
# ("pkgdeps NAME..."), so the uninstall can take exactly them away and nothing that was on the router before us
pkg_track_begin() { PKG_BEFORE=$(pf_pkg_names | sort); }
pkg_track_end() {
  [ "$DRY" = 1 ] && return 0
  new=$(pf_pkg_names | sort | while read -r p; do
    printf '%s\n' "$PKG_BEFORE" | grep -qxF "$p" || printf '%s ' "$p"; done)
  [ -n "$new" ] && remember "pkgdeps ${new% }"
  return 0
}
pf_pkg_remove() {
  pf_pkg_installed "$1" || return 0
  if [ "$PKGMGR" = apk ]; then run apk del "$1"; else run opkg remove "$1" </dev/null; fi
  pf_pkg_installed "$1" && return 1
  case $1 in   # what the package leaves behind (conffiles we changed): ours to clean, the package was ours
    nfqws2-keenetic) run rm -rf "$NFQ" ;;
    https-dns-proxy) run rm -f "$ETC_DIR/config/https-dns-proxy" ;;
  esac
  return 0
}
# pf_pkgs_remove NAME...: remove packages that depend on each other; a package another one still needs is
# retried after that one has gone. Anything that does not go after all passes is reported, not forced.
pf_pkgs_remove() {
  if [ "$DRY" = 1 ]; then dry "удалить пакеты: $*"; return 0; fi
  left="$*"; pass=0
  while [ -n "$left" ] && [ $pass -lt 6 ]; do
    pass=$((pass+1)); next=""
    for p in $left; do
      pf_pkg_installed "$p" || continue
      if [ "$PKGMGR" = apk ]; then apk del "$p" >/dev/null 2>&1; else opkg remove "$p" </dev/null >/dev/null 2>&1; fi
      pf_pkg_installed "$p" && next="$next $p"
    done
    [ "$next" = "$left" ] && break
    left=$next
  done
  [ -z "$(echo $left)" ] || { warn "не удалось удалить пакеты (их использует что-то ещё):$left"; return 1; }
}

pf_feeds_https() { return 2; }   # OpenWrt release feeds are https already
pf_feeds_restore() { :; }

# ---------- zapret ----------
pf_zapret_installed() { [ -x "$NFQ_INIT" ]; }
pf_zapret_install() {
  pkg_track_begin
  pf_pkg_install ca-certificates wget-ssl || return 1
  if [ "$PKGMGR" = apk ]; then
    feed_file "$ETC_DIR/apk/keys/nfqws2-keenetic.pem"
    run wget -q -O "$ETC_DIR/apk/keys/nfqws2-keenetic.pem" "$NFQ_FEED/nfqws2-keenetic.pem" || return 1
    feed_file "$ETC_DIR/apk/repositories.d/nfqws2-keenetic.list"
    echo "$NFQ_FEED/packages.adb" | write_file "$ETC_DIR/apk/repositories.d/nfqws2-keenetic.list"
    run apk --update-cache add nfqws2-keenetic || return 1
  else
    run wget -q -O /tmp/nfqws2-keenetic.pub "$NFQ_FEED/nfqws2-keenetic.pub" || return 1
    keys0=$(ls "$ETC_DIR/opkg/keys" 2>/dev/null)
    run opkg-key add /tmp/nfqws2-keenetic.pub || return 1
    for k in $(ls "$ETC_DIR/opkg/keys" 2>/dev/null); do   # opkg-key names the file by the key's fingerprint
      printf '%s\n' "$keys0" | grep -qxF "$k" || remember "pkgfile $ETC_DIR/opkg/keys/$k"
    done
    feed_file "$ETC_DIR/opkg/nfqws2-keenetic.conf"
    echo "src/gz nfqws2-keenetic $NFQ_FEED" | write_file "$ETC_DIR/opkg/nfqws2-keenetic.conf"
    run opkg update >/dev/null && run opkg install nfqws2-keenetic || return 1
  fi
  pkg_track_end
}
# feed_file PATH: a package-source file switchback is about to add (not there before): removed with our packages
feed_file() { [ -e "$1" ] || remember "pkgfile $1"; }
pf_zapret_conf_backup()  { [ -f "$NFQ_CONF.orig" ] || run cp "$NFQ_CONF" "$NFQ_CONF.orig"; }
pf_zapret_conf_restore() { [ -f "$NFQ_CONF.orig" ] && run cp "$NFQ_CONF.orig" "$NFQ_CONF" && run rm -f "$NFQ_CONF.orig"; }
pf_zapret_restart()      { run "$NFQ_INIT" restart >/dev/null 2>&1; }
pf_zapret_running()      { pidof nfqws2 >/dev/null 2>&1; }
pf_list_del() { run sed -i "/^$(printf '%s' "$1" | sed 's/\./\\./g')\$/d" "$NFQ_LIST"; }
pf_exclude_hint() {
  say "  На OpenWrt установщик пока не умеет исключать отдельный компьютер: выключите обход"
  say "  на компьютере (zapret на роутере уже работает для всех устройств)."
}

uci_set() {   # uci_set KEY VALUE: change a setting and remember the old value for undo
  old=$(uci -q get "$1"); [ -n "$old" ] || old=__unset__
  [ "$old" = "$2" ] && return 0
  run uci set "$1=$2" && remember "uci $1 $old"
}
pf_uci_restore() {   # pf_uci_restore KEY OLD
  if [ "$2" = __unset__ ]; then run uci -q delete "$1"; else run uci set "$1=$2"; fi
  case $1 in firewall.*) FW_CHANGED=1 ;; network.*) NET_CHANGED=1 ;; https-dns-proxy.*|dhcp.*) DNS_CHANGED=1 ;; esac
}

pf_zapret_prepare() {
  fw_offload_on || return 0
  say "  Включено аппаратное/программное ускорение (flow offloading): пакеты идут мимо zapret."
  if yes_no "  Выключить ускорение? (скорость на гигабитных тарифах может немного снизиться)" y disable_offload; then
    uci_set firewall.@defaults[0].flow_offloading 0
    uci_set firewall.@defaults[0].flow_offloading_hw 0
    FW_CHANGED=1; pf_save
    ok "ускорение выключено"
  else
    warn "ускорение оставлено: zapret, скорее всего, не будет работать"
  fi
}

# ---------- DNS per domain: https-dns-proxy (DoH) + dnsmasq ----------
pf_dns_intro() { say "  Нужен адрес DoH сервиса-прокси (вида https://сервис/dns-query, возьмите на его сайте)."; }
pf_dns_ask() {   # pf_dns_ask SERVICE -> DNS_SRV="127.0.0.1#PORT", DNS_LABEL
  case $1 in ChatGPT) port=5153; sec=sb_chatgpt ;; Claude) port=5154; sec=sb_claude ;; *) return 1 ;; esac
  ask "    Адрес DoH для $1:" "" "dns_$(echo "$1" | tr 'A-Z' 'a-z')_doh"; url=$REPLY
  case $url in https://*) ;; *) warn "адрес должен начинаться с https://, $1 пропускаю"; return 1 ;; esac
  if ! pf_pkg_installed https-dns-proxy; then
    pkg_track_begin
    pf_pkg_install https-dns-proxy || fail "не удалось установить https-dns-proxy"
    pkg_track_end; remember "pkg https-dns-proxy"
    DNS_CHANGED=1; CLI_CHANGED=1   # (re)installed, e.g. after a firmware upgrade: restart it with our settings
  fi
  # do not let it take over all DNS of the router: only our domains go to it
  uci_set https-dns-proxy.config.dnsmasq_config_update -
  uci_set https-dns-proxy.config.force_dns 0
  if [ "$(uci -q get https-dns-proxy.$sec.resolver_url)" != "$url" ]; then
    if ! uci -q get "https-dns-proxy.$sec" >/dev/null; then
      run uci set "https-dns-proxy.$sec=https-dns-proxy" && remember "uci https-dns-proxy.$sec __unset__"
    fi
    run uci set "https-dns-proxy.$sec.resolver_url=$url"
    run uci set "https-dns-proxy.$sec.listen_addr=127.0.0.1"
    run uci set "https-dns-proxy.$sec.listen_port=$port"
    run uci set "https-dns-proxy.$sec.bootstrap_dns=1.1.1.1,8.8.8.8"
    DNS_CHANGED=1; CLI_CHANGED=1
  fi
  DNS_SRV="127.0.0.1#$port"; DNS_LABEL="DoH ${url#https://}"
}
dns_servers() { uci -q get dhcp.@dnsmasq[0].server | tr ' ' '\n'; }
pf_dns_count() { dns_servers | grep -c '^/'; }
pf_dns_has()   { dns_servers | grep -q "^/$1/"; }
pf_dns_add()   { run uci add_list "dhcp.@dnsmasq[0].server=/$2/$1" && DNS_CHANGED=1; }
pf_dns_del()   { run uci del_list "dhcp.@dnsmasq[0].server=/$2/$1" && DNS_CHANGED=1; }
pf_ns_has() { dns_servers | grep -qxF "/$2/$1"; }   # plain DNS server for a domain (Meta via VPN)
pf_ns_add() { pf_dns_add "$1" "$2"; }
pf_ns_del() { pf_dns_del "$1" "$2"; }
pf_dns_srv_of() { dns_servers | awk -F/ -v d="$1" '$2 == d {print $3; exit}'; }   # DOMAIN -> 127.0.0.1#PORT

# ---------- VPN routes ----------
pf_vpn_ifaces() { uci show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)\.proto='wireguard'\$/\1/p"; }
pf_vpn_is_global() {
  for s in $(uci show network 2>/dev/null | sed -n "s/^network\.\([^=]*\)=wireguard_$1\$/\1/p"); do
    [ "$(uci -q get "network.$s.route_allowed_ips")" = 1 ] &&
      uci -q get "network.$s.allowed_ips" | grep -q '0\.0\.0\.0/0' && return 0
  done
  return 1
}
pf_vpn_hint() {
  say "  Добавьте WireGuard: Network -> Interfaces -> Add new interface -> WireGuard VPN, импортируйте"
  say "  конфиг; в пире: Allowed IPs = 0.0.0.0/0, Route Allowed IPs = выкл; интерфейс добавьте в зону wan."
}
route_sec() { echo "sb_tg_$(echo "$1" | tr . _)"; }
pf_route_has() { [ "$(uci -q get "network.$(route_sec "$1").interface")" = "$3" ]; }
pf_route_via() {   # pf_route_via NET MASK -> interface of our route for NET, or of any uci route with that target
  i=$(uci -q get "network.$(route_sec "$1").interface")
  [ -n "$i" ] || i=$(uci show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.target='$1'\$/\1/p" | head -1 |
    while read -r s; do uci -q get "network.$s.interface"; done)
  echo "$i"
}
pf_vpn_alive() {   # a handshake with the server in the last 5 minutes
  command -v wg >/dev/null 2>&1 || return 1
  t=$(wg show "$1" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
  case $t in ''|0|*[!0-9]*) return 1 ;; esac
  [ $(( $(date +%s) - t )) -lt 300 ]
}
pf_route_add() {
  s=$(route_sec "$1")
  if run uci set "network.$s=route" && run uci set "network.$s.interface=$3" &&
     run uci set "network.$s.target=$1" && run uci set "network.$s.netmask=$2"; then
    NET_CHANGED=1; return 0
  fi
  run uci -q delete "network.$s"     # refused halfway: do not leave a half-made route behind
  return 1
}
pf_wg_up()   { run ifup "$1" >/dev/null 2>&1; }
pf_wg_down() { run ifdown "$1" >/dev/null 2>&1; }
pf_wg_dev() { echo "$1"; }   # the uci interface name is the device name
pf_route_del() { run uci -q delete "network.$(route_sec "$1")" && NET_CHANGED=1; }

# ---------- WireGuard from a .conf ----------
pf_wg_free_name() {
  for n in "" 1 2 3 4 5 6 7 8 9; do
    uci -q get "network.sbwg$n" >/dev/null || { echo "sbwg$n"; return; }
  done
}
uci_new_section() {   # uci_new_section network.NAME TYPE: create, undo deletes it
  uci -q get "$1" >/dev/null && return 1
  run uci set "$1=$2" && remember "uci $1 __unset__"
}
uci_secret_set() {    # uci_secret_set KEY VALUE "label": a key, never shown or logged
  if [ "$DRY" = 1 ]; then dry "uci set $1=<скрыто>"; return 0; fi
  log "run: uci set $1=<скрыто>"
  uci set "$1=$2"
}
wan_zone() {   # index of the firewall zone that holds the wan network
  for z in 0 1 2 3 4 5 6 7 8 9; do
    uci -q get "firewall.@zone[$z]" >/dev/null || continue
    [ "$(uci -q get "firewall.@zone[$z].name")" = wan ] && { echo "$z"; return; }
    uci -q get "firewall.@zone[$z].network" | tr ' ' '\n' | grep -qx wan && { echo "$z"; return; }
  done
}
pf_wg_create() {   # pf_wg_create NAME (WG_* from wg_parse)
  i=$1; p=network.${i}_peer
  pf_pkg_installed wireguard-tools || pf_pkg_installed kmod-wireguard || {
    pf_pkg_install kmod-wireguard wireguard-tools luci-proto-wireguard || return 1
    remember "pkg luci-proto-wireguard"
  }
  remember "wg $i"
  uci_new_section "network.$i" interface || return 1
  run uci set "network.$i.proto=wireguard" &&
  uci_secret_set "network.$i.private_key" "$WG_PRIV" &&
  run uci add_list "network.$i.addresses=$WG_ADDR" &&
  { [ -z "$WG_MTU" ] || run uci set "network.$i.mtu=$WG_MTU"; } || return 1
  uci_new_section "$p" "wireguard_$i" || return 1
  run uci set "$p.description=switchback" &&
  run uci set "$p.public_key=$WG_PUB" &&
  { [ -z "$WG_PSK" ] || uci_secret_set "$p.preshared_key" "$WG_PSK"; } &&
  run uci set "$p.endpoint_host=$WG_EP_HOST" &&
  run uci set "$p.endpoint_port=$WG_EP_PORT" &&
  run uci add_list "$p.allowed_ips=0.0.0.0/0" &&
  run uci set "$p.route_allowed_ips=0" &&       # only Telegram's addresses go into the tunnel
  { [ -z "$WG_KA" ] || run uci set "$p.persistent_keepalive=$WG_KA"; } || return 1
  z=$(wan_zone)
  if [ -n "$z" ]; then
    run uci add_list "firewall.@zone[$z].network=$i" && remember "uci_list firewall.@zone[$z].network $i"
    FW_CHANGED=1
  else warn "не нашёл зону wan: добавьте $i в неё вручную (Network -> Firewall)"; fi
  NET_CHANGED=1
}
pf_wg_delete() { :; }   # the uci journal entries remove the sections
pf_uci_list_del() { run uci del_list "$1=$2"; case $1 in firewall.*) FW_CHANGED=1 ;; network.*) NET_CHANGED=1 ;; esac; }

# ---------- surviving a firmware upgrade (sysupgrade) ----------
# sysupgrade keeps /etc/config but drops packages and our own files. Files listed in
# /etc/sysupgrade.conf are kept. Not the snapshot folders: every new snapshot would contain
# the older ones and grow without end.
SYSUPGRADE_CONF=$ETC_DIR/sysupgrade.conf
KEEP_PATHS="/etc/switchback/state /etc/switchback/bot.conf /etc/switchback/cron5/ /etc/switchback/cronw/ /etc/switchback/cron1/
/etc/switchback/app/ /etc/switchback/failover.conf /etc/switchback/nodes.conf /etc/switchback/sites /etc/switchback/sites.routes
/etc/nfqws2/ /etc/crontabs/root"
pf_keep_files() {
  for p in $KEEP_PATHS; do
    grep -qxF "$p" "$SYSUPGRADE_CONF" 2>/dev/null && continue
    append_line "$SYSUPGRADE_CONF" "$p" && remember "keep $p"
  done
  return 0
}
pf_keep_del() {   # pf_keep_del PATH: take our line out of sysupgrade.conf
  if [ "$DRY" = 1 ]; then dry "убрать $1 из $SYSUPGRADE_CONF"; return 0; fi
  [ -f "$SYSUPGRADE_CONF" ] || return 0
  grep -vxF "$1" "$SYSUPGRADE_CONF" > "$SYSUPGRADE_CONF.sb"
  cat "$SYSUPGRADE_CONF.sb" > "$SYSUPGRADE_CONF"; rm -f "$SYSUPGRADE_CONF.sb"
  log "keep removed: $1"
}

pf_reboot_cmd() { echo reboot; }   # for the night reboot (lib/heal.sh)
pf_save() {
  run uci commit
  [ "$FW_CHANGED" = 1 ]  && run "$ETC_DIR/init.d/firewall" restart >/dev/null 2>&1
  [ "$NET_CHANGED" = 1 ] && run "$ETC_DIR/init.d/network" reload >/dev/null 2>&1
  if [ "$DNS_CHANGED" = 1 ]; then
    # stop + start, not restart: its "restart" is a reload that never runs stop_service, and only stop_service
    # gives dnsmasq back the noresolv/server it had (the package takes over all DNS when it is first installed)
    if [ -x "$ETC_DIR/init.d/https-dns-proxy" ]; then
      run "$ETC_DIR/init.d/https-dns-proxy" stop >/dev/null 2>&1
      run "$ETC_DIR/init.d/https-dns-proxy" start >/dev/null 2>&1
    fi
    run "$ETC_DIR/init.d/dnsmasq" restart >/dev/null 2>&1
  fi
  NET_CHANGED=0; DNS_CHANGED=0; FW_CHANGED=0
  return 0
}
pf_reload() { :; }   # uci reads live settings, nothing to re-read

# ---------- scheduler ----------
pf_cron_setup() {
  command -v curl >/dev/null || { pkg_track_begin; pf_pkg_install curl || return 1; pkg_track_end; remember "pkg curl"; }
  [ -e "$CRONTAB" ] || remember "cronfile"
  added=0
  for l in "*/5 * * * * $CRON5/watchdog # switchback" "22 4 * * 0 $CRONW/backup # switchback" \
           "* * * * * for f in $CRON1/*; do [ -x \"\$f\" ] && \"\$f\"; done # switchback"; do
    grep -qxF "$l" "$CRONTAB" 2>/dev/null && continue
    append_line "$CRONTAB" "$l"; added=1
  done
  [ $added = 1 ] && remember "crontab"
  run "$ETC_DIR/init.d/cron" enable >/dev/null 2>&1
  run "$ETC_DIR/init.d/cron" restart >/dev/null 2>&1
  return 0
}
pf_crontab_remove() {
  run sed -i '/# switchback$/d' "$CRONTAB"
  run "$ETC_DIR/init.d/cron" restart >/dev/null 2>&1
}

pf_backup_job() {
cat <<'EOF'
#!/bin/sh
# Weekly backup (switchback): full OpenWrt settings archive, keeps the 8 newest.
B=/etc/switchback/backups-weekly
mkdir -p "$B"; chmod 700 "$B"
d=$(date +%Y-%m-%d)
sysupgrade -b "$B/openwrt-$d.tar.gz" >/dev/null 2>&1
chmod 600 "$B"/* 2>/dev/null
ls -t "$B"/openwrt-*.tar.gz | tail -n +9 | xargs -r rm -f
if [ ! -s "$B/openwrt-$d.tar.gz" ] && [ -f /etc/switchback/bot.conf ]; then
  TOKEN=""; NTFY=""; . /etc/switchback/bot.conf
  # Telegram first; the reserve channel ntfy if Telegram does not answer
  { [ -n "$TOKEN" ] && curl -s -o /dev/null --max-time 20 -w '%{http_code}' "https://api.telegram.org/bot$TOKEN/sendMessage" \
      -d chat_id="$CHAT" --data-urlencode text="[роутер] Не удалось сделать еженедельный бэкап настроек ($d). Проверьте флешку: она могла заполниться или сломаться." | grep -q 200; } ||
    { [ -n "$NTFY" ] && curl -s -o /dev/null --max-time 20 -H "Title: router" -d "Не удалось сделать еженедельный бэкап настроек ($d). Проверьте флешку: она могла заполниться или сломаться." "$NTFY"; }
fi
EOF
}

# ---------- failover: platform part of the installed script (see lib/failover.sh) ----------
# Tunnels = uci interfaces with proto wireguard. Standbys stay down: "auto 0" (not started at boot),
# ifup/ifdown while testing. Routes through a tunnel = uci route sections; moving = new interface.
pf_failover_funcs() {
cat <<'EOF'
fo_load()    { :; }
fo_tunnels() { uci show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)\.proto='wireguard'\$/\1/p"; }
fo_exists()  { [ "$(uci -q get "network.$1.proto")" = wireguard ]; }
fo_routes() {   # NET MASK TUNNEL SECTION
  for s in $(uci show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=route$/\1/p'); do
    i=$(uci -q get "network.$s.interface"); fo_exists "$i" || continue
    m=$(uci -q get "network.$s.netmask") || m=255.255.255.255
    echo "$(uci -q get "network.$s.target") $m $i $s"
  done
}
fo_hs() {       # seconds since the last handshake, 99999 if none
  t=$(wg show "$1" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
  case $t in ''|0|*[!0-9]*) echo 99999 ;; *) echo $(( $(date +%s) - t )) ;; esac
}
fo_desc()    { echo "$1"; }
fo_works() {    # a request bound to that tunnel reaches Telegram (a handshake alone proves nothing)
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 --interface "$1" https://api.telegram.org/)
  [ -n "$c" ] && [ "$c" != "000" ]
}
fo_was_on()  { ifstatus "$1" 2>/dev/null | grep -q '"up": true'; }
fo_up()      { ifup "$1" >/dev/null 2>&1; }
fo_down()    { ifdown "$1" >/dev/null 2>&1; }
fo_move()    { uci set "network.$5.interface=$4"; }
fo_commit() {   # the new one starts at boot, the old one becomes a standby
  uci set "network.$1.auto=0"; uci set "network.$2.auto=1"; uci commit network
  __ROOT__/etc/init.d/network reload >/dev/null 2>&1
}
EOF
}

# ---------- Claude nodes: pins (dnsmasq "address") and QUIC rules (firewall rules) ----------
quic_secs() { uci show firewall 2>/dev/null | sed -n "s/^\(firewall\.[^=]*\)\.dest_ip='\{0,1\}$1'\{0,1\}\$/\1/p"; }
pf_quic_state() {   # on | off | none: a rule rejecting UDP 443 to IP
  st=none
  for s in $(quic_secs "$1"); do
    uci -q get "$s.proto" | grep -qw udp || continue
    [ "$(uci -q get "$s.dest_port")" = 443 ] || continue
    case $(uci -q get "$s.target") in REJECT|DROP) ;; *) continue ;; esac
    if [ "$(uci -q get "$s.enabled")" = 0 ]; then st=off; else echo on; return; fi
  done
  echo $st
}
pf_quic_blocked() {
  s=$(pf_quic_state "$1")
  [ "$s" = off ] && warn "правило QUIC для $1 есть, но выключено: включите его (Network -> Firewall -> Traffic Rules)"
  [ "$s" != none ]
}
pf_quic_block() {   # a firewall rule: lan -> wan, UDP 443 to IP, reject (undo: the uci journal)
  s=firewall.sb_quic_$(echo "$1" | tr . _)
  uci_new_section "$s" rule || return 1
  run uci set "$s.name=switchback: no QUIC to $1" && run uci set "$s.src=lan" && run uci set "$s.dest=wan" &&
  run uci set "$s.family=ipv4" && run uci set "$s.proto=udp" && run uci set "$s.dest_ip=$1" &&
  run uci set "$s.dest_port=443" && run uci set "$s.target=REJECT" || return 1
  FW_CHANGED=1
}
pf_quic_unblock() { :; }   # the uci journal entry removes the rule
pf_acl_unbind()   { :; }
dns_addr()        { uci -q get dhcp.@dnsmasq[0].address | tr ' ' '\n'; }
pf_host_pinned()  { dns_addr | awk -F/ -v d="$1" '$2 == d {print $3; exit}'; }
pf_host_pin() {     # dnsmasq answers IP for DOMAIN (address=/DOMAIN/IP)
  old=$(pf_host_pinned "$1")
  [ -n "$old" ] && { run uci del_list "dhcp.@dnsmasq[0].address=/$1/$old" || return 1; }
  run uci add_list "dhcp.@dnsmasq[0].address=/$1/$2" || return 1
  remember "host $1 ${old:--}"; DNS_CHANGED=1
}
pf_host_restore() {
  for v in $(dns_addr | awk -F/ -v d="$1" '$2 == d'); do run uci del_list "dhcp.@dnsmasq[0].address=$v"; done
  [ "$2" = - ] || run uci add_list "dhcp.@dnsmasq[0].address=/$1/$2"
  DNS_CHANGED=1
}

pf_nodes_funcs() {
cat <<'EOF'
nd_load()    { :; }
nd_pinned()  { uci -q get dhcp.@dnsmasq[0].address | tr ' ' '\n' | awk -F/ -v d="$1" '$2 == d {print $3; exit}'; }
nd_pins()    { uci -q get dhcp.@dnsmasq[0].address | tr ' ' '\n' | awk -F/ 'NF >= 3 {print $2, $3}'; }   # every pin: NAME IP
nd_quic_ok() {   # an enabled rule rejecting UDP 443 to IP
  for s in $(uci show firewall 2>/dev/null | sed -n "s/^\(firewall\.[^=]*\)\.dest_ip='\{0,1\}$1'\{0,1\}\$/\1/p"); do
    uci -q get "$s.proto" | grep -qw udp || continue
    [ "$(uci -q get "$s.dest_port")" = 443 ] || continue
    case $(uci -q get "$s.target") in REJECT|DROP) ;; *) continue ;; esac
    [ "$(uci -q get "$s.enabled")" = 0 ] && continue
    return 0
  done
  return 1
}
nd_pin() {
  o=$(nd_pinned "$1"); [ -n "$o" ] && uci del_list "dhcp.@dnsmasq[0].address=/$1/$o"
  uci add_list "dhcp.@dnsmasq[0].address=/$1/$2"
}
nd_commit()  { uci commit dhcp; __ROOT__/etc/init.d/dnsmasq restart >/dev/null 2>&1; }
EOF
}

# ---------- report: the uci settings worth showing (keys are left out before sanitize too) ----------
pf_report_config() {
  sub "uci: туннели и маршруты"
  uci show network 2>/dev/null | grep -vE 'private_key|preshared_key' |
    grep -E "=route\$|=interface\$|\.(target|netmask|interface|proto|auto|addresses|allowed_ips|route_allowed_ips|endpoint_port|persistent_keepalive|description)=" | sed 's/^/    /'
  sub "uci: DNS (dnsmasq, https-dns-proxy)"
  uci show dhcp 2>/dev/null | grep -E 'dnsmasq\[0\]\.(server|address)=' | sed 's/^/    /'
  uci show https-dns-proxy 2>/dev/null | grep -E '\.(resolver_url|listen_port)=' | sed 's/^/    /'
  sub "uci: межсетевой экран (ускорение, правила switchback)"
  uci show firewall 2>/dev/null | grep -E 'flow_offloading|sb_quic|=zone$|\.network=' | sed 's/^/    /'
}
