# VLESS through Xray (Keenetic): "install.sh vless set|status|test|off".
# Why (19.11.2026): every WireGuard tunnel of the house is from one provider; a VLESS server from another one is
# a way that is jammed less often. Xray is heavy for a one-core router: idle ~27 MB of memory, ~18 Mbit/s
# through it at 100% CPU (43 Mbit/s directly). So only chosen, light traffic goes there: the AI reserve's
# fifth path (lib/ai.sh, "vless") and, if the owner turns it on per site, Telegram, Instagram, an own site.
#
# How: the link (vless://UUID@HOST:PORT?...) comes in a file or on stdin, never in a command line; it is
# checked and turned into $SB_DIR/xray.json (mode 600: the only place the keys are kept). The link itself is
# not kept, and neither it nor its keys are ever printed or logged (messages name what is wrong, not values).
# Supported: Reality (tcp + xtls-rprx-vision, also grpc/xhttp) and TLS (tcp, ws, grpc, httpupgrade, xhttp).
#   Xray inbounds: dokodemo-door on VLESS_PORT (connections redirected by iptables; sniffing gives Xray the
#   site's name, so the server resolves it) and SOCKS on 127.0.0.1:VLESS_SOCKS (the router's own checks).
#   Its outbound carries SO_MARK VLESS_MARK: its own connections are never redirected into itself.
#   The service: $VLESS_INIT (Entware init script, starts at boot), it adds the rules when Xray runs and takes
#   them out when it stops (a dead Xray must not swallow the traffic).
#   The rules: the netfilter hook $VLESS_HOOK (KeeneticOS rebuilds its firewall often): TCP to the addresses
#   in ipset VLESS_SET -> REDIRECT to VLESS_PORT, in PREROUTING (home devices) and OUTPUT (the router itself).
#   The set is filled from $SB_DIR/vless.ips ("ADDRESS/BITS TAG", TAG: ai:GROUP or site:NAME).
# Journal: "vless" (vless_undo: the service, the hook, the rules, the files, the sites through VLESS).

VLESS_PORT=10808
VLESS_SOCKS=10809
VLESS_MARK=23387          # 0x5b5b: Xray's sockopt.mark (decimal there), iptables "--mark 0x5b5b"
VLESS_MARK_HEX=0x5b5b
VLESS_SET=sb-vless
# The reserve's tests bound to a device leave from these ports and skip the router's OUTPUT redirect: redirected to
# Xray on loopback, a socket bound to nwg2 never connects (21.11.2026: 000 for claude.ai and chatgpt.com, tunnel alive)
VLESS_PROBE_PORTS=61100:61119
VLESS_MAX_IPS=24          # addresses of one own site at most (like SITES_MAX_IPS)

vless_files() {
  VLESS_JSON=$SB_DIR/xray.json; VLESS_CONF=$SB_DIR/vless.conf; VLESS_IPS=$SB_DIR/vless.ips
  VLESS_INIT=$ETC_DIR/init.d/S99switchback-xray; VLESS_PID=$VAR_DIR/run/sb-xray.pid
  XRAY_BIN=${SB_XRAY:-$OPT/sbin/xray}
  vsub_files
}
vless_on() { [ -f "$SB_DIR/xray.json" ]; }
# in tests nothing may reach a real iptables or ipset: only fakes named in SB_IPT / SB_IPSET are called
vless_can_run() { [ "$DRY" != 1 ] && { [ -z "$SB_TEST" ] || [ -n "$SB_IPT" ]; }; }
vless_kind() { sed -n 's/^KIND="\(.*\)"$/\1/p' "$SB_DIR/vless.conf" 2>/dev/null; }

# ---------- the link ----------
# vless_dec VALUE: %XX decoded (C locale: byte by byte)
vless_dec() {
  printf '%s' "$1" | LC_ALL=C awk 'BEGIN { h = "0123456789abcdef" }
    { s = $0; o = ""
      while ((i = index(s, "%")) > 0) {
        o = o substr(s, 1, i - 1); x = tolower(substr(s, i + 1, 2))
        a = index(h, substr(x, 1, 1)); b = index(h, substr(x, 2, 1))
        if (length(x) == 2 && a && b) { o = o sprintf("%c", (a - 1) * 16 + b - 1); s = substr(s, i + 3) }
        else { o = o "%"; s = substr(s, i + 1) }
      }
      printf "%s", o s }'
}
# vless_safe VALUE: nothing that could break out of a JSON string or a shell word (quotes, backslash, spaces...)
vless_safe() { case $1 in *[!A-Za-z0-9._~/?=\&:,@!+*\;%-]*) return 1 ;; esac; return 0; }
vless_hex() { case $1 in *[!0-9a-fA-F]*) return 1 ;; esac; return 0; }

