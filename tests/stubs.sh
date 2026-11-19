#!/bin/sh
# Stubs shared by both fake routers: curl and nslookup. Usage: sh stubs.sh BINDIR
# State files in $SB_OPT (Keenetic) or $SB_ROOT (OpenWrt):
#   nodes           IPs the DNS proxy returns for claude.com (one per line)
#   node-ms-IP      network time of that node in ms (default 100); node-dead-IP: it does not answer
#   dns-NAME        IPs any other name resolves to (one per line)
#   updates         what the next bot getUpdates returns (used once); tune-best: zapret settings text that
#                   makes YouTube fast (90 KB/s instead of 10)
B=${1:?usage: stubs.sh BINDIR}
cat > "$B/curl" <<'EOF'
#!/bin/sh
D=${SB_OPT:-$SB_ROOT}
echo "curl $*" >> "$D/curl.log"
# -K FILE: DoH questions of the AI reserve (lib/ai.sh), one block per name ("# name NAME", "url = ...", "output = ...").
# The answer (DNS wire format) holds zdns-NAME or else zdns-ip (an IPv4) for Zapret DNS (vpn-ip: nslookup 1.1.1.1;
# through the tunnel); zdns-cname: a CNAME comes first; zdns-down / vpn-down: no answer
zdns_answer() {   # zdns_answer NAME IP (no subshells: Windows test runs start processes slowly)
  an='\000\001'; [ -f "$D/zdns-cname" ] && an='\000\002'
  printf "\000\000\201\200\000\001$an\000\000\000\000"
  _ifs=$IFS; IFS=.; set -- $1; IFS=$_ifs
  for l; do _l=${#l}; printf "\\$((_l / 64 * 100 + _l / 8 % 8 * 10 + _l % 8))%s" "$l"; done
  printf '\000\000\001\000\001'
  [ -f "$D/zdns-cname" ] && printf '\300\014\000\005\000\001\000\000\000\074\000\002\300\014'
  printf '\300\014\000\001\000\001\000\000\000\074\000\004'
  _ifs=$IFS; IFS=.; set -- $ZIP; IFS=$_ifs
  for n; do printf "\\$((n / 64 * 100 + n / 8 % 8 * 10 + n % 8))"; done
}
case " $* " in *" -K "*)
  cfg=""; prev=""; for a; do [ "$prev" = -K ] && cfg=$a; prev=$a; done
  cat "$cfg" >> "$D/curl.log"
  case $(cat "$cfg") in *1.1.1.1*) kind=vpn ;; *) kind=zdns ;; esac
  [ -f "$D/$kind-down" ] && exit 7
  name=""; all=""; [ -f "$D/$kind-ip" ] && read -r all < "$D/$kind-ip"
  while read -r k eq v; do
    case $k in
      '#') [ "$eq" = name ] && name=$v ;;
      output) o=${v#\"}; o=${o%\"}; ZIP=$all
              [ $kind = zdns ] && [ -f "$D/zdns-$name" ] && read -r ZIP < "$D/zdns-$name"
              [ -n "$ZIP" ] && zdns_answer "$name" > "$o" ;;
    esac
  done < "$cfg"
  exit 0 ;;
esac
# tg-down: Telegram does not answer (the VPN is down) — for the reserve channel
case "$*" in *api.telegram.org*) [ -f "$D/tg-down" ] && { printf 000; exit 7; } ;; esac
# net-down: ordinary sites do not open either (the internet is down)
case "$*" in *ya.ru*|*www.google.com*) [ -f "$D/net-down" ] && { printf 000; exit 7; } ;; esac
case "$*" in *getUpdates*offset*)
  if [ -f "$D/updates" ]; then cat "$D/updates"; rm -f "$D/updates"; else echo '{"ok":true,"result":[]}'; fi; exit 0 ;; esac
case "$*" in *getUpdates*) echo '{"ok":true,"result":[{"message":{"chat":{"id":123}}}]}'; exit 0 ;; esac
# a file sent to the bot: getFile names it, the download copies tg-file to the -o target
case "$*" in *getFile*) echo '{"ok":true,"result":{"file_id":"F1","file_path":"documents\/file_1.zip"}}'; exit 0 ;; esac
case "$*" in */file/bot*)
  o=""; prev=""; for a; do [ "$prev" = -o ] && o=$a; prev=$a; done
  [ -n "$o" ] && cp "$D/tg-file" "$o" 2>/dev/null; exit 0 ;; esac
# --doh-url: a reserve DNS service; doh-node holds the node address it gives
case "$*" in *--doh-url*) cat "$D/doh-node" 2>/dev/null; exit 0 ;; esac
ip=""; prev=""
for a; do [ "$prev" = --resolve ] && ip=${a##*:}; prev=$a; done
# a server asked by its address (https://IP/): ip-dead-IP = silent directly; ip-novpn-IP = silent through the tunnel too
case "$*" in *time_appconnect*)
  case "$*" in *time_connect*) ;; *)
    for a; do last=$a; done; ip=${last#https://}; ip=${ip%%/*}
    case "$*" in
      *"--interface ppp0"*) [ -f "$D/ip-dead-$ip" ] && { printf 0.000000; exit 28; } ;;   # directly, past a route (SB_WAN_DEV)
      *--interface*) [ -f "$D/ip-novpn-$ip" ] && { printf 0.000000; exit 28; } ;;
      *)             [ -f "$D/ip-dead-$ip" ] && { printf 0.000000; exit 28; }
                     [ -f "$D/ip-flaky-$ip" ] && { rm -f "$D/ip-flaky-$ip"; printf 0.000000; exit 28; } ;;   # silent once
    esac
    printf 0.300000; exit 0 ;;
  esac ;;
