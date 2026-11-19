#!/bin/sh
# Build a fake OpenWrt root for testing switchback on a PC. Prints the root path.
R=${1:?usage: fake-openwrt.sh DIR}
rm -rf "$R"; mkdir -p "$R/bin" "$R/etc/init.d" "$R/etc/crontabs" "$R/etc/opkg" "$R/overlay" "$R/var/log"

cat > "$R/etc/openwrt_release" <<'EOF'
DISTRIB_DESCRIPTION='OpenWrt 24.10.4 (test)'
DISTRIB_TARGET='mediatek/filogic'
EOF
: > "$R/etc/crontabs/root"

# --- uci: settings in a TAB-separated file "key<TAB>value" (one line per list item) ---
cat > "$R/bin/uci" <<'EOF'
#!/bin/sh
DB=$SB_ROOT/uci.db; touch "$DB"
echo "uci $*" >> "$SB_ROOT/uci.log"
[ "$1" = -q ] && shift
cmd=$1; shift
case $cmd in
  get)
    v=$(awk -F'\t' -v k="$1" '$1==k {printf "%s%s", s, $2; s=" "}' "$DB"); [ -n "$v" ] || exit 1; echo "$v" ;;
  set)
    k=${1%%=*}; v=${1#*=}
    case "$k|$v" in *"target|$SB_FAIL_NET") exit 1 ;; esac
    case "$k" in *.target) [ -n "$SB_FAIL_NET" ] && [ "$v" = "$SB_FAIL_NET" ] && exit 1 ;; esac
    awk -F'\t' -v k="$k" '$1!=k' "$DB" > "$DB.t"; mv "$DB.t" "$DB"; printf '%s\t%s\n' "$k" "$v" >> "$DB" ;;
  add_list) k=${1%%=*}; v=${1#*=}; printf '%s\t%s\n' "$k" "$v" >> "$DB" ;;
  del_list) k=${1%%=*}; v=${1#*=}; awk -F'\t' -v k="$k" -v v="$v" '!($1==k && $2==v)' "$DB" > "$DB.t"; mv "$DB.t" "$DB" ;;
  delete)   awk -F'\t' -v k="$1" '$1!=k && index($1, k".")!=1' "$DB" > "$DB.t"; mv "$DB.t" "$DB" ;;
  show)     awk -F'\t' -v c="$1" 'c=="" || index($1, c".")==1 {
              n=split($1, a, "."); if (n==2) print $1"="$2; else print $1"=\x27"$2"\x27" }' "$DB" ;;
  commit|changes) : ;;
esac
EOF

cat > "$R/uci.db.seed" <<'EOF'
network.lan	interface
network.wg0	interface
network.wg0.proto	wireguard
network.@wireguard_wg0[0]	wireguard_wg0
network.@wireguard_wg0[0].allowed_ips	0.0.0.0/0
network.@wireguard_wg0[0].route_allowed_ips	0
network.wg1	interface
network.wg1.proto	wireguard
firewall.@defaults[0]	defaults
firewall.@defaults[0].flow_offloading	1
firewall.@zone[1]	zone
firewall.@zone[1].network	wan
firewall.@zone[1].network	wan6
firewall.@zone[1].network	wg0
dhcp.@dnsmasq[0]	dnsmasq
dhcp.@dnsmasq[0].server	/lan.example/192.168.1.5
https-dns-proxy.config	main
https-dns-proxy.config.dnsmasq_config_update	*
https-dns-proxy.config.force_dns	1
EOF
cp "$R/uci.db.seed" "$R/uci.db"