# vless_parse LINK: sets V_ID V_HOST V_PORT V_SEC V_TYPE V_FLOW V_SNI V_FP V_PBK V_SID V_SPX V_PATH V_HHOST V_SVC
# V_MODE V_ALPN V_AUTH, and VLESS_KIND (words for messages). 1 with a message that names the problem, never a value.
vless_parse() {
  V_ID=""; V_HOST=""; V_PORT=""; V_SEC=""; V_TYPE=tcp; V_FLOW=""; V_SNI=""; V_FP=chrome; V_PBK=""; V_SID=""
  V_SPX=""; V_PATH=""; V_HHOST=""; V_SVC=""; V_MODE=""; V_ALPN=""; V_AUTH=""; VLESS_KIND=""
  _l=$1; _l=${_l%%#*}                                   # the name after "#" is not needed
  case $_l in vless://?*) _l=${_l#vless://} ;; *) bad "это не ссылка vless:// (она начинается с vless://)"; return 1 ;; esac
  case $_l in *@*) ;; *) bad "в ссылке нет идентификатора пользователя (UUID@сервер:порт)"; return 1 ;; esac
  V_ID=${_l%%@*}; _r=${_l#*@}; _q=""
  case $_r in *\?*) _q=${_r#*\?}; _r=${_r%%\?*} ;; esac
  _r=${_r%/}
  case $_r in
    \[*\]:*) V_HOST=${_r%%\]*}; V_HOST=${V_HOST#\[}; V_PORT=${_r##*\]:} ;;
    *:*)     V_HOST=${_r%:*}; V_PORT=${_r##*:} ;;
    *)       bad "в ссылке нет порта сервера (сервер:порт)"; return 1 ;;
  esac
  _ifs=$IFS; IFS='&'; set -f; set -- $_q; set +f; IFS=$_ifs
  for _kv; do
    _k=${_kv%%=*}; _v=""; case $_kv in *=*) _v=${_kv#*=} ;; esac
    case $_v in *%*) _v=$(vless_dec "$_v") ;; esac
    case $_k in
      security) V_SEC=$_v ;; type) V_TYPE=$_v ;; flow) V_FLOW=$_v ;; sni|serverName|peer) V_SNI=$_v ;;
      fp|fingerprint) V_FP=$_v ;; pbk|publicKey) V_PBK=$_v ;; sid|shortId) V_SID=$_v ;; spx|spiderX) V_SPX=$_v ;;
      path) V_PATH=$_v ;; host) V_HHOST=$_v ;; serviceName) V_SVC=$_v ;; mode) V_MODE=$_v ;; alpn) V_ALPN=$_v ;;
      authority) V_AUTH=$_v ;;
      encryption) case $_v in ''|none) ;; *) bad "в ссылке шифрование VLESS (encryption), которое не поддерживается: нужно none"; return 1 ;; esac ;;
      headerType) case $_v in ''|none) ;; *) bad "в ссылке маскировка заголовков (headerType), которая не поддерживается"; return 1 ;; esac ;;
    esac
  done
  # who: a UUID, or Xray's short form (up to 30 characters)
  case $V_ID in ''|*[!0-9A-Za-z._-]*) bad "идентификатор пользователя (UUID) в ссылке неверный"; return 1 ;; esac
  [ ${#V_ID} -le 36 ] || { bad "идентификатор пользователя (UUID) в ссылке неверный"; return 1; }
  case $V_HOST in ''|*[!0-9A-Za-z.:-]*|.*|-*) bad "адрес сервера в ссылке неверный"; return 1 ;; esac
  case $V_PORT in ''|*[!0-9]*) bad "порт сервера в ссылке неверный"; return 1 ;; esac
  [ "$V_PORT" -ge 1 ] && [ "$V_PORT" -le 65535 ] || { bad "порт сервера в ссылке неверный"; return 1; }
  for _v in "$V_SEC" "$V_TYPE" "$V_FLOW" "$V_SNI" "$V_FP" "$V_PBK" "$V_SID" "$V_SPX" "$V_PATH" "$V_HHOST" "$V_SVC" "$V_MODE" "$V_ALPN" "$V_AUTH"; do
    vless_safe "$_v" || { bad "в ссылке недопустимые знаки (кавычки, пробелы, обратная косая черта): так её не применить"; return 1; }
  done
  case $V_TYPE in
    tcp|raw) V_TYPE=tcp ;; ws|grpc|httpupgrade) ;; xhttp|splithttp) V_TYPE=xhttp ;;
    *) bad "способ передачи в ссылке (type) не поддерживается: нужны tcp, ws, grpc, httpupgrade или xhttp"; return 1 ;;
  esac
  case $V_SEC in
    reality)
      case $V_TYPE in tcp|grpc|xhttp) ;; *) bad "Reality работает только с type=tcp, grpc или xhttp"; return 1 ;; esac
      [ -n "$V_PBK" ] || { bad "в ссылке нет открытого ключа сервера (pbk): без него Reality не работает"; return 1; }
      case $V_PBK in *[!A-Za-z0-9_-]*) bad "открытый ключ сервера (pbk) в ссылке неверный"; return 1 ;; esac
      [ ${#V_PBK} = 43 ] || { bad "открытый ключ сервера (pbk) в ссылке неверный"; return 1; }
      vless_hex "$V_SID" && [ ${#V_SID} -le 16 ] && [ $(( ${#V_SID} % 2 )) = 0 ] || { bad "shortId (sid) в ссылке неверный: нужно до 16 шестнадцатеричных знаков"; return 1; }
      [ -n "$V_SNI" ] || { bad "в ссылке нет имени сайта для Reality (sni)"; return 1; } ;;
    tls) ;;
    ""|none) bad "ссылка без шифрования (security=none): такая не поддерживается, нужны reality или tls"; return 1 ;;
    *) bad "защита соединения в ссылке (security) не поддерживается: нужны reality или tls"; return 1 ;;
  esac
  case $V_FLOW in
    "") ;;
    xtls-rprx-vision|xtls-rprx-vision-udp443) [ "$V_TYPE" = tcp ] || { bad "flow=xtls-rprx-vision работает только с type=tcp"; return 1; }
                        V_FLOW=xtls-rprx-vision ;;
    *) bad "flow в ссылке не поддерживается: нужен xtls-rprx-vision или никакого"; return 1 ;;
  esac
  case $V_FP in ""|none) V_FP=chrome ;; chrome|firefox|safari|ios|android|edge|360|qq|random|randomized) ;;
    *) bad "отпечаток браузера (fp) в ссылке не поддерживается"; return 1 ;; esac
  for _v in $(echo "$V_ALPN" | tr ',' ' '); do
    case $_v in h2|http/1.1|h3) ;; *) bad "alpn в ссылке не поддерживается: нужны h2, http/1.1 или h3"; return 1 ;; esac
  done
  case $V_TYPE:$V_MODE in
    grpc:|grpc:gun|grpc:multi|xhttp:|xhttp:auto|xhttp:packet-up|xhttp:stream-up|xhttp:stream-one) ;;
    tcp:*|ws:*|httpupgrade:*) V_MODE="" ;;
    *) bad "режим (mode) в ссылке не поддерживается"; return 1 ;;
  esac
  case $V_SEC in reality) VLESS_KIND="Reality" ;; *) VLESS_KIND="TLS" ;; esac
  VLESS_KIND="$VLESS_KIND, $V_TYPE${V_FLOW:+, vision}"
  return 0
}

