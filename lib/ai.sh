# AI reserve: Claude and ChatGPT keep opening when their DNS service dies ("install.sh ai ...", job ai-path).
# Why (18.11.2026): at 09:16 every GeoHide node and every spare service stopped answering on TCP 443; Claude was
# gone for 10 hours, and the watchdog only said "usually passes by itself".
#
# Each group (claude, gpt) goes one PATH at a time; the paths, best first:
#   dns        the DNS service set up by module "dns" (GeoHide over DoT, the node auto-switch): nothing of ours
#   zdns       the address Zapret DNS (dns.zapret.moe) gives for each name: DoH through zapret ($ZCURL ports;
#              the router's own connections go past zapret, and Cloudflare in front of the service answers the
#              router only through zapret), dns.zapret.moe is in zapret's list
#   proxy:IP   a spare proxy address (lists/ai-*-proxies.nets), in list order
#   vpn        the real addresses (plain DNS 1.1.1.1, like Meta: ai_ns), routes to them through
#              that tunnel, checked in the kernel's table (Keenetic sets an "auto" route only while the tunnel is up)
#   vless      Xray (lib/vless.sh), last: it is heavy for a small router. The real addresses (DoH to 1.1.1.1
#              through Xray itself, else plain DNS) go into its ipset: TCP to them is redirected into Xray, which
#              reads the site's name and lets the VLESS server resolve it. Tested through Xray's SOCKS port.
# The names of a group (lists/ai-*.domains) are pinned (Keenetic ip host, OpenWrt dnsmasq address) to the
# path's addresses; "dns" takes the pins back. A path is used only after a test: TLS with the service's name
# through that address, any HTTP answer = alive (claude.ai answers programs with 403), none = dead.
# The job (every minute) asks each group's site the way the home devices do; DEAD_RUNS dead runs in a row:
# the best path that passes the test is taken, the bot and ntfy are told at once; nothing passes: an alarm
# with buttons, repeated every ALARM_MIN. Every BACK_MIN it tries the better paths; every REFRESH_MIN it asks
# Zapret DNS again (VPN: every VPN_REFRESH_MIN). A path chosen by hand ("ai via vpn", the bot's buttons) holds
# for HOURS hours, then "auto" again. While a group is not on "dns", the node auto-switch leaves it alone.
# Undo: $(ai_dir)/pinned keeps what each name had before we first pinned it ("NAME OLD|-"), $(ai_dir)/routes
# the routes we made ("GROUP IP TUNNEL"); "ai off" and uninstall (journal line "ai") put everything back.

AI_GROUPS="claude gpt"
AI_ZDNS=https://dns.zapret.moe/dns-query
AI_ZDNS_HOST=dns.zapret.moe
AI_VPN_NS=1.1.1.1      # the VPN path's DNS: plain DNS (port 53), routed into the tunnel like Meta's
# Claude's artifacts' host (any name under it). 20.11.2026: every tunnel let claude.ai out in NL but claudeusercontent.com
# in Russia (its servers pick the way by the name), artifacts answered 451 "unavailable for legal reasons"
AI_FRAME=sbcheck.frame.claudeusercontent.com
AI_SVC_TUN_MIN=30      # the DNS service silent directly: asked through the live tunnel at most this often (ai_svc_tunnel)
# AI_CLAUDE, AI_CHATGPT, AI_CLAUDE_PROXIES, AI_CHATGPT_PROXIES: lists/ai-*.domains, lists/ai-*-proxies.nets

ai_on()    { [ -f "$SB_DIR/ai.conf" ]; }
ai_dir()   { echo "$VAR_DIR/ai-path"; }
ai_probe() { case $1 in claude) echo claude.ai ;; gpt) echo chatgpt.com ;; esac; }
ai_title() { case $1 in claude) echo Claude ;; gpt) echo ChatGPT ;; esac; }
# ai_names GROUP: the names the reserve pins: the list without ai_svc_probe
ai_names() {
  case $1 in claude) echo $AI_CLAUDE ;; gpt) echo $AI_CHATGPT ;; esac | tr ' ' '\n' | grep -vx "$(ai_svc_probe "$1")" |
    if [ -n "$SB_T_AI_FEW" ]; then awk -v p="$(ai_probe "$1")" '{ l = $0 } NR <= 5 || $0 == p { print; x = $0 } END { if (l != x) print l }'; else cat; fi   # tests: each pin is a process
}
# ai_svc_probe GROUP: a name the reserve never pins, so the DNS service can be asked for its nodes while the group
# goes another way (the node auto-switch asks the same names: lib/nodes.sh NODES_PROBE, NODES_GPT_PROBE)
ai_svc_probe() { case $1 in claude) echo "$NODES_PROBE" ;; gpt) echo "$NODES_GPT_PROBE" ;; esac; }
ai_proxies() { case $1 in claude) echo $AI_CLAUDE_PROXIES ;; gpt) echo $AI_CHATGPT_PROXIES ;; esac | sed 's#/32##g'; }
ai_cur()   { cat "$(ai_dir)/cur.$1" 2>/dev/null; }
ai_path_title() {   # the words for a path in messages
  case $1 in
    dns) echo "DNS-сервис (как было настроено)" ;; zdns) echo "Zapret DNS" ;; vpn) echo "VPN (туннель $(sites_tunnel))" ;;
    proxy:*) echo "запасной адрес ${1#proxy:}" ;; vless) echo "VLESS (Xray)" ;; none|"") echo "не выбран" ;; *) echo "$1" ;;
  esac
}
# ai_domain DOMAIN: one of the AI services' names (or a subdomain): those go through VPN by "ai via vpn"
ai_domain() {
  for b in $DNS_CLAUDE $DNS_CHATGPT $AI_CLAUDE $AI_CHATGPT; do
    [ "$1" = "$b" ] && return 0
    case $1 in *".$b") return 0 ;; esac
  done
  return 1
}

# ---------- settings ----------
MODE=auto; UNTIL=0; HOURS=24; DEAD_RUNS=2; BACK_MIN=60; REFRESH_MIN=5; VPN_REFRESH_MIN=60; ALARM_MIN=60
# Against flapping: a path taken less than SWITCH_HOLD_MIN ago needs one dead run more before it is left; a path that
# fell is not returned to for BACK_HOLD_MIN (a real death still moves at once: only the way back waits)
SWITCH_HOLD_MIN=10; BACK_HOLD_MIN=120
ai_conf_load() {
  [ -f "$SB_DIR/ai.conf" ] && . "$SB_DIR/ai.conf"
  [ -n "$SB_T_HOLD" ] && { SWITCH_HOLD_MIN=$SB_T_HOLD; BACK_HOLD_MIN=$SB_T_HOLD; }   # tests
  return 0
}
# ai_need_runs GROUP: dead runs in a row before the group leaves its path
ai_need_runs() {
  _rs=$(cat "$(ai_dir)/since.$1" 2>/dev/null)
  if [ -n "$_rs" ] && [ $(($(date +%s) - _rs)) -lt $((SWITCH_HOLD_MIN * 60)) ]; then echo $((DEAD_RUNS + 1)); else echo "$DEAD_RUNS"; fi
}
# ai_fell GROUP PATH: remember that the path just failed; ai_fell_recent: it did within BACK_HOLD_MIN
ai_fell() {
  _ff=$(ai_dir)/fell.$1
  { awk -v p="$2" '$1 != p' "$_ff" 2>/dev/null; echo "$2 $(date +%s)"; } > "$_ff.tmp"; mv "$_ff.tmp" "$_ff"
}
ai_fell_recent() {
  _ft=$(awk -v p="$2" '$1 == p {print $2; exit}' "$(ai_dir)/fell.$1" 2>/dev/null)
  [ -n "$_ft" ] && [ $(($(date +%s) - _ft)) -lt $((BACK_HOLD_MIN * 60)) ]
}
# ai_nap SECONDS: a pause between tries; tests (SB_T_NAP) do not wait and start no process
ai_nap() { [ -n "$SB_T_NAP" ] || sleep "$1"; }
# ai_pports: the source ports of a test bound to a device (lib/vless.sh VLESS_PROBE_PORTS), as curl writes them
ai_pports() { echo "${VLESS_PROBE_PORTS%:*}-${VLESS_PROBE_PORTS#*:}"; }
# ai_bind DEVICE IP: curl's arguments for a test to IP by this device. By the device's own address + the test ports when
# the kernel sends that address's traffic to IP by this device: the router's curl 8.15 ignores --local-port together with
# a device name (21.11.2026), and only those ports skip the redirect into Xray. Else by the device's name, as before
ai_bind() {
  _bs=$(ip -4 addr show dev "$1" 2>/dev/null | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }')
  if [ -n "$_bs" ] && ip route get "$2" from "$_bs" 2>/dev/null | grep " dev $1\( \|\$\)" >/dev/null; then
    echo "--interface $_bs --local-port $(ai_pports)"
  else echo "--interface $1"; fi
}
ai_conf_set() {   # ai_conf_set KEY VALUE
  [ "$DRY" = 1 ] && return 0
  if grep -q "^$1=" "$SB_DIR/ai.conf"; then sed -i "s|^$1=.*|$1=$2|" "$SB_DIR/ai.conf"
  else echo "$1=$2" >> "$SB_DIR/ai.conf"; fi
}

