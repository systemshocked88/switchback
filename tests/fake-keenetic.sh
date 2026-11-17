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
  printf '      description: test-%s\n             link: up\n' "$i"
  if [ $alive = yes ]; then printf '        connected: yes\n           last-handshake: 42\n'
  else printf '        connected: no\n           last-handshake: 4294967295\n'; fi ;;
"dns-proxy tls upstream 9.9.9.9 sni bad.example domain claude.ai"|"dns-proxy tls upstream 9.9.9.9 sni bad.example domain openai.com") exit 1 ;;
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
printf 'NFQWS_EXTRA_ARGS="$MODE_AUTO"\nUDP_PORTS=443\n' > "$T/etc/nfqws2/nfqws2.conf"
printf 'instagram.com\n' > "$T/etc/nfqws2/lists/user.list"
printf 'src/gz entware http://bin.entware.net/mipselsf-k3.4\n' > "$T/etc/opkg.conf"
printf '#!/bin/sh\necho "S10cron $*" >> "$SB_OPT/init.log"\n' > "$T/etc/init.d/S10cron"
# curl and nslookup: shared with the fake OpenWrt
sh "$(dirname "$0")/stubs.sh" "$T/bin"
chmod +x "$T/bin/"* "$T/etc/init.d/"*
echo "$T"