# vless_outbound TAG: one VLESS outbound of Xray from V_* (every value was checked by vless_parse: vless_safe,
# nothing can break the JSON). Its connections carry SO_MARK VLESS_MARK: never redirected into Xray itself
vless_outbound() {
  case $V_SEC in
    reality) _sec="\"security\":\"reality\",\"realitySettings\":{\"serverName\":\"$V_SNI\",\"fingerprint\":\"$V_FP\",\"publicKey\":\"$V_PBK\",\"shortId\":\"$V_SID\"${V_SPX:+,\"spiderX\":\"$V_SPX\"}}" ;;
    tls)     _a=""; [ -n "$V_ALPN" ] && _a=",\"alpn\":[\"$(echo "$V_ALPN" | sed 's/,/","/g')\"]"
             _sec="\"security\":\"tls\",\"tlsSettings\":{${V_SNI:+\"serverName\":\"$V_SNI\",}\"fingerprint\":\"$V_FP\"$_a}" ;;
  esac
  case $V_TYPE in
    tcp)  _net='"network":"tcp"' ;;
    ws)   _net="\"network\":\"ws\",\"wsSettings\":{\"path\":\"${V_PATH:-/}\"${V_HHOST:+,\"host\":\"$V_HHOST\"}}" ;;
    httpupgrade) _net="\"network\":\"httpupgrade\",\"httpupgradeSettings\":{\"path\":\"${V_PATH:-/}\"${V_HHOST:+,\"host\":\"$V_HHOST\"}}" ;;
    grpc) _m=false; [ "$V_MODE" = multi ] && _m=true
          _net="\"network\":\"grpc\",\"grpcSettings\":{\"serviceName\":\"$V_SVC\"${V_AUTH:+,\"authority\":\"$V_AUTH\"},\"multiMode\":$_m}" ;;
    xhttp) _net="\"network\":\"xhttp\",\"xhttpSettings\":{\"path\":\"${V_PATH:-/}\"${V_HHOST:+,\"host\":\"$V_HHOST\"},\"mode\":\"${V_MODE:-auto}\"}" ;;
  esac
  cat <<EOT
    {"tag": "$1", "protocol": "vless",
     "settings": {"vnext": [{"address": "$V_HOST", "port": $V_PORT,
       "users": [{"id": "$V_ID", "encryption": "none"${V_FLOW:+, \"flow\": \"$V_FLOW\"}}]}]},
     "streamSettings": {$_net, $_sec, "sockopt": {"mark": $VLESS_MARK}}}
EOT
}

# vless_json [PROTOCOL [POOL]]: Xray's settings (PROTOCOL of the redirect inbound: dokodemo-door, or "tunnel", its
# newer name). One outbound from V_*; or, with POOL (lib/vsub.sh: the best keys of a subscription, a link per line in
# its last column), outbounds vless-1..N behind a balancer: leastPing on what the observatory measures every
# VSUB_EVERY, so Xray itself leaves a key that stopped answering (vless-1, the best when checked, if none answers)
vless_json() {
  _in=${1:-dokodemo-door}
  cat <<EOT
{
  "log": {"loglevel": "error", "access": "none", "error": "$VAR_DIR/log/xray.log"},
  "policy": {"levels": {"0": {"handshake": 4, "connIdle": 120, "bufferSize": 16}}},
  "inbounds": [
    {"tag": "redirect", "listen": "0.0.0.0", "port": $VLESS_PORT, "protocol": "$_in",
     "settings": {"network": "tcp", "followRedirect": true},
     "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}},
    {"tag": "check", "listen": "127.0.0.1", "port": $VLESS_SOCKS, "protocol": "socks", "settings": {"udp": false}}
  ],
  "outbounds": [
EOT
  if [ -z "$2" ]; then vless_outbound vless; echo "  ]"; echo "}"; return 0; fi
  _vo=0
  while IFS= read -r _pl; do
    vless_parse "${_pl##*	}" >/dev/null 2>&1 || continue
    _vo=$((_vo+1)); [ $_vo -gt 1 ] && echo "    ,"
    vless_outbound "vless-$_vo"
  done < "$2"
  cat <<EOT
  ],
  "routing": {"domainStrategy": "AsIs",
    "rules": [{"type": "field", "inboundTag": ["redirect", "check"], "balancerTag": "pool"}],
    "balancers": [{"tag": "pool", "selector": ["vless-"], "strategy": {"type": "leastPing"}, "fallbackTag": "vless-1"}]},
  "observatory": {"subjectSelector": ["vless-"], "probeURL": "$VSUB_PROBE", "probeInterval": "$VSUB_EVERY", "enableConcurrency": false}
}
EOT
}

# ---------- the service and the rules ----------
vless_init_script() {
script_subst <<'EOF' | sed -e "s|__XRAY__|$XRAY_BIN|g" -e "s|__HOOK__|$VLESS_HOOK|g"
#!/bin/sh
# switchback: Xray for the VLESS path (lib/vless.sh). start|stop|restart|status|ensure
# Entware starts it at boot. The redirect rules (__HOOK__) follow it: in while Xray runs, out when it stops.
export PATH=__PATH__
CONF=__CONF__/xray.json
PID=__STATE__/run/sb-xray.pid
XRAY=__XRAY__
HOOK=__HOOK__
running() { p=$(cat "$PID" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
start() {
  [ -f "$CONF" ] && [ -x "$XRAY" ] || return 1
  if ! running; then
    mkdir -p "${PID%/*}" __STATE__/log
    : > __STATE__/log/xray.log
    trap '' HUP
    # a small router: Go's collector works harder instead of taking memory (idle ~27 MB, 19.11.2026)
    GOGC=50 GOMEMLIMIT=48MiB "$XRAY" run -c "$CONF" < /dev/null > /dev/null 2>&1 &
    echo $! > "$PID"
    sleep "${SB_XRAY_WAIT:-1}"
  fi
  if running; then [ -x "$HOOK" ] && "$HOOK"; return 0; fi
  [ -x "$HOOK" ] && "$HOOK" off
  return 1
}
stop() {
  [ -x "$HOOK" ] && "$HOOK" off
  p=$(cat "$PID" 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null; rm -f "$PID"
  return 0
}
case $1 in
  start)   start ;;
  stop)    stop ;;
  restart) stop; sleep "${SB_XRAY_WAIT:-1}"; start ;;
  status)  if running; then echo running; else echo stopped; exit 1; fi ;;
  ensure)  running || start ;;          # from the minute jobs: back after a crash
  *)       echo "usage: $0 start|stop|restart|status|ensure"; exit 2 ;;
esac
EOF
}

vless_hook_script() {
script_subst <<'EOF' | sed -e "s|__PORT__|$VLESS_PORT|g" -e "s|__MARK__|$VLESS_MARK_HEX|g" -e "s|__SET__|$VLESS_SET|g" -e "s|__PROBE__|$VLESS_PROBE_PORTS|g"
#!/bin/sh
# switchback: chosen addresses (__CONF__/vless.ips) go to Xray (VLESS): TCP only, REDIRECT to its port, from home
# devices (PREROUTING) and from the router itself (OUTPUT). Xray's own connections carry mark __MARK__ and are
# never redirected into itself. Runs when the router rebuilds its firewall, from the Xray service and from
# the installer; puts back only what is missing. "off" (or Xray not running, or nothing to send): rules out.
[ -z "$table" ] || [ "$table" = nat ] || exit 0
[ -z "$type" ] || [ "$type" = iptables ] || exit 0
[ -n "$SB_TEST" ] && [ -z "$SB_IPT" ] && exit 0      # tests: never a real iptables
export PATH=__PATH__
IPT=${SB_IPT:-iptables}; IPS=${SB_IPSET:-ipset}
L=__CONF__/vless.ips
M="-p tcp -m set --match-set __SET__ dst -m mark ! --mark __MARK__ -j REDIRECT --to-ports __PORT__"
# the router's own connections, except the reserve's tests bound to a device (their source ports). Home devices may
# use any port, so PREROUTING has no such exception
O="-p tcp ! --sport __PROBE__ -m set --match-set __SET__ dst -m mark ! --mark __MARK__ -j REDIRECT --to-ports __PORT__"
p=$(cat __STATE__/run/sb-xray.pid 2>/dev/null)
if [ "$1" = off ] || [ ! -s "$L" ] || [ ! -f __CONF__/xray.json ] || [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; then
  for r in "PREROUTING $M" "OUTPUT $M" "OUTPUT $O"; do
    n=0; while [ $n -lt 5 ] && $IPT -w -t nat -D $r 2>/dev/null; do n=$((n+1)); done
  done
  exit 0
fi
$IPS create __SET__ hash:net -exist || exit 1
# the set as the list says (after a reboot it is empty): filled aside, then swapped in
$IPS create __SET__-new hash:net -exist && $IPS flush __SET__-new &&
  awk '$1 ~ /^[0-9.]+(\/[0-9]+)?$/ { print "add __SET__-new " $1 }' "$L" | $IPS -exist restore &&
  $IPS swap __SET__-new __SET__
$IPS destroy __SET__-new 2>/dev/null
$IPT -w -t nat -C PREROUTING $M 2>/dev/null || $IPT -w -t nat -I PREROUTING $M
$IPT -w -t nat -C OUTPUT $O 2>/dev/null || $IPT -w -t nat -I OUTPUT $O
# the rule of older versions goes after the new one is in: no moment without a redirect
n=0; while [ $n -lt 5 ] && $IPT -w -t nat -D OUTPUT $M 2>/dev/null; do n=$((n+1)); done
exit 0
EOF
}

vless_running() { _vp=$(cat "$VLESS_PID" 2>/dev/null); [ -n "$_vp" ] && kill -0 "$_vp" 2>/dev/null; }   # _vp: ai_apply keeps its path in p
vless_start() { [ "$DRY" = 1 ] && return 0; [ -x "$VLESS_INIT" ] && "$VLESS_INIT" start >/dev/null 2>&1; }
# vless_sync: the set and the rules as vless.ips says (through the hook)
vless_sync() { vless_can_run && [ -x "$VLESS_HOOK" ] && "$VLESS_HOOK" >/dev/null 2>&1; return 0; }

# ---------- the addresses that go to Xray ----------
# vless_cidr NET/MASK|NET/BITS|IP: as ipset wants it (ADDRESS/BITS)
vless_cidr() {
  echo "$@" | tr ' ' '\n' | awk -F/ 'NF {
    if ($2 == "") { print $1 "/32"; next }
    if ($2 ~ /^[0-9]+$/) { print $1 "/" $2; next }
    n = split($2, o, "."); b = 0
    for (i = 1; i <= n; i++) { v = o[i] + 0; while (v > 0) { b += v % 2; v = int(v / 2) } }
    print $1 "/" b }'
}
# vless_ips_set TAG ADDR...: the addresses of TAG are these (the server's own addresses never: a loop)
vless_ips_set() {
  [ "$DRY" = 1 ] && return 0
  _t=$1; shift; _skip=" $(sed -n 's/^SERVER_IPS="\(.*\)"$/\1/p' "$VLESS_CONF" 2>/dev/null) "
  { awk -v t="$_t" '$2 != t' "$VLESS_IPS" 2>/dev/null
    vless_cidr "$@" | while read -r _a; do
      case $_skip in *" ${_a%/32} "*) continue ;; esac
      echo "$_a $_t"
    done; } > "$VLESS_IPS.tmp"
  ( umask 077; mv "$VLESS_IPS.tmp" "$VLESS_IPS" )
}
# vless_ips_add TAG ADDR...: new addresses of TAG added, VLESS_MAX_IPS at most; 0 when something was added
vless_ips_add() {
  [ "$DRY" = 1 ] && return 1
  _t=$1; shift; _n=$(awk -v t="$_t" '$2 == t' "$VLESS_IPS" 2>/dev/null | wc -l); _new=1
  for _a in $(vless_cidr "$@"); do
    [ "$_n" -ge "$VLESS_MAX_IPS" ] && break
    grep -q "^$_a $_t\$" "$VLESS_IPS" 2>/dev/null && continue
    echo "$_a $_t" >> "$VLESS_IPS"; _n=$((_n+1)); _new=0
  done
  return $_new
}
# vless_ips_del TAG: its addresses out; 1 when it had none
vless_ips_del() {
  [ "$DRY" = 1 ] && return 1
  awk -v t="$1" '$2 == t {f=1} END {exit !f}' "$VLESS_IPS" 2>/dev/null || return 1
  awk -v t="$1" '$2 != t' "$VLESS_IPS" > "$VLESS_IPS.tmp"; mv "$VLESS_IPS.tmp" "$VLESS_IPS"
}
vless_ips_count() { awk -v t="$1" '$2 == t' "$VLESS_IPS" 2>/dev/null | wc -l | tr -d ' '; }
# vless_named NAME: the networks of a name the owner can send through VLESS as a whole (apps that connect by
# address, not by name): telegram, instagram (Meta's networks: Instagram, Facebook, WhatsApp)
vless_named() { case $1 in telegram) echo $TG_NETS ;; instagram) echo $META_NETS ;; esac; }
vless_title() { case $1 in telegram) echo Telegram ;; instagram) echo "Instagram (и всё Meta: Facebook, WhatsApp)" ;; *) echo "$1" ;; esac; }
VLESS_CPU="Внимание: всё, что идёт через VLESS, шифрует процессор роутера. На слабом роутере (одно ядро) это около 15–20 Мбит/с при полной загрузке процессора — для Telegram и лёгких сайтов хватит, но видео и ролики будут тормозить, а остальной интернет дома может замедлиться."

