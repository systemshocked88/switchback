# A VLESS subscription (Keenetic): "install.sh vless sub set --conf FILE|- | check [auto] | status".
# Why (19.11.2026): VLESS is the last emergency path for the AI services (Claude, ChatGPT): their main path is the DNS
# service, the sites stay on WireGuard. One VLESS key dies and that path is gone; a subscription gives hundreds of
# keys (Reality with different SNI), part of them dead. The router checks them itself and keeps the best VSUB_KEEP
# in xray.json, behind Xray's balancer (leastPing on what its observatory measures every VSUB_EVERY): Xray itself
# leaves a key that dies. Whatever uses VLESS (the AI reserve's path "vless") uses the balancer unchanged.
#
# The check, in batches: one temporary Xray per VSUB_BATCH keys (fewer when memory is short), a SOCKS inbound on
# 127.0.0.1 per key routed by inboundTag to that key's outbound. Per key, through curl --socks5-hostname: first a
# warm-up request to VSUB_PROBE with time to spare (VSUB_WARM: alive or not), then by the next requests with the usual
# time limits: the delay to VSUB_PROBE; claude.ai, api.anthropic.com, chatgpt.com (HEAD, any HTTP code but 000);
# api.telegram.org (an extra sign of life, not required). Why the warm-up (20.11.2026, a check on the router: 1 of 518
# alive, by hand 7 of 9): most keys are TLS + grpc or ws, and the first connection through one (TLS on one core)
# takes 3-8 s; the next requests answer in 1-3 s. VSUB_PAR keys at once, Xray and curl at the lowest priority (nice)
# when there is one: MT7628 has one core, at 100% the AI reserve's own minute check failed and the home internet
# with it. A batch Xray refuses
# ("xray run -test") is split in halves down to the key it does not take. The VSUB_TOP fastest are then checked once
# more, one at a time, the first VSUB_SPEED_N of them with a light download (3 MB at most, 20 s at most: a slower
# key's speed is what came by then; the addresses VSUB_SPEED_URLS in turn, the next when one gives nothing: the
# servers block some). Kept: alive, Claude (both names) and ChatGPT open; by delay (50 ms steps), then Telegram
# open, then speed.
#
# Secrets: the subscription's address ($SB_DIR/vless.sub), its keys ($SB_DIR/vless.list: the last list, for a refill
# when the address does not answer; vless.pool: the kept ones; xray.json): files mode 600, work files in a private
# /tmp folder. None of it is printed, logged or sent: only numbers, and the names after "#" (countries) and SNI.
# A day after the last check (at night) the job VSUB_JOB checks the kept keys again; fewer than VSUB_MIN alive: the
# subscription again. Same by hand: "vless sub check" (the bot: «Перепроверить ключи», /vless check).

VSUB_PORT0=10820            # the check's SOCKS inbounds: 127.0.0.1:10821...
VSUB_BATCH=10               # keys per temporary Xray
VSUB_PAR=2                  # keys checked at once
VSUB_WARM=20                # the first request through a key: the whole of it (s); its connect: VSUB_WARM_CONN
VSUB_WARM_CONN=15
VSUB_TOP=10                 # checked again
VSUB_SPEED_N=5              # of them measured for speed
VSUB_KEEP=8                 # kept in the balancer (8 outbounds: ~1 MB more of Xray's memory, see vsub_status)
VSUB_MIN=3                  # fewer alive at a recheck: the subscription again
VSUB_ENOUGH=50              # this many fitting ones found: the rest is not checked (half an hour less)
VSUB_EVERY=3m               # the observatory's probe interval
VSUB_PROBE=https://www.gstatic.com/generate_204
# the speed: the first of these that downloads through the key (20.11.2026: the subscription's servers block
# Cloudflare's, 000 through all 8; OVH: through VLESS yes, straight from the router no). VSUB_SPEED_BYTES at most (a
# range), VSUB_SPEED_T seconds at most: a slow key's download is cut, its speed is what came by then (VSUB_SPEED_MIN at least)
VSUB_SPEED_URLS="https://proof.ovh.net/files/10Mb.dat https://speed.cloudflare.com/__down?bytes=3000000"
VSUB_SPEED_BYTES=3000000
VSUB_SPEED_T=20
VSUB_SPEED_MIN=300000
VT=$(printf '\t')

