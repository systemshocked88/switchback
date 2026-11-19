# Module "nodes": Claude through the fastest proxy node + QUIC blocked to the nodes.
# Based on the user's claude-nodes script (Keenetic, 2026-11-07). A DNS proxy service for Claude
# (module "dns") answers with several nodes; this module:
#   1) blocks QUIC (UDP 443) to every node: the Claude apps otherwise go around the proxy over QUIC;
#   2) pins each Claude domain group to the fastest live node (router DNS answers it for the domain);
#   3) installs a script that every minute checks the pinned node and moves the group to a faster live
#      node that has a QUIC rule when the current one is dead (3 runs) or slow (5 runs).
# Fixes over the original: a lock left by a reboot is cleared, a disabled QUIC rule does not count,
# a pause after a scan that found nothing better, the "nodes without QUIC rule" alert repeats daily.

NODES_PROBE=claude.com     # asked through the router's DNS: the proxy service answers with all its nodes
NODES_GROUPS="web:claude.ai,claudeusercontent.com api:api.anthropic.com,a-api.anthropic.com"
# a second service as a reserve: its nodes are asked over DoH (the router's curl does it: --doh-url), the router
# itself need not support DoH. Its nodes need no QUIC rule: the Claude apps worked through them without one.
NODES_EXTRA_DOH=https://dns.zapret.moe/dns-query
# ChatGPT the same way, when its DNS service is set up (module "dns"): a group with its OWN nodes — the ones
# its DNS service gives (asked by a name that is not pinned: a pinned name answers with the pin) plus the
# reserve service's — and no QUIC rule needed (ChatGPT works without one). Only these names are pinned; other
# subdomains keep going through the DNS service.
NODES_GPT="gpt:chatgpt.com,persistent.oaistatic.com,cdn.oaistatic.com,auth.openai.com,api.openai.com,files.oaiusercontent.com"
NODES_GPT_PROBE=openai.com

# nodes_list: the proxy service's nodes, as the router's DNS sees them (IPv4, one per line)
nodes_list() {
  nslookup "$NODES_PROBE" 127.0.0.1 2>/dev/null | awk '/^Name:/ {n=1}
    n && /^Address/ { for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; break } }' |
    grep -v '^127\.' | sort -u
}

mod_nodes() {
  hr "Claude: быстрый узел и запрет QUIC"
  command -v pf_nodes_funcs >/dev/null 2>&1 || { mod_skip "на этой прошивке пока не поддерживается"; return 0; }
  nodes=$(nodes_list)
  n=$(echo $nodes | wc -w)
  if [ "$n" -lt 2 ]; then
    mod_skip "DNS для Claude отдаёт узлов: $n — переключать не между чем (нужен DNS-сервис с несколькими узлами, модуль «DNS»)"
    return 0
  fi
  ok "узлов у DNS-сервиса: $n ($(echo $nodes))"
  pf_cron_setup || fail "не удалось поставить curl/cron"
  say "  Приложения Claude иначе ходят мимо узла по QUIC (UDP 443) и обрывают сессию: запрещаю его к узлам."
  for ip in $nodes; do
    if pf_quic_blocked "$ip"; then skip "QUIC к $ip уже запрещён"
    else pf_quic_block "$ip" || fail "роутер не принял правило для $ip"; ok "QUIC к $ip запрещён"; CLI_CHANGED=1; fi
  done
  tmp=/tmp/switchback.new.$$
  nodes_script > "$tmp"
  groups=$NODES_GROUPS; own=""
  if pf_dns_has chatgpt.com; then groups="$groups $NODES_GPT"; own=gpt; fi
  for g in $groups; do
    domains=$(echo "${g#*:}" | tr ',' ' '); probe=${domains%% *}
    cur=$(pf_host_pinned "$probe")
    if [ -n "$cur" ]; then skip "${g%%:*}: $probe уже закреплён за $cur (дальше следит автосмена)"; continue; fi
    gn=$nodes; [ "${g%%:*}" = gpt ] && gn=$(NODES_PROBE=$NODES_GPT_PROBE nodes_list)
    if [ "$DRY" = 1 ] && ! command -v curl >/dev/null 2>&1; then   # curl comes with the real run
      dry "${g%%:*}: измерить узлы и закрепить самый быстрый"; continue
    fi
    best=$(sh "$tmp" --best "$probe" $gn)
    [ -n "$best" ] || { warn "${g%%:*}: ни один узел не ответил, закрепление пропущено"; continue; }
    for d in $domains; do pf_host_pin "$d" "$best" || fail "роутер не принял закрепление $d"; done
    ok "${g%%:*}: $(echo $domains) $ARROW $best (самый быстрый)"; CLI_CHANGED=1
  done
  save_if_changed
  sb_conf "$SB_DIR/nodes.conf" "автосмены узлов" "группы: $(echo $groups | sed 's/:[^ ]*//g')" <<EOF
# switchback: Claude (and ChatGPT) node auto-switch. Edit and it applies on the next minute.
GROUPS="$groups"
# groups with their own nodes and no QUIC rule needed; PROBE_<group>: the unpinned name to ask their DNS
OWN="$own"
PROBE_gpt=$NODES_GPT_PROBE
# ChatGPT's node normally answers in ~350 ms: its own "slow"
SLOW_gpt=800
PROBE=$NODES_PROBE
SLOW=300
SLOW_RUNS=5
DEAD_RUNS=3
GAIN=2
RETRY=15
# reserve nodes of another DNS service, asked over DoH (empty = off); they are used without a QUIC rule
EXTRA_DOH=$NODES_EXTRA_DOH
EOF
  install_file "$CRON1/claude-nodes" "автосмена узлов (проверка каждую минуту)" "$tmp" replace_nodes
}