# vless_alive NAME: the site answers through Xray's SOCKS port (TLS with its name; any HTTP code = alive)
vless_alive() {
  vless_running || vless_start || return 1
  for _vt in 1 2 3; do   # new connections came and went on 20-21.11.2026: one miss is not a dead path
    _vc=$(curl -s -I -o /dev/null --connect-timeout 6 --max-time 10 -w '%{http_code}' --socks5-hostname "127.0.0.1:$VLESS_SOCKS" "https://$1/" 2>/dev/null)
    [ -n "$_vc" ] && [ "$_vc" != 000 ] && return 0
    [ "$_vt" = 3 ] || [ -n "$SB_T_NAP" ] || sleep 2
  done
  return 1
}

# ---------- commands ----------
# vless_read FILE|-: the first vless:// link in it (the file is not changed); empty when there is none
vless_read() {
  if [ "$1" = - ]; then head -c 65536 | grep -o 'vless://[^[:space:]"<>]*' | head -n 1
  else head -c 65536 "$1" 2>/dev/null | grep -o 'vless://[^[:space:]"<>]*' | head -n 1; fi
}

vless_set() {
  hr "VLESS через Xray"
  [ -n "$VLESS_HOOK" ] || { bad "VLESS пока поддерживается только на Keenetic"; return 1; }
  [ -n "$CONF" ] || { say "Нужно: vless set --conf ФАЙЛ (или --conf - и ссылка на входе)"; return 2; }
  link=$(vless_read "$CONF")
  [ "$SB_ANSWERS_RM" = 1 ] && [ "$CONF" != - ] && rm -f "$CONF"   # the bot's and the program's copy: read, gone
  [ -n "$link" ] || { bad "ссылки vless:// не нашёл"; return 1; }
  vless_parse "$link" || { link=""; return 1; }
  link=""
  ok "ссылка разобрана: VLESS ($VLESS_KIND)"
  # the server's own addresses never go to Xray (a loop): remembered once
  case $V_HOST in *[!0-9.]*) sips=$(site_ips "$V_HOST" | tr '\n' ' ' | sed 's/ $//') ;; *) sips=$V_HOST ;; esac
  vless_activate "$VLESS_KIND" "$sips" || return 1
  # one key by hand: the subscription's keys are no longer used (lib/vsub.sh; its address stays for "vless sub check")
  [ "$DRY" = 1 ] || rm -f "$VSUB_POOL"
  ev vless set "$VLESS_KIND"
  log "vless: set ($VLESS_KIND)"
  return 0
}

