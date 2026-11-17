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
  *http_code*)        # site-dead-HOST: that site does not open
    for a; do last=$a; done; h=${last#https://}; h=${h%%/*}
    [ -f "$D/site-dead-$h" ] && { printf 000; exit 7; }
    [ -f "$D/site-cut-$h" ] && { printf '200 1.000 19000'; exit 28; }     # answers, then cut at ~19 KB
    printf 200 ;;
esac
exit 0
EOF
cat > "$B/nslookup" <<'EOF'
#!/bin/sh
D=${SB_OPT:-$SB_ROOT}
if [ "$1" = claude.com ] && [ -f "$D/nodes" ]; then
  printf 'Server:    127.0.0.1\nAddress 1: 127.0.0.1 localhost\n\nName:      claude.com\n'
  n=0; while read -r ip; do n=$((n+1)); echo "Address $n: $ip"; done < "$D/nodes"
elif [ -f "$D/dns-$1" ]; then
  printf 'Server:    127.0.0.1\nAddress 1: 127.0.0.1 localhost\n\nName:      %s\n' "$1"
  n=0; while read -r ip; do n=$((n+1)); echo "Address $n: $ip"; done < "$D/dns-$1"
fi
exit 0
EOF
chmod +x "$B/curl" "$B/nslookup"