# one change at a time: the minute job, the bot and a command by hand (a lock left by a reboot: 10 min)
ai_lock() {
  l=$(ai_dir)/busy; mkdir -p "$(ai_dir)"; w=0
  until mkdir "$l" 2>/dev/null; do
    t=$(date -r "$l" +%s 2>/dev/null || echo 0)
    [ $(( $(date +%s) - t )) -gt 600 ] && { rm -rf "$l"; continue; }
    w=$((w+1)); [ "$w" -gt "${SB_LOCK_WAIT:-90}" ] && { bad "занято: идёт переключение, повторите через минуту"; return 1; }
    sleep 1
  done
  AI_LOCKED=1
}
ai_unlock() { [ "$AI_LOCKED" = 1 ] && rm -rf "$(ai_dir)/busy"; AI_LOCKED=0; }

# ---------- DNS over HTTPS ----------
# ai_query NAME: a DNS question (type A, id 0 as DoH wants) in wire format. No subshells: the label length
# goes into printf as octal digits made by arithmetic (one question per name, ~100 names on a slow router)
ai_query() {
  printf '\000\000\001\000\000\001\000\000\000\000\000\000'
  _ifs=$IFS; IFS=.; set -- $1; IFS=$_ifs
  for l; do _l=${#l}; printf "\\$((_l / 64 * 100 + _l / 8 % 8 * 10 + _l % 8))%s" "$l"; done
  printf '\000\000\001\000\001'
}
# ai_bytes FILE: its bytes as decimal numbers. KeeneticOS's busybox od has no -A/-t (seen 19.11.2026: "od: invalid
# option -- 'A'", so no DoH answer was ever read there): hexdump first, then a full od, then busybox's "od -b" (octal)
ai_bytes() {
  if command -v hexdump >/dev/null 2>&1; then hexdump -v -e '1/1 "%u\n"' "$1"
  elif od -An -v -tu1 "$1" 2>/dev/null; then :
  else od -b -v "$1" | awk '{ for (i = 2; i <= NF; i++) { v = 0; s = $i
         for (j = 1; j <= length(s); j++) v = v * 8 + substr(s, j, 1); print v } }'
  fi
}
# ai_doh zdns NAME...: "NAME IP" for each name the service gave an IPv4 for (CNAMEs skipped). One curl for
# all names: one TLS connection; the first failed transfer ends it (a broken way would hold it for minutes).
# Zapret DNS, from a zapret port.
ai_doh() {
  kind=$1; shift
  q=/tmp/switchback-ai.$$; rm -rf "$q"; mkdir -p "$q"; i=0
  case $kind in
    zdns) url=$AI_ZDNS; how="local-port = \"$(echo "$SB_ZPORTS" | tr : -)\"" ;;
    svc)  url=$AI_SVC_URL; how=""   # the DNS service itself (ai_dns_nodes), by its DoT server's IP when known
          [ -n "$AI_SVC_IP" ] && { how=${url#https://}; how="resolve = \"${how%%/*}:443:$AI_SVC_IP\""; }
          [ -n "$AI_DOH_DEV" ] && how="$how${how:+
}interface = \"$AI_DOH_DEV\"" ;;   # through a tunnel (ai_svc_tunnel)
    vless) url=https://$AI_VPN_NS/dns-query; how="proxy = \"socks5h://127.0.0.1:$VLESS_SOCKS\"" ;;   # through Xray
  esac
  echo fail-early > "$q/cfg"
  for n; do
    i=$((i+1)); ai_query "$n" > "$q/$i"
    [ $i -gt 1 ] && echo next
    printf '# name %s\nurl = "%s"\ndata-binary = "@%s"\noutput = "%s"\n' "$n" "$url" "$q/$i" "$q/$i.r"
    printf 'header = "content-type: application/dns-message"\nheader = "accept: application/dns-message"\n'
    printf '%s\nconnect-timeout = 8\nmax-time = 10\nsilent\n' "$how"
  done >> "$q/cfg"
  curl -K "$q/cfg" >/dev/null 2>&1
  i=0
  for n; do
    i=$((i+1)); echo "N $n"
    [ -s "$q/$i.r" ] && ai_bytes "$q/$i.r"
  done | awk '
    function ip(   an, p, k, t, l) {
      if (n < 12 || b[3] % 16 != 0) return ""
      an = b[6] * 256 + b[7]; p = 12
      while (p < n && b[p] != 0) { if (b[p] >= 192) { p++; break }; p += b[p] + 1 }
      p += 5
      for (k = 0; k < an && p < n; k++) {
        while (p < n) { if (b[p] >= 192) { p += 2; break }; if (b[p] == 0) { p++; break }; p += b[p] + 1 }
        t = b[p] * 256 + b[p + 1]; l = b[p + 8] * 256 + b[p + 9]; p += 10
        # 0.0.0.0 or 127.x is "no address" (Zapret DNS answered claude.ai with 0.0.0.0 on 19.11.2026)
        if (t == 1 && l == 4 && p + 3 < n && b[p] != 0 && b[p] != 127) return b[p] "." b[p + 1] "." b[p + 2] "." b[p + 3]
        p += l
      }
      return ""
    }
    function flush(   a) { if (name != "") { a = ip(); if (a != "") print name, a } }
    $1 == "N" { flush(); name = $2; n = 0; next }
    { for (i = 1; i <= NF; i++) b[n++] = $i + 0 }
    END { flush() }'
  rm -rf "$q"
}