# vless_prereq: Xray and ipset installed (asked for once)
vless_prereq() {
  if [ ! -x "$XRAY_BIN" ]; then
    note "Xray не установлен: ставлю пакет xray-core (около 10 МБ на флешке)"
    pf_pkg_install xray-core >/dev/null 2>&1
    [ "$DRY" = 1 ] || [ -x "$XRAY_BIN" ] || { bad "Xray не установился (opkg install xray-core)"; return 1; }
    remember "pkg xray-core"
  fi
  # the redirect rules need ipset (on KeeneticOS also the component "Модули ядра подсистемы Netfilter")
  if ! command -v "${SB_IPSET:-ipset}" >/dev/null 2>&1; then
    pf_pkg_install ipset >/dev/null 2>&1
    if [ "$DRY" = 1 ] || command -v ipset >/dev/null 2>&1; then remember "pkg ipset"
    else warn "нет ipset (opkg install ipset): без него в Xray пойдёт только то, что роутер проверяет сам"; fi
  fi
  return 0
}

# vless_activate KIND SERVER_IPS [POOL]: Xray's settings written (from V_*, or from POOL: lib/vsub.sh) once Xray has
# accepted them, the service and the rules in place, Xray restarted and checked through
# vless_xray_err FILE CONF: the last line Xray printed, the config's path, UUIDs, addresses, names and long tokens masked
vless_xray_err() {
  grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | cut -c1-400 | sed \
    -e "s|$2|CONF|g" \
    -e 's/[0-9a-fA-F]\{8\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{12\}/UUID/g' \
    -e 's/[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/ADDR/g' \
    -e 's/[0-9a-fA-F]\{1,4\}\(:[0-9a-fA-F]\{0,4\}\)\{2,7\}/ADDR/g' \
    -e 's/[A-Za-z0-9-]\{1,\}\(\.[A-Za-z0-9-]\{1,\}\)*\.[A-Za-z][A-Za-z0-9-]\{1,\}/HOST/g' \
    -e 's/[A-Za-z0-9_+=-]\{20,\}/KEY/g'
}
vless_activate() {
  vless_prereq || return 1
  if [ "$DRY" = 1 ]; then dry "записать настройки Xray в $VLESS_JSON (права 600), поставить службу и правила"; return 0; fi
  mkdir -p "$SB_DIR" "$VAR_DIR/log"
  # Xray checks its settings before they are used; Xray 25+ calls dokodemo-door "tunnel": the new name if the old is refused
  t=${VLESS_JSON%.json}.new.json; okp=""   # Xray takes the format from the name: "xray.json.new" was refused (20.11.2026)
  for proto in dokodemo-door tunnel; do
    ( umask 077; vless_json "$proto" "$3" > "$t" )
    "$XRAY_BIN" run -test -c "$t" > "$t.err" 2>&1 && { okp=$proto; break; }
  done
  if [ -z "$okp" ]; then
    # what Xray said (its last line), with keys and addresses masked: into the log and the answer
    _xe=$(vless_xray_err "$t.err" "$t"); _xn=$(grep -c '"protocol": "vless"' "$t" 2>/dev/null); rm -f "$t" "$t.err"
    log "vless: xray -test refused (${3:+pool, }outbounds ${_xn:-0}): ${_xe:-no output}"
    [ -n "$_xe" ] && note "Xray: $_xe"
    if [ -n "$3" ]; then bad "Xray не принял настройки с ключами подписки — рабочие настройки не тронуты"
    else bad "Xray не принял настройки из этой ссылки — проверьте её у того, кто её дал"; fi
    return 1
  fi
  rm -f "$t.err"; chmod 600 "$t"; mv "$t" "$VLESS_JSON"; chmod 600 "$VLESS_JSON"
  ( umask 077; printf '# switchback: VLESS (lib/vless.sh). Links are not kept here; keys: xray.json (and vless.pool, vless.list)\nKIND="%s"\nSERVER_IPS="%s"\n' "$1" "$2" > "$VLESS_CONF" )
  remember "vless"
  tmp=/tmp/switchback.vless.$$
  vless_init_script > "$tmp"; install_file "$VLESS_INIT" "служба Xray (запуск при включении роутера)" "$tmp"
  vless_hook_script > "$tmp"; install_file "$VLESS_HOOK" "правила: выбранные адреса — в Xray" "$tmp"
  [ -f "$VLESS_IPS" ] || ( umask 077; : > "$VLESS_IPS" )
  "$VLESS_INIT" restart >/dev/null 2>&1
  if ! vless_running; then
    warn "Xray не запустился — подробности: $VAR_DIR/log/xray.log"
  elif vless_alive claude.ai; then ok "VLESS работает: claude.ai открывается через него"
  else warn "Xray запущен, но через VLESS сайты не открываются: сервер не отвечает или ссылка устарела"; fi
  ai_on && note "резерв для нейросетей: путь VLESS добавлен последним (после VPN); сразу — кнопка «через VLESS» в /ai"
  self_install
  return 0
}