vsub_files() {
  VSUB_URL=$SB_DIR/vless.sub; VSUB_LIST=$SB_DIR/vless.list; VSUB_POOL=$SB_DIR/vless.pool; VSUB_STAT=$SB_DIR/vless.stat
  VSUB_JOB=""; [ -n "$CRON5" ] && VSUB_JOB=$CRON5/sb-vless-sub
  VSUB_LOCK=$VAR_DIR/run/sb-vsub.lock
}
vsub_stat() { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$VSUB_STAT" 2>/dev/null; }

# ---------- the subscription: fetched, decoded, its VLESS links ----------
# vsub_url_ok URL: an address curl may be given in a config file (nothing that breaks its quoting)
vsub_url_ok() {
  case $1 in http://?*|https://?*) ;; *) return 1 ;; esac
  case $1 in *[!A-Za-z0-9._~:/?#@!\&=%+,\;*-]*) return 1 ;; esac
  return 0
}
# vsub_get URL: into $W/sub.raw, fetched by the router itself — directly, past zapret's ports ($ZCURL), then through Xray if it
# runs. The address goes to curl in a private config file: never in a command line (ps) or a log
vsub_get() {
  ( umask 077; printf 'url = "%s"\noutput = "%s"\n' "$1" "$W/sub.raw" > "$W/curlrc" )
  for _how in direct zapret xray; do
    case $_how in
      direct) set -- ;;
      zapret) [ -n "$ZCURL" ] || continue; set -- $ZCURL ;;
      xray)   vless_running || continue; set -- --socks5-hostname "127.0.0.1:$VLESS_SOCKS" ;;
    esac
    rm -f "$W/sub.raw"
    ( umask 077; curl "$@" -s -f -L --max-redirs 3 --connect-timeout 10 --max-time 90 --max-filesize 8000000 \
        ${VSUB_UA:+-A "$VSUB_UA"} -K "$W/curlrc" ) </dev/null >/dev/null 2>&1
    [ -s "$W/sub.raw" ] && { rm -f "$W/curlrc"; VSUB_HOW=$_how; return 0; }
  done
  rm -f "$W/curlrc" "$W/sub.raw"; return 1
}
# vsub_plain IN OUT: the links, one per line: as they are, or out of base64 (standard or URL-safe, padded or not;
# one blob, wrapped at a fixed width, or a link per line). C locale: byte by byte, no tool beyond awk needed
vsub_plain() {
  # links as they are, or something that is not base64 at all (a page, a client's settings: said so later)
  if grep -q -i -e '://' -e '<html' -e '<!doctype' -e '^proxies:' -e '"outbounds"' "$1"; then tr -d '\r' < "$1" > "$2"; return 0; fi
  # one blob (wrapped or not): base64 -d when the router has it. The awk below took over an hour on a 650 KB
  # subscription (busybox awk, a one-core router), base64 -d 0.4 s (20.11.2026). A link per line: the awk
  # a blob: one line, or every line as long as the first and the last one not longer (a link per line is not one)
  if [ "${VSUB_NO_B64:-0}" != 1 ] && command -v base64 >/dev/null 2>&1 &&
     tr -d ' \t\r' < "$1" | awk 'NF { L[++n] = length($0) }
       END { if (n == 0) exit 1; for (i = 2; i < n; i++) if (L[i] != L[1]) exit 1; exit (n > 1 && L[n] > L[1]) }'; then
    tr -d ' \t\r\n' < "$1" | tr '_-' '/+' |
      awk '{ n = length($0) % 4; if (n == 2) $0 = $0 "=="; else if (n == 3) $0 = $0 "="; print }' |
      base64 -d 2>/dev/null | tr -d '\r' > "$2.b64"
    if grep -q '://' "$2.b64" 2>/dev/null; then mv "$2.b64" "$2"; return 0; fi
    rm -f "$2.b64"
  fi
  LC_ALL=C awk 'BEGIN { b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
                        for (i = 0; i < 64; i++) v[substr(b, i + 1, 1)] = i
                        v["-"] = 62; v["_"] = 63; p[0] = 1; for (i = 1; i < 16; i++) p[i] = p[i - 1] * 2 }
    function feed(s,   i, n, c, x) {
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "=") { acc = 0; bits = 0; continue }
        if (!(c in v)) continue
        acc = acc * 64 + v[c]; bits += 6
        if (bits >= 8) { bits -= 8; x = int(acc / p[bits]); acc -= x * p[bits]; if (x) printf "%c", x }
      }
    }
    { gsub(/[ \t\r]/, ""); if ($0 != "") L[++n] = $0 }
    END {
      # a blob wrapped at a fixed width: every line as long as the first, the last one not longer
      blob = 1; for (i = 2; i < n; i++) if (length(L[i]) != length(L[1])) blob = 0
      if (n > 1 && length(L[n]) > length(L[1])) blob = 0
      for (i = 1; i <= n; i++) { feed(L[i]); if (!blob) { acc = 0; bits = 0; printf "\n" } }
      printf "\n"
    }' "$1" > "$2"
}
# vsub_scan PLAIN: its links by scheme: VLESS ones into $W/vl (scheme in small letters), the counts on stdout:
# "ALL VLESS name=N ..." (the others: vmess, trojan, ss... are counted and skipped)
vsub_scan() {
  awk -v out="$W/vl" '{
      sub(/\r$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
      if ($0 !~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) next
      s = tolower(substr($0, 1, index($0, ":") - 1)); n++; c[s]++
      if (s == "vless") print "vless" substr($0, 6) > out
    }
    END { printf "%d %d", n, c["vless"]; for (k in c) if (k != "vless") printf " %s=%d", k, c[k]; printf "\n" }' "$1"
}
# vsub_keys: $W/vl -> $W/keys ("N<TAB>SNI<TAB>LINK"): broken links out (vless_parse, silent), one per server:port+UUID.
# Sets VS_BROKEN VS_DUP VS_UNIQ
vsub_keys() {
  _p=$PROBLEMS; VS_BROKEN=0; : > "$W/kk"
  while IFS= read -r _ln; do
    if vless_parse "$_ln" >/dev/null 2>&1; then printf '%s:%s:%s\t%s\t%s\n' "$V_HOST" "$V_PORT" "$V_ID" "${V_SNI:--}" "$_ln" >> "$W/kk"
    else VS_BROKEN=$((VS_BROKEN+1)); fi
  done < "$W/vl"
  PROBLEMS=$_p; _ln=""
  _n=$(wc -l < "$W/kk" | tr -d ' ')
  # one per server; in a random order (a list sorted by country must not decide which ones are seen first)
  awk -F'\t' -v OFS='\t' '!s[tolower($1)]++ { print $2, $3 }' "$W/kk" |
    if [ "${VSUB_SHUFFLE:-1}" = 1 ]; then awk -v r="$$" 'BEGIN { srand(); s = srand(); srand(s + r) } { print rand() "\t" $0 }' | sort -k1,1 | cut -f2-
    else cat; fi | awk -v OFS='\t' '{ print NR, $0 }' > "$W/keys"
  rm -f "$W/kk" "$W/vl"
  VS_UNIQ=$(wc -l < "$W/keys" | tr -d ' '); VS_DUP=$((_n - VS_UNIQ))
}
# vsub_label LINK...: on stdin "...<TAB>LINK" lines; out: the same with the name after "#" (decoded) put before the
# link: a country or a server's name. Anything like a UUID or a link goes; a name too long or empty is "-"
vsub_label() {
  LC_ALL=C awk -F'\t' -v OFS='\t' 'BEGIN { h = "0123456789abcdef" }
    { l = $NF; i = index(l, "#"); f = (i ? substr(l, i + 1) : ""); o = ""
      while ((i = index(f, "%")) > 0) {
        o = o substr(f, 1, i - 1); x = tolower(substr(f, i + 1, 2))
        a = index(h, substr(x, 1, 1)); b = index(h, substr(x, 2, 1))
        if (length(x) == 2 && a && b) { c = (a - 1) * 16 + b - 1; if (c >= 32 && c != 127) o = o sprintf("%c", c); f = substr(f, i + 3) }
        else { o = o "%"; f = substr(f, i + 1) }
      }
      f = o f
      gsub(/[\t"\\<>`$|]/, "", f); gsub(/[a-zA-Z0-9]+:\/\/[^ ]*/, "", f)
      gsub(/[0-9a-fA-F]+-[0-9a-fA-F]+-[0-9a-fA-F]+-[0-9a-fA-F]+-[0-9a-fA-F]+/, "", f)
      sub(/^[ _+-]+/, "", f); sub(/[ _+-]+$/, "", f)
      if (f == "" || length(f) > 60) f = "-"
      $NF = f OFS l; print }'
}

# ---------- the check ----------
# vsub_mem: memory free now (MB)
vsub_mem() { awk '/^MemAvailable:/ {a=$2} /^MemFree:/ {f=$2} END {if (!a) a=f; printf "%d", a/1024}' "${SB_MEMINFO:-/proc/meminfo}" 2>/dev/null; }
# vsub_size: keys per temporary Xray, by free memory (the service's Xray ~27 MB runs too); 0: not now
vsub_size() {
  _m=$(vsub_mem); [ -n "$_m" ] || _m=100
  if [ "$_m" -ge 50 ]; then echo "$VSUB_BATCH"; elif [ "$_m" -ge 32 ]; then echo $((VSUB_BATCH / 2)); else echo 0; fi
}
# vsub_conf LIST FROM TO OUT: a temporary Xray: keys FROM..TO of LIST, one SOCKS inbound each; the map "PORT N" in OUT.map
vsub_conf() {
  sed -n "$2,$3p" "$1" > "$4.list"; _bk=0
  : > "$4.in"; : > "$4.out"; : > "$4.rt"; : > "$4.map"
  while IFS="$VT" read -r _n _sni _l; do
    vless_parse "$_l" >/dev/null 2>&1 || continue
    _bk=$((_bk+1)); _pt=$((VSUB_PORT0 + _bk)); _c=","; [ $_bk = 1 ] && _c=" "
    echo "   $_c{\"tag\": \"i$_bk\", \"listen\": \"127.0.0.1\", \"port\": $_pt, \"protocol\": \"socks\", \"settings\": {\"udp\": false}}" >> "$4.in"
    [ $_bk = 1 ] || echo "    ," >> "$4.out"
    vless_outbound "k$_bk" >> "$4.out"
    echo "   $_c{\"type\": \"field\", \"inboundTag\": [\"i$_bk\"], \"outboundTag\": \"k$_bk\"}" >> "$4.rt"
    echo "$_pt $_n" >> "$4.map"
  done < "$4.list"
  _l=""
  { echo '{"log": {"loglevel": "none", "access": "none"},'
    echo ' "policy": {"levels": {"0": {"handshake": 5, "connIdle": 30, "bufferSize": 16}}},'
    echo ' "inbounds": ['; cat "$4.in"; echo ' ],'
    echo ' "outbounds": ['; cat "$4.out"; echo ' ],'
    echo ' "routing": {"rules": ['; cat "$4.rt"; echo ' ]}}'; } > "$4"
  rm -f "$4.list" "$4.in" "$4.out" "$4.rt"
  [ $_bk -gt 0 ]
}
# vsub_nice: VSUB_NICE, the prefix that runs the check's Xray and curl at the lowest priority ("" without a working nice)
vsub_nice() {
  VSUB_NICE=""
  command -v nice >/dev/null 2>&1 && nice -n 19 true >/dev/null 2>&1 && VSUB_NICE="nice -n 19"
  VSUB_NICED=1
}
# vsub_curl PORT URL CONNECT SECONDS [CURL ARGS]: "CODE SECONDS BYTES" through one key
vsub_curl() {
  _p=$1; _u=$2; _ct=$3; _t=$4; shift 4
  $VSUB_NICE curl -s -o /dev/null "$@" --connect-timeout "$_ct" --max-time "$_t" -w '%{http_code} %{time_total} %{size_download}' \
    --socks5-hostname "127.0.0.1:$_p" "$_u" </dev/null 2>/dev/null
}
# vsub_open PORT URL: it answers through this key (HEAD; any HTTP code but 000)
vsub_open() { case $(vsub_curl "$1" "$2" 6 12 -I) in ''|000*) return 1 ;; esac; return 0; }
# vsub_probe PORT N [speed]: one key: "N MS CLAUDE CHATGPT TELEGRAM MBITS" appended to $W/res (MS 0: dead; CLAUDE 1:
# claude.ai and api.anthropic.com both). The first request opens the key's connection (slow: TLS, grpc): it says only
# alive or not; the delay is the next one's (the first one's when the next one fails: alive, but slow)
vsub_probe() {
  set -- "$1" "$2" "$3" $(vsub_curl "$1" "$VSUB_PROBE" "$VSUB_WARM_CONN" "$VSUB_WARM")
  case $4 in ''|000) echo "$2 0 0 0 0 0" >> "$W/res"; return 0 ;; esac
  _wt=$5
  set -- "$1" "$2" "$3" $(vsub_curl "$1" "$VSUB_PROBE" 6 8)
  case $4 in ''|000) set -- "$1" "$2" "$3" 204 "$_wt" ;; esac
  _ms=$(awk -v t="$5" 'BEGIN { m = int(t * 1000 + 0.5); if (m < 1) m = 1; print m }')
  _c=0; vsub_open "$1" https://claude.ai/ && vsub_open "$1" https://api.anthropic.com/ && _c=1
  _gp=0; vsub_open "$1" https://chatgpt.com/ && _gp=1
  _tg=0; vsub_open "$1" https://api.telegram.org/ && _tg=1
  _s=0
  if [ "$3" = speed ]; then
    # the first address of VSUB_SPEED_URLS that gives VSUB_SPEED_MIN bytes; cut by the time limit: what came by then
    for _su in $VSUB_SPEED_URLS; do
      set -- "$1" "$2" "$3" $(vsub_curl "$1" "$_su" 6 "$VSUB_SPEED_T" -r "0-$((VSUB_SPEED_BYTES-1))")
      _s=$(awk -v t="$5" -v b="$6" -v m="$VSUB_SPEED_MIN" 'BEGIN { if (b + 0 >= m + 0 && t + 0 > 0) printf "%.1f", b * 8 / t / 1000000; else print 0 }')
      [ "$_s" = 0 ] || break
    done
  fi
  echo "$2 $_ms $_c $_gp $_tg $_s" >> "$W/res"
}
# vsub_try LIST FROM TO [speed]: keys FROM..TO through one temporary Xray; 1 when Xray does not take that config
vsub_try() {
  _f=$W/batch.json
  [ "$VSUB_NICED" = 1 ] || vsub_nice
  vsub_conf "$1" "$2" "$3" "$_f" || return 0
  "$XRAY_BIN" run -test -c "$_f" >/dev/null 2>&1 || { rm -f "$_f"; return 1; }
  GOGC=50 GOMEMLIMIT=32MiB $VSUB_NICE "$XRAY_BIN" run -c "$_f" </dev/null >/dev/null 2>&1 &
  _xp=$!
  # it listens once its config is read (a few seconds on a one-core router)
  _last=$(tail -n 1 "$_f.map" | cut -d' ' -f1); _w=0
  while [ "$_w" -lt "${SB_XRAY_WAIT:-8}" ]; do
    kill -0 "$_xp" 2>/dev/null || break
    if command -v netstat >/dev/null 2>&1; then netstat -ltn 2>/dev/null | grep -q "127.0.0.1:$_last " && break
    elif [ "$_w" -ge 3 ]; then break; fi
    sleep 1; _w=$((_w+1))
  done
  if ! kill -0 "$_xp" 2>/dev/null; then rm -f "$_f" "$_f.map"; return 1; fi
  if [ "$4" = speed ]; then
    # one at a time (a download takes the whole processor); the first VSUB_SPEED_N (the fastest) with a download
    _sn=0
    while read -r _pt _n; do
      _sn=$((_sn+1)); if [ "$_sn" -le "$VSUB_SPEED_N" ]; then vsub_probe "$_pt" "$_n" speed; else vsub_probe "$_pt" "$_n"; fi
    done < "$_f.map"
  else
    _pids=""; _par=0
    while read -r _pt _n; do
      vsub_probe "$_pt" "$_n" & _pids="$_pids $!"; _par=$((_par+1))
      [ $((_par % VSUB_PAR)) = 0 ] && { wait $_pids; _pids=""; }
    done < "$_f.map"
    [ -n "$_pids" ] && wait $_pids
  fi
  kill "$_xp" 2>/dev/null; wait "$_xp" 2>/dev/null
  rm -f "$_f" "$_f.map"
  return 0
}
# vsub_part LIST FROM TO [speed]: as vsub_try; a batch Xray refuses is split in halves, a single key it refuses
# counts in VS_REFUSED
vsub_part() {
  [ "$2" -le "$3" ] || return 0
  vsub_try "$@" && return 0
  if [ "$2" = "$3" ]; then VS_REFUSED=$((VS_REFUSED+1)); return 0; fi
  vsub_part "$1" "$2" $((($2 + $3) / 2)) "$4"
  vsub_part "$1" $((($2 + $3) / 2 + 1)) "$3" "$4"
}
vsub_fit() { awk '$2 > 0 && $3 == 1 && $4 == 1' "$W/res" 2>/dev/null | wc -l | tr -d ' '; }   # Claude and ChatGPT open