# ai_ns NAME...: "NAME IP" from plain DNS at AI_VPN_NS (the VPN path: the real addresses). Not DoH bound to the
# tunnel: on a real Keenetic (19.11.2026) "curl --interface nwg15 https://1.1.1.1/" failed at once while plain
# DNS to 1.1.1.1 (routed into the tunnel) and the site itself through nwg15 worked
# Asked 16 at a time: one by one, ~100 names through the tunnel took most of the ~2 minutes "ai via vpn" did
# (19.11.2026); one awk reads all the answers.
ai_ns() {
  nq=/tmp/switchback-ns.$$; rm -rf "$nq"; mkdir -p "$nq"; i=0
  for n; do
    i=$((i+1)); nslookup "$n" "$AI_VPN_NS" > "$nq/$i" 2>/dev/null &
    [ $((i % 16)) = 0 ] && wait
  done
  wait
  i=0; files=""; for n; do i=$((i+1)); files="$files $nq/$i"; done
  # the name by the file's number (a name without an answer leaves an empty file: no line to count it by)
  [ -n "$files" ] && awk -v names="$*" 'BEGIN { split(names, nm, " ") }
    FILENAME != cur { cur = FILENAME; k = FILENAME; sub(/.*\//, "", k); f = 0; done = 0 }
    /^Name:/ { f = 1 }
    f && !done && /^Address/ { for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $i !~ /^(0|127)\./) { print nm[k], $i; done = 1; break } }' $files
  rm -rf "$nq"
}

# ai_alive IP NAME [DEVICE]: the site answers through this address (TLS with its name; any HTTP code = alive).
# Headers only (HEAD): through a slow node the whole chatgpt.com page took 9-10 s, the answer 1.2-1.8 s (20.11.2026)
ai_alive() {
  set -- "$1" "$2" ${3:+$(ai_bind "$3" "$1")}
  _ai=$1; _an=$2; shift 2
  for _at in 1 2; do
    _ac=$(curl -s -I -o /dev/null --connect-timeout 5 --max-time 8 -w '%{http_code} %{time_connect}' "$@" --resolve "$_an:443:$_ai" "https://$_an/" 2>/dev/null)
    _ac=${_ac%% *}; [ -n "$_ac" ] && [ "$_ac" != 000 ] && return 0
    [ "$_at" = 2 ] || ai_nap 1
  done
  return 1
}
# ai_dns_alive IP NAME: the dns path's test, as the site will go once on that path. Our VPN-path route to IP (the
# "routes" file, any group) carries the test through the tunnel, and "dns" takes the route away: 20.11.2026 node
# 2.27.31.124 answered only through Wireguard25 (directly TCP 443 silent), the test passed, the route went, the node
# fell silent, the minute check went back to vpn: every hour. Then asked past the tunnel, by the WAN device (as
# video_prune does); the WAN device unknown: not alive
# Always by the WAN device when known: a node the service gave through the tunnel (ai_svc_tunnel) may sit on another
# module's VPN route too (20.11.2026: the service's servers answer only through the tunnel)
ai_dns_alive() {
  _ar=0; awk -v i="$1" '$2 == i {f=1} END {exit !f}' "$(ai_dir)/routes" 2>/dev/null && _ar=1
  _aw=$(wan_dev)
  if [ -z "$_aw" ]; then
    [ "$_ar" = 1 ] || { ai_alive "$1" "$2"; return; }
    log "ai: $1 ($2) is on our VPN route and the WAN device is unknown: not taken for the dns path"; return 1
  fi
  ai_alive "$1" "$2" "$_aw" && return 0
  [ "$_ar" = 1 ] && log "ai: $1 ($2) answers only through our VPN route, not by $_aw: not taken for the dns path"
  return 1
}

# ai_frame_ok GROUP CURL-ARGS...: Claude's artifacts open by this way: not 451 (a country Anthropic closed). Other
# groups, and no answer at all: not this check's business
ai_frame_ok() {
  [ "$1" = claude ] || return 0; shift
  _fc=$(curl -s -I -o /dev/null --connect-timeout 5 --max-time 8 -w '%{http_code}' "$@" "https://$AI_FRAME/" 2>/dev/null)
  [ "$_fc" = 451 ] || return 0
  AI_FRAMEBAD=1
  log "ai: claude: artifacts (claudeusercontent.com) answer 451 this way (it goes out in a closed country): not taken"; return 1
}

# ---------- paths ----------
# ai_cands GROUP: the paths this router has for the group, best first
ai_cands() {
  pf_dns_has "$(ai_probe "$1")" && echo dns
  pf_zapret_installed && echo zdns
  for _ci in $(ai_proxies "$1"); do echo "proxy:$_ci"; done
  [ -n "$(sites_tunnel)" ] && echo vpn
  vless_on && echo vless
  return 0
}
# ai_old NAME: what the name had before our first pin ("-": nothing), empty when we never pinned it
ai_old() { awk -v n="$1" '$1 == n { print $2; exit }' "$(ai_dir)/pinned" 2>/dev/null; }
# ai_free_probe GROUP: the service's probe name back to what it had (versions before 20.11.2026 pinned it too)
ai_free_probe() {
  _fp=$(ai_svc_probe "$1"); _fo=$(ai_old "$_fp"); [ -n "$_fo" ] || return 0
  pf_host_restore "$_fp" "$_fo"; CLI_CHANGED=1; save_if_changed
  _ff=$(ai_dir)/pinned; awk -v n="$_fp" '$1 != n' "$_ff" > "$_ff.tmp"; mv "$_ff.tmp" "$_ff"
}

# ai_test GROUP PATH: does the group's site open by this path (nothing is changed). AI_ADDR: the address
# ai_dns_nodes GROUP: the DNS service's nodes now, past the router's pins (pins by hand point the probe names at a
# dead node too: 19.11.2026): the service's own DoH; the node auto-switch's reserve service (nodes.conf EXTRA_DOH,
# its nodes need no QUIC rule: AI_XNODES); last, the router's answer for the name we never pin. -> AI_DNODES
# (not printed: AI_XNODES has to outlive the call)
ai_dns_nodes() {
  _dg=$1; _dp=$(ai_svc_probe "$1"); _ds=$(ai_probe "$1"); AI_XNODES=""
  set -- $(pf_dns_doh "$_ds"); AI_SVC_URL=$1; AI_SVC_IP=$2; _dl=""
  if [ -n "$AI_SVC_URL" ]; then
    _dl=$(ai_doh svc "$_ds" "$_dp" | awk '{print $2}')
    if [ -n "$_dl" ]; then echo "$(date +%s) direct" $_dl > "$(ai_dir)/svc.$_dg"
    else ai_svc_tunnel "$_dg" "$_ds" "$_dp"; _dl=$AI_SVC_TUN; fi
  fi
  _dx=$(sed -n 's/^EXTRA_DOH=//p' "$SB_DIR/nodes.conf" 2>/dev/null | tr -d '"' | awk 'NR == 1')
  if [ "$_dx" = "$AI_ZDNS" ] && pf_zapret_installed; then AI_XNODES=$(ai_doh zdns "$_ds" "$_dp" | awk '{print $2}')
  elif [ -n "$_dx" ]; then AI_XNODES=$(curl -s -o /dev/null --max-time 8 --doh-url "$_dx" -w '%{remote_ip}' "https://$_ds/" 2>/dev/null); fi
  AI_XNODES=$(echo $AI_XNODES)
  AI_DNODES=$( { echo "$_dl"; echo "$AI_XNODES" | tr ' ' '\n'; site_ips "$_dp"; } | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | awk '!s[$0]++')
}
# ai_svc_tunnel GROUP NAME PROBE: the DNS service is silent directly (20.11.2026: the provider cuts TCP to all its
# servers, the ones that answer DoH and the ones it gives for claude.ai alike; through a tunnel some answer): ask it
# through the live tunnel, so the reserve knows the service's addresses now; they are still tested directly
# (ai_dns_alive), and the dns path comes back once they open past the VPN. At most every AI_SVC_TUN_MIN: the answer
# waits in $(ai_dir)/svc.GROUP ("TIME HOW IP..."; HOW: direct, the tunnel, "-" no tunnel). -> AI_SVC_TUN
ai_svc_tunnel() {
  _sf=$(ai_dir)/svc.$1; _sn=$(date +%s); AI_SVC_TUN=""
  if [ -f "$_sf" ]; then
    set -- "$@" $(cat "$_sf")
    if [ "$5" != direct ] && [ $((_sn - ${4:-0})) -lt $((AI_SVC_TUN_MIN * 60)) ]; then
      shift 5; AI_SVC_TUN="$*"; return 0
    fi
    set -- "$1" "$2" "$3"
  fi
  _st=$(sites_tunnel)
  [ -n "$_st" ] || { echo "$_sn -" > "$_sf"; log "ai: $1: the DNS service is silent directly, no tunnel to ask it through"; return 0; }
  AI_DOH_DEV=$(pf_wg_dev "$_st")
  for _sa in 1 2; do   # through the tunnel the service answers now and then (20.11.2026: the first try silent, the next 200)
    AI_SVC_TUN=$(ai_doh svc "$2" "$3" | awk '!s[$2]++ {print $2}')
    [ -n "$AI_SVC_TUN" ] && break
  done
  AI_DOH_DEV=""; AI_SVC_TUN=$(echo $AI_SVC_TUN)
  echo "$_sn $_st $AI_SVC_TUN" > "$_sf"
  if [ -n "$AI_SVC_TUN" ]; then log "ai: $1: the DNS service is silent directly; through $_st it gives: $AI_SVC_TUN"
  else log "ai: $1: the DNS service is silent directly and through $_st"; fi
}
# AI_DNS_MOVE ("OLD NEW", path dns): the node the names had is dead, the service gives NEW now
ai_test() {
  _tp=$(ai_probe "$1"); AI_ADDR=""; AI_DNS_MOVE=""
  case $2 in
    dns)  ai_free_probe "$1"; _to=$(ai_old "$_tp")
          [ -z "$_to" ] && { AI_ADDR=$(site_ips "$_tp" | awk 'NR == 1'); [ -n "$AI_ADDR" ] && ai_dns_alive "$AI_ADDR" "$_tp"; return; }   # never pinned: the router's DNS answers
          # the node the names had before ours while it answers; else a node the service gives now: 19.11.2026
          # node 161.104.89.59 died, the service went on with 2.27.31.124, the test kept asking the dead one and the
          # reserve never came back
          case $_to in -) ;; *) ai_dns_alive "$_to" "$_tp" && { AI_ADDR=$_to; return 0; } ;; esac
          ai_dns_nodes "$1"
          for _ti in $(echo "$AI_DNODES" | grep -vx "$_to" | awk 'NR <= 5'); do
            ai_dns_alive "$_ti" "$_tp" || continue
            # the node auto-switch blocks QUIC to its nodes (Claude's apps go around a node over QUIC); one without
            # a rule still opens the site: taken, and said so (the reserve service's nodes need none)
            if [ "$1" = claude ] && [ -f "$SB_DIR/nodes.conf" ] && [ "$(pf_quic_state "$_ti")" != on ]; then
              case " $AI_XNODES " in *" $_ti "*) ;; *) log "ai: claude: node $_ti has no QUIC block rule: Claude's apps may go around it over QUIC" ;; esac
            fi
            AI_ADDR=$_ti; [ "$_to" = - ] || AI_DNS_MOVE="$_to $_ti"; return 0
          done
          return 1 ;;
    zdns) AI_ADDR=$(ai_doh zdns "$_tp" | awk '{print $2; exit}') ;;
    proxy:*) AI_ADDR=${2#proxy:} ;;
    vpn)  _tt=$(sites_tunnel); [ -n "$_tt" ] || return 1
          AI_DEV=$(pf_wg_dev "$_tt")
          AI_ADDR=$(ai_ns "$_tp" | awk '{print $2; exit}')
          [ -n "$AI_ADDR" ] && ai_alive "$AI_ADDR" "$_tp" "$AI_DEV" || return 1
          [ "$1" = claude ] || return 0
          _tf=$(ai_ns "$AI_FRAME" | awk '{print $2; exit}'); [ -n "$_tf" ] || return 0
          ai_frame_ok "$1" $(ai_bind "$AI_DEV" "$_tf") --resolve "$AI_FRAME:443:$_tf"; return ;;
    vless) vless_alive "$_tp" && ai_frame_ok "$1" --socks5-hostname "127.0.0.1:$VLESS_SOCKS"; return ;;
  esac
  [ -n "$AI_ADDR" ] && ai_alive "$AI_ADDR" "$_tp"
}