vless_status() {
  if ! vless_on; then skip "VLESS не настроен (пришлите боту ссылку vless://)"; ev vless off; return 0; fi
  ok "VLESS настроен: $(vless_kind)"
  if vless_running; then
    m=$(awk '/^VmRSS:/ {printf "%d", $2 / 1024}' "/proc/$(cat "$VLESS_PID")/status" 2>/dev/null)
    ok "Xray работает${m:+ (память: $m МБ)}"
  else warn "Xray не запущен"; fi
  vsub_status
  n=0; sos=""; for t in $(awk '{print $2}' "$VLESS_IPS" 2>/dev/null | sort -u); do
    case $t in
      sos:*)  sos=1 ;;
      ai:*)   ok "$(ai_title "${t#ai:}") идёт через VLESS (адресов: $(vless_ips_count "$t"))" ;;
      site:*) ok "$(vless_title "${t#site:}") — через VLESS (адресов: $(vless_ips_count "$t"))"; n=$((n+1)) ;;
    esac
  done
  [ "$n" = 0 ] && skip "свои сайты через VLESS не выбраны (по умолчанию все идут как раньше)"
  [ -n "$sos" ] && warn "все туннели WireGuard мертвы: Telegram, Instagram и сайты через VPN временно идут через VLESS (вернутся сами)"
  ev vless on "$(vless_kind)"
  return 0
}