nodes_script() {
  { cat <<'EOF'
#!/bin/sh
# Claude node auto-switch (switchback): every minute. Measures the node each Claude domain group is
# pinned to; if it is dead DEAD_RUNS runs in a row or slow SLOW_RUNS runs in a row, measures all the
# DNS service's nodes and re-pins the group to the fastest live node that has an active QUIC block rule
# (and is GAIN times faster). Nodes without such a rule are only reported.
# Test, changing nothing:  sh claude-nodes --dry       Fastest node:  sh claude-nodes --best DOMAIN IP...
export PATH=__PATH__
GROUPS="web:claude.ai,claudeusercontent.com api:api.anthropic.com,a-api.anthropic.com"
PROBE=claude.com; SLOW=300; SLOW_RUNS=5; DEAD_RUNS=3; GAIN=2; RETRY=15; EXTRA_DOH=""; OWN=""
[ -f __CONF__/nodes.conf ] && . __CONF__/nodes.conf
# the AI reserve (lib/ai.sh) moved a group to another path (Zapret DNS, a spare address, VPN): its pins are the
# reserve's then, and moving them to the DNS service's nodes would undo it. ai_away GROUP (web, api, gpt)
ai_away() {
  case $1 in gpt) a=gpt ;; *) a=claude ;; esac
  c=$(cat __STATE__/ai-path/cur.$a 2>/dev/null)
  [ -f __CONF__/ai.conf ] && [ -n "$c" ] && [ "$c" != dns ]
}
S=__STATE__/claude-nodes
LOG=$S/log
BOT=__BOT__
DRY=0; [ "$1" = "--dry" ] && { DRY=1; S=/tmp/claude-nodes-dry; LOG=/dev/null; }

# measure IP HOST [TRIES] -> median network time in ms, 9999 if most tries fail. Network time =
# TCP connect + server reply after TLS; the TLS handshake is left out (a slow router CPU spends the
# same ~0.6 s on it for every node). HEAD request: headers only.
measure() {
  tries=${3:-3}; ok=0; times=""; i=0
  while [ $i -lt "$tries" ]; do
    i=$((i+1))
    r=$(curl -s -I -o /dev/null --max-time 5 -w '%{http_code} %{time_connect} %{time_appconnect} %{time_starttransfer}' \
        --resolve "$2:443:$1" "https://$2/")
    set -- "$1" "$2" "$tries" $r
    [ -n "$4" ] && [ "$4" != "000" ] && { ok=$((ok+1)); times="$times $(echo "$5 $6 $7" | awk '{printf "%d", ($1 + $3 - $2) * 1000}')"; }
    set -- "$1" "$2" "$3"
  done
  [ $((ok * 2)) -le "$tries" ] && { echo 9999; return; }
  echo $times | tr ' ' '\n' | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'
}
if [ "$1" = "--best" ]; then   # used by the installer before anything is pinned
  host=$2; shift 2; best=""; bm=9999
  for ip in "$@"; do m=$(measure "$ip" "$host"); [ "$m" -lt "$bm" ] && { best=$ip; bm=$m; }; done
  echo "$best"; exit 0