# NOT DONE ANY MORE: "ip name-server 1.1.1.1 DOMAIN" for the group's domains (so any name under them resolved on
# vpn/vless). 20.11.2026 on a real Keenetic the six added to Meta's ten made 16, and the router's own DNS died
# ("Temporary failure in name resolution" for every other name): the provider's DNS was gone from its list; the
# tunnel checks went by names, every tunnel looked dead, Telegram and the rest went to VLESS. Only taking them back
# is left: $(ai_dir)/subs ("GROUP DOMAIN") holds what versions of that day added.
ai_subs_off() {   # ai_subs_off GROUP|all
  _uf=$(ai_dir)/subs; [ -f "$_uf" ] || return 0
  for _ud in $(awk -v g="$1" 'g == "all" || $1 == g {print $2}' "$_uf" | sort -u); do
    awk -v g="$1" -v d="$_ud" '$2 == d && $1 != g && g != "all" {f=1} END {exit !f}' "$_uf" || { pf_ns_del "$AI_VPN_NS" "$_ud"; CLI_CHANGED=1; }
  done
  awk -v g="$1" 'g != "all" && $1 != g' "$_uf" > "$_uf.tmp"; mv "$_uf.tmp" "$_uf"
}

# ai_pin NAME IP: pin, remembering what the name had before our first pin (journal: the "pinned" file)
ai_pin() {
  _pc=$(pf_host_pinned "$1")
  [ -n "$(ai_old "$1")" ] || echo "$1 ${_pc:--}" >> "$(ai_dir)/pinned"
  [ "$_pc" = "$2" ] && return 0
  pf_host_restore "$1" "$2" && CLI_CHANGED=1
}
# ai_unpin GROUP: the group's names get back what they had before (path "dns")
ai_unpin() {
  f=$(ai_dir)/pinned; [ -f "$f" ] || return 0
  ai_free_probe "$1"
  for n in $(ai_names "$1"); do
    o=$(ai_old "$n"); [ -n "$o" ] || continue
    pf_host_restore "$n" "$o"; CLI_CHANGED=1
    awk -v n="$n" '$1 != n' "$f" > "$f.tmp"; mv "$f.tmp" "$f"
  done
}
# ai_move OLD NEW: the DNS service's node OLD is dead, NEW answers: every pin on OLD goes to NEW (pinned by hand,
# other names: 18.11.2026 eight names were left on a dead node), except the names the reserve holds now: their
# "before" value in the journal changes instead
ai_move() {
  _mf=$(ai_dir)/pinned; touch "$_mf"; _mn=0
  for _mx in $(pf_host_pins | awk -v a="$1" '$2 == a {print $1}'); do
    awk -v n="$_mx" '$1 == n {f=1} END {exit !f}' "$_mf" && continue
    pf_host_restore "$_mx" "$2"; _mn=$((_mn+1)); CLI_CHANGED=1
  done
  awk -v a="$1" -v b="$2" '$2 == a { $2 = b } { print }' "$_mf" > "$_mf.tmp"; mv "$_mf.tmp" "$_mf"
  log "ai: the DNS service's node $1 is dead, back by $2 (other pins moved: $_mn)"
}
# ai_route_ok IP DEVICE: the kernel really sends IP into the tunnel (KeeneticOS keeps an "auto" route in its
# settings but not in the kernel while that tunnel is down: seen 18.11.2026); waits up to ~8 s
ai_route_ok() {
  for _rt in 1 2 3 4 5; do
    ip route get "$1" 2>/dev/null | grep " dev $2\( \|\$\)" >/dev/null && return 0   # not -q: read to the end
    [ "$_rt" = 5 ] || ai_nap 2
  done
  return 1
}
# ai_routes_clear GROUP [KEEP...]: our routes of the group, except the addresses in KEEP, go
ai_routes_clear() {
  g=$1; shift; f=$(ai_dir)/routes; [ -f "$f" ] || return 0
  keep=" $* "
  for ip in $(awk -v g="$g" '$1 == g {print $2}' "$f"); do
    case $keep in *" $ip "*) continue ;; esac
    # another group may use the same address (ChatGPT and Claude share Cloudflare): keep it then
    if awk -v g="$g" -v i="$ip" '$1 != g && $2 == i {f=1} END {exit !f}' "$f"; then :
    else   # wherever it points now (the failover moves routes); else the tunnel it was made through
      via=$(pf_route_via "$ip" 255.255.255.255); [ -n "$via" ] || via=$(awk -v i="$ip" '$2 == i {print $3; exit}' "$f")
      [ -n "$via" ] && pf_route_del "$ip" 255.255.255.255 "$via"; CLI_CHANGED=1
    fi
    awk -v g="$g" -v i="$ip" '!($1 == g && $2 == i)' "$f" > "$f.tmp"; mv "$f.tmp" "$f"
  done
}

# One address can serve both groups (21.11.2026: the DNS answers gave Claude and ChatGPT the same node). The redirect into
# Xray goes by address, so a group on VLESS holding it took the other group, shown as "VPN", into Xray too. Xray reads the
# site's name from TLS, so the VLESS group can use any address of its own: its names move to one nobody else uses.
# ai_foreign GROUP: the addresses the other groups use while they are not on VLESS
ai_foreign() {
  for _og in $AI_GROUPS; do
    [ "$_og" = "$1" ] && continue
    [ -f "$(ai_dir)/cur.$_og" ] && [ "$(ai_cur "$_og")" != vless ] || continue
    awk -v g="$_og" '$1 == g {print $2}' "$(ai_dir)/routes" 2>/dev/null
    site_ips "$(ai_probe "$_og")"
    pf_host_pins | awk -v l=" $(echo $(ai_names "$_og")) " 'index(l, " " $1 " ") {print $2}'
  done | sort -u
}
# ai_vless_split GROUP "NAME IP" lines: the same lines, an address another group uses replaced by one of this group's own
# (from these lines, else what it already holds in the set). None: unchanged, and shared.GROUP says so for "ai status"
ai_vless_split() {
  _vf=" $(echo $(ai_foreign "$1")) "; _vs=$(ai_dir)/shared.$1
  _vk=$( { echo "$2" | awk '{print $2}'; awk -v t="ai:$1" '$2 == t { sub(/\/32$/, "", $1); print $1 }' "$VLESS_IPS" 2>/dev/null; } |
    awk -v f="$_vf" 'index(f, " " $1 " ") == 0 {print; exit}')
  _vc=$(echo "$2" | awk -v f="$_vf" 'index(f, " " $2 " ") {print $2}' | sort -u)
  rm -f "$_vs"
  if [ -z "$_vc" ]; then echo "$2"; return 0; fi
  if [ -z "$_vk" ]; then echo $_vc > "$_vs"; log "ai: $1: VLESS shares $(echo $_vc) with another group: no address of its own"; echo "$2"; return 0; fi
  echo "$2" | awk -v f="$_vf" -v k="$_vk" 'index(f, " " $2 " ") { $2 = k } { print }'
}
# ai_unshare GROUP: after GROUP's path changed, the other groups on VLESS let go of the addresses it uses now
ai_unshare() {
  [ "$DRY" = 1 ] && return 0
  for _ug in $AI_GROUPS; do
    [ "$_ug" != "$1" ] && [ "$(ai_cur "$_ug")" = vless ] || continue
    _ua=$(pf_host_pins | awk -v l=" $(echo $(ai_names "$_ug")) " 'index(l, " " $1 " ")')
    [ -n "$_ua" ] || continue
    _un=$(ai_vless_split "$_ug" "$_ua")
    [ "$_un" = "$_ua" ] && continue
    # the names first, then the set: no moment when a name points at an address that left it
    echo "$_un" | while read -r _ux _uy; do ai_pin "$_ux" "$_uy"; done
    vless_ips_set "ai:$_ug" $(echo "$_un" | awk '{print $2}' | sort -u); vless_sync; CLI_CHANGED=1
    log "ai: $_ug: VLESS moved off the addresses another group uses"
  done
}