vless_test() {
  vless_on || { bad "VLESS не настроен"; return 1; }
  if vless_alive claude.ai; then ok "через VLESS открывается claude.ai"; else bad "через VLESS сайты сейчас не открываются"; return 1; fi
}

# ---------- the last path when every WireGuard tunnel is dead: "vless sos on | off [auto|no] | status" ----------
# Why (19.11.2026, the owner's choice): normally only the AI services may use VLESS (their emergency path). When the
# failover finds no working tunnel at all, Telegram, Meta (Instagram) and the own sites that go through VPN go to
# VLESS for a while — the same redirect as own sites through VLESS, under their own tags sos:* — and come back
# by themselves as soon as any tunnel answers (the failover calls "vless sos off auto"). The owner may say no
# (a button): then nothing goes there until a tunnel has answered again ($SB_DIR/vless.sos.no, the failover clears it).
VLESS_SOS_KB='{"inline_keyboard":[[{"text":"Не надо, оставить как есть","callback_data":"vsos no"}]]}'
vless_sos_on() {
  vless_on || { skip "VLESS не настроен"; return 1; }
  [ -f "$SB_DIR/vless.sos.no" ] && { skip "вы отказались: пока туннель WireGuard не оживёт, через VLESS сайты не пускаю"; return 1; }
  [ -f "$SB_DIR/vless.sos" ] && { skip "Telegram, Instagram и сайты уже идут через VLESS"; return 0; }
  [ "$DRY" = 1 ] && { dry "пустить Telegram, Instagram и сайты через VPN временно через VLESS"; return 0; }
  vless_ips_set sos:telegram $TG_NETS
  vless_ips_set sos:instagram $META_NETS
  _sn=0
  for _sd in $(awk '$1 == "vpn" {print $2}' "$SB_DIR/sites" 2>/dev/null); do
    _sa=$(site_ips "$_sd"); [ -n "$_sa" ] || continue
    vless_ips_set "sos:$_sd" $_sa; _sn=$((_sn+1))
  done
  ( umask 077; echo "$(date +%s) $_sn" > "$SB_DIR/vless.sos" )
  vless_running || vless_start
  vless_sync
  ok "все туннели WireGuard мертвы: Telegram, Instagram и свои сайты через VPN ($_sn) временно идут через VLESS"
  vsub_tell "✗ Ни один туннель WireGuard не отвечает. Временно пустил через VLESS Telegram, Instagram и свои сайты через VPN ($_sn). Это последний путь: процессор роутера загружен сильнее, видео может тормозить. Как только любой туннель оживёт — верну всё на него сам и напишу." "$VLESS_SOS_KB"
  log "vless sos: on (telegram, meta, vpn sites: $_sn)"
  return 0
}
vless_sos_off() {
  if [ ! -f "$SB_DIR/vless.sos" ] && [ "$1" != no ]; then skip "Telegram, Instagram и сайты и так не идут через VLESS"; return 0; fi
  [ "$DRY" = 1 ] && { dry "вернуть Telegram, Instagram и сайты с VLESS"; return 0; }
  for _st in $(awk '$2 ~ /^sos:/ {print $2}' "$VLESS_IPS" 2>/dev/null | sort -u); do vless_ips_del "$_st"; done
  vless_sync
  rm -f "$SB_DIR/vless.sos"
  case $1 in
    no)   ( umask 077; date +%s > "$SB_DIR/vless.sos.no" )
          ok "хорошо: Telegram, Instagram и сайты не идут через VLESS; пока туннель WireGuard не оживёт, сам не включу"
          log "vless sos: off (the owner said no)" ;;
    auto) ok "туннель WireGuard снова работает: Telegram, Instagram и сайты вернулись на него"
          vsub_tell "✓ Туннель WireGuard снова работает — Telegram, Instagram и сайты вернулись на него, через VLESS они больше не идут."
          log "vless sos: off (a tunnel works again)" ;;
    *)    ok "Telegram, Instagram и сайты больше не идут через VLESS"; log "vless sos: off" ;;
  esac
  return 0
}