fi
EOF
  script_lock
  echo "# ---- platform part ----"
  pf_nodes_funcs
  cat <<'EOF'
# ---- common part ----
# reserve nodes: the address the other DNS service gives for each group's domain (curl asks it over DoH)
extra_nodes() {
  [ -n "$EXTRA_DOH" ] || return 0
  for g in $GROUPS; do is_own "${g%%:*}" && continue; d=${g#*:}; d=${d%%,*}
    curl -s -o /dev/null --max-time 8 --doh-url "$EXTRA_DOH" -w '%{remote_ip}' "https://$d/" 2>/dev/null; echo
  done | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u
}
is_extra() { case " $(echo $XNODES) " in *" $1 "*) return 0 ;; esac; return 1; }
is_own() { case " $OWN " in *" $1 "*) return 0 ;; esac; return 1; }
svc() { case $1 in gpt) echo ChatGPT ;; *) echo Claude ;; esac; }
# what IP: "узел IP" for a node of the DNS service; a spare proxy of the AI reserve (lists/ai-*-proxies.nets,
# the service after "#") is named so: "узел 161.104.89.59 снова отвечает" was read as "GeoHide is back" (19.11.2026)
what() {
  l=$(cat __CONF__/app/lists/ai-*-proxies.nets 2>/dev/null | awk -v ip="$1/32" '$1 == ip {
        n = index($0, "#"); s = n ? substr($0, n + 1) : ""; gsub(/^[ \t]+|[ \t]+$/, "", s); print (s != "" ? s : "резерва"); exit }')
  if [ -n "$l" ]; then echo "прокси $l $1 (не узел DNS-сервиса)"; else echo "узел $1"; fi
}
ip4() { grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }
dns_ips() { nslookup "$1" 127.0.0.1 2>/dev/null | awk '/^Name:/ {n=1}
  n && /^Address/ { for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; break } }' | grep -v '^127\.'; }