# vsub_run: every key of $W/keys checked (batch by batch, VSUB_ENOUGH fitting ones are enough), the VSUB_TOP best
# checked again (VSUB_SPEED_N of them for speed), the best VSUB_KEEP into $W/pool ("MS<TAB>MBITS<TAB>SNI<TAB>NAME<TAB>LINK"). Sets VS_* counts
vsub_run() {
  VS_REFUSED=0; VS_CHECKED=0; VS_LOWMEM=0; : > "$W/res"
  _tot=$(wc -l < "$W/keys" | tr -d ' '); _i=1
  while [ "$_i" -le "$_tot" ]; do
    _b=$(vsub_size)
    if [ "$_b" = 0 ]; then VS_LOWMEM=1; warn "мало свободной памяти ($(vsub_mem) МБ): дальше не проверяю, чтобы роутер не завис"; break; fi
    _j=$((_i + _b - 1)); [ "$_j" -gt "$_tot" ] && _j=$_tot
    vsub_part "$W/keys" "$_i" "$_j"
    VS_CHECKED=$_j; _i=$((_j + 1))
    _g=$(vsub_fit)
    say "  …проверено $VS_CHECKED из $_tot, подходят $_g"
    [ "$_g" -ge "$VSUB_ENOUGH" ] && break
  done
  VS_ALIVE=$(awk '$2 > 0' "$W/res" | wc -l | tr -d ' ')
  VS_CLAUDE=$(awk '$2 > 0 && $3 == 1' "$W/res" | wc -l | tr -d ' ')
  VS_GPT=$(awk '$2 > 0 && $4 == 1' "$W/res" | wc -l | tr -d ' ')
  VS_TG=$(awk '$2 > 0 && $5 == 1' "$W/res" | wc -l | tr -d ' ')
  VS_FIT=$(vsub_fit)
  # the fastest fitting ones, fastest first; when fewer than VSUB_MIN, keys that open Claude without ChatGPT too
  { awk '$2 > 0 && $3 == 1 && $4 == 1 { print $2, $1 }' "$W/res" | sort -n | head -n "$VSUB_TOP"
    [ "$VS_FIT" -lt "$VSUB_MIN" ] && awk '$2 > 0 && $3 == 1 && $4 == 0 { print $2, $1 }' "$W/res" | sort -n | head -n $((VSUB_MIN - VS_FIT))
  } | awk 'FILENAME == ARGV[1] { k[$1] = $0; next } ($2 in k) { print k[$2] }' "$W/keys" - > "$W/top"
  mv "$W/res" "$W/res.scan"; : > "$W/res"
  if [ -s "$W/top" ]; then
    say "  Самые быстрые ($(wc -l < "$W/top" | tr -d ' ')): ещё раз по одному, у $VSUB_SPEED_N лучших — скорость (скачивание 3 МБ)"
    vsub_part "$W/top" 1 "$(wc -l < "$W/top" | tr -d ' ')" speed
  fi
  # kept: alive at the second check too, Claude open; ChatGPT too first (others only to make VSUB_MIN); then by delay
  # in 50 ms steps, Telegram open, speed. MS: the smaller of the two checks. "GROUP STEP NOTG -SPEED MS N MBITS"
  awk 'FILENAME == ARGV[1] { s[$1] = $2; next }
       $2 > 0 && $3 == 1 { m = $2; if (s[$1] > 0 && s[$1] < m) m = s[$1]
                           printf "%d %d %d %d %d %s %s\n", ($4 == 1) ? 0 : 1, int(m / 50), ($5 == 1) ? 0 : 1, -int($6 * 10), m, $1, $6 }' \
    "$W/res.scan" "$W/res" | sort -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n > "$W/ranked"
  _n=$(awk '$1 == 0' "$W/ranked" | wc -l | tr -d ' ')
  if [ "$_n" -ge "$VSUB_MIN" ]; then awk '$1 == 0' "$W/ranked" | head -n "$VSUB_KEEP"; else head -n "$VSUB_MIN" "$W/ranked"; fi |
    awk '{ print $6, $5, $7 }' > "$W/best"
  # "MS MBITS SNI NAME LINK", in the order chosen
  awk -F'\t' -v OFS='\t' 'FILENAME == ARGV[1] { split($0, a, " "); ord[a[1]] = FNR; ms[a[1]] = a[2]; sp[a[1]] = a[3]; next }
    ($1 in ord) { print ord[$1], ms[$1], sp[$1], $2, $3 }' "$W/best" "$W/top" | sort -n | cut -f2- | vsub_label > "$W/pool"
  VS_KEPT=$(wc -l < "$W/pool" | tr -d ' ')
}