# vless_undo: everything of VLESS goes (journal line "vless"; "vless off")
vless_undo() {
  # by its pid and with the hook's own text: uninstall may have removed the service and the hook already
  if [ "$DRY" != 1 ]; then _vp=$(cat "$VLESS_PID" 2>/dev/null); [ -n "$_vp" ] && kill "$_vp" 2>/dev/null; rm -f "$VLESS_PID"; fi
  if vless_can_run; then
    t=/tmp/switchback.vhook.$$; vless_hook_script > "$t"; sh "$t" off >/dev/null 2>&1; rm -f "$t"
    ${SB_IPSET:-ipset} destroy "$VLESS_SET" 2>/dev/null
  fi
  # own sites through VLESS: out of the list and the journal
  if [ -f "$SB_DIR/sites" ] && [ "$DRY" != 1 ]; then
    awk '$1 != "vless"' "$SB_DIR/sites" > "$SB_DIR/sites.tmp"; mv "$SB_DIR/sites.tmp" "$SB_DIR/sites"
    grep -v '^site vless ' "$STATE" > "$STATE.tmp" 2>/dev/null; mv "$STATE.tmp" "$STATE"
  fi
  run rm -f "$VLESS_JSON" "$VLESS_JSON.new" "${VLESS_JSON%.json}.new.json" "$VLESS_CONF" "$VLESS_IPS" "$VLESS_INIT" "$VLESS_HOOK"     "$VSUB_URL" "$VSUB_LIST" "$VSUB_POOL" "$VSUB_STAT" ${VSUB_JOB:+"$VSUB_JOB"} "$SB_DIR/vless.sos" "$SB_DIR/vless.sos.no"
  ok "VLESS убран: Xray остановлен, его правила и настройки удалены"
  return 0
}

vless_off() {
  hr "VLESS через Xray"
  vless_on || [ -f "$VLESS_INIT" ] || { skip "VLESS не настроен"; return 0; }
  [ "$DRY" = 1 ] && { dry "остановить Xray, убрать правила и настройки"; return 0; }
  # the AI reserve leaves the path first (the best other path that works)
  if ai_on; then
    ai_conf_load
    for g in $AI_GROUPS; do
      [ "$(ai_cur "$g")" = vless ] || continue
      ai_lock || break
      if ai_switch "$g" vless; then ok "$(ai_title "$g"): $(ai_path_title "$AI_NEW")"
      else ai_unpin "$g"; echo none > "$(ai_dir)/cur.$g"; warn "$(ai_title "$g"): другого рабочего пути сейчас нет"; fi
      ai_unlock
    done
    [ "$MODE" = vless ] && { ai_conf_set MODE auto; ai_conf_set UNTIL 0; }
  fi
  vless_undo
  grep -v -e '^vless$' -e "^file $VLESS_INIT\$" -e "^file $VLESS_HOOK\$" -e "^file ${VSUB_JOB:-/-}\$" "$STATE" > "$STATE.tmp" 2>/dev/null; mv "$STATE.tmp" "$STATE"
  ev vless off; log "vless off"
}

do_vless() {
  vless_files
  set -- $SITES_ARGS
  case ${1:-status} in
    set)    : > "$RUN_JOURNAL"; vless_set; r=$?; rm -f "$RUN_JOURNAL"; return $r ;;
    status) vless_status ;;
    test)   vless_test ;;
    off)    vless_off ;;
    sub)    shift; vsub_do "$@" ;;
    check)  vsub_do check ;;
    sos)    case $2 in on) vless_sos_on ;; off) vless_sos_off "$3" ;; *) say "Нужно: vless sos on | off [auto|no]"; return 2 ;; esac ;;
    *)      say "Нужно: vless set --conf ФАЙЛ | status | test | off | sub set --conf ФАЙЛ | sub check | sub status"; return 2 ;;
  esac
}