# cand GROUP PROBE: the nodes a group may move to. Own groups: their DNS service's nodes (asked by the
# unpinned PROBE_<group> name) + the reserve service's + the pinned one; the others: the shared list.
cand() {
  if is_own "$1"; then
    eval "p=\${PROBE_$1:-$2}"
    { dns_ips "$p"; nd_pinned "$2"
      [ -n "$EXTRA_DOH" ] && curl -s -o /dev/null --max-time 8 --doh-url "$EXTRA_DOH" -w '%{remote_ip}' "https://$2/" 2>/dev/null; echo
    } | ip4 | sort -u
  else echo "$NODES"; fi
}
eligible() { is_own "$1" || nd_quic_ok "$2" || is_extra "$2"; }   # eligible GROUP IP
# is the internet there at all (ordinary sites that do not depend on the DNS service)
net_ok() {
  for u in https://ya.ru https://www.google.com; do
    c=$(curl -s -o /dev/null --max-time 6 -w '%{http_code}' "$u" 2>/dev/null)
    [ -n "$c" ] && [ "$c" != 000 ] && return 0
  done
  return 1
}
nodes() {
  { nslookup "$PROBE" 127.0.0.1 2>/dev/null | awk '/^Name:/ {n=1}
      n && /^Address/ { for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; break } }'
    for g in $GROUPS; do is_own "${g%%:*}" && continue; d=${g#*:}; nd_pinned "${d%%,*}"; done; } | grep -E '^[0-9.]+$' | grep -v '^127\.' | sort -u
}
group() {   # group NAME "DOMAINS" (the first domain is measured)
  name=$1; domains=$2; probe=${domains%% *}
  cur=$(nd_pinned "$probe")
  [ -z "$cur" ] && { log "$name: $probe is not pinned, skip"; return; }
  ms=$(measure "$cur" "$probe" 1)    # routine check: 1 request
  eval "slow=\${SLOW_$name:-$SLOW}"     # a group may have its own "slow" (ChatGPT answers slower than Claude)
  bad=$S/$name.bad                   # "slow N" or "dead N": runs in a row
  if [ "$ms" -le "$slow" ] && [ $DRY = 0 ]; then
    [ -f "$bad" ] && log "$name: $cur ${ms}ms ok again ($(cat "$bad") reset)"
    # there was an alert: say it is over, so nobody keeps worrying
    [ -f "$S/$name.dead.sent" ] && send "$(svc "$name") ($name): $(what "$cur") снова отвечает (${ms} мс). Делать ничего не нужно."
    rm -f "$bad" "$S/$name.dead.sent" "$S/$name.last_scan"; return
  fi
  [ $DRY = 1 ] && echo "$name: current $cur ${ms}ms (dry run: full scan anyway)"
  kind=slow; need=$SLOW_RUNS; [ "$ms" = 9999 ] && { kind=dead; need=$DEAD_RUNS; }
  set -- $(cat "$bad" 2>/dev/null)
  if [ "$1" = "$kind" ]; then n=$(($2 + 1)); else n=1; fi
  if [ $n -lt "$need" ] && [ $DRY = 0 ]; then
    echo "$kind $n" > "$bad"; log "$name: $cur ${ms}ms $kind ($n/$need, wait)"; return
  fi
  # the last full scan found nothing better: do not rescan every few minutes
  if [ -f "$S/$name.last_scan" ] && [ $((now - $(cat "$S/$name.last_scan"))) -lt $((RETRY * 60)) ] && [ $DRY = 0 ]; then
    log "$name: $cur ${ms}ms $kind, last scan less than $RETRY min ago found nothing better, wait"; return
  fi
  [ "$ms" -le "$slow" ] && kind=ok      # dry run of a healthy node
  log "$name: $cur ${ms}ms $kind, scanning"
  best=""; bestms=9999; noquic=""
  for ip in $(cand "$name" "$probe"); do
    [ "$ip" = "$cur" ] && continue
    m=$(measure "$ip" "$probe"); log "  $ip ${m}ms"
    [ "$m" -lt 9999 ] || continue
    if eligible "$name" "$ip"; then [ "$m" -lt "$bestms" ] && { best=$ip; bestms=$m; }
    else noquic="$noquic $ip(${m}ms)"; fi
  done
  # repeated once a day, not just once ever
  if [ -n "$noquic" ] && { [ ! -f "$S/noquic.sent" ] || [ $((now - $(cat "$S/noquic.sent"))) -gt 86400 ]; }; then
    send "Claude: есть живые узлы, но они не используются — для них нет правила запрета QUIC:$noquic. Чтобы использовать, добавьте правило (запрет UDP 443) в настройках роутера."
    [ $DRY = 0 ] && echo "$now" > "$S/noquic.sent"
  fi
  if [ -z "$best" ] || [ $((bestms * GAIN)) -gt "$ms" ]; then
    log "$name: no better node (best: ${best:-none} ${bestms}ms)"
    [ $DRY = 0 ] && { rm -f "$bad"; echo "$now" > "$S/$name.last_scan"; }
    if [ "$ms" = 9999 ] && [ ! -f "$S/$name.dead.sent" ]; then
      if ! net_ok; then
        # nothing answers, ordinary sites neither: the internet is down, not the node (seen 2026-11-09 for 3 min)
        log "$name: no node answers and ordinary sites do not either: the internet is down, no alert"
      else
        if [ -z "$best" ] && [ -z "$noquic" ]; then
          send "✗ $(svc "$name") ($name) не отвечает ни через один узел, хотя интернет есть: похоже, сбой у самого сервиса или его DNS. Проверяю каждую минуту, напишу, когда заработает."
        else
          send "✗ $(svc "$name") ($name): $(what "$cur") не отвечает, а замены с правилом QUIC нет. Проверяю каждую минуту."
        fi
        [ $DRY = 0 ] && touch "$S/$name.dead.sent"
      fi
    fi
    return
  fi
  [ $DRY = 1 ] && { echo "WOULD SWITCH $name: $cur (${ms}ms) -> $best (${bestms}ms)"; return; }
  for d in $domains; do nd_pin "$d" "$best"; done
  nd_commit
  rm -f "$bad" "$S/$name.dead.sent" "$S/$name.last_scan"
  log "$name: SWITCHED $cur (${ms}ms) -> $best (${bestms}ms)"
  # ChatGPT's nodes die several times a day (seen on a real router: 4 switches a day): a switch that worked
  # is not worth a message; it is in the log and in the weekly digest. Claude's are rare: still reported
  [ "$name" = gpt ] || send "$(svc "$name") ($name): перешёл на более быстрый адрес — $(what "$cur") (${ms} мс) → $(what "$best") (${bestms} мс). Делать ничего не нужно."
}

nd_load
XNODES=$(extra_nodes)
NODES=$( { nodes; for ip in $XNODES; do echo "$ip"; done; } | sort -u)
[ $DRY = 1 ] && echo "nodes:" $NODES
[ $DRY = 1 ] && [ -n "$XNODES" ] && echo "reserve nodes (no QUIC rule needed):" $XNODES
# for the bot: "--list" every node with its time; "--pin GROUP IP|best" pins a group by hand
if [ "$1" = --list ]; then
  for ip in $NODES; do
    m=$(measure "$ip" claude.ai)
    if is_extra "$ip"; then k=reserve; elif nd_quic_ok "$ip"; then k=quic; else k=noquic; fi
    on=""; for g in $GROUPS; do d=${g#*:}; d=${d%%,*}; [ "$(nd_pinned "$d")" = "$ip" ] && on="$on ${g%%:*}"; done
    echo "$ip $m $k$on"
  done
  exit 0
fi
if [ "$1" = --pin ]; then
  domains=""; for g in $GROUPS; do [ "${g%%:*}" = "$2" ] && domains=$(echo "${g#*:}" | tr ',' ' '); done
  [ -n "$domains" ] || { echo "нет группы $2"; exit 1; }
  if ai_away "$2"; then
    echo "$2: сейчас путь выбирает резерв для нейросетей ($(cat __STATE__/ai-path/cur.$a)) — узел не меняю. Вернуть DNS-сервис: /ai → «Авто» или sh install.sh ai via dns"
    exit 1
  fi
  probe=${domains%% *}; want=$3
  if [ "$want" = best ]; then
    want=""; wm=9999
    for ip in $(cand "$2" "$probe"); do
      eligible "$2" "$ip" || continue
      m=$(measure "$ip" "$probe"); [ "$m" -lt "$wm" ] && { want=$ip; wm=$m; }
    done
    [ -n "$want" ] || { echo "ни один узел не отвечает — ничего не меняю"; exit 1; }
  else
    case " $(echo $(cand "$2" "$probe")) " in *" $want "*) ;; *) echo "$want нет среди узлов (/node — список)"; exit 1 ;; esac
    wm=$(measure "$want" "$probe")
    [ "$wm" -lt 9999 ] || { echo "$want не отвечает — ничего не меняю"; exit 1; }
  fi
  [ "$(nd_pinned "$probe")" = "$want" ] && { echo "$2: уже закреплён за $want (${wm} мс)"; exit 0; }
  for d in $domains; do nd_pin "$d" "$want"; done
  nd_commit
  rm -f "$S/$2.bad" "$S/$2.dead.sent" "$S/$2.last_scan"
  log "$2: PINNED by hand -> $want (${wm}ms)"
  echo "$2: $(svc "$2") закреплён за $want (${wm} мс)"
  exit 0
fi
for g in $GROUPS; do
  if ai_away "${g%%:*}"; then log "${g%%:*}: the AI reserve holds it ($(cat __STATE__/ai-path/cur.$a)), skip"; continue; fi
  group "${g%%:*}" "$(echo "${g#*:}" | tr ',' ' ')"
done
exit 0
EOF
  } | script_subst
}