# vsub_apply KIND: $W/pool -> $VSUB_POOL and xray.json (balancer + observatory); the servers' addresses are never
# redirected into Xray (a loop)
vsub_apply() {
  _sips=""; _pn=0
  while IFS= read -r _pl; do
    vless_parse "${_pl##*$VT}" >/dev/null 2>&1 || continue
    _pn=$((_pn+1))
    case $V_HOST in *[!0-9.]*) _sips="$_sips $(site_ips "$V_HOST" | tr '\n' ' ')" ;; *) _sips="$_sips $V_HOST" ;; esac
  done < "$W/pool"
  if [ "$_pn" = 0 ]; then
    # 20.11.2026, on the router: 55 fitting keys and still nothing to give Xray. Not Xray's fault: the list of the
    # best broke on its way (the joins and names in awk). Its shape goes to the log (counts only, never a key)
    bad "не собрал список лучших ключей (внутренняя ошибка проверки) — рабочие настройки не тронуты; подробности в журнале"
    log "vless sub: the pool has no key to parse: $(vsub_shape "$W/pool")"
    return 1
  fi
  _sips=$(echo $_sips | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')
  vless_activate "подписка, ключей: $VS_KEPT (балансировщик)" "$_sips" "$W/pool" || return 1
  ( umask 077; cp "$W/pool" "$VSUB_POOL.new" ) && mv "$VSUB_POOL.new" "$VSUB_POOL"
}
# vsub_shape FILE: what a pool file looks like, without a key: "lines N, fields F1/F2/..., vless:// last L"
vsub_shape() {
  awk -F'\t' '{ n++; f = f (n > 1 ? "/" : "") NF; if ($NF ~ /^vless:\/\//) v++ }
    END { printf "lines %d, fields %s, vless:// last %d", n, (n ? f : "-"), v }' "$1" 2>/dev/null || echo "unreadable"
}
# vsub_show: the kept keys: names, SNI, delay and speed (no address, no key)
vsub_show() {
  awk -F'\t' '{ s = ($2 + 0 > 0) ? ", " $2 " Мбит/с" : ""; n = ($4 == "-") ? "без имени" : $4
                printf "     %d. %s (%s) — %s мс%s\n", NR, n, $3, $1, s }' "$1"
}
vsub_best() { cut -f1 "$1" 2>/dev/null | sort -n | head -n 1; }   # the smallest delay of a pool file
vsub_took() { _s=$(( $(date +%s) - $1 )); if [ "$_s" -ge 60 ]; then echo "$((_s / 60)) мин $((_s % 60)) с"; else echo "$_s с"; fi; }
vsub_save_stat() {   # vsub_save_stat KEY=VALUE...: the non-secret state for status and the daily job
  ( umask 077
    for _kv; do echo "${_kv%%=*}=\"${_kv#*=}\""; done
    grep -v -e '^#' $(for _kv; do printf -- '-e ^%s= ' "${_kv%%=*}"; done) "$VSUB_STAT" 2>/dev/null
  ) > "$VSUB_STAT.new"
  { echo "# switchback: VLESS subscription, the last check (lib/vsub.sh). Numbers only"; cat "$VSUB_STAT.new"; } > "$VSUB_STAT"
  rm -f "$VSUB_STAT.new"; chmod 600 "$VSUB_STAT"
}
vsub_lock() {
  mkdir -p "${VSUB_LOCK%/*}"
  if ! mkdir "$VSUB_LOCK" 2>/dev/null; then
    _t=$(cat "$VSUB_LOCK/t" 2>/dev/null || echo 0)
    [ $(( $(date +%s) - _t )) -gt 10800 ] || return 1        # left by a run a reboot cut short
    rm -rf "$VSUB_LOCK"; mkdir "$VSUB_LOCK" || return 1
  fi
  date +%s > "$VSUB_LOCK/t"
}
vsub_work() {   # a private work folder; with the lock, gone at the end however it ends
  W=${SB_TMP:-/tmp}/switchback-vsub.$$; rm -rf "$W"; mkdir -p "$W"; chmod 700 "$W"
  trap 'rm -rf "$W" "$VSUB_LOCK"' EXIT; trap 'exit 1' INT TERM HUP
}
vsub_tell() {   # vsub_tell TEXT [BUTTONS]: a message to the owner (from the jobs; by hand the output is the answer)
  [ "$DRY" = 1 ] || [ ! -f "$BOT" ] && return 0
  ( TOKEN=""; CHAT=""; NTFY=""; . "$BOT"
    [ -n "$TOKEN" ] && curl -s -o /dev/null --max-time 20 "https://api.telegram.org/bot$TOKEN/sendMessage" \
      -d chat_id="$CHAT" --data-urlencode text="[роутер] $1" ${2:+--data-urlencode reply_markup="$2"}
  ) </dev/null >/dev/null 2>&1
  return 0
}