# ai_apply GROUP PATH: make the group go this way. 1 (with AI_WHY) when it could not
ai_apply() {
  g=$1; p=$2; AI_WHY=""; names=$(ai_names "$g")
  case $p in
    dns) [ -n "$AI_DNS_MOVE" ] && ai_move $AI_DNS_MOVE
         ai_unpin "$g" ;;
    zdns)
      ans=$(ai_doh zdns $names); [ -n "$ans" ] || { AI_WHY="Zapret DNS не ответил"; return 1; }
      okips=" "; badips=" "
      echo "$ans" | { while read -r n ip; do
          case $badips in *" $ip "*) continue ;; esac
          case $okips in *" $ip "*) ;; *)
            if ai_alive "$ip" "$n"; then okips="$okips$ip "; else badips="$badips$ip "; log "ai: $ip does not answer ($n)"; continue; fi ;;
          esac
          ai_pin "$n" "$ip"
        done; [ "$okips" != " " ]; } || { AI_WHY="адрес от Zapret DNS не отвечает"; return 1; }
      CLI_CHANGED=1 ;;
    proxy:*) for n in $names; do ai_pin "$n" "${p#proxy:}"; done ;;
    vpn)
      t=$(sites_tunnel); [ -n "$t" ] || { AI_WHY="нет работающего туннеля WireGuard"; return 1; }
      AI_DEV=$(pf_wg_dev "$t")
      ans=$(ai_ns $names); [ -n "$ans" ] || { AI_WHY="DNS $AI_VPN_NS не ответил"; return 1; }
      f=$(ai_dir)/routes; good=""; failed=""
      for ip in $(echo "$ans" | awk '{print $2}' | sort -u); do
        via=$(pf_route_via "$ip" 255.255.255.255)
        if [ "$via" != "$t" ]; then
          [ -n "$via" ] && pf_route_del "$ip" 255.255.255.255 "$via"
          pf_route_add "$ip" 255.255.255.255 "$t" || { failed="$failed $ip"; continue; }
          CLI_CHANGED=1
        fi
        awk -v g="$g" -v i="$ip" '$1 == g && $2 == i {f=1} END {exit !f}' "$f" 2>/dev/null || echo "$g $ip $t" >> "$f"
        good="$good $ip"
      done
      pf_save >/dev/null 2>&1; CLI_CHANGED=0; pf_reload
      ok_ips=""
      for ip in $good; do
        if [ "$DRY" = 1 ] || ai_route_ok "$ip" "$AI_DEV"; then ok_ips="$ok_ips $ip"; else failed="$failed $ip"; fi
      done
      if [ -z "$ok_ips" ]; then
        ai_routes_clear "$g"
        AI_WHY="маршрут через туннель $t не встал (в таблице ядра его нет:$failed)"; return 1
      fi
      [ -n "$failed" ] && log "ai: routes not in the kernel:$failed"
      echo "$ans" | while read -r n ip; do
        case " $ok_ips " in *" $ip "*) ai_pin "$n" "$ip" ;; esac
      done
      CLI_CHANGED=1 ;;
    vless)
      vless_running || vless_start || { AI_WHY="Xray не запускается"; return 1; }
      ans=$(ai_doh vless $names); [ -n "$ans" ] || ans=$(ai_ns $names)
      [ -n "$ans" ] || { AI_WHY="адреса не узнать ни через VLESS, ни через DNS $AI_VPN_NS"; return 1; }
      ans=$(ai_vless_split "$g" "$ans")
      vless_ips_set "ai:$g" $(echo "$ans" | awk '{print $2}' | sort -u); vless_sync
      echo "$ans" | while read -r n ip; do ai_pin "$n" "$ip"; done
      CLI_CHANGED=1 ;;
  esac
  case $p in vpn) ;; *) ai_routes_clear "$g" ;; esac
  ai_subs_off "$g"
  case $p in vless) ;; *) vless_ips_del "ai:$g" && vless_sync ;; esac
  # "since" and the switch list change only when the path does (Zapret DNS is asked again every 5 minutes)
  if [ "$DRY" != 1 ] && [ "$(ai_cur "$g")" != "$p" ]; then
    sw=$(ai_dir)/switches; o=$(ai_cur "$g")
    { tail -n 19 "$sw" 2>/dev/null; echo "$(date +%s) $g ${o:-none} $p"; } > "$sw.tmp"; mv "$sw.tmp" "$sw"
    echo "$p" > "$(ai_dir)/cur.$g"; date +%s > "$(ai_dir)/since.$g"
  fi
  [ "$p" = vless ] || rm -f "$(ai_dir)/shared.$g"
  ai_unshare "$g"
  # the first path that passes is the best one: the job then stops trying to go back
  if [ "$p" = "$(ai_cands "$g" | awk 'NR == 1')" ]; then rm -f "$(ai_dir)/best.$g"; touch "$(ai_dir)/best.$g"; else rm -f "$(ai_dir)/best.$g"; fi
  save_if_changed
  log "ai: $g -> $p"
  return 0
}

# ai_switch GROUP [FROM]: the best path that passes the test (FROM is skipped); 1 when none does
# A path that opens the site but not Claude's artifacts (451) is taken only when no path opens both (21.11.2026: VLESS
# went silent, the VPN path opened claude.ai but was refused for its artifacts: Claude stayed on the dead path, alarm).
# AI_NOLOOSE=1 ("ai tick frame"): only a path that opens them too
ai_switch() {
  g=$1; skip=$2; AI_TRIED=""; _sl=""
  for c in $(ai_cands "$g"); do
    [ "$c" = "$skip" ] && continue
    AI_TRIED="$AI_TRIED $c"
    AI_FRAMEBAD=0
    ai_test "$g" "$c" || { [ "$AI_FRAMEBAD" = 1 ] && [ -z "$_sl" ] && _sl=$c; continue; }
    # after a change, better paths are tried again only in BACK_MIN
    ai_apply "$g" "$c" && { AI_NEW=$c; date +%s > "$(ai_dir)/back"; return 0; }
    log "ai: $g: $c passed the test but: $AI_WHY"
  done
  if [ -n "$_sl" ] && [ "$AI_NOLOOSE" != 1 ]; then   # vpn/vless: their apply needs nothing from the test
    log "ai: $g: no path opens Claude's artifacts too; $_sl opens the site at least"
    ai_apply "$g" "$_sl" && { AI_NEW=$_sl; date +%s > "$(ai_dir)/back"; return 0; }
  fi
  return 1
}

# ---------- messages: Telegram with buttons and ntfy, both at once (a lost service is worth a loud message) ----------
AI_KB='{"inline_keyboard":[[{"text":"Claude через VPN","callback_data":"ai vpn"},{"text":"через VLESS","callback_data":"ai vless"}],[{"text":"Следующий путь","callback_data":"ai next"},{"text":"Авто","callback_data":"ai auto"}],[{"text":"Статус","callback_data":"ai"}]]}'
ai_tell() {
  [ "$DRY" = 1 ] && { say "  (сообщение) $1"; return 0; }
  log "ai: tell: $1"
  [ -f "$BOT" ] || return 0
  ( TOKEN=""; CHAT=""; NTFY=""; . "$BOT"
    [ -n "$TOKEN" ] && curl -s -o /dev/null --max-time 20 "https://api.telegram.org/bot$TOKEN/sendMessage" \
      -d chat_id="$CHAT" --data-urlencode text="[роутер] $1" ${2:+--data-urlencode reply_markup="$2"}
    [ -n "$NTFY" ] && curl -s -o /dev/null --max-time 20 -H "Title: router" -d "$1" "$NTFY"
  ) >/dev/null 2>&1
  return 0
}
ai_alarm() {   # ai_alarm GROUP: nothing opens the service; at once, then every ALARM_MIN
  a=$(ai_dir)/alarm.$1; now=$(date +%s)
  [ -f "$a" ] && [ $((now - $(cat "$a"))) -lt $((ALARM_MIN * 60)) ] && return 0
  echo "$now" > "$a"
  t=$(sites_tunnel)
  ai_tell "✗ $(ai_title "$1") не открывается ни одним путём. Проверено: $(for c in $AI_TRIED; do printf '%s, ' "$(ai_path_title "$c")"; done | sed 's/, $//')${t:+.}${t:-; туннеля WireGuard нет}. Роутер пробует каждую минуту и напишет, когда заработает; это сообщение повторится через час. Что сделать: подождать; если на телефоне есть свой VPN — включить его; добавить туннель WireGuard (тогда сработает путь через VPN)." "$AI_KB"
}

