#!/bin/sh
# Build a fake Keenetic /opt in DIR for tests (stubs for ndmc, opkg, curl...). Prints DIR.
T=${1:?usage: fake-keenetic.sh DIR}
rm -rf "$T"; mkdir -p "$T/bin" "$T/etc/init.d" "$T/etc/nfqws2/lists" "$T/var/log"

cat > "$T/bin/ndmc" <<'EOF'
#!/bin/sh
# Fake KeeneticOS CLI. Tunnels: Wireguard0 is up, Wireguard1 is down; a test can flip them with
# files $SB_OPT/wg-alive-NAME / wg-dead-NAME. running-config indents like the real one (4 spaces).
echo "ndmc $*" >> "$SB_OPT/ndmc.log"
case "$2" in
"show version") printf '  release: 3.8.7\n  title: 3.8.7\n' ;;
"show interface Wireguard"*)
  i=${2#show interface }
  alive=no; [ "$i" = Wireguard0 ] && alive=yes
  [ -f "$SB_OPT/wg-alive-$i" ] && alive=yes
  [ -f "$SB_OPT/wg-dead-$i" ] && alive=no
  # wg-revive-NAME: dead until it is switched on ("interface NAME up"), then it answers
  [ -f "$SB_OPT/wg-revive-$i" ] && grep -qx "ndmc -c interface $i up" "$SB_OPT/ndmc.log" && alive=yes
  printf '      description: test-%s\n             link: up\n' "$i"
  if [ $alive = yes ]; then printf '        connected: yes\n           last-handshake: 42\n'
  else printf '        connected: no\n           last-handshake: 4294967295\n'; fi ;;
"dns-proxy tls upstream 9.9.9.9 sni bad.example domain claude.ai"|"dns-proxy tls upstream 9.9.9.9 sni bad.example domain openai.com") exit 1 ;;
# lists tests: a route to 192.0.2.0/24 breaks Telegram (tg-down) until it is removed; 203.0.113.128/25 is refused
"ip route 192.0.2.0 "*) : > "$SB_OPT/tg-down" ;;
"no ip route 192.0.2.0 "*) rm -f "$SB_OPT/tg-down" ;;
"ip route 203.0.113.128 "*) exit 1 ;;
"show running-config") cat <<'RC'
! $$$ Model: Keenetic Test
interface Wireguard0
    description test
    security-level public
    up
!
interface Wireguard1
    description spare
    security-level public
!
ip route 91.108.56.0 255.255.252.0 Wireguard0 auto
ip route 1.1.1.1 Wireguard0 auto
dns-proxy
    tls upstream 1.2.3.4 sni dns.example domain chatgpt.com
!
RC
cat "$SB_OPT/rc.extra" 2>/dev/null
;;
esac
EOF
cat > "$T/bin/opkg" <<'EOF'
#!/bin/sh
echo "opkg $*" >> "$SB_OPT/opkg.log"
case $1 in print-architecture) printf 'arch all 100\narch mipsel-3.4 150\n' ;; esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/ping"
printf '#!/bin/sh\n[ "$1" = nfqws2 ]\n' > "$T/bin/pidof"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/wget"
cat > "$T/etc/init.d/S51nfqws2" <<'EOF'
#!/bin/sh
echo "S51nfqws2 $*" >> "$SB_OPT/init.log"
EOF
printf 'NFQWS_EXTRA_ARGS="$MODE_AUTO"
UDP_PORTS=443
NFQWS_ARGS_QUIC="--filter-udp=443 --filter-l7=quic <HOSTLIST_NOAUTO>
                 --payload=quic_initial --lua-desync=fake:blob=quic_initial:repeats=11"
' > "$T/etc/nfqws2/nfqws2.conf"
printf 'instagram.com\n' > "$T/etc/nfqws2/lists/user.list"
printf 'src/gz entware http://bin.entware.net/mipselsf-k3.4\n' > "$T/etc/opkg.conf"
printf '#!/bin/sh\necho "S10cron $*" >> "$SB_OPT/init.log"\n' > "$T/etc/init.d/S10cron"
# Xray (lib/vless.sh): "run -test -c FILE" accepts unless xray-bad (xray-tunnel: refuses "dokodemo-door" as a newer
# Xray might); "run -c FILE" stays up a while (xray-crash: exits at once). Only paths in its arguments, never keys
mkdir -p "$T/sbin"
cat > "$T/sbin/xray" <<'EOF'
#!/bin/sh
echo "xray $*" >> "$SB_OPT/xray.log"
case "$*" in
  "run -test -c "*) [ -f "$SB_OPT/xray-bad" ] && exit 1
                    # like the real one: the format comes from the name (20.11.2026: "xray.json.new" refused)
                    case $4 in *.json) ;; *) echo "Failed to start: main: failed to load config files: [$4] > core: Failed to get format of $4"; exit 1 ;; esac
                    # xray-refuse-pool: the balancer's settings refused, Xray says why (with an address, a UUID, a key)
                    if [ -f "$SB_OPT/xray-refuse-pool" ] && grep -q '"balancers"' "$4"; then
                      echo "Xray 26.10.29 (Xray, Penetrates Everything.) Custom (go1.25 linux/mipsle)"
                      echo "Failed to start: main: failed to load config files: [$4] > infra/conf: failed to build outbound config with tag vless-3 > address 203.0.113.19 (cdn.example.net) id 1f1e2d3c-4b5a-4987-8a6b-5c4d3e2f1a13 pbk TestPublicKeyOnlyForTests_abcdefghijklmnopq: invalid"
                      echo ""
                      exit 1
                    fi
                    for f in "$SB_OPT"/xray-refuse-*; do [ -f "$f" ] && grep -q "\"address\": \"${f##*xray-refuse-}\"" "$4" && exit 1; done
                    [ -f "$SB_OPT/xray-tunnel" ] && grep -q dokodemo-door "$4" && exit 1
                    # a subscription's check (lib/vsub.sh): which port goes to which server, for the fake curl (in -test:
                    # it runs right before the batch starts, and the batch is not waited for in tests)
                    if grep -q '"tag": "i1"' "$4"; then
                      cp "$4" "$SB_OPT/batch-last.json"; rm -f "$SB_OPT"/vsub-warm-*
                      awk '/"tag": "i[0-9]+"/ { t = $0; sub(/.*"tag": "i/, "", t); sub(/".*/, "", t)
                                                            p = $0; sub(/.*"port": /, "", p); sub(/,.*/, "", p); port[t] = p }
                           /"tag": "k[0-9]+"/ { c = $0; sub(/.*"tag": "k/, "", c); sub(/".*/, "", c) }
                           /"address": / { a = $0; sub(/.*"address": "/, "", a); sub(/".*/, "", a); addr[c] = a }
                           END { for (t in port) print port[t], addr[t] }' "$4" > "$SB_OPT/vsub-map"
                    fi
                    exit 0 ;;
  "run -c "*) [ -f "$SB_OPT/xray-crash" ] && exit 1
              grep -q '"tag": "i1"' "$3" && echo "batch $(grep -c '"tag": "i' "$3")" >> "$SB_OPT/xray.log"
              exec sleep 120 ;;
esac
EOF
chmod +x "$T/sbin/xray"
# curl and nslookup: shared with the fake OpenWrt
sh "$(dirname "$0")/stubs.sh" "$T/bin"
chmod +x "$T/bin/"* "$T/etc/init.d/"*
echo "$T"