# vsub_load: the subscription's list into $W/keys: fetched again (its address saved), else the last list kept. 1: none
vsub_load() {
  : > "$W/sub.txt"; VSUB_HOW=""
  if [ -s "$VSUB_URL" ]; then
    _u=$(head -n 1 "$VSUB_URL")
    vsub_get "$_u" && vsub_plain "$W/sub.raw" "$W/sub.txt"
    # some servers send a page or a client's settings to an unknown client: asked once more as an Xray client
    if ! grep -q '://' "$W/sub.txt" 2>/dev/null; then
      VSUB_UA=v2rayNG/1.8.5; vsub_get "$_u" && vsub_plain "$W/sub.raw" "$W/sub.txt"; VSUB_UA=""
    fi
    rm -f "$W/sub.raw"
    _u=""
    [ -s "$W/sub.txt" ] || warn "подписка сейчас не скачивается"
  fi
  if [ ! -s "$W/sub.txt" ] && [ -s "$VSUB_LIST" ]; then note "беру список ключей, сохранённый при прошлой проверке"; cp "$VSUB_LIST" "$W/sub.txt"; fi
  [ -s "$W/sub.txt" ]
}

# vsub_pass: the whole subscription checked, the best kept and applied; the summary in the style of wg-batch
vsub_pass() {
  _t0=$(date +%s)
  set -- $(vsub_scan "$W/sub.txt"); _all=${1:-0}; _vl=${2:-0}; shift 2; _oth=$((_all - _vl))
  _what=$(echo "$*" | awk '{ for (i = 1; i <= NF; i++) { split($i, a, "="); printf "%s%s %s", (i > 1) ? ", " : "", a[1], a[2] } }')
  if [ "$_all" = 0 ]; then
    if grep -qi -e '<html' -e '<!doctype' "$W/sub.txt"; then bad "вместо подписки пришла веб-страница: нужна ссылка для клиентов Xray / v2rayN"
    elif grep -q -e '^proxies:' -e '"outbounds"' "$W/sub.txt"; then bad "подписка пришла настройками программы (Clash или Xray), а не списком ссылок: нужна ссылка для v2rayN"
    else bad "в подписке не нашёл ссылок (ни простым текстом, ни в base64)"; fi
    return 1
  fi
  ok "в подписке ссылок: $_all — VLESS $_vl${_what:+, других $_oth ($_what): пропущены, нужен VLESS}"
  [ "$_vl" -gt 0 ] || { bad "ключей VLESS в подписке нет"; return 1; }
  vsub_keys
  ok "разных ключей VLESS: $VS_UNIQ (повторы $VS_DUP, не разобрать $VS_BROKEN)"
  [ "$VS_UNIQ" -gt 0 ] || { bad "ни одной годной ссылки VLESS"; return 1; }
  ( umask 077; cut -f3 "$W/keys" > "$VSUB_LIST.new" ) && mv "$VSUB_LIST.new" "$VSUB_LIST"   # for a refill without the address
  if [ "$DRY" = 1 ]; then dry "проверить ключи ($VS_UNIQ) и оставить лучшие $VSUB_KEEP в Xray"; return 0; fi
  # ~1-3.5 s a key (a dead one waits 8 s, three at once), 5-8 s a batch (Xray checks and starts its config)
  say "  Проверяю пачками до $VSUB_BATCH ключей, по $VSUB_PAR сразу (интернет дома не ляжет): обычно до $(( (VS_UNIQ * 6 + (VS_UNIQ / VSUB_BATCH + 1) * 8) / 60 + 1 )) мин, раньше — если быстро наберётся $VSUB_ENOUGH подходящих"
  ev vless_sub start "$VS_UNIQ"
  vsub_run
  _took=$(vsub_took "$_t0")
  say ""
  _ap=0; [ "$VS_KEPT" -gt 0 ] && { vsub_apply && _ap=1 || { VS_KEPT=0; [ -s "$VSUB_POOL" ] && note "прежние ключи оставлены"; }; }
  if [ "$_ap" = 1 ]; then
    ok "оставлены лучшие $VS_KEPT — в Xray за балансировщиком: если ключ умрёт, Xray сам перейдёт на живой (проверка каждые 3 мин)"
    vsub_show "$VSUB_POOL"
    [ "$VS_FIT" -lt "$VSUB_MIN" ] && note "подходящих (Claude и ChatGPT) меньше $VSUB_MIN: взяты и ключи, через которые открывается только Claude"
    vsub_job_install
  elif [ ! -s "$W/pool" ]; then
    bad "подходящих ключей нет: ни через один не открылся Claude"; [ -s "$VSUB_POOL" ] && note "прежние ключи оставлены"
  fi
  _best=$(vsub_best "$W/pool")
  vsub_save_stat LAST="$(date +%s)" WHEN="$(date '+%d.%m %H:%M')" TOOK="$_took" LINKS="$_all" UNIQ="$VS_UNIQ" CHECKED="$VS_CHECKED" \
    ALIVE="$VS_ALIVE" FIT="$VS_FIT" KEPT="$VS_KEPT" BEST="$_best"
  say "Итог: проверено $VS_CHECKED из $VS_UNIQ за $_took — живые $VS_ALIVE, Claude открывается через $VS_CLAUDE, ChatGPT через $VS_GPT, Telegram через $VS_TG, подходят $VS_FIT; Xray не принял $VS_REFUSED; оставлено $VS_KEPT${_best:+, лучшая задержка $_best мс}."
  [ "$VS_CHECKED" -lt "$VS_UNIQ" ] && [ "$VS_LOWMEM" = 0 ] && note "остальные $((VS_UNIQ - VS_CHECKED)) не проверял: уже набрано $VSUB_ENOUGH подходящих"
  ev vless_sub done "$VS_UNIQ" "$VS_CHECKED" "$VS_ALIVE" "$VS_FIT" "$VS_KEPT" "$(( $(date +%s) - _t0 ))"
  log "vless sub: links $_all, vless $_vl, unique $VS_UNIQ (dup $VS_DUP, broken $VS_BROKEN), checked $VS_CHECKED in $_took: alive $VS_ALIVE, claude $VS_CLAUDE, chatgpt $VS_GPT, telegram $VS_TG, fit $VS_FIT, refused $VS_REFUSED, kept $VS_KEPT"
  [ "$VS_KEPT" -gt 0 ]
}