# ---------- the job's call: "ai tick fail|ok|refresh|back|expire" ----------
ai_tick() {
  ai_on || return 0
  ai_conf_load; ai_lock || return 1
  now=$(date +%s); d=$(ai_dir)
  if [ "$MODE" != auto ] && [ "${UNTIL:-0}" -gt 0 ] && [ "$now" -ge "$UNTIL" ]; then
    ai_conf_set MODE auto; ai_conf_set UNTIL 0; MODE=auto
    ai_tell "Ручной выбор пути для нейросетей истёк ($HOURS ч): снова выбираю сам." "$AI_KB"
  fi
  for g in $AI_GROUPS; do
    [ -f "$d/cur.$g" ] || continue
    cur=$(ai_cur "$g"); b=$(cat "$d/bad.$g" 2>/dev/null); b=${b:-0}
    case $1 in
      fail)
        [ "$b" -ge "$(ai_need_runs "$g")" ] || continue
        if [ "$MODE" != auto ]; then
          AI_TRIED=$cur; ai_alarm "$g"; continue     # the owner's choice: say so, do not move it
        fi
        ai_fell "$g" "$cur"
        if ai_switch "$g" "$cur"; then
          rm -f "$d/bad.$g"
          if [ -f "$d/alarm.$g" ]; then rm -f "$d/alarm.$g"
            ai_tell "$(ai_title "$g") снова открывается: путь — $(ai_path_title "$AI_NEW"). Делать ничего не нужно." "$AI_KB"
          else
            ai_tell "✗ $(ai_title "$g") перестал открываться ($(ai_path_title "$cur")). Переключил на: $(ai_path_title "$AI_NEW") — открывается. Делать ничего не нужно." "$AI_KB"
          fi
        else
          AI_TRIED="$cur$AI_TRIED"; ai_alarm "$g"
        fi ;;
      ok)
        [ -f "$d/alarm.$g" ] && [ "$b" = 0 ] || continue
        rm -f "$d/alarm.$g"
        ai_tell "$(ai_title "$g") снова открывается (путь — $(ai_path_title "$cur")). Делать ничего не нужно." "$AI_KB" ;;
      refresh)
        case $cur in
          zdns) ai_apply "$g" zdns || log "ai: $g: refresh: $AI_WHY" ;;
          vpn)  [ $((now - $(cat "$d/vpn.$g" 2>/dev/null || echo 0))) -ge $((VPN_REFRESH_MIN * 60)) ] ||
                  [ "$(sites_tunnel)" != "$(cat "$d/tun.$g" 2>/dev/null)" ] || continue
                ai_apply "$g" vpn && { echo "$now" > "$d/vpn.$g"; sites_tunnel > "$d/tun.$g"; } || log "ai: $g: refresh: $AI_WHY" ;;
          vless) [ $((now - $(cat "$d/vless.$g" 2>/dev/null || echo 0))) -ge $((VPN_REFRESH_MIN * 60)) ] || continue
                ai_apply "$g" vless && echo "$now" > "$d/vless.$g" || log "ai: $g: refresh: $AI_WHY" ;;
        esac ;;
      frame)   # Claude opens, its artifacts answer 451 by this path (the job): another path where they open, if any
        [ "$g" = claude ] || continue
        [ -f "$d/frame.$g" ] && [ $((now - $(cat "$d/frame.$g"))) -lt $((BACK_MIN * 60)) ] && continue
        echo "$now" > "$d/frame.$g"
        [ "$MODE" = auto ] || continue     # the owner's choice: left as it is
        AI_NOLOOSE=1; ai_switch "$g" "$cur"; _fs=$?; AI_NOLOOSE=""
        if [ "$_fs" = 0 ]; then
          ai_tell "Claude: артефакты (claudeusercontent.com) через $(ai_path_title "$cur") не открывались — этот путь выходит в стране, закрытой для Anthropic (ответ 451). Переключил на: $(ai_path_title "$AI_NEW"). Делать ничего не нужно." "$AI_KB"
        else log "ai: claude: artifacts answer 451 by $cur and no other path opens them: stays, tries again in $BACK_MIN min"; fi ;;
      back)
        [ "$MODE" = auto ] && [ ! -f "$d/best.$g" ] || continue
        for c in $(ai_cands "$g"); do
          [ "$c" = "$cur" ] && break
          ai_fell_recent "$g" "$c" && { log "ai: $g: $c fell recently: not back yet"; continue; }
          ai_test "$g" "$c" || continue
          ai_nap 5; ai_test "$g" "$c" || { log "ai: $g: $c passed once, then not: stays on $cur"; continue; }   # steady, not a lucky try
          ai_apply "$g" "$c" || continue
          ai_tell "$(ai_title "$g"): лучший путь снова работает — $(ai_path_title "$c") (был: $(ai_path_title "$cur")). Делать ничего не нужно."
          break
        done ;;
    esac
  done
  case $1 in refresh) echo "$now" > "$d/refresh" ;; back) echo "$now" > "$d/back" ;; esac
  ai_unlock
  return 0
}

# ---------- by hand ----------
# ai_via PATH [HOURS]: both groups go this way (if it passes the test) for HOURS hours; "proxy": the first spare
# address that answers. auto: back to automatic choice (the best path that passes)
ai_via() {
  want=$1; h=${2:-$HOURS}
  case $want in dns|zdns|vpn|vless|proxy|auto|next) ;; *) say "Нужно: ai via vpn|zdns|proxy|dns|vless [часов] | ai auto | ai next"; return 2 ;; esac
  case $h in ''|*[!0-9]*) h=$HOURS ;; esac
  ai_on || { bad "резерв для нейросетей выключен: включите его — sh install.sh ai on (или кнопкой в боте)"; return 1; }
  ai_conf_load; ai_lock || return 1
  rc=0; d=$(ai_dir)
  for g in $AI_GROUPS; do
    [ -f "$d/cur.$g" ] || continue
    cur=$(ai_cur "$g"); title=$(ai_title "$g")
    case $want in
      auto)  if ai_switch "$g"; then ok "$title: $(ai_path_title "$AI_NEW")"; else warn "$title: ни один путь сейчас не открывает сайт"; fi ;;
      next)  # the path after the current one that passes the test (round the list)
             list=$(ai_cands "$g"); after=$(echo "$list" | awk -v c="$cur" 'f {print} $0 == c {f=1}'); before=$(echo "$list" | awk -v c="$cur" '$0 == c {exit} {print}')
             done_=0
             for c in $after $before; do
               ai_test "$g" "$c" || continue
               ai_apply "$g" "$c" && { ok "$title: $(ai_path_title "$cur") → $(ai_path_title "$c")"; done_=1; break; }
             done
             [ "$done_" = 1 ] || { warn "$title: других рабочих путей сейчас нет, остаётся $(ai_path_title "$cur")"; rc=1; } ;;
      proxy) done_=0
             for c in $(ai_cands "$g" | grep '^proxy:'); do
               ai_test "$g" "$c" && ai_apply "$g" "$c" && { ok "$title: $(ai_path_title "$c")"; done_=1; break; }
             done
             [ "$done_" = 1 ] || { warn "$title: ни один запасной адрес не отвечает, остаётся $(ai_path_title "$cur")"; rc=1; } ;;
      *)     if ! ai_cands "$g" | grep -x "$want" >/dev/null; then
               if [ "$want" = vless ]; then warn "$title: VLESS не настроен — пришлите боту ссылку vless:// (или sh install.sh vless set --conf ФАЙЛ)"
               else warn "$title: путь $(ai_path_title "$want") здесь не настроен"; fi; rc=1
             elif AI_FRAMEBAD=0; ! ai_test "$g" "$want" && [ "$AI_FRAMEBAD" != 1 ]; then warn "$title: через $(ai_path_title "$want") сайт сейчас не открывается — остаётся $(ai_path_title "$cur")"; rc=1
             elif ai_apply "$g" "$want"; then ok "$title: $(ai_path_title "$want")"
               [ "$AI_FRAMEBAD" = 1 ] && warn "артефакты Claude (claudeusercontent.com) этим путём не откроются: ответ 451, выход в стране, закрытой для Anthropic"
             else warn "$title: $AI_WHY — остаётся $(ai_path_title "$cur")"; rc=1; fi ;;
    esac
    rm -f "$d/bad.$g" "$d/alarm.$g"
  done
  case $want in
    auto|next) ai_conf_set MODE auto; ai_conf_set UNTIL 0; date +%s > "$d/back" ;;   # next: no going back for BACK_MIN
    *) ai_conf_set MODE "$want"; ai_conf_set UNTIL $(( $(date +%s) + h * 3600 ))
       say "  Выбрано вручную на $h ч, потом снова автоматически (сразу: sh install.sh ai auto или кнопка «Авто»)." ;;
  esac
  ai_unlock; ev ai_via "$want" "$rc"
  log "ai: by hand: $want ($h h)"
  return $rc
}