# --- packages ---
: > "$R/pkgs.db"
# https-dns-proxy's init, like the real one: start with dnsmasq_config_update='*' takes over all DNS of
# dnsmasq (noresolv=1, servers 127.0.0.1#5053/#5054, a backup); only "stop" gives it back. "restart" is a
# reload: it never stops (that is what left the real router's DNS taken over, VM 2026-11-17)
cat > "$R/hdp-init" <<'EOF'
#!/bin/sh
echo "https-dns-proxy $*" >> "$SB_ROOT/svc.log"
DB=$SB_ROOT/uci.db; k=dhcp.@dnsmasq[0]
take() {
  awk -F'\t' '$1=="https-dns-proxy.config.dnsmasq_config_update" {v=$2} END {exit !(v=="*")}' "$DB" || return 0
  grep -q "^$k.doh_backup_noresolv	" "$DB" && return 0
  printf '%s.doh_backup_noresolv\t-1\n%s.noresolv\t1\n%s.server\t127.0.0.1#5053\n%s.server\t127.0.0.1#5054\n' "$k" "$k" "$k" "$k" >> "$DB"
}
give_back() {
  awk -F'\t' -v k="$k" '!($1==k".doh_backup_noresolv" || $1==k".noresolv" || ($1==k".server" && $2 ~ /^127\.0\.0\.1#505[34]$/))' "$DB" > "$DB.t"
  mv "$DB.t" "$DB"
}
case $1 in start) take ;; stop) give_back ;; restart|reload) take ;; esac
exit 0
EOF
cat > "$R/bin/opkg" <<'EOF'
#!/bin/sh
echo "opkg $*" >> "$SB_ROOT/pkg.log"
case $1 in
  print-architecture) printf 'arch all 1\narch aarch64_cortex-a53 10\n' ;;
  list-installed) sed 's/$/ - 1.0/' "$SB_ROOT/pkgs.db" ;;
  install) shift; for p in "$@"; do grep -qx "$p" "$SB_ROOT/pkgs.db" || echo "$p" >> "$SB_ROOT/pkgs.db"
      case $p in
        nfqws2-keenetic) # like the real feed package: it pulls the legacy iptables stack in
          for d in iptables-zz-legacy kmod-ipt-nfqueue; do grep -qx "$d" "$SB_ROOT/pkgs.db" || echo "$d" >> "$SB_ROOT/pkgs.db"; done
          mkdir -p "$SB_ROOT/etc/nfqws2/lists"
          printf 'NFQWS_EXTRA_ARGS="$MODE_AUTO"\nUDP_PORTS=443\n' > "$SB_ROOT/etc/nfqws2/nfqws2.conf"
          : > "$SB_ROOT/etc/nfqws2/lists/user.list"
          printf '#!/bin/sh\necho "nfqws2 $*" >> "$SB_ROOT/svc.log"\n' > "$SB_ROOT/etc/init.d/nfqws2-keenetic"; chmod +x "$SB_ROOT/etc/init.d/nfqws2-keenetic" ;;
        https-dns-proxy) cp "$SB_ROOT/hdp-init" "$SB_ROOT/etc/init.d/https-dns-proxy"; chmod +x "$SB_ROOT/etc/init.d/https-dns-proxy"
          "$SB_ROOT/etc/init.d/https-dns-proxy" start >/dev/null ;;   # postinst starts it with the default config
      esac; done ;;
  remove) # a package another installed one depends on is refused, like the real opkg
    case $2 in iptables-zz-legacy|kmod-ipt-nfqueue) grep -qx nfqws2-keenetic "$SB_ROOT/pkgs.db" && { echo "dependent packages" >&2; exit 255; } ;; esac
    [ "$2" = https-dns-proxy ] && [ -x "$SB_ROOT/etc/init.d/https-dns-proxy" ] && "$SB_ROOT/etc/init.d/https-dns-proxy" stop   # prerm
    grep -vx "$2" "$SB_ROOT/pkgs.db" > "$SB_ROOT/pkgs.t"; mv "$SB_ROOT/pkgs.t" "$SB_ROOT/pkgs.db" ;;
esac
exit 0
EOF
printf '#!/bin/sh\necho "opkg-key $*" >> "$SB_ROOT/pkg.log"\nmkdir -p "$SB_ROOT/etc/opkg/keys"; : > "$SB_ROOT/etc/opkg/keys/96e4a10c3f9d405d"\n' > "$R/bin/opkg-key"
cat > "$R/bin/wget" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = -O ] && { shift; : > "$1"; }; shift; done; exit 0
EOF
cat > "$R/bin/sysupgrade" <<'EOF'
#!/bin/sh
[ "$1" = -b ] && echo "fake backup" > "$2"; exit 0
EOF
printf '#!/bin/sh\n[ "$1" = nfqws2 ] && grep -qx nfqws2-keenetic "$SB_ROOT/pkgs.db"\n' > "$R/bin/pidof"
printf '#!/bin/sh\nexit 0\n' > "$R/bin/ping"
printf '#!/bin/sh\nexit 0\n' > "$R/bin/nslookup"
for s in firewall network dnsmasq cron; do
  printf '#!/bin/sh\necho "%s $*" >> "$SB_ROOT/svc.log"\n' "$s" > "$R/etc/init.d/$s"
done
# WireGuard tunnels: wg show / ifup / ifdown / ifstatus. A tunnel has a fresh handshake if the test
# made $SB_ROOT/wg-alive-NAME; ifup/ifdown mark it up/down ($SB_ROOT/up-NAME).
cat > "$R/bin/wg" <<'EOF'
#!/bin/sh
[ "$1 $3" = "show latest-handshakes" ] || exit 0
if [ -f "$SB_ROOT/wg-alive-$2" ]; then echo "PEERKEY= $(( $(date +%s) - 30 ))"; else echo "PEERKEY= 0"; fi
EOF
printf '#!/bin/sh\necho "ifup $*" >> "$SB_ROOT/svc.log"; touch "$SB_ROOT/up-$1"\n' > "$R/bin/ifup"
printf '#!/bin/sh\necho "ifdown $*" >> "$SB_ROOT/svc.log"; rm -f "$SB_ROOT/up-$1"\n' > "$R/bin/ifdown"
printf '#!/bin/sh\nif [ -f "$SB_ROOT/up-$1" ]; then echo "\\"up\\": true"; else echo "\\"up\\": false"; fi\n' > "$R/bin/ifstatus"
sh "$(dirname "$0")/stubs.sh" "$R/bin"
chmod +x "$R/bin/"* "$R/etc/init.d/"*
echo "$R"