# ---------- commands ----------
vsub_set() {
  hr "VLESS: подписка"
  [ -n "$VLESS_HOOK" ] || { bad "VLESS пока поддерживается только на Keenetic"; return 1; }
  [ -n "$CONF" ] || { say "Нужно: vless sub set --conf ФАЙЛ (или --conf -): в файле адрес подписки (https://…) или сам список ключей"; return 2; }
  vsub_lock || { bad "проверка ключей уже идёт — дождитесь итога"; return 1; }
  vsub_work
  ( umask 077; if [ "$CONF" = - ]; then head -c 8000000; else head -c 8000000 "$CONF" 2>/dev/null; fi > "$W/in" )
  [ "$SB_ANSWERS_RM" = 1 ] && [ "$CONF" != - ] && rm -f "$CONF"   # the bot's and the program's copy: read, gone
  _u=$(tr -d '\r' < "$W/in" | grep -v '^[[:space:]]*$' | head -n 1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  if ! grep -q 'vless://' "$W/in" && vsub_url_ok "$_u" && [ "$(grep -c '[^[:space:]]' "$W/in")" -le 2 ]; then
    # the address of a subscription: kept (600) for the daily refill, fetched now
    if [ "$DRY" = 1 ]; then dry "сохранить адрес подписки (права 600), скачать её и проверить ключи"; _u=""; return 0; fi
    mkdir -p "$SB_DIR"; ( umask 077; printf '%s\n' "$_u" > "$VSUB_URL.new" ) && mv "$VSUB_URL.new" "$VSUB_URL"; chmod 600 "$VSUB_URL"
    _u=""
    ok "адрес подписки сохранён (виден только root): раз в сутки ключи перепроверяются, при нехватке — подписка заново"
    vsub_load || { bad "подписка не скачивается ни напрямую, ни в обход — проверьте адрес, пришлите её файлом"; return 1; }
    [ "$VSUB_HOW" = direct ] || note "подписку пришлось скачать в обход ($VSUB_HOW)"
  else
    _u=""
    vsub_plain "$W/in" "$W/sub.txt"
  fi
  rm -f "$W/in"
  mkdir -p "$SB_DIR"
  vsub_pass; _r=$?
  ev vless sub "$VS_KEPT"
  return $_r
}

# vsub_check [auto]: the kept keys checked again; fewer than VSUB_MIN alive: the subscription again (auto: the daily
# job — a message to the owner only when something changed)
vsub_check() {
  hr "VLESS: перепроверка ключей"
  [ -n "$VLESS_HOOK" ] || { bad "VLESS пока поддерживается только на Keenetic"; return 1; }
  [ -s "$VSUB_POOL" ] || [ -s "$VSUB_URL" ] || [ -s "$VSUB_LIST" ] || { skip "подписки нет: пришлите боту ссылку на подписку VLESS"; return 0; }
  vsub_lock || { skip "проверка ключей уже идёт — пришлю итог, когда закончится"; return 0; }
  vsub_work; _t0=$(date +%s)
  [ "$DRY" = 1 ] && { dry "перепроверить ключи подписки"; return 0; }
  vsub_save_stat LAST="$_t0"                      # the daily job does not start a second one meanwhile
  _was=0; _alive=0
  if [ -s "$VSUB_POOL" ]; then
    _was=$(wc -l < "$VSUB_POOL" | tr -d ' ')
    awk -F'\t' -v OFS='\t' '{ print NR, $3, $NF }' "$VSUB_POOL" > "$W/keys"
    : > "$W/res"; VS_REFUSED=0
    vsub_part "$W/keys" 1 "$_was"
    # still fit: alive, Claude and ChatGPT open; ordered by today's delay, the speed from the last full check
    awk 'NR == FNR { if ($2 > 0 && $3 == 1 && $4 == 1) ms[$1] = $2; next } (FNR in ms) { print ms[FNR] "\t" $0 }' "$W/res" "$VSUB_POOL" |
      sort -n -k1,1 | awk -F'\t' -v OFS='\t' '{ $2 = $1; print }' | cut -f2- > "$W/pool"
    _alive=$(wc -l < "$W/pool" | tr -d ' ')
    ok "ключей в балансировщике: $_was, подходят сейчас: $_alive (за $(vsub_took "$_t0"))"
  fi
  if [ "$_alive" -ge "$VSUB_MIN" ]; then
    VS_KEPT=$_alive
    if [ "$_alive" != "$_was" ]; then vsub_apply && ok "умершие убраны из Xray: осталось $_alive"; fi
    vsub_save_stat LAST="$(date +%s)" WHEN="$(date '+%d.%m %H:%M')" KEPT="$_alive" BEST="$(vsub_best "$W/pool")"
    say "Итог: живы $_alive из $_was, лучшая задержка $(vsub_best "$W/pool") мс."
    [ "$1" = auto ] && [ "$_alive" -lt "$_was" ] && vsub_tell "VLESS: из $_was ключей подписки умерли $((_was - _alive)), убрал их; живых $_alive."
    log "vless sub check: alive $_alive of $_was"
    return 0
  fi
  say "  Подходят меньше $VSUB_MIN — прохожу подписку заново и добираю"
  if ! vsub_load; then
    bad "подписки нет: ни адреса, ни сохранённого списка — пришлите её боту снова"
    [ "$1" = auto ] && vsub_tell "VLESS: из ключей подписки подходят $_alive, а подписку скачать не удалось — пришлите её боту снова."
    return 1
  fi
  vsub_pass; _r=$?
  [ "$1" = auto ] && vsub_tell "VLESS: ключей подписки подходило $_alive из $_was — прошёл подписку заново: оставлено ${VS_KEPT:-0}, лучшая задержка $(vsub_best "$W/pool") мс."
  return $_r
}

vsub_status() {
  [ -s "$VSUB_POOL" ] || { [ -s "$VSUB_URL" ] && skip "подписка сохранена, но её ключи сейчас не используются (настроен один ключ)"; return 0; }
  _n=$(wc -l < "$VSUB_POOL" | tr -d ' ')
  ok "ключи подписки: $_n в балансировщике, лучшая задержка $(vsub_stat BEST) мс (проверено $(vsub_stat WHEN)); Xray сам переходит на живой"
  vsub_show "$VSUB_POOL"
  [ -s "$VSUB_URL" ] && note "адрес подписки сохранён: раз в сутки перепроверка, при нехватке живых — подписка заново"
  _c=$(vsub_stat CHECKED); [ -n "$_c" ] && note "последняя полная проверка: $_c ключей за $(vsub_stat TOOK), подходили $(vsub_stat FIT)"
  return 0
}

# the job: every 5 minutes it looks; at night, a day after the last check, the kept keys are checked again
vsub_job() {
script_subst <<'EOF'
#!/bin/sh
# switchback: the VLESS subscription's keys (lib/vsub.sh) checked again once a day, at night (or 36 h after the last
# check); fewer than 3 alive: the subscription is checked anew. The router's own install.sh does the work.
export PATH=__PATH__
[ -s __CONF__/vless.pool ] && [ -f __CONF__/app/install.sh ] || exit 0
[ -d __STATE__/run/sb-vsub.lock ] && exit 0
l=$(sed -n 's/^LAST="\{0,1\}\([0-9]*\)"\{0,1\}$/\1/p' __CONF__/vless.stat 2>/dev/null); now=$(date +%s)
a=$((now - ${l:-0}))
[ "$a" -ge 86400 ] || exit 0
case $(date +%H) in 03|04|05) ;; *) [ "$a" -ge 129600 ] || exit 0 ;; esac
sh __CONF__/app/install.sh vless sub check auto --plain >/dev/null 2>&1
exit 0
EOF
}
vsub_job_install() {
  [ -n "$VSUB_JOB" ] || return 0
  _t=/tmp/switchback.vsubjob.$$; vsub_job > "$_t"
  if [ -f "$VSUB_JOB" ] && cmp -s "$_t" "$VSUB_JOB"; then rm -f "$_t"; return 0; fi
  install_file "$VSUB_JOB" "перепроверка ключей подписки (раз в сутки, ночью)" "$_t"
}

vsub_do() {
  case ${1:-status} in
    set)    : > "$RUN_JOURNAL"; vsub_set; r=$?; rm -f "$RUN_JOURNAL"; return $r ;;
    check)  vsub_check "$2" ;;
    status) hr "VLESS: подписка"; if [ -s "$VSUB_POOL" ] || [ -s "$VSUB_URL" ]; then vsub_status; else skip "подписки нет: пришлите боту ссылку на подписку VLESS"; fi ;;
    *)      say "Нужно: vless sub set --conf ФАЙЛ|- | sub check | sub status"; return 2 ;;
  esac
}