# ai_svc_note GROUP PATH: what the DNS service answered last (svc.GROUP), while the group is off the dns path
ai_svc_note() {
  [ "$2" = dns ] && return 0
  _nt=$(ai_title "$1"); set -- $(cat "$(ai_dir)/svc.$1" 2>/dev/null); [ -n "$1" ] || return 0
  _nw=$(ai_when "$1"); _nh=$2; shift 2
  case $_nh in
    direct) note "$_nt: DNS-сервис отвечает напрямую ($_nw), адреса: $*" ;;
    -)      note "$_nt: DNS-сервис напрямую не отвечает ($_nw); туннеля, чтобы спросить через него, нет" ;;
    *) if [ -n "$1" ]; then note "$_nt: DNS-сервис отвечает через туннель $_nh ($_nw): адреса $*; напрямую недоступны — путь DNS-сервис вернётся сам, когда откроются"
       else note "$_nt: DNS-сервис не отвечает ни напрямую, ни через туннель $_nh ($_nw)"; fi ;;
  esac
}
ai_when() { date -d "@$1" '+%d.%m %H:%M' 2>/dev/null || echo "$1"; }   # seconds since 1970 -> "19.11 10:05"
# the bot's /ai and its "Статус" button: only the reserve, a few lines
ai_status() {
  if ! ai_on; then skip "резерв для нейросетей выключен (включить: sh install.sh ai on)"; ev ai off; return 0; fi
  ai_conf_load; d=$(ai_dir)
  if [ "$MODE" = auto ]; then ok "резерв для нейросетей включён: путь выбирается сам"
  else ok "путь выбран вручную: $(ai_path_title "$MODE") — до $(ai_when "$UNTIL"), потом снова сам (сразу: «Авто»)"; fi
  for g in $AI_GROUPS; do
    [ -f "$d/cur.$g" ] || continue
    c=$(ai_cur "$g"); s=$(cat "$d/since.$g" 2>/dev/null); b=$(cat "$d/bad.$g" 2>/dev/null)
    if [ -f "$d/alarm.$g" ]; then warn "$(ai_title "$g"): не открывается ни одним путём (последний: $(ai_path_title "$c"))"
    elif [ -n "$b" ]; then warn "$(ai_title "$g"): $(ai_path_title "$c") — не открылся проверок подряд: $b"
    else ok "$(ai_title "$g"): $(ai_path_title "$c")${s:+ (с $(ai_when "$s"))}"; fi
    case $(cat "$d/state.$g" 2>/dev/null) in
      flaky) note "$(ai_title "$g"): путь работает с перебоями (ответил не с первой попытки)" ;;
      "geo 451") note "$(ai_title "$g"): сервис отвечает отказом по стране (код 451): связь есть, это не обрыв" ;;
    esac
    # the real way: an address of this group inside the redirect into Xray means VLESS, whatever the path is called
    if [ "$c" != vless ] && [ -s "$VLESS_IPS" ]; then
      for _sa in $(site_ips "$(ai_probe "$g")"); do
        if grep -q "^$_sa\(/32\)\? " "$VLESS_IPS"; then warn "$(ai_title "$g"): на деле идёт через VLESS: его адрес $_sa в перенаправлении на Xray"; break; fi
      done
    fi
    [ -f "$d/shared.$g" ] && warn "$(ai_title "$g"): на VLESS, но адрес $(cat "$d/shared.$g") общий с другой группой и своего нет: та группа тоже идёт через VLESS"
    ev ai "$g" "$c" "$MODE"
    ai_svc_note "$g" "$c"
    [ -f "$d/frame.$g" ] && note "$(ai_title "$g"): артефакты (claudeusercontent.com) этим путём не открываются — ответ 451, выход в стране, закрытой для Anthropic; другой путь пробую раз в час"
  done
  ch=$(cat "$d/checked" 2>/dev/null)
  if [ -n "$ch" ]; then note "последняя проверка: $(ai_when "$ch") (проверяю каждую минуту)"
  else note "проверок ещё не было (первая — в течение минуты)"; fi
  for g in $AI_GROUPS; do   # the last switch of each group
    [ -f "$d/cur.$g" ] || continue
    l=$(awk -v g="$g" '$2 == g' "$d/switches" 2>/dev/null | tail -n 1)
    if [ -n "$l" ]; then set -- $l; note "последнее переключение — $(ai_title "$g"): $(ai_when "$1"), $(ai_path_title "$3") → $(ai_path_title "$4")"
    else note "$(ai_title "$g"): переключений ещё не было"; fi
  done
}

# ---------- on / off ----------
# asked at the end of module "dns" (answers key ai_reserve); off by default
ai_ask() {
  say ""
  say "  Резерв для нейросетей: если Claude или ChatGPT перестанут открываться, роутер сам перейдёт на другой"
  say "  путь — Zapret DNS, запасные адреса, VPN — и напишет в бот. Вручную — кнопками в боте (/ai)."
  if ai_on; then skip "резерв для нейросетей уже включён"; ai_enable; return $?; fi
  yes_no "  Включить резерв для нейросетей?" n ai_reserve || return 0
  ai_enable
}

ai_enable() {
  command -v pf_nodes_funcs >/dev/null 2>&1 || { warn "резерв для нейросетей: на этой прошивке пока не поддерживается"; return 1; }
  pf_cron_setup || fail "не удалось поставить curl/cron"
  if pf_zapret_installed; then
    if grep -qx "$AI_ZDNS_HOST" "$NFQ_LIST" 2>/dev/null; then skip "$AI_ZDNS_HOST уже в списке zapret"
    else append_line "$NFQ_LIST" "$AI_ZDNS_HOST"; remember "list $AI_ZDNS_HOST"; pf_zapret_restart; ok "$AI_ZDNS_HOST в списке zapret"; fi
  else note "zapret не установлен: путь через Zapret DNS не будет использоваться (остальные — да)"; fi
  [ -n "$(sites_tunnel)" ] || note "туннеля WireGuard нет: путь через VPN появится, когда он будет"
  if [ ! -f "$SB_DIR/ai.conf" ]; then
    sb_conf "$SB_DIR/ai.conf" "резерва для нейросетей" "резерв для нейросетей включён" <<EOF
# switchback: the AI reserve (lib/ai.sh). Edit and it applies on the next minute.
# MODE: auto, or a path chosen by hand (dns, zdns, proxy, vpn, vless) until UNTIL (seconds since 1970)
MODE=auto
UNTIL=0
# a path chosen by hand holds this many hours
HOURS=24
# dead runs (1 a minute) before another path; minutes between tries of a better path, Zapret DNS
# questions, VPN address refreshes, repeated alarms
DEAD_RUNS=2
BACK_MIN=60
REFRESH_MIN=5
VPN_REFRESH_MIN=60
ALARM_MIN=60
EOF
  fi
  remember "ai"
  tmp=/tmp/switchback.new.$$
  ai_job > "$tmp"
  install_file "$CRON1/ai-path" "резерв для нейросетей (проверка каждую минуту)" "$tmp"
  [ "$DRY" = 1 ] && { dry "выбрать путь для Claude и ChatGPT"; return 0; }
  mkdir -p "$(ai_dir)"; date +%s > "$(ai_dir)/back"
  ai_conf_load; ai_lock || return 1
  for g in $AI_GROUPS; do
    [ -n "$(ai_names "$g")" ] || continue
    [ -f "$(ai_dir)/cur.$g" ] && { skip "$(ai_title "$g"): $(ai_path_title "$(ai_cur "$g")")"; continue; }
    if [ "$(ai_cands "$g" | awk 'NR == 1')" = dns ]; then   # the DNS service set up: it stays, the job watches it
      echo dns > "$(ai_dir)/cur.$g"; date +%s > "$(ai_dir)/since.$g"; touch "$(ai_dir)/best.$g"
      ok "$(ai_title "$g"): $(ai_path_title dns), резервные пути — если он перестанет открывать сайт"
    elif ai_switch "$g"; then ok "$(ai_title "$g"): $(ai_path_title "$AI_NEW")"
    else
      echo none > "$(ai_dir)/cur.$g"; date +%s > "$(ai_dir)/since.$g"
      warn "$(ai_title "$g"): ни один путь сейчас не открывает сайт — задание будет пробовать каждую минуту"
    fi
  done
  ai_unlock
  return 0
}