esac
# a YouTube video server: video-dead-IP = silent directly; video-novpn-IP = silent through the tunnel too
case "$*" in *googlevideo.com/generate_204*)
  case "$*" in
    *--interface*) [ -f "$D/video-novpn-$ip" ] && { printf 000; exit 28; } ;;
    *)             [ -f "$D/video-dead-$ip" ] && { printf 000; exit 28; }
                   [ -f "$D/video-flaky-$ip" ] && { rm -f "$D/video-flaky-$ip"; printf 000; exit 28; } ;;   # silent once
  esac
  printf 204; exit 0 ;;
esac
case "$*" in
  *time_connect*)     # node measurement: network time = connect + (first byte - TLS) = ms
    [ -f "$D/node-dead-$ip" ] && { printf '000 0 0 0'; exit 28; }
    ms=$(cat "$D/node-ms-$ip" 2>/dev/null || echo 100)
    awk -v m="$ms" 'BEGIN { printf "200 0.010 0.600 %.3f", 0.600 + m / 1000 - 0.010 }' ;;
  *speed_download*)
    s=10000; b=$(cat "$D/tune-best" 2>/dev/null)
    [ -n "$b" ] && grep -qF -- "$b" "$D/etc/nfqws2/nfqws2.conf" && s=90000
    printf '200 %s.000' "$s" ;;
  *http_code*)        # site-dead-HOST: that site does not open (through the tunnel: site-novpn-HOST)
    for a; do last=$a; done; h=${last#https://}; h=${h%%/*}
    case "$*" in *--interface*)
      [ -f "$D/site-novpn-$h" ] && { printf 000; exit 7; }
      printf 200; exit 0 ;; esac
    [ -f "$D/site-dead-$h" ] && { printf 000; exit 7; }
    [ -f "$D/site-slow-$h" ] && { printf '200 6.500 300000'; exit 0; }
    [ -f "$D/site-cut-$h" ] && { printf '200 1.000 19000'; exit 28; }     # answers, then cut at ~19 KB
    printf 200 ;;
esac
exit 0
EOF
cat > "$B/nslookup" <<'EOF'
#!/bin/sh
D=${SB_OPT:-$SB_ROOT}
echo "nslookup $*" >> "$D/nslookup.log"
# the AI reserve's VPN path asks 1.1.1.1 (lib/ai.sh, ai_ns): vpn-ip is the real address; vpn-down: no answer
if [ "$2" = 1.1.1.1 ] && [ -f "$D/vpn-ip" ]; then
  [ -f "$D/vpn-down" ] || [ -f "$D/vpn-none-$1" ] && exit 0     # vpn-none-NAME: no answer for that name
  printf 'Server:    1.1.1.1\nAddress 1: 1.1.1.1 one.one.one.one\n\nName:      %s\nAddress 1: %s\n' "$1" "$(cat "$D/vpn-ip")"
  exit 0
fi
if [ "$1" = claude.com ] && [ -f "$D/nodes" ]; then
  printf 'Server:    127.0.0.1\nAddress 1: 127.0.0.1 localhost\n\nName:      claude.com\n'
  n=0; while read -r ip; do n=$((n+1)); echo "Address $n: $ip"; done < "$D/nodes"
elif [ -f "$D/dns-$1" ]; then
  printf 'Server:    127.0.0.1\nAddress 1: 127.0.0.1 localhost\n\nName:      %s\n' "$1"
  n=0; while read -r ip; do n=$((n+1)); echo "Address $n: $ip"; done < "$D/dns-$1"
fi
exit 0
EOF
# od as busybox has it on KeeneticOS 3.8.7 (v1.37.0, "Usage: od [-abcdeFfhiloxsv]"): no -A, -t, -N. A full od here
# hid that the AI reserve could not read a single DoH answer on the router (19.11.2026)
REALOD=$(command -v od)
cat > "$B/od" <<'EOF'
#!/bin/sh
for a; do case $a in -A*|-t*|-N*) echo "od: invalid option -- '${a#-}'" >&2; exit 1 ;; esac; done
exec __REALOD__ "$@"
EOF
# hexdump (the router has it): the two formats switchback uses, one byte per line in decimal and hex digits
cat > "$B/hexdump" <<'EOF'
#!/bin/sh
fmt=""; file=""; prev=""
for a; do if [ "$prev" = -e ]; then fmt=$a; else case $a in -*) ;; *) file=$a ;; esac; fi; prev=$a; done
case $fmt in
  *%u*)   __REALOD__ -An -v -tu1 ${file:+"$file"} | tr -s ' ' '\n' | sed '/^$/d' ;;
  *%02x*) __REALOD__ -An -v -tx1 ${file:+"$file"} | tr -d ' \n' ;;
  *) echo "hexdump stub: unknown format $fmt" >&2; exit 1 ;;
esac
EOF
sed -i "s|__REALOD__|$REALOD|" "$B/od" "$B/hexdump"
chmod +x "$B/curl" "$B/nslookup" "$B/od" "$B/hexdump"