ai_disable() {
  hr "Резерв для нейросетей"
  ai_on || [ -f "$CRON1/ai-path" ] || { skip "резерв для нейросетей не включён"; return 0; }
  [ "$DRY" = 1 ] && { dry "выключить резерв и вернуть прежние закрепления"; return 0; }
  ai_undo
  grep -v -e "^ai\$" -e "^file $CRON1/ai-path\$" -e "^file $SB_DIR/ai.conf\$" "$STATE" > "$STATE.tmp" 2>/dev/null
  mv "$STATE.tmp" "$STATE"
  pf_save || warn "роутер не сохранил настройки"
  ok "резерв для нейросетей выключен"; ev ai off
  log "ai off"
}
ai_undo() {   # also the journal line "ai" (uninstall)
  run rm -f "$CRON1/ai-path" "$SB_DIR/ai.conf"
  d=$(ai_dir); n=0
  if [ -f "$d/pinned" ]; then
    while read -r name old; do
      [ -n "$name" ] || continue
      pf_host_restore "$name" "${old:--}"; n=$((n+1))
    done < "$d/pinned"
  fi
  for g in $AI_GROUPS; do vless_ips_del "ai:$g"; done; vless_sync   # the VLESS path: its addresses out
  ai_subs_off all
  if [ -f "$d/routes" ]; then
    for ip in $(awk '{print $2}' "$d/routes" | sort -u); do
      via=$(pf_route_via "$ip" 255.255.255.255); [ -n "$via" ] || via=$(awk -v i="$ip" '$2 == i {print $3; exit}' "$d/routes")
      [ -n "$via" ] && pf_route_del "$ip" 255.255.255.255 "$via"
    done
  fi
  [ "$DRY" = 1 ] || rm -rf "$d"
  [ "$n" -gt 0 ] && ok "закрепления резерва убраны: $n (прежние возвращены)"
  return 0
}

do_ai() {
  set -- $SITES_ARGS
  case ${1:-status} in
    on)     : > "$RUN_JOURNAL"; trap on_interrupt INT TERM
            hr "Резерв для нейросетей: Claude, ChatGPT"
            ai_enable || { trap - INT TERM; return 1; }
            self_install
            trap - INT TERM; rm -f "$RUN_JOURNAL"; ev ai on; log "ai on" ;;
    off)    ai_disable ;;
    status) ai_status ;;
    via)    ai_via "$2" "$3" ;;
    auto|next) ai_via "$1" ;;
    vpn|zdns|proxy|dns|vless) ai_via "$1" "$2" ;;
    tick)   ai_tick "$2" ;;
    *)      say "Нужно: ai on | off | status | via vpn|zdns|proxy|dns|vless [часов] | auto | next"; return 2 ;;
  esac
}

# the minute job: asks each group's site the way home devices do; calls "install.sh ai tick" only to act
ai_job() {
  script_subst <<'EOF' | sed "s|__XRAYINIT__|$VLESS_INIT|g; s|__FRAME__|$AI_FRAME|g"
#!/bin/sh
# AI reserve (switchback): every minute, does Claude (and ChatGPT) open by its current path. Dead DEAD_RUNS runs
# in a row: "install.sh ai tick fail" takes the best path that works and tells the bot and ntfy.
# Also: back to a better path every BACK_MIN, Zapret DNS asked again every REFRESH_MIN.
export PATH=__PATH__
[ -f __CONF__/ai.conf ] || exit 0
APP=__CONF__/app/install.sh
[ -f "$APP" ] || exit 0
MODE=auto; UNTIL=0; DEAD_RUNS=2; BACK_MIN=60; REFRESH_MIN=5; SWITCH_HOLD_MIN=10
. __CONF__/ai.conf
[ -n "$SB_T_HOLD" ] && SWITCH_HOLD_MIN=$SB_T_HOLD
S=__STATE__/ai-path
LOG=$S/log
[ -d "$S/busy" ] && exit 0               # a switch is running (the bot or by hand)
mkdir -p "$S"
# one run at a time: on one slow core a late run must not pile onto the next (a lock left by a reboot: 5 min)
J=$S/job
if ! mkdir "$J" 2>/dev/null; then
  [ $(( $(date +%s) - $(date -r "$J" +%s 2>/dev/null || echo 0) )) -gt 300 ] || exit 0
  rm -rf "$J"; mkdir "$J" 2>/dev/null || exit 0
fi
trap 'rm -rf "$J"' EXIT
trap 'exit 1' INT TERM
# a group on the VLESS path: Xray back after a crash (its service also puts the redirect rules back)
grep -qx vless "$S"/cur.* 2>/dev/null && [ -x __XRAYINIT__ ] && __XRAYINIT__ ensure >/dev/null 2>&1
[ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 400 ] && tail -n 300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
now=$(date +%s)
echo "$now" > "$S/checked"               # for "ai status": when it last looked
nap() { [ -n "$SB_T_NAP" ] || sleep "$1"; }   # tests do not wait
# alive NAME: the router's DNS address for NAME answers TLS with that name. Up to 3 tries, 2 s apart, stops at the first
# answer (a healthy path costs one request). st: ok, flaky (answered, not at once), "geo CODE" (403/451: the service
# refused by country: reachable, NOT dead; claude.ai gives programs 403 anyway), dead (000 = no connection, every try).
# Headers only (HEAD): the whole page through a slow node outran the time limit, a false "does not open" (20.11.2026)
alive() {
  st=dead
  for t in 1 2; do
    ip=$(nslookup "$1" 127.0.0.1 2>/dev/null | awk '/^Name:/ {n=1}
      n && /^Address/ { for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit } }')
    [ -n "$ip" ] && break
    [ "$t" = 2 ] || nap 2
  done
  [ -n "$ip" ] || return 1
  for t in 1 2 3; do
    c=$(curl -s -I -o /dev/null --connect-timeout 4 --max-time 8 -w '%{http_code} %{time_connect}' --resolve "$1:443:$ip" "https://$1/" 2>/dev/null)
    c=${c%% *}
    if [ -n "$c" ] && [ "$c" != 000 ]; then
      if [ "$t" != 1 ]; then st=flaky
      else case $c in 403|451) st="geo $c" ;; *) st=ok ;; esac; fi
      return 0
    fi
    [ "$t" = 3 ] || nap 2
  done
  return 1
}
# state GROUP: what the last run saw, for "ai status"; written only when it changes (the router's flash)
state() { [ "$(cat "$S/state.$1" 2>/dev/null)" = "$st" ] || echo "$st" > "$S/state.$1"; }
# frame_ok GROUP: Claude's artifacts do not answer 451 (they went out in a closed country: 20.11.2026, every tunnel)
frame_ok() {
  [ "$1" = claude ] || return 0
  c=$(curl -s -I -o /dev/null --max-time 10 -w '%{http_code}' https://__FRAME__/ 2>/dev/null)
  [ "$c" = 451 ] || return 0
  log "claude: artifacts (claudeusercontent.com) answer 451 by $(cat "$S/cur.claude")"; return 1
}
need=""; fr=""
for g in claude gpt; do
  [ -f "$S/cur.$g" ] || continue
  case $g in claude) p=claude.ai ;; gpt) p=chatgpt.com ;; esac
  if alive "$p"; then
    state "$g"; [ "$st" = flaky ] && log "$g: $p answered, not at once (by $(cat "$S/cur.$g"))"
    [ -f "$S/bad.$g" ] && log "$g: $p opens again"
    rm -f "$S/bad.$g"; [ -f "$S/alarm.$g" ] && need=${need:-ok}
    # the site opens, its artifacts do not: not "dead" (no alarm, no switch every minute); another path is looked
    # for at once, then every BACK_MIN ("ai tick frame" keeps the time in frame.GROUP)
    if frame_ok "$g"; then
      [ -f "$S/frame.$g" ] && { log "$g: artifacts open again"; rm -f "$S/frame.$g"; }
    elif [ ! -f "$S/frame.$g" ] || [ $((now - $(cat "$S/frame.$g"))) -ge $((BACK_MIN * 60)) ]; then fr=1; fi
  else
    state "$g"; b=$(cat "$S/bad.$g" 2>/dev/null); b=$(( ${b:-0} + 1 )); echo "$b" > "$S/bad.$g"
    log "$g: $p does not open by $(cat "$S/cur.$g") ($b)"
    r=$DEAD_RUNS; s=$(cat "$S/since.$g" 2>/dev/null)   # just moved here: one run more before leaving (ai_need_runs)
    [ -n "$s" ] && [ $((now - s)) -lt $((SWITCH_HOLD_MIN * 60)) ] && r=$((r + 1))
    [ "$b" -ge "$r" ] && need=fail
  fi
done
[ -z "$need" ] && [ -n "$fr" ] && need=frame
if [ -z "$need" ]; then
  if [ "$MODE" != auto ] && [ "${UNTIL:-0}" -gt 0 ] && [ "$now" -ge "$UNTIL" ]; then need=expire
  elif grep -qx -e zdns -e vpn -e vless "$S"/cur.* 2>/dev/null &&
       [ $((now - $(cat "$S/refresh" 2>/dev/null || echo 0))) -ge $((REFRESH_MIN * 60)) ]; then need=refresh
  elif [ "$MODE" = auto ] && [ $((now - $(cat "$S/back" 2>/dev/null || echo 0))) -ge $((BACK_MIN * 60)) ]; then
    for g in claude gpt; do [ -f "$S/cur.$g" ] && [ ! -f "$S/best.$g" ] && need=back; done
  fi
fi
[ -n "$need" ] || exit 0
log "tick $need"
sh "$APP" ai tick "$need" --plain >> "$LOG" 2>&1
exit 0
EOF
}
