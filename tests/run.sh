#!/bin/sh
# Automatic tests of install.sh on fake routers (no real router is touched).
#   sh tests/run.sh              all of them: the groups run side by side, at most 4 at a time, at the lowest
#                                priority, so the computer stays responsive (SB_JOBS=1: one after another;
#                                SB_NICE=0: the normal priority)
#   sh tests/run.sh vless ai     only these groups (the same: TESTS=vless,ai sh tests/run.sh)
#   sh tests/run.sh --list       the groups and what they test
# Uses dash if present (closest to BusyBox ash on routers). Each case builds a fresh fake Keenetic /opt or
# OpenWrt root in a temp folder. Every group has a temp folder of its own, also for the files the scripts
# put in "/tmp" (SB_TMP), so groups running side by side never see each other's files.
# A group is every section whose title line ends in "[NAME]": its sections run in the order of this file,
# on their own (a group never uses what another one made). A new section needs a group: an old name or a new one.

HERE=${SB_T_HERE:-$(cd "$(dirname "$0")" && pwd)}
SRC=$(cd "$HERE/.." && pwd)
SH=$(command -v dash || command -v sh)

# ---- the runner: picks the groups, makes a script of each and runs them (the checks start further down) ----
if [ -z "$SB_T_GROUP" ]; then
  T=$HERE/run.sh
  all=$(sed -n 's/^# ---------- .* \[\([a-z0-9-]*\)\]$/\1/p' "$T" | awk '!seen[$0]++')
  if [ "$1" = --list ] || [ "$1" = -l ]; then
    awk '/^# ---------- .* \[[a-z0-9-]*\]$/ { g = $NF; gsub(/[][]/, "", g); t = $0; sub(/^# -+ /, "", t); sub(/ -+ \[.*$/, "", t)
           if (!(g in n)) { o[++k] = g; f[g] = t }; n[g]++ }
         END { for (i = 1; i <= k; i++) { g = o[i]; printf "%-10s %s%s\n", g, f[g], (n[g] > 1 ? "  (+ ещё разделов: " n[g] - 1 ")" : "") } }' "$T"
    exit 0
  fi
  want=$(echo $* $TESTS | tr ',' ' ')
  for g in $want; do
    case " $(echo $all) " in *" $g "*) ;; *) echo "Нет группы «$g». Группы: $(echo $all)"; exit 2 ;; esac
  done
  # all of them: the longest first, so that the last ones to finish are short
  [ -n "$want" ] || want=$(for g in ai vless bot vsub openwrt failover $all; do echo "$g"; done | awk '!seen[$0]++')
  n=$(echo $want | wc -w); jobs=${SB_JOBS:-4}; [ "$jobs" -gt "$n" ] && jobs=$n
  # the lowest priority: on Windows "nice -n 19" is the Idle class, and (measured 21.11.2026) Idle starts processes
  # 2 times faster than "below normal" (nice 5-11); SB_NICE=0: the normal priority
  NICE=""; [ "$SB_NICE" = 0 ] || ! nice -n 19 true 2>/dev/null || NICE="nice -n 19"
  RUN=$(mktemp -d "${TMPDIR:-/tmp}/sb-tests.XXXXXX"); start=$(date +%s)
  # a script per group: the start of this file (the helpers), the group's sections, the end (the result)
  awk -v dir="$RUN" -v want=" $(echo $want) " '
    /^# ---------- .* \[[a-z0-9-]*\]$/ { g = $NF; gsub(/[][]/, "", g); part = 1 }
    /^# ========== the result/ { part = 2 }
    part == 0 { head = head $0 "\n" } part == 1 { body[g] = body[g] $0 "\n" } part == 2 { tail = tail $0 "\n" }
    END { for (g in body) if (index(want, " " g " ")) printf "%s%s%s", head, body[g], tail > (dir "/" g ".sh") }' "$T"
  export SB_T_HERE=$HERE
  worker() {   # takes the next group nobody took yet (mkdir is atomic), runs it, says how it went
    for g in $want; do
      mkdir "$RUN/$g.taken" 2>/dev/null || continue
      mkdir -p "$RUN/$g.tmp"; s=$(date +%s)
      TMPDIR=$RUN/$g.tmp SB_T_GROUP=$g $NICE "$SH" "$RUN/$g.sh" > "$RUN/$g.log" 2>&1; rc=$?
      set -- $(sed -n 's/^Тесты: прошло \([0-9]*\), не прошло \([0-9]*\).*/\1 \2/p' "$RUN/$g.log")
      grep '^  FAIL' "$RUN/$g.log"
      [ $# = 2 ] || { echo "  FAIL: группа $g оборвалась (код $rc):"; tail -n 5 "$RUN/$g.log"; set -- 0 1; }
      echo "$1 $2" > "$RUN/$g.sum"
      printf '%-10s прошло %4s, не прошло %s  (%s с)\n' "$g" "$1" "$2" "$(( $(date +%s) - s ))"
    done
  }
  i=0; while [ $i -lt "$jobs" ]; do worker & i=$((i + 1)); done; wait
  P=0; F=0
  for g in $want; do read p f < "$RUN/$g.sum"; P=$((P + p)); F=$((F + f)); done
  echo ""
  echo "Тесты: прошло $P, не прошло $F  (оболочка: $SH; групп $n, одновременно $jobs; $(( $(date +%s) - start )) с)"
  if [ "$F" = 0 ]; then rm -rf "$RUN"; else echo "Журналы групп (ГРУППА.log) и файлы упавших проверок: $RUN"; fi
  [ "$F" = 0 ]; exit
fi
# ---- the checks: a group's script starts here (SB_T_GROUP is its name) ----

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sb-tests.XXXXXX")
SB_TMP=$WORK/tmp; mkdir -p "$SB_TMP"; export SB_TMP   # instead of /tmp in lib/vsub.sh, lib/wireguard.sh
PASS=0; FAILED=0
TOKEN=123456789:AAFakeTokenForTestsOnly_abcdefghijklmnop
export SB_WG_TRIES=1           # the WireGuard traffic check waits 5 s per try: one try in tests
export SB_T_HOLD=0             # the AI reserve's anti-flap delays: off, except in the checks made for them
export SB_T_NAP=1              # the pauses between the reserve's tries: none (the same tries in the same order)

check() {   # check "description" COMMAND...
  d=$1; shift
  if "$@"; then PASS=$((PASS+1)); else FAILED=$((FAILED+1)); echo "  FAIL: $CASE: $d"; fi
}
# helpers used as COMMAND in check (first arg is the description, ignored)
has()     { grep -qF -- "$3" "$2"; }           # has "desc" FILE TEXT
hasnt()   { ! grep -qF -- "$3" "$2" 2>/dev/null; }
exists()  { [ -e "$2" ]; }
missing() { [ ! -e "$2" ]; }
equal()   { [ "$2" = "$3" ]; }
differ()  { [ "$2" != "$3" ]; }

# a fresh fake router for each case: a copy of the one built once per run (one process instead of ~40)
keenetic() {
  CASE=$1; K=$WORK/$1; [ -d "$WORK/.keenetic" ] || sh "$HERE/fake-keenetic.sh" "$WORK/.keenetic" >/dev/null
  rm -rf "$K"; cp -r "$WORK/.keenetic" "$K"
}
sb_k() {    # run install.sh against the fake Keenetic $K; output in $K/out, exit code in $RC
  SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$SRC/install.sh" "$@" > "$K/out" 2>&1; RC=$?
}
openwrt() {
  CASE=$1; R=$WORK/$1; [ -d "$WORK/.openwrt" ] || sh "$HERE/fake-openwrt.sh" "$WORK/.openwrt" >/dev/null
  rm -rf "$R"; cp -r "$WORK/.openwrt" "$R"
}
sb_o() {
  SB_ROOT=$R SB_OPT=$R SB_TEST=1 SB_PLATFORM=openwrt "$SH" "$SRC/install.sh" "$@" > "$R/out" 2>&1; RC=$?
}
ev_count() { grep -c "^@@sb	$2" "$1"; }    # ev_count FILE EVENT
# shared by several groups: a made-up WireGuard key; bot messages (getUpdates) and one run of the bot
PRIV=aFakePrivateKeyForTestsOnly0123456789abcdE=
botmsg() { n=0; out='{"ok":true,"result":['; for m; do n=$((n+1)); [ $n -gt 1 ] && out="$out,"; out="$out{\"update_id\":$((100+n)),\"message\":{\"chat\":{\"id\":-100},\"text\":\"$m\"}}"; done; printf '%s]}\n' "$out" > "$K/updates"; }
bot1() { : > "$K/curl.log"; SB_OPT=$K SB_BOT_ONCE=1 SB_TEST=1 SB_PLATFORM=keenetic SB_MEMINFO="$K/meminfo-ok" "$SH" "$K/etc/cron.1min/sb-bot" > /dev/null 2>&1; }
botdoc() { printf '{"ok":true,"result":[{"update_id":301,"message":{"chat":{"id":-100},"document":{"file_name":"%s","mime_type":"x","thumbnail":{"file_id":"THUMB","file_unique_id":"T1","width":90},"file_id":"F1","file_unique_id":"U1","file_size":300}}}]}\n' "$1" > "$K/updates"; }

# ---------- doctor with progress events ---------- [install]
keenetic doctor
sb_k doctor --progress
check "doctor event"           has x "$K/out" "@@sb	doctor	"
check "end event"              has x "$K/out" "@@sb	end	$RC"
check "items as events"        has x "$K/out" "@@sb	item	ok	"
check "no colour codes"        hasnt x "$K/out" "$(printf '\033')"
check "auto-update noted"      has x "$K/out" "включено автообновление KeeneticOS"

# ---------- answers file: bad input is refused before anything happens ---------- [install]
keenetic badkey
printf 'profle=full\n' > "$K/a"; sb_k install --answers "$K/a"
check "unknown key -> exit 2"  equal x "$RC" 2
check "says which key"         has x "$K/out" "неизвестный ключ profle"
printf 'just-a-token-pasted\n' > "$K/a"; sb_k install --answers "$K/a"
check "line without = -> 2"    equal x "$RC" 2
check "value not echoed"       hasnt x "$K/out" "just-a-token-pasted"

# ---------- dry run with answers: nothing changes ---------- [install]
keenetic dry
cp "$K/etc/nfqws2/nfqws2.conf" "$K/conf.before"
cat > "$K/a" <<EOF
profile=full
dns_claude=y
dns_claude_ip=5.6.7.8
dns_claude_sni=dns.claude.example
vpn_iface=Wireguard0
bot_token=$TOKEN
EOF
sb_k install --dry-run --progress --answers "$K/a"
check "exit 0"                 equal x "$RC" 0
check "8 steps"                equal x "$(ev_count "$K/out" step)" 8
check "plan event"             has x "$K/out" "@@sb	plan	https	zapret	dns	nodes	vpn	meta	watchdog	failover"
check "conf untouched"         equal x "$(cat "$K/conf.before")" "$(cat "$K/etc/nfqws2/nfqws2.conf")"
check "no state file"          missing x "$K/etc/switchback/state"
check "only show commands"     equal x "$(grep -v ' show ' "$K/ndmc.log" | wc -l | tr -d ' ')" 0
check "token not printed"      hasnt x "$K/out" "$TOKEN"

# ---------- real install from stdin answers, then uninstall ---------- [install]
keenetic full
printf 'src/gz entware http://bin.entware.net/mipselsf-k3.4\n' > "$K/etc/opkg.conf"
cp "$K/etc/nfqws2/nfqws2.conf" "$K/conf.before"
printf 'profile=full\r\nzapret_exclude_policy=nfqws\r\ndns_claude=y\r\ndns_claude_ip=5.6.7.8\r\ndns_claude_sni=dns.claude.example\r\nvpn_iface=Wireguard0\r\nbot_token=%s\r\nbot_chat=-100\r\n' "$TOKEN" |
  SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$SRC/install.sh" install --progress --answers - > "$K/out" 2>&1; RC=$?
check "exit 0"                 equal x "$RC" 0
check "CRLF answers accepted"  has x "$K/etc/nfqws2/nfqws2.conf" 'POLICY_NAME="nfqws"'
check "video servers: own ways" has x "$K/etc/nfqws2/nfqws2.conf" 'NFQWS_ARGS_CUSTOM="--filter-tcp=443 --filter-l7=tls --hostlist-domains=googlevideo.com'
check "QUIC: the working way"  has x "$K/etc/nfqws2/nfqws2.conf" 'NFQWS_ARGS_QUIC="--filter-udp=443 --filter-l7=quic <HOSTLIST_NOAUTO> --payload=quic_initial --lua-desync=fake:blob=quic_initial:ip_autottl=-2,3-20:repeats=10"'
check "QUIC: no line left"     hasnt x "$K/etc/nfqws2/nfqws2.conf" "                 --payload=quic_initial"
check "DNS for Claude added"   has x "$K/ndmc.log" "dns-proxy tls upstream 5.6.7.8 sni dns.claude.example domain claude.ai"
check "ChatGPT not asked -> skipped" hasnt x "$K/ndmc.log" "domain openai.com"
check "Telegram routes"        has x "$K/ndmc.log" "ip route 149.154.160.0 255.255.240.0 Wireguard0 auto"
check "bot.conf written"       has x "$K/etc/watchdog/bot.conf" "CHAT=-100"
touch "$K/probe"; chmod 600 "$K/probe"   # Windows (NTFS) cannot store such permissions: check only where it can
[ "$(stat -c %a "$K/probe" 2>/dev/null)" = 600 ] && check "bot.conf private" equal x "$(stat -c %a "$K/etc/watchdog/bot.conf")" 600
check "token not printed"      hasnt x "$K/out" "$TOKEN"
check "token not in log"       hasnt x "$K/var/log/switchback.log" "$TOKEN"
check "backup event"           has x "$K/out" "@@sb	backup	"
check "result events"          equal x "$(ev_count "$K/out" result)" 8
check "end 0"                  has x "$K/out" "@@sb	end	0"
printf 'uninstall_confirm=y\n' > "$K/u"
sb_k uninstall --answers "$K/u"
check "uninstall exit 0"       equal x "$RC" 0
check "zapret conf restored"   equal x "$(cat "$K/conf.before")" "$(cat "$K/etc/nfqws2/nfqws2.conf")"
check "DNS removed"            has x "$K/ndmc.log" "ndmc -c no dns-proxy tls upstream 5.6.7.8"
check "not the form KeeneticOS refuses" hasnt x "$K/ndmc.log" "no dns-proxy tls upstream 5.6.7.8 sni"
check "bot.conf removed"       missing x "$K/etc/watchdog/bot.conf"
check "state archived"         missing x "$K/etc/switchback/state"

# ---------- KeeneticOS removes a DoT server with all its domains: the others are put back (real router, 2026-11-11) ---------- [dns]
keenetic dnsdel
printf 'profile=custom\nmodules=dns\ndns_claude=y\ndns_claude_ip=5.6.7.8\ndns_claude_sni=dns.claude.example\n' > "$K/a"
sb_k install --answers "$K/a"
check "install exit 0"         equal x "$RC" 0
# the router's settings now hold our four domains and somebody else's one on the same server
for d in claude.ai claude.com claudeusercontent.com anthropic.com keep.example; do
  echo "    tls upstream 5.6.7.8 sni dns.claude.example domain $d"; done > "$K/rc.extra"
: > "$K/ndmc.log"; printf 'uninstall_confirm=y\n' > "$K/u"
sb_k uninstall --answers "$K/u"
check "uninstall exit 0"       equal x "$RC" 0
awk '/no dns-proxy tls upstream 5.6.7.8/ {n=NR} {l[NR]=$0} END {for (i=n+1; i<=NR; i++) print l[i]}' "$K/ndmc.log" > "$K/after-last"
check "foreign domain put back" has x "$K/after-last" "dns-proxy tls upstream 5.6.7.8 sni dns.claude.example domain keep.example"
check "our domains stay removed" hasnt x "$K/after-last" "domain claude"
check "our last one too"       hasnt x "$K/after-last" "domain anthropic.com"
check "other server untouched" hasnt x "$K/ndmc.log" "no dns-proxy tls upstream 1.2.3.4"

# ---------- another DNS service for a domain that already has one: replaced, not skipped ---------- [dns]
# (the fake router already has "1.2.3.4 dns.example" for chatgpt.com)
keenetic dnsswap
printf 'profile=custom\nmodules=dns\ndns_chatgpt=y\ndns_chatgpt_ip=5.6.7.8\ndns_chatgpt_sni=new.example\n' > "$K/a"
sb_k install --answers "$K/a"
check "swap exit 0"            equal x "$RC" 0
check "old record removed"     has x "$K/ndmc.log" "ndmc -c no dns-proxy tls upstream 1.2.3.4"
check "new record added"       has x "$K/ndmc.log" "dns-proxy tls upstream 5.6.7.8 sni new.example domain chatgpt.com"
check "removed before added (limit of records)" equal x "$(grep -n 'no dns-proxy tls upstream 1.2.3.4\|5.6.7.8 sni new.example domain chatgpt.com' "$K/ndmc.log" | head -1 | grep -c 'no dns-proxy')" 1
check "the rest added as usual" has x "$K/ndmc.log" "dns-proxy tls upstream 5.6.7.8 sni new.example domain openai.com"
check "journal knows the new one" has x "$K/etc/switchback/state" "dns 5.6.7.8 new.example chatgpt.com"
check "says it was replaced"   has x "$K/out" "chatgpt.com: DNS-сервис заменён"
check "hint about the node"    has x "$K/out" "/node gpt best"
keenetic dnssame
printf 'profile=custom\nmodules=dns\ndns_chatgpt=y\ndns_chatgpt_ip=1.2.3.4\ndns_chatgpt_sni=dns.example\n' > "$K/a"
sb_k install --answers "$K/a"
check "same service: left alone" has x "$K/out" "chatgpt.com уже настроен"
check "same service: nothing removed" hasnt x "$K/ndmc.log" "no dns-proxy"
# the router refuses the next record: this run is rolled back and the old service is put back
keenetic dnsswapfail
printf 'profile=custom\nmodules=dns\ndns_chatgpt=y\ndns_chatgpt_ip=9.9.9.9\ndns_chatgpt_sni=bad.example\n' > "$K/a"
sb_k install --answers "$K/a"
check "failure: exit not 0"    equal x "$([ "$RC" != 0 ] && echo bad)" bad
check "failure: old service back" equal x "$(grep 'domain chatgpt.com' "$K/ndmc.log" | tail -1)" "ndmc -c dns-proxy tls upstream 1.2.3.4 sni dns.example domain chatgpt.com"
# OpenWrt: each service has its own DoH proxy; another address replaces the old one, the domains stay as they are
openwrt owdns
printf 'profile=custom\nmodules=dns\ndns_chatgpt=y\ndns_chatgpt_doh=https://one.example/dns-query\n' > "$R/a"
sb_o install --answers "$R/a"
check "first service exit 0"   equal x "$RC" 0
# the package took over all DNS on install (VM 2026-11-17): only our domains may go to DoH, the rest as before
check "no takeover: noresolv"  hasnt x "$R/uci.db" "dhcp.@dnsmasq[0].noresolv"
check "no takeover: servers"   hasnt x "$R/uci.db" "127.0.0.1#5053"
check "no takeover: backup"    hasnt x "$R/uci.db" "doh_backup_noresolv"
check "own server kept"        has x "$R/uci.db" "/lan.example/192.168.1.5"
check "our domain to DoH"      has x "$R/uci.db" "/chatgpt.com/127.0.0.1#5153"
check "stopped, then started"  equal x "$(grep -E 'https-dns-proxy (stop|start)' "$R/svc.log" | tail -2 | tr '\n' ' ')" "https-dns-proxy stop https-dns-proxy start "
printf 'profile=custom\nmodules=dns\ndns_chatgpt=y\ndns_chatgpt_doh=https://two.example/dns-query\n' > "$R/a"; : > "$R/svc.log"
sb_o install --answers "$R/a"
check "second service exit 0"  equal x "$RC" 0
check "new address in place"   has x "$R/uci.db" "$(printf 'https-dns-proxy.sb_chatgpt.resolver_url\thttps://two.example/dns-query')"
check "old address gone"       hasnt x "$R/uci.db" "one.example"
check "DoH proxy restarted"    has x "$R/svc.log" "https-dns-proxy stop"
check "domains left as they are" has x "$R/out" "chatgpt.com уже настроен"

# ---------- the router's own connections go past zapret (kernel memory leak, real Keenetic 2026-11-11) ---------- [zapret]
# a fake iptables only (SB_IPT): "-S" prints zapret's rules and what was added, "-I"/"-D" are written down
keenetic own
cat > "$K/ipt" <<'EOF'
#!/bin/sh
shift 3
case $1 in
  -S) cat "$IPT_DIR/rules" 2>/dev/null; sed 's/^/-A /' "$IPT_DIR/added" 2>/dev/null ;;
  -C) shift; grep -qxF -- "$*" "$IPT_DIR/added" 2>/dev/null ;;
  -I) shift; echo "$*" >> "$IPT_DIR/added" ;;
  -D) shift; echo "$*" >> "$IPT_DIR/deleted" ;;
esac
EOF
Z='-p tcp -m mark ! --mark 0x40000000/0x40000000 -m multiport --dports 80,443 -j NFQUEUE --queue-num 300 --queue-bypass'
printf -- '-A nfqws_post -o eth2.2 %s\n-A nfqws_post -o eth2.2 %s\n-A nfqws_pre -i eth2.2 %s\n' "$Z" "$Z" "$Z" > "$K/rules"
OWN=$K/etc/ndm/netfilter.d/101-switchback-own.sh
OWNRULE='OUTPUT -o eth2.2 -p tcp ! --sport 61000:61099 -j MARK --or-mark 0x40000000'
printf 'profile=custom\nmodules=zapret\nno_quic=n\n' > "$K/a"
IPT_DIR=$K SB_IPT="sh $K/ipt" SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$SRC/install.sh" install --answers "$K/a" > "$K/out" 2>&1; RC=$?
check "install exit 0"         equal x "$RC" 0
check "hook installed"         exists x "$OWN"
check "no QUIC rule when declined" missing x "$K/etc/ndm/netfilter.d/102-switchback-noquic.sh"
check "rule added at install"  equal x "$(cat "$K/added" 2>/dev/null)" "$OWNRULE"
IPT_DIR=$K SB_IPT="sh $K/ipt" table=mangle type=iptables sh "$OWN"
check "rule not added twice"   equal x "$(grep -c . "$K/added")" 1
: > "$K/added"
IPT_DIR=$K SB_IPT="sh $K/ipt" table=nat type=iptables sh "$OWN"
IPT_DIR=$K SB_IPT="sh $K/ipt" table=mangle type=ip6tables sh "$OWN"
check "other tables left alone" equal x "$(cat "$K/added")" ""
IPT_DIR=$K SB_IPT="sh $K/ipt" table=mangle type=iptables sh "$OWN"
check "rule back after a firewall rebuild" equal x "$(cat "$K/added")" "$OWNRULE"
: > "$K/added"; mv "$K/rules" "$K/rules.off"
IPT_DIR=$K SB_IPT="sh $K/ipt" sh "$OWN"
check "no zapret rules -> nothing added" equal x "$(cat "$K/added")" ""
mv "$K/rules.off" "$K/rules"; echo "$OWNRULE" > "$K/added"
printf 'uninstall_confirm=y\n' > "$K/u"
IPT_DIR=$K SB_IPT="sh $K/ipt" SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$SRC/install.sh" uninstall --answers "$K/u" > "$K/out" 2>&1; RC=$?
check "uninstall exit 0"       equal x "$RC" 0
check "hook removed"           missing x "$OWN"
check "rule removed"           equal x "$(cat "$K/deleted" 2>/dev/null)" "$OWNRULE"
# ---------- devices at home do not use QUIC (the YouTube app on a TV, real Keenetic 2026-11-15) ---------- [zapret]
keenetic noquic
cp "$WORK/own/ipt" "$K/ipt"; cp "$WORK/own/rules" "$K/rules"
QH=$K/etc/ndm/netfilter.d/102-switchback-noquic.sh
QRULE='FORWARD -o eth2.2 -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable'
printf 'profile=custom\nmodules=zapret\n' > "$K/a"
IPT_DIR=$K SB_IPT="sh $K/ipt" SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$SRC/install.sh" install --answers "$K/a" > "$K/out" 2>&1; RC=$?
check "install exit 0"         equal x "$RC" 0
check "QUIC hook installed"    exists x "$QH"
check "QUIC rule added"        has x "$K/added" "$QRULE"
IPT_DIR=$K SB_IPT="sh $K/ipt" table=filter type=iptables sh "$QH"
check "QUIC rule not twice"    equal x "$(grep -c 'dport 443 -j REJECT' "$K/added")" 1
: > "$K/added"
IPT_DIR=$K SB_IPT="sh $K/ipt" table=mangle type=iptables sh "$QH"
check "QUIC: other tables left alone" equal x "$(cat "$K/added")" ""
IPT_DIR=$K SB_IPT="sh $K/ipt" table=filter type=iptables sh "$QH"
check "QUIC rule back after a rebuild" equal x "$(cat "$K/added")" "$QRULE"
printf 'uninstall_confirm=y\n' > "$K/u"
IPT_DIR=$K SB_IPT="sh $K/ipt" SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$SRC/install.sh" uninstall --answers "$K/u" > "$K/out" 2>&1; RC=$?
check "QUIC hook removed"      missing x "$QH"
check "QUIC rule removed"      has x "$K/deleted" "$QRULE"
# requests that must go through zapret keep a marked local port; the every-minute ones do not
check "tune goes through zapret"   has x "$SRC/lib/tune.sh" 'curl $ZCURL'
check "bot /check through zapret"  has x "$SRC/lib/bot.sh" 'curl --local-port 61000-61099'
check "node checks past zapret"    hasnt x "$SRC/lib/nodes.sh" 'local-port'

# ---------- answers without bot token: watchdog skipped, not a failure ---------- [install]
keenetic notoken
printf 'profile=custom\nmodules=watchdog\n' > "$K/a"
sb_k install --answers "$K/a"
check "exit 0"                 equal x "$RC" 0
check "explains the skip"      has x "$K/out" "нет ни токена бота"
check "no watchdog installed"  missing x "$K/etc/cron.5mins/watchdog"

# ---------- found on the real Keenetic (2026-11-07) ---------- [install]
# answers from standard input are really used; a network already routed through another
# connection is left alone; the default connection is the one Telegram already uses
keenetic real-1
printf 'profile=vpn\nvpn_iface=Wireguard1\n' |
  SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$SRC/install.sh" install --dry-run --answers - > "$K/out" 2>&1
check "stdin answer used"      has x "$K/out" "Через какое подключение пускать Telegram? [Wireguard0] Wireguard1"
check "hand-made route kept"   has x "$K/out" "91.108.56.0 уже идёт через Wireguard0 — не трогаю"
check "no duplicate route"     hasnt x "$K/out" "ip route 91.108.56.0 255.255.252.0 Wireguard1"
check "dead tunnel warned"     has x "$K/out" "Wireguard1 сейчас не подключено"
keenetic real-2
SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$SRC/install.sh" doctor --progress > "$K/out" 2>&1
check "alive tunnel shown"     has x "$K/out" "Wireguard0: подключено, только для выбранных адресов"
check "vpn event with state"   has x "$K/out" "@@sb	vpn	Wireguard0	up"
check "telegram route found"   has x "$K/out" "@@sb	tgvia	Wireguard0"

# ---------- failover: the module installs it; the script switches, and handles the edge cases ---------- [failover]
keenetic failover
printf 'profile=custom\nmodules=failover\nfailover_tunnels=Wireguard0 Wireguard9 Wireguard1\n' > "$K/a"
sb_k install --answers "$K/a"
FO=$K/etc/cron.1min/wg-failover
check "installed"              exists x "$FO"
check "config: known only"     has x "$K/etc/switchback/failover.conf" 'TUNNELS="Wireguard0 Wireguard1"'
check "unknown tunnel warned"  has x "$K/out" "нет подключения Wireguard9"
check "paths filled in"        hasnt x "$FO" "__"
sed -i 's/^DEAD_RUNS=.*/DEAD_RUNS=1/; s/^UP_WAIT=.*/UP_WAIT=5/' "$K/etc/switchback/failover.conf"
fo() { SB_OPT=$K "$SH" "$FO" "$@" > "$K/fo.out" 2>&1; }
# active (Wireguard0) is fine: nothing happens
: > "$K/ndmc.log"; fo
check "healthy: no changes"    equal x "$(grep -cv ' show ' "$K/ndmc.log")" 0
# active dies, the standby answers: routes move to it, the old one goes down
touch "$K/wg-dead-Wireguard0" "$K/wg-alive-Wireguard1"; : > "$K/ndmc.log"; fo
check "switched"               has x "$K/ndmc.log" "ip route 91.108.56.0 255.255.252.0 Wireguard1 auto"
check "host route moved"       has x "$K/ndmc.log" "ip route 1.1.1.1 255.255.255.255 Wireguard1 auto"
check "old route removed"      has x "$K/ndmc.log" "no ip route 91.108.56.0 255.255.252.0 Wireguard0"
check "old tunnel down"        has x "$K/ndmc.log" "interface Wireguard0 down"
check "logged"                 has x "$K/var/wg-failover/log" "SWITCHED Wireguard0"
# a lock left by a killed run (reboot) is older than 15 min: it is cleared
rm -f "$K/var/wg-failover/last_switch"; mkdir -p "$K/var/wg-failover/lock"; echo 0 > "$K/var/wg-failover/lock/t"
: > "$K/ndmc.log"; fo
check "stale lock cleared"     has x "$K/ndmc.log" "ip route 91.108.56.0 255.255.252.0 Wireguard1 auto"
# a fresh lock (another run is working): this run leaves
mkdir -p "$K/var/wg-failover/lock"; date +%s > "$K/var/wg-failover/lock/t"; : > "$K/ndmc.log"; fo
check "busy: does nothing"     equal x "$(wc -l < "$K/ndmc.log" | tr -d ' ')" 0
# run by hand or by the bot (with an argument) while another run works: waits, then says so (it used to leave silently)
export SB_LOCK_WAIT=1; fo --force Wireguard1; FRC=$?; unset SB_LOCK_WAIT
check "busy by hand: says so"  has x "$K/fo.out" "занято"
check "busy by hand: exit 1"   equal x "$FRC" 1
check "busy by hand: nothing changed" equal x "$(wc -l < "$K/ndmc.log" | tr -d ' ')" 0
rm -rf "$K/var/wg-failover/lock"
# nobody answers: one round of tries, then a pause instead of flipping tunnels every few minutes
rm -f "$K/var/wg-failover/last_switch" "$K/wg-alive-Wireguard1"; : > "$K/ndmc.log"; fo
check "tried the standby"      has x "$K/ndmc.log" "interface Wireguard1 up"
check "gave it back"           has x "$K/ndmc.log" "interface Wireguard1 down"
check "no switch"              hasnt x "$K/ndmc.log" "Wireguard1 auto"
: > "$K/ndmc.log"; fo
check "pause before retrying"  hasnt x "$K/ndmc.log" "interface Wireguard1 up"
check "pause logged"           has x "$K/var/wg-failover/log" "no standby answered less than"
# a tunnel listed but not on the router is never "switched on" (that would create an empty one)
rm -f "$K/var/wg-failover/last_try"; sed -i 's/^TUNNELS=.*/TUNNELS="Wireguard0 Wireguard7"/' "$K/etc/switchback/failover.conf"
: > "$K/ndmc.log"; fo
check "missing tunnel skipped" hasnt x "$K/ndmc.log" "interface Wireguard7"
check "skip logged"            has x "$K/var/wg-failover/log" "Wireguard7 is not on the router"
# standby check (05:00 or --standby, only while the active one works): a live standby is switched back off
sed -i 's/^TUNNELS=.*/TUNNELS="Wireguard0 Wireguard1"/' "$K/etc/switchback/failover.conf"
mkdir -p "$K/etc/watchdog"; printf 'TOKEN=%s\nCHAT=1\n' "$TOKEN" > "$K/etc/watchdog/bot.conf"
rm -f "$K/wg-dead-Wireguard0" "$K/var/wg-failover/last_try"; touch "$K/wg-alive-Wireguard1"
: > "$K/ndmc.log"; : > "$K/curl.log"; SB_FO_TIME=1200 fo
check "standby: not at noon"   missing x "$K/var/wg-failover/standby"
SB_FO_TIME=0500 fo
check "standby: checked at 05" has x "$K/var/wg-failover/standby" "live Wireguard1"
check "standby: tried it"      has x "$K/ndmc.log" "interface Wireguard1 up"
check "standby: put it back"   has x "$K/ndmc.log" "interface Wireguard1 down"
check "standby: no switch"     hasnt x "$K/ndmc.log" "Wireguard1 auto"
check "standby: one left, told" has x "$K/curl.log" "остался один"
: > "$K/ndmc.log"; SB_FO_TIME=0500 fo
check "standby: once a day"    hasnt x "$K/ndmc.log" "interface Wireguard1 up"
rm -f "$K/wg-alive-Wireguard1"; : > "$K/curl.log"; fo --standby
check "standby: by hand"       has x "$K/fo.out" "не отвечают: Wireguard1"
check "standby: told again after 3 days only" hasnt x "$K/curl.log" "не осталось"
rm -f "$K/var/wg-failover/fewstandby.sent"; fo --standby
check "standby: none left"     has x "$K/curl.log" "Запасных туннелей VPN не осталось"
# a switch says how many standbys are left
touch "$K/wg-dead-Wireguard0" "$K/wg-alive-Wireguard1"; rm -f "$K/var/wg-failover/last_switch"; : > "$K/curl.log"; fo
check "switch: in Russian"     has x "$K/curl.log" "переключил на Wireguard1"
check "switch: reserve count"  has x "$K/curl.log" "Запас кончается"
rm -f "$K/wg-dead-Wireguard0" "$K/wg-alive-Wireguard1" "$K/etc/watchdog/bot.conf"
# dry run changes nothing
: > "$K/ndmc.log"; fo --dry
check "dry: only reads"        equal x "$(grep -cv ' show ' "$K/ndmc.log")" 0
# status reports it; uninstall removes the script and its settings
sb_k status
check "status shows it"        has x "$K/out" "Автосмена VPN-туннеля"
printf 'uninstall_confirm=y\n' > "$K/u"; sb_k uninstall --answers "$K/u"
check "uninstall removes it"   missing x "$FO"
check "and its settings"       missing x "$K/etc/switchback/failover.conf"
# OpenWrt: failover — routes move to the standby through uci, the standby starts at boot from now on
openwrt fo-owrt
printf 'profile=custom\nmodules=vpn failover\nvpn_iface=wg0\nfailover_tunnels=wg0 wg1\n' > "$R/a"
sb_o install --answers "$R/a"
check "openwrt: installed"     exists x "$R/etc/switchback/cron1/wg-failover"
check "openwrt: minute job"    has x "$R/etc/crontabs/root" "$R/etc/switchback/cron1/*"
sed -i 's/^DEAD_RUNS=.*/DEAD_RUNS=1/; s/^UP_WAIT=.*/UP_WAIT=5/' "$R/etc/switchback/failover.conf"
touch "$R/wg-alive-wg1"     # wg0 has no handshake, wg1 answers
SB_ROOT=$R "$SH" "$R/etc/switchback/cron1/wg-failover" > "$R/fo.out" 2>&1
check "openwrt: routes moved"  has x "$R/uci.db" "network.sb_tg_149_154_160_0.interface	wg1"
check "openwrt: none left"     hasnt x "$R/uci.db" ".interface	wg0"
check "openwrt: old = standby" has x "$R/uci.db" "network.wg0.auto	0"
check "openwrt: new at boot"   has x "$R/uci.db" "network.wg1.auto	1"
check "openwrt: old down"      has x "$R/svc.log" "ifdown wg0"
check "openwrt: applied"       has x "$R/svc.log" "network reload"
printf 'uninstall_confirm=y\n' > "$R/u"; sb_o uninstall --answers "$R/u"
check "openwrt: moved routes removed" hasnt x "$R/uci.db" "sb_tg_"
check "openwrt: crontab clean" hasnt x "$R/etc/crontabs/root" "switchback"

# OpenWrt: Claude nodes — firewall rules, dnsmasq pins, the switch script
openwrt nd-owrt
printf '10.0.0.1\n10.0.0.2\n' > "$R/nodes"; echo 400 > "$R/node-ms-10.0.0.1"; echo 90 > "$R/node-ms-10.0.0.2"
printf 'profile=custom\nmodules=nodes\n' > "$R/a"; sb_o install --answers "$R/a"
check "openwrt: QUIC rule"     has x "$R/uci.db" "firewall.sb_quic_10_0_0_2.dest_ip	10.0.0.2"
check "openwrt: rule rejects"  has x "$R/uci.db" "firewall.sb_quic_10_0_0_2.target	REJECT"
check "openwrt: pinned"        has x "$R/uci.db" "dhcp.@dnsmasq[0].address	/claude.ai/10.0.0.2"
# pinned by hand to the slow node -> the script moves it
SB_ROOT=$R "$R/bin/uci" del_list "dhcp.@dnsmasq[0].address=/claude.ai/10.0.0.2"
SB_ROOT=$R "$R/bin/uci" add_list "dhcp.@dnsmasq[0].address=/claude.ai/10.0.0.1"
sed -i 's/^SLOW_RUNS=.*/SLOW_RUNS=1/' "$R/etc/switchback/nodes.conf"
SB_ROOT=$R "$SH" "$R/etc/switchback/cron1/claude-nodes" > "$R/nd.out" 2>&1
check "openwrt: node switched" has x "$R/uci.db" "dhcp.@dnsmasq[0].address	/claude.ai/10.0.0.2"
check "openwrt: old pin gone"  hasnt x "$R/uci.db" "/claude.ai/10.0.0.1"
check "openwrt: dnsmasq restarted" has x "$R/svc.log" "dnsmasq restart"
# a switched-off rule does not count
SB_ROOT=$R "$R/bin/uci" set "firewall.sb_quic_10_0_0_2.enabled=0"
SB_ROOT=$R "$R/bin/uci" del_list "dhcp.@dnsmasq[0].address=/claude.ai/10.0.0.2"
SB_ROOT=$R "$R/bin/uci" add_list "dhcp.@dnsmasq[0].address=/claude.ai/10.0.0.1"
rm -f "$R/var/claude-nodes/web.bad" "$R/var/claude-nodes/web.last_scan"
SB_ROOT=$R "$SH" "$R/etc/switchback/cron1/claude-nodes" > "$R/nd.out" 2>&1
check "openwrt: off rule not used" hasnt x "$R/uci.db" "/claude.ai/10.0.0.2"
SB_ROOT=$R "$R/bin/uci" delete "firewall.sb_quic_10_0_0_2.enabled"
SB_ROOT=$R "$R/bin/uci" del_list "dhcp.@dnsmasq[0].address=/claude.ai/10.0.0.1"
printf 'uninstall_confirm=y\n' > "$R/u"; sb_o uninstall --answers "$R/u"
check "openwrt: uci back to original" equal x "$(sort "$R/uci.db.seed")" "$(sort "$R/uci.db")"

# ---------- Claude nodes (Keenetic): QUIC rules, pin to the fastest node, the switch script ---------- [nodes]
keenetic nodes
printf '10.0.0.1\n10.0.0.2\n10.0.0.3\n' > "$K/nodes"
echo 400 > "$K/node-ms-10.0.0.1"; echo 90 > "$K/node-ms-10.0.0.2"; touch "$K/node-dead-10.0.0.3"
# the user already has a rule for 10.0.0.1 (switched off) in the Home list
cat > "$K/rc.extra" <<'EOF'
access-list _WEBADMIN_Home
    deny udp 0.0.0.0 0.0.0.0 10.0.0.1 255.255.255.255 port eq 443
    deny description users-own
    deny disable
!
interface Bridge0
    ip access-group _WEBADMIN_Home in
!
EOF
printf 'profile=custom\nmodules=nodes\n' > "$K/a"
printf '10.0.0.7\n' > "$K/dns-openai.com"; echo 120 > "$K/node-ms-10.0.0.7"   # ChatGPT's DNS service: one node
sb_k install --progress --answers "$K/a"
check "gpt: group in conf"     has x "$K/etc/switchback/nodes.conf" "gpt:chatgpt.com,"
check "gpt: no QUIC needed"    has x "$K/etc/switchback/nodes.conf" 'OWN="gpt"'
check "gpt: pinned"            has x "$K/ndmc.log" "ip host chatgpt.com 10.0.0.7"
check "gpt: assets pinned"     has x "$K/ndmc.log" "ip host persistent.oaistatic.com 10.0.0.7"
check "gpt: no QUIC rule added" hasnt x "$K/ndmc.log" "10.0.0.7 255.255.255.255 port eq 443"
check "install exit 0"         equal x "$RC" 0
check "QUIC rule added"        has x "$K/ndmc.log" "access-list _WEBADMIN_Home deny udp 0.0.0.0 0.0.0.0 10.0.0.2 255.255.255.255 port eq 443"
check "user's rule not doubled" hasnt x "$K/ndmc.log" "access-list _WEBADMIN_Home deny udp 0.0.0.0 0.0.0.0 10.0.0.1 "
check "switched-off rule told" has x "$K/out" "правило QUIC для 10.0.0.1 есть, но выключено"
check "pinned to the fastest"  has x "$K/ndmc.log" "ip host claude.ai 10.0.0.2"
check "whole group pinned"     has x "$K/ndmc.log" "ip host a-api.anthropic.com 10.0.0.2"
ND=$K/etc/cron.1min/claude-nodes
check "script installed"       exists x "$ND"
check "no placeholders"        hasnt x "$ND" "__"
nd() { SB_OPT=$K "$SH" "$ND" "$@" > "$K/nd.out" 2>&1; }
# now pinned (by hand) to slow 10.0.0.1; 10.0.0.2 is fast and has an active rule -> switch
cat >> "$K/rc.extra" <<'EOF'
access-list _WEBADMIN_Home
    deny udp 0.0.0.0 0.0.0.0 10.0.0.2 255.255.255.255 port eq 443
!
ip host claude.ai 10.0.0.1
ip host claudeusercontent.com 10.0.0.1
EOF
sed -i 's/^SLOW_RUNS=.*/SLOW_RUNS=1/' "$K/etc/switchback/nodes.conf"
: > "$K/ndmc.log"; nd
check "slow node replaced"     has x "$K/ndmc.log" "ip host claude.ai 10.0.0.2"
check "switch logged"          has x "$K/var/claude-nodes/log" "web: SWITCHED 10.0.0.1"
# the AI reserve holds Claude (lib/ai.sh): the auto-switch leaves its groups alone, /node refuses
touch "$K/etc/switchback/ai.conf"; mkdir -p "$K/var/ai-path"; echo zdns > "$K/var/ai-path/cur.claude"
: > "$K/ndmc.log"; nd
check "ai holds Claude: nodes pin nothing" hasnt x "$K/ndmc.log" "ip host"
check "ai holds Claude: logged"   has x "$K/var/claude-nodes/log" "the AI reserve holds it (zdns)"
nd --pin web best
check "ai holds Claude: /node refuses" has x "$K/nd.out" "путь выбирает резерв для нейросетей"
# the reserve is switching (its lock; "cur" changes only at the end): a scan then re-pinned over it (19.11.2026)
echo dns > "$K/var/ai-path/cur.claude"; mkdir "$K/var/ai-path/busy"; : > "$K/ndmc.log"; nd
check "ai switching: nodes pin nothing" hasnt x "$K/ndmc.log" "ip host"
check "ai switching: logged"      has x "$K/var/claude-nodes/log" "the AI reserve holds it (switching)"
rm -rf "$K/etc/switchback/ai.conf" "$K/var/ai-path"
# the only fast node's rule is switched off -> not used, nothing better -> pause before the next scan
sed -i 's/^    deny udp 0.0.0.0 0.0.0.0 10.0.0.2 255.255.255.255 port eq 443$/&\n    deny disable/' "$K/rc.extra"
rm -f "$K/var/claude-nodes/web.bad"; : > "$K/ndmc.log"; nd
check "off rule: not used"     hasnt x "$K/ndmc.log" "ip host claude.ai 10.0.0.2"
check "off rule: nothing better" has x "$K/var/claude-nodes/log" "web: no better node"
: > "$K/curl.log"; nd
check "pause: no rescan"       hasnt x "$K/curl.log" "10.0.0.2"
check "pause logged"           has x "$K/var/claude-nodes/log" "found nothing better, wait"
# a fast pinned node: nothing happens
echo 90 > "$K/node-ms-10.0.0.1"; : > "$K/ndmc.log"; nd
check "healthy: no changes"    equal x "$(grep -cv ' show ' "$K/ndmc.log")" 0
# every node silent: the internet is down -> no alert; the internet is up -> "the service is down"; back -> "works again"
mkdir -p "$K/etc/watchdog"; printf 'TOKEN=%s\nCHAT=-100\n' "$TOKEN" > "$K/etc/watchdog/bot.conf"
sed -i 's/^DEAD_RUNS=.*/DEAD_RUNS=1/' "$K/etc/switchback/nodes.conf"
touch "$K/node-dead-10.0.0.1" "$K/node-dead-10.0.0.2" "$K/net-down"
rm -f "$K/var/claude-nodes/"*.last_scan; : > "$K/curl.log"; nd
check "no internet: logged"    has x "$K/var/claude-nodes/log" "the internet is down, no alert"
check "no internet: no alert"  hasnt x "$K/curl.log" "sendMessage"
rm -f "$K/net-down" "$K/var/claude-nodes/"*.last_scan; : > "$K/curl.log"; nd
check "service down: told so"  has x "$K/curl.log" "не отвечает ни через один узел"
# the pinned address is a spare proxy of the AI reserve (lists/ai-*-proxies.nets): named so, not "узел" (it was read
# as "GeoHide is back", 19.11.2026)
PX=$K/etc/switchback/app/lists/ai-claude-proxies.nets; mkdir -p "${PX%/*}"
[ -f "$PX" ] && cp "$PX" "$PX.keep"; printf '10.0.0.1/32   # Zapret DNS\n' >> "$PX"
rm -f "$K/node-dead-10.0.0.1"; : > "$K/curl.log"; nd
check "back: told so"          has x "$K/curl.log" "снова отвечает"
check "back: a proxy is named" has x "$K/curl.log" "прокси Zapret DNS 10.0.0.1 (не узел DNS-сервиса) снова отвечает"
if [ -f "$PX.keep" ]; then mv "$PX.keep" "$PX"; else rm -f "$PX"; fi
: > "$K/curl.log"; nd
check "back: only once"        hasnt x "$K/curl.log" "снова отвечает"
rm -f "$K/node-dead-10.0.0.2"
# a reserve node from the second DNS service (DoH): no QUIC rule needed, chosen when it is the fastest
check "reserve service in conf" has x "$K/etc/switchback/nodes.conf" "EXTRA_DOH=https://dns.zapret.moe/dns-query"
printf '10.0.0.9' > "$K/doh-node"; echo 50 > "$K/node-ms-10.0.0.9"; echo 400 > "$K/node-ms-10.0.0.1"
rm -f "$K/var/claude-nodes/"*.last_scan "$K/var/claude-nodes/"*.bad; : > "$K/ndmc.log"; nd
check "reserve node used"      has x "$K/ndmc.log" "ip host claude.ai 10.0.0.9"
nd --dry
check "dry run shows reserve"  has x "$K/nd.out" "reserve nodes (no QUIC rule needed): 10.0.0.9"
# a dead node: every other pin on it goes too (pinned by hand: 18.11.2026 eight names were left on a dead node);
# a name the AI reserve holds keeps its pin, its "before" value in the reserve's journal changes
printf 'ip host cdn.auth0.com 10.0.0.1\nip host sora.com 10.0.0.1\n' >> "$K/rc.extra"
mkdir -p "$K/var/ai-path"; echo 'sora.com 10.0.0.1' > "$K/var/ai-path/pinned"; touch "$K/node-dead-10.0.0.1"
rm -f "$K/var/claude-nodes/"*.last_scan "$K/var/claude-nodes/"*.bad; : > "$K/ndmc.log"; nd
check "dead node: group moved"  has x "$K/ndmc.log" "ip host claude.ai 10.0.0.9"
check "dead node: pins by hand too" has x "$K/ndmc.log" "ip host cdn.auth0.com 10.0.0.9"
check "dead node: the reserve's name left" hasnt x "$K/ndmc.log" "ip host sora.com"
check "dead node: the reserve's before value" has x "$K/var/ai-path/pinned" "sora.com 10.0.0.9"
check "dead node: logged"       has x "$K/var/claude-nodes/log" "other pins moved: 1"
sed -i '/^ip host cdn.auth0.com /d; /^ip host sora.com /d' "$K/rc.extra"; rm -rf "$K/var/ai-path" "$K/node-dead-10.0.0.1"
rm -f "$K/var/claude-nodes/"*.last_scan "$K/var/claude-nodes/"*.bad
# for the bot: the list with times, pinning by hand (only known, live nodes)
nd --list
check "list: reserve node"     has x "$K/nd.out" "10.0.0.9 50 reserve"
check "list: rule-less node"   has x "$K/nd.out" "10.0.0.2 90 noquic"
: > "$K/ndmc.log"; nd --pin web 10.0.0.3
check "pin: dead node refused" has x "$K/nd.out" "10.0.0.3 не отвечает"
nd --pin web 10.9.9.9
check "pin: unknown refused"   has x "$K/nd.out" "нет среди узлов"
nd --pin api best
check "pin: best chosen"       has x "$K/ndmc.log" "ip host api.anthropic.com 10.0.0.9"
# ChatGPT: its node dies -> it moves to the reserve service's node, no QUIC rule needed, says "ChatGPT"
printf 'ip host chatgpt.com 10.0.0.7\n' >> "$K/rc.extra"; touch "$K/node-dead-10.0.0.7"
rm -f "$K/var/claude-nodes/"*.last_scan "$K/var/claude-nodes/"*.bad; : > "$K/ndmc.log"; : > "$K/curl.log"; nd
check "gpt: moved to reserve"  has x "$K/ndmc.log" "ip host chatgpt.com 10.0.0.9"
check "gpt: whole group moved" has x "$K/ndmc.log" "ip host files.oaiusercontent.com 10.0.0.9"
check "gpt: switch is silent"  hasnt x "$K/curl.log" "ChatGPT gpt: 10.0.0.7"
check "gpt: switch in the log" has x "$K/var/claude-nodes/log" "gpt: SWITCHED 10.0.0.7"
check "claude list w/o gpt node" hasnt x "$K/var/claude-nodes/log" "  10.0.0.7 "
rm -f "$K/doh-node"; echo 90 > "$K/node-ms-10.0.0.1"
nd --dry
check "dry run lists nodes"    has x "$K/nd.out" "nodes: 10.0.0.1 10.0.0.2 10.0.0.3"
printf 'uninstall_confirm=y\n' > "$K/u"; sb_k uninstall --answers "$K/u"
check "rollback: rule removed" has x "$K/ndmc.log" "access-list _WEBADMIN_Home no deny udp 0.0.0.0 0.0.0.0 10.0.0.2"
check "rollback: pin removed"  has x "$K/ndmc.log" "no ip host claude.ai"
check "rollback: script gone"  missing x "$ND"
# DNS gives one node: nothing to switch between, skipped
keenetic nodes-one
printf '10.0.0.1\n' > "$K/nodes"; printf 'profile=custom\nmodules=nodes\n' > "$K/a"; sb_k install --answers "$K/a"
check "one node: skipped"      has x "$K/out" "переключать не между чем"

# ---------- report: useful parts in, every secret out ---------- [report]
keenetic report
cat > "$K/rc.extra" <<'EOF'
interface Wireguard0
    wireguard private-key aFakePrivateKeyForTestsOnly0123456789abcdE=
    wireguard peer SERVERpubKEYforTESTSonly0123456789abcdefgh= !vpn
        endpoint vpn.example.com:51820
        preshared-key aFakePresharedKeyForTestsOnly0123456789abc=
    !
!
username admin
    password md5 0123456789abcdef0123456789abcdef
!
interface WifiMaster0/AccessPoint0
    authentication wpa-psk ns3 SuperSecretWifi
!
ip host claude.ai 10.0.0.2
ip hotspot
    host aa:bb:cc:00:00:01 permit
!
EOF
mkdir -p "$K/etc/watchdog"; printf 'TOKEN=%s\nCHAT=1\n' "$TOKEN" > "$K/etc/watchdog/bot.conf"
sb_k report
check "report exit 0"          equal x "$RC" 0
check "has routes"             has x "$K/out" "ip route 91.108.56.0 255.255.252.0 Wireguard0 auto"
check "has pins"               has x "$K/out" "ip host claude.ai 10.0.0.2"
check "has tunnel state"       has x "$K/out" "Wireguard0: подключено"
check "has Telegram route"     has x "$K/out" "Telegram идёт через: Wireguard0"
check "saved on router"        exists x "$K/var/switchback-report.txt"
for s in aFakePrivateKeyForTestsOnly aFakePresharedKeyForTestsOnly SERVERpubKEY 0123456789abcdef0123 SuperSecretWifi \
         AAFakeTokenForTestsOnly aa:bb:cc:00:00:01; do
  check "no secret: $s"        hasnt x "$K/out" "$s"
done
check "file has no secret"     hasnt x "$K/var/switchback-report.txt" "SuperSecretWifi"
check "whole config not dumped" hasnt x "$K/out" "username admin"
# the last line of defence: a report with a key shape left in is not given out
printf 'line\nwireguard private-key aFakePrivateKeyForTestsOnly0123456789abcdE=\n' > "$K/leaky"
check "leak detector works"    equal x "$(dash -c ". '$SRC/lib/common.sh'; report_leaks '$K/leaky'" | cut -d: -f1)" 2
openwrt report-owrt
SB_ROOT=$R "$R/bin/uci" set "network.wg0.private_key=aFakePrivateKeyForTestsOnly0123456789abcdE="
sb_o report
check "openwrt report exit 0"  equal x "$RC" 0
check "openwrt: tunnels shown" has x "$R/out" "network.wg0.proto='wireguard'"
check "openwrt: no key"        hasnt x "$R/out" "aFakePrivateKeyForTestsOnly"

# ---------- custom modules keep the safe order ---------- [install]
keenetic order
printf 'profile=custom\nmodules=vpn https\nvpn_iface=Wireguard0\n' > "$K/a"
sb_k install --dry-run --progress --answers "$K/a"
check "order https, vpn"       has x "$K/out" "@@sb	plan	https	vpn"

# ---------- failure in the middle rolls back this run ---------- [install]
keenetic fail
cp "$K/etc/nfqws2/nfqws2.conf" "$K/conf.before"
printf 'profile=full\ndns_claude=y\ndns_claude_ip=9.9.9.9\ndns_claude_sni=bad.example\nvpn_iface=Wireguard0\n' > "$K/a"
sb_k install --progress --answers "$K/a"
check "exit 1"                 equal x "$RC" 1
check "fail event"             has x "$K/out" "@@sb	fail	"
check "end 1"                  has x "$K/out" "@@sb	end	1"
check "zapret conf rolled back" equal x "$(cat "$K/conf.before")" "$(cat "$K/etc/nfqws2/nfqws2.conf")"
check "no Telegram routes"     hasnt x "$K/ndmc.log" "ip route 91.108.4.0"

# ---------- OpenWrt: install with answers, uninstall restores uci exactly ---------- [openwrt]
openwrt owrt
cat > "$R/a" <<EOF
profile=custom
modules=zapret dns vpn
disable_offload=y
dns_chatgpt=y
dns_chatgpt_doh=https://doh.example/dns-query
vpn_iface=wg0
EOF
sb_o install --progress --answers "$R/a"
check "exit 0"                 equal x "$RC" 0
check "offload off"            has x "$R/uci.db" "flow_offloading	0"
check "DoH instance"           has x "$R/uci.db" "https-dns-proxy.sb_chatgpt.resolver_url	https://doh.example/dns-query"
check "3 steps"                equal x "$(ev_count "$R/out" step)" 3
printf 'uninstall_confirm=y\nuninstall_packages=y\n' > "$R/u"
sb_o uninstall --answers "$R/u"
check "uninstall exit 0"       equal x "$RC" 0
check "uci back to original"   equal x "$(sort "$R/uci.db.seed")" "$(sort "$R/uci.db")"

# ---------- OpenWrt in a VM (2026-11-17): uninstall leaves the router as it was before us ---------- [openwrt]
openwrt owclean
echo ca-certificates > "$R/pkgs.db"            # on the router before us: must stay
rm -f "$R/etc/crontabs/root"                   # a fresh OpenWrt has no crontab
sb_o doctor
check "doctor: legacy iptables note" has x "$R/out" "потянет старый iptables"
cat > "$R/a" <<EOF
profile=custom
modules=zapret dns watchdog
dns_chatgpt=y
dns_chatgpt_doh=https://doh.example/dns-query
ntfy_url=https://ntfy.sh/sb-testchannel1234
EOF
sb_o install --answers "$R/a"
check "exit 0"                 equal x "$RC" 0
check "deps journaled"         has x "$R/etc/switchback/state" "iptables-zz-legacy"
check "ours only in deps"      equal x "$(grep '^pkgdeps' "$R/etc/switchback/state" | grep -c ca-certificates)" 0
check "feed journaled"         has x "$R/etc/switchback/state" "pkgfile $R/etc/opkg/nfqws2-keenetic.conf"
check "feed key journaled"     has x "$R/etc/switchback/state" "pkgfile $R/etc/opkg/keys/96e4a10c3f9d405d"
check "new crontab journaled"  has x "$R/etc/switchback/state" "cronfile"
check "orig conf made"         exists x "$R/etc/nfqws2/nfqws2.conf.orig"
sb_o doctor
check "doctor: no note after"  hasnt x "$R/out" "потянет старый iptables"
mkdir -p "$R/etc/config"; echo "config main" > "$R/etc/config/https-dns-proxy"   # the real package has one
date +%s > "$R/etc/switchback/tune.running"
printf 'uninstall_confirm=y\nuninstall_packages=y\n' > "$R/u"
sb_o uninstall --answers "$R/u"
check "uninstall exit 0"       equal x "$RC" 0
check "only what was before"   equal x "$(cat "$R/pkgs.db")" "ca-certificates"
check "feed removed"           missing x "$R/etc/opkg/nfqws2-keenetic.conf"
check "feed key removed"       missing x "$R/etc/opkg/keys/96e4a10c3f9d405d"
check "zapret conf removed"    missing x "$R/etc/nfqws2"
check "DoH conf removed"       missing x "$R/etc/config/https-dns-proxy"
check "our crontab removed"    missing x "$R/etc/crontabs/root"
check "tune mark removed"      missing x "$R/etc/switchback/tune.running"
check "nothing failed"         hasnt x "$R/out" "не удалось удалить пакеты"

# nfqws2 appears a few seconds after the restart (25.12 in the VM, 2026-11-17): wait for it, do not roll back
openwrt owslow
printf '#!/bin/sh\nn=$(cat "$SB_ROOT/pidof-n" 2>/dev/null || echo 0); echo $((n+1)) > "$SB_ROOT/pidof-n"\n[ "$n" -ge 2 ] && [ "$1" = nfqws2 ] && grep -qx nfqws2-keenetic "$SB_ROOT/pkgs.db"\n' > "$R/bin/pidof"
printf 'profile=zapret\n' > "$R/a"
export SB_ZAPRET_WAIT=3
sb_o install --answers "$R/a"
check "slow start: exit 0"     equal x "$RC" 0
check "slow start: no rollback" hasnt x "$R/out" "не запустился"
check "slow start: asked again" "$SH" -c "[ $(cat "$R/pidof-n") -ge 3 ]"
# never appears: given up after SB_ZAPRET_WAIT seconds, rolled back as before
openwrt owdead
printf '#!/bin/sh\nexit 1\n' > "$R/bin/pidof"
export SB_ZAPRET_WAIT=0
printf 'profile=zapret\n' > "$R/a"
sb_o install --answers "$R/a"
check "dead: fails"            equal x "$RC" 1
check "dead: says so"          has x "$R/out" "zapret не запустился после настройки"
unset SB_ZAPRET_WAIT

# packages kept on uninstall: their source stays too; zapret settings back, the copy gone
openwrt owkeep
printf 'profile=zapret\n' > "$R/a"
sb_o install --answers "$R/a"
printf 'uninstall_confirm=y\nuninstall_packages=n\n' > "$R/u"
sb_o uninstall --answers "$R/u"
check "keep: exit 0"           equal x "$RC" 0
check "keep: zapret stays"     has x "$R/pkgs.db" "nfqws2-keenetic"
check "keep: feed stays"       exists x "$R/etc/opkg/nfqws2-keenetic.conf"
check "keep: settings back"    has x "$R/etc/nfqws2/nfqws2.conf" 'NFQWS_EXTRA_ARGS="$MODE_AUTO"'
check "keep: orig gone"        missing x "$R/etc/nfqws2/nfqws2.conf.orig"
check "keep: crontab kept"     exists x "$R/etc/crontabs/root"

# no bot token, no ntfy: the watchdog is skipped before the scheduler is touched
openwrt ownotoken
printf 'profile=custom\nmodules=watchdog\n' > "$R/a"
sb_o install --answers "$R/a"
check "exit 0"                 equal x "$RC" 0
check "explains the skip"      has x "$R/out" "нет ни токена бота"
check "no cron lines"          hasnt x "$R/etc/crontabs/root" "switchback"
check "no curl journaled"      hasnt x "$R/etc/switchback/state" "pkg curl"

# a module with nothing to do is "skipped" in the summary, not "already set up"
openwrt owskip
printf 'profile=custom\nmodules=nodes\n' > "$R/a"
sb_o install --answers "$R/a"
check "exit 0"                 equal x "$RC" 0
check "summary: skipped"       has x "$R/out" "пропущено, см. выше"
check "not 'already set up'"   hasnt x "$R/out" "уже было настроено"

# ntfy channel name without od (BusyBox on OpenWrt has none), and without hexdump either
openwrt owntfy
mkdir -p "$R/nood"; printf '#!/bin/sh\nexit 127\n' > "$R/nood/od"; cp "$R/nood/od" "$R/nood/hexdump"; chmod +x "$R/nood/"*
n1=$(PATH="$R/nood:$PATH" "$SH" -c ". '$SRC/lib/common.sh'; . '$SRC/lib/modules.sh'; ntfy_new")
check "no od/hexdump: long name" equal x "${#n1}" 43
check "no od/hexdump: valid"   "$SH" -c ". '$SRC/lib/common.sh'; . '$SRC/lib/modules.sh'; ntfy_valid '$n1'"
rm "$R/nood/hexdump"
n2=$(PATH="$R/nood:$PATH" "$SH" -c ". '$SRC/lib/common.sh'; . '$SRC/lib/modules.sh'; ntfy_new")
check "no od: long name"       equal x "${#n2}" 43
check "two names differ"       "$SH" -c "[ '$n1' != '$n2' ]"

# ---------- OpenWrt firmware upgrade: our files kept, lost packages found and reinstalled ---------- [openwrt]
openwrt upgrade
printf '/etc/my-own-file\n' > "$R/etc/sysupgrade.conf"
cat > "$R/a" <<EOF
profile=custom
modules=zapret dns
dns_chatgpt=y
dns_chatgpt_doh=https://doh.example/dns-query
EOF
sb_o install --answers "$R/a"
check "install exit 0"         equal x "$RC" 0
check "state kept on upgrade"  has x "$R/etc/sysupgrade.conf" "/etc/switchback/state"
check "zapret conf kept"       has x "$R/etc/sysupgrade.conf" "/etc/nfqws2/"
check "snapshots NOT kept"     hasnt x "$R/etc/sysupgrade.conf" "backups"
check "user's line untouched"  has x "$R/etc/sysupgrade.conf" "/etc/my-own-file"
sb_o status --progress
check "status: zapret works"   has x "$R/out" "zapret работает"
check "status: DNS counted"    has x "$R/out" "доменов настроено: 4"
check "status event"           has x "$R/out" "@@sb	status	"
# "sysupgrade": packages gone, settings and kept files stay
grep -vx 'nfqws2-keenetic\|https-dns-proxy' "$R/pkgs.db" > "$R/pkgs.t"; mv "$R/pkgs.t" "$R/pkgs.db"
rm -f "$R/etc/init.d/nfqws2-keenetic" "$R/etc/init.d/https-dns-proxy"
sb_o doctor --progress
check "doctor sees lost pkgs"  has x "$R/out" "пропали пакеты, которые ставил switchback: nfqws2-keenetic https-dns-proxy"
sb_o install --answers "$R/a"
check "reinstall exit 0"       equal x "$RC" 0
check "zapret back"            has x "$R/pkgs.db" "nfqws2-keenetic"
check "DoH proxy back"         has x "$R/pkgs.db" "https-dns-proxy"
check "DoH proxy restarted"    has x "$R/svc.log" "https-dns-proxy stop"
check "no duplicate journal"   equal x "$(sort "$R/etc/switchback/state" | uniq -d)" ""
check "no duplicate keep lines" equal x "$(sort "$R/etc/sysupgrade.conf" | uniq -d)" ""
printf 'uninstall_confirm=y\nuninstall_packages=y\n' > "$R/u"
sb_o uninstall --answers "$R/u"
check "sysupgrade.conf restored" equal x "$(cat "$R/etc/sysupgrade.conf")" "/etc/my-own-file"

# ---------- status on a router where nothing was installed ---------- [install]
keenetic status-empty
sb_k status --progress
check "nothing installed yet"  has x "$K/out" "ещё ничего не ставил"
check "neutral status event"   has x "$K/out" "@@sb	status	none"

# ---------- WireGuard from a .conf: keys never shown, logged or journaled ---------- [wireguard]
PSK=aFakePresharedKeyForTestsOnly0123456789abc=
wgconf() {
  printf '[Interface]\r\nPrivateKey = %s\r\nAddress = 10.8.0.2/32, fd00::2/128\r\nDNS = 1.1.1.1\r\n\r\n[Peer]\r\nPublicKey = SERVERpubKEYforTESTSonly0123456789abcdefgh=\r\nPresharedKey = %s\r\nEndpoint = 198.51.100.7:51820\r\nAllowedIPs = 0.0.0.0/0, ::/0\r\nPersistentKeepalive = 25\r\n' "$PRIV" "$PSK" > "$1"
}
secrets_hidden() {   # secrets_hidden DIR OUTFILE
  check "private key not on screen" hasnt x "$2" "$PRIV"
  check "psk not on screen"         hasnt x "$2" "$PSK"
  check "keys not in the journal"   hasnt x "$1/state.copy" "$PRIV"
  check "keys not in the log"       hasnt x "$1/log.copy" "$PRIV"
}

keenetic wg-dry
wgconf "$K/wg.conf"
sb_k wg-import --conf "$K/wg.conf" --dry-run --progress
check "dry exit 0"             equal x "$RC" 0
check "dry: no real commands"  equal x "$(grep -v ' show ' "$K/ndmc.log" | wc -l | tr -d ' ')" 0
check "dry: key hidden"        has x "$K/out" "private-key <скрыто>"
check "dry: key not printed"   hasnt x "$K/out" "$PRIV"

keenetic wg
wgconf "$K/wg.conf"
SB_ANSWERS_RM=1 SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$SRC/install.sh" wg-import --conf "$K/wg.conf" --progress > "$K/out" 2>&1; RC=$?
cp "$K/etc/switchback/state" "$K/state.copy" 2>/dev/null; cp "$K/var/log/switchback.log" "$K/log.copy" 2>/dev/null
check "import exit 0"          equal x "$RC" 0
check "conf deleted after read" missing x "$K/wg.conf"
check "next free name"         has x "$K/out" "@@sb	wg	Wireguard2"
check "address and mask"       has x "$K/ndmc.log" "interface Wireguard2 ip address 10.8.0.2 255.255.255.255"
check "endpoint"               has x "$K/ndmc.log" "endpoint 198.51.100.7:51820"
check "only chosen addresses"  hasnt x "$K/ndmc.log" "Wireguard2 ip global"
check "traffic check: no handshake" has x "$K/out" "@@sb	wg_check	Wireguard2	nohandshake"
# the same once the server answers: Telegram is opened through the new tunnel's device
keenetic wg-ok; wgconf "$K/wg.conf"; touch "$K/wg-alive-Wireguard2"
SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$SRC/install.sh" wg-import --conf "$K/wg.conf" --progress > "$K/out" 2>&1
check "traffic check: works"   has x "$K/out" "@@sb	wg_check	Wireguard2	ok"
check "through the tunnel only" has x "$K/curl.log" "--interface nwg2"
# a standby: created off, switched on only for the check, then off again
keenetic wg-spare; wgconf "$K/wg.conf"; touch "$K/wg-alive-Wireguard2"
SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$SRC/install.sh" wg-import --conf "$K/wg.conf" --standby --progress > "$K/out" 2>&1
check "standby: checked"       has x "$K/out" "@@sb	wg_check	Wireguard2	ok"
check "standby: on for check"  has x "$K/ndmc.log" "interface Wireguard2 up"
check "standby: off again"     has x "$K/ndmc.log" "interface Wireguard2 down"
keenetic wg; wgconf "$K/wg.conf"
SB_ANSWERS_RM=1 SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$SRC/install.sh" wg-import --conf "$K/wg.conf" --progress > "$K/out" 2>&1
secrets_hidden "$K" "$K/out"
sb_k status
check "status shows it"        has x "$K/out" "подключение WireGuard Wireguard2"
printf 'uninstall_confirm=y\n' > "$K/u"; sb_k uninstall --answers "$K/u"
check "uninstall removes it"   has x "$K/ndmc.log" "no interface Wireguard2"

keenetic wg-bad
printf '[Interface]\nAddress = 10.8.0.2/32\n[Peer]\nPublicKey = X\nEndpoint = 1.2.3.4:51820\n' > "$K/bad.conf"
sb_k wg-import --conf "$K/bad.conf"
check "no PrivateKey -> exit 2" equal x "$RC" 2
check "explains"               has x "$K/out" "нет PrivateKey"

# ---------- many servers at once (wg-batch): checked one by one, working ones kept as standbys ---------- [wireguard]
wgconf2() {   # wgconf2 FILE HOST
  printf '[Interface]\nPrivateKey = %s\nAddress = 10.8.0.2/32\n[Peer]\nPublicKey = SERVERpubKEYforTESTSonly0123456789abcdefgh=\nEndpoint = %s:51820\n' "$PRIV" "$2" > "$1"
}
keenetic wgb
export SB_WG_SLEEP=0
mkdir -p "$K/wgb/slot"
wgconf2 "$K/wgb/slot/1.conf" 203.0.113.21      # -> Wireguard2, answers
wgconf2 "$K/wgb/slot/2.conf" 203.0.113.22      # -> Wireguard3, silent: removed again
wgconf2 "$K/wgb/slot/3.conf" 203.0.113.21      # the same server again: skipped
printf '[Interface]\nAddress = 10.8.0.2/32\n' > "$K/wgb/slot/4.conf"   # not a whole config
wgconf2 "$K/wgb/slot/5.conf" 203.0.113.23      # -> Wireguard3 again, silent
printf 'nothing to read\n' > "$K/wgb/slot/readme.txt"
mkdir -p "$K/etc/switchback"; printf 'TUNNELS="Wireguard0 Wireguard1"\n' > "$K/etc/switchback/failover.conf"
touch "$K/wg-alive-Wireguard2"
SB_ANSWERS_RM=1 SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$SRC/install.sh" wg-batch --conf "$K/wgb" --progress > "$K/out" 2>&1; RC=$?
cp "$K/etc/switchback/state" "$K/state.copy" 2>/dev/null; cp "$K/var/log/switchback.log" "$K/log.copy" 2>/dev/null
check "batch: exit 0"            equal x "$RC" 0
check "batch: working one kept"  has x "$K/out" "Wireguard2 (203.0.113.21) — работает"
check "batch: made switched off" has x "$K/ndmc.log" "interface Wireguard2 down"
check "batch: silent removed"    has x "$K/ndmc.log" "no interface Wireguard3"
check "batch: kept not removed"  hasnt x "$K/ndmc.log" "no interface Wireguard2"
check "batch: totals"            has x "$K/out" "работают 1, не работают 2, повторы 1, не разобрать 1"
check "batch: kept journaled"    has x "$K/state.copy" "wg Wireguard2"
check "batch: removed forgotten" hasnt x "$K/state.copy" "wg Wireguard3"
check "batch: into failover"     has x "$K/etc/switchback/failover.conf" 'TUNNELS="Wireguard0 Wireguard1 Wireguard2"'
check "batch: saved"             has x "$K/ndmc.log" "system configuration save"
check "batch: files wiped"       missing x "$K/wgb"
check "batch: no unpacked copy"  equal x "$(ls -d "$SB_TMP"/switchback-wgb.* 2>/dev/null | wc -l | tr -d ' ')" 0
check "batch: done event"        has x "$K/out" "@@sb	wg_batch	done	5	1	2	1	1"
check "batch: in turns, all read" has x "$K/out" "проверено 5 из 5"
secrets_hidden "$K" "$K/out"
# --keep 1: stops at the first working one; the given files are not wiped without SB_ANSWERS_RM
keenetic wgb-keep
mkdir -p "$K/wgb"; wgconf2 "$K/wgb/a.conf" 203.0.113.41; wgconf2 "$K/wgb/b.conf" 203.0.113.42
touch "$K/wg-alive-Wireguard2" "$K/wg-alive-Wireguard3"
sb_k wg-batch --conf "$K/wgb" --keep 1
check "keep: one added"          has x "$K/out" "работают 1"
check "keep: rest not checked"   has x "$K/out" "остальные 1 не проверял"
check "keep: own files stay"     exists x "$K/wgb/a.conf"
sb_k wg-batch --conf "$K/nothing-here"
check "batch: missing -> exit 2" equal x "$RC" 2
# servers already on the router (seen 2026-11-18: 320 of 351): a dead one is checked anew - .31 comes back (and
# back into the failover list), .32 stays dead and is not removed; a live one (.33) and a standby that answered
# the daily check and is only switched off (.34) are skipped as before
keenetic wgb-dead
mkdir -p "$K/wgb" "$K/var/wg-failover" "$K/etc/switchback"
for x in 31 32 33 34; do wgconf2 "$K/wgb/$x.conf" 203.0.113.$x; done
wgconf2 "$K/wgb/dup.conf" 203.0.113.32
n=4; for x in 31 32 33 34; do
  printf 'interface Wireguard%s\n    description switchback-203.0.113.%s\n    wireguard peer SERVERpub\n        endpoint 203.0.113.%s:51820\n!\n' "$n" "$x" "$x"; n=$((n+1))
done > "$K/rc.extra"
touch "$K/wg-revive-Wireguard4" "$K/wg-alive-Wireguard6"
printf 'date 2026-11-18 05:00\nlive Wireguard7\ndead Wireguard5\n' > "$K/var/wg-failover/standby"
printf 'TUNNELS="Wireguard0 Wireguard1 Wireguard5 Wireguard7"\n' > "$K/etc/switchback/failover.conf"
sb_k wg-batch --conf "$K/wgb" --progress
check "recheck: exit 0"            equal x "$RC" 0
check "recheck: revived"           has x "$K/out" "Wireguard4 (203.0.113.31) — был мёртв, снова работает"
check "recheck: back off"          has x "$K/ndmc.log" "interface Wireguard4 down"
check "recheck: back in failover"  has x "$K/etc/switchback/failover.conf" 'TUNNELS="Wireguard0 Wireguard1 Wireguard5 Wireguard7 Wireguard4"'
check "recheck: still dead said"   has x "$K/out" "Wireguard5 (203.0.113.32) — уже на роутере и по-прежнему не отвечает"
check "recheck: dead not removed"  hasnt x "$K/ndmc.log" "no interface Wireguard5"
check "recheck: live one skipped"  hasnt x "$K/ndmc.log" "interface Wireguard6 up"
check "recheck: standby skipped"   hasnt x "$K/ndmc.log" "interface Wireguard7 up"
check "recheck: nothing created"   hasnt x "$K/ndmc.log" "description switchback-"
check "recheck: totals"            has x "$K/out" "повторы 3, не разобрать 0; перепроверено мёртвых 2, ожило 1"
check "recheck: done event"        has x "$K/out" "@@sb	wg_batch	done	5	0	0	3	0	2	1"
check "recheck: no 'none found'"   hasnt x "$K/out" "рабочих не нашлось"
check "recheck: logged"            has x "$K/var/log/switchback.log" "dead ones rechecked 2, revived 1: Wireguard4"
unset SB_WG_SLEEP

openwrt wg-owrt
wgconf "$R/wg.conf"
sb_o wg-import --conf "$R/wg.conf" --progress
cp "$R/etc/switchback/state" "$R/state.copy" 2>/dev/null; cp "$R/var/log/switchback.log" "$R/log.copy" 2>/dev/null
check "import exit 0"          equal x "$RC" 0
check "interface created"      has x "$R/uci.db" "network.sbwg.proto	wireguard"
check "not all traffic"        has x "$R/uci.db" "network.sbwg_peer.route_allowed_ips	0"
check "endpoint port"          has x "$R/uci.db" "network.sbwg_peer.endpoint_port	51820"
check "in wan zone"            has x "$R/uci.db" "firewall.@zone[1].network	sbwg"
secrets_hidden "$R" "$R/out"
check "analysis now sees it"   has x "$(SB_ROOT=$R SB_OPT=$R SB_TEST=1 SB_PLATFORM=openwrt "$SH" "$SRC/install.sh" doctor --progress > "$R/d" 2>&1; echo "$R/d")" "@@sb	vpn	sbwg"
printf 'uninstall_confirm=y\nuninstall_packages=y\n' > "$R/u"; sb_o uninstall --answers "$R/u"
check "uci back to original"   equal x "$(sort "$R/uci.db.seed")" "$(sort "$R/uci.db")"

# ---------- 0.6: own copy on the router, bot commands, own sites, update, zapret tuning ---------- [bot]
keenetic v06
printf 'profile=custom\nmodules=zapret vpn watchdog\nvpn_iface=Wireguard0\nbot_token=%s\nbot_chat=-100\n' "$TOKEN" > "$K/a"
sb_k install --answers "$K/a"
check "install exit 0"         equal x "$RC" 0
check "copy on the router"     equal x "$(cat "$K/etc/switchback/app/VERSION")" "$(sed -n 's/^VERSION=//p' "$SRC/install.sh")"
check "copy is complete"       exists x "$K/etc/switchback/app/lib/sites.sh"
check "copy has the lists"     equal x "$(ls "$K/etc/switchback/app/lists" | wc -l | tr -d ' ')" "$(ls "$SRC/lists" | wc -l | tr -d ' ')"
check "bot job installed"      exists x "$K/etc/cron.1min/sb-bot"
check "bot paths filled in"    hasnt x "$K/etc/cron.1min/sb-bot" "__"
check "bot: no background copy" hasnt x "$K/etc/cron.1min/sb-bot" "--run"
# load log: every 5th minute (the minute check taken out here), CPU % needs two runs; status sums up the day
check "load job installed"     exists x "$K/etc/cron.1min/sb-load"
sed '/m % 5/d' "$K/etc/cron.1min/sb-load" > "$K/load-now"
"$SH" "$K/load-now"; "$SH" "$K/load-now"
check "load logged"            has x "$K/var/switchback-load.log" " cpu="
sb_k status
check "status: load of the day" has x "$K/out" "Нагрузка роутера за сутки"
# weekly digest: a quiet week is one line; with events it is the detailed one
check "digest job installed"   exists x "$K/etc/cron.1min/sb-digest"
check "digest: paths filled"   hasnt x "$K/etc/cron.1min/sb-digest" "__"
"$SH" "$K/etc/cron.1min/sb-digest" --now > "$K/dg.out" 2>&1
check "digest: quiet week"     has x "$K/dg.out" "Неделя без происшествий"
d=$(date +%F)
mkdir -p "$K/var/wg-failover" "$K/var/claude-nodes"
echo "$d 04:44:10 SWITCHED Wireguard1 (slot7, handshake 999s) -> Wireguard5 (slot5), routes left on old: 0" >> "$K/var/wg-failover/log"
echo "$d 05:10:00 web: SWITCHED 1.1.1.1 (900ms) -> 2.2.2.2 (100ms)" >> "$K/var/claude-nodes/log"
printf '%s 16:55 DOWN chatgpt\n%s 23:45 BACK chatgpt 430\n' "$d" "$d" >> "$K/var/watchdog-events.log"
mkdir -p "$K/var/sb-bot"; echo "$d 12:00:00 action zapret" >> "$K/var/sb-bot/log"
"$SH" "$K/etc/cron.1min/sb-digest" --now > "$K/dg.out" 2>&1
check "digest: tunnel switch"  has x "$K/dg.out" "Wireguard1 → Wireguard5 (не отвечал)"
check "digest: node switch"    has x "$K/dg.out" "Узлы Claude: переключений 1"
check "digest: outage length"  has x "$K/dg.out" "chatgpt — 1 раз, всего ~430 мин"
check "digest: bot action"     has x "$K/dg.out" "Действия через бота"
check "digest: free space"     has x "$K/dg.out" "Флешка: свободно"
check "watchdog logs events"   has x "$K/etc/cron.5mins/watchdog" "watchdog-events.log"
check "bot menu set"           has x "$K/curl.log" "setMyCommands"
# self-healing: the reboot is always a fake here (writes a file); uptime, memory and time are given
check "heal job installed"     exists x "$K/etc/cron.1min/sb-heal"
check "heal: paths filled"     hasnt x "$K/etc/cron.1min/sb-heal" "__"
check "heal: Keenetic reboot"  has x "$K/etc/cron.1min/sb-heal" "ndmc -c 'system reboot'"
printf '#!/bin/sh\necho rebooted >> "%s/rebooted"\n' "$K" > "$K/fake-reboot"; chmod +x "$K/fake-reboot"
heal() {   # heal UPTIME_S FREE_KB [TIME]
  echo "$1.00 1.00" > "$K/uptime"
  printf 'MemTotal: 100000 kB\nMemFree: 1000 kB\nMemAvailable: %s kB\n' "$2" > "$K/meminfo"
  SB_OPT="$K" SB_UPTIME="$K/uptime" SB_MEMINFO="$K/meminfo" SB_HEAL_FLAG="$K/booted" SB_REBOOT="$K/fake-reboot" \
    SB_HEAL_TIME="${3:-1200}" "$SH" "$K/etc/cron.1min/sb-heal"
}
rm -f "$K/booted" "$K/rebooted" "$K/var/heal."*; : > "$K/curl.log"
heal 100 50000
check "heal: waits after boot" hasnt x "$K/curl.log" "перезагрузился"
heal 300 50000
check "heal: boot message"     has x "$K/curl.log" "причина неизвестна"
: > "$K/curl.log"; heal 400 50000
check "heal: boot told once"   hasnt x "$K/curl.log" "перезагрузился"
heal 90000 50000 0430
check "heal: enough memory"    missing x "$K/rebooted"
rm -f "$K/var/heal.night"; heal 3000 10000 0430
check "heal: not right after a reboot" missing x "$K/rebooted"
rm -f "$K/var/heal.night"; heal 90000 10000 1200
check "heal: only at 04:30"    missing x "$K/rebooted"
heal 90000 10000 0430
check "heal: night reboot"     exists x "$K/rebooted"
check "heal: told why"         has x "$K/curl.log" "Ночная перезагрузка"
rm -f "$K/rebooted"; heal 90000 10000 0430
check "heal: once a night"     missing x "$K/rebooted"
rm -f "$K/booted"; : > "$K/curl.log"; heal 300 50000
check "heal: boot after night" has x "$K/curl.log" "ночная перезагрузка"
"$SH" "$K/etc/cron.1min/sb-digest" --now > "$K/dg.out" 2>&1
check "digest: night reboot"   has x "$K/dg.out" "ночная, мало памяти (9 МБ, 10%)"
echo "NIGHT_REBOOT=0" >> "$K/etc/watchdog/bot.conf"
rm -f "$K/var/heal.night"; heal 90000 10000 0430
check "heal: can be turned off" missing x "$K/rebooted"
sed -i '/^NIGHT_REBOOT=/d' "$K/etc/watchdog/bot.conf"
# own sites: zapret, vpn (addresses looked up, refreshed), bad input, built-in, delete
sb_k sites add 'https://www.Example.org/page?x=1' --via zapret --progress
check "zapret site added"      has x "$K/etc/nfqws2/lists/user.list" "example.org"
check "site event"             has x "$K/out" "@@sb	site_res	example.org	added	zapret"
# a check needs the whole page: a site that answers and is cut at ~19 KB does not "open"
sb_k sites check whole.example
check "check: whole page opens" has x "$K/out" "whole.example открывается"
check "check: follows redirects" has x "$K/curl.log" "-L --max-redirs 3"
touch "$K/site-cut-cut.example"; sb_k sites check cut.example
check "check: cut is not open"  has x "$K/out" "страница обрывается на ~18 КБ"
rm -f "$K/site-cut-cut.example"
sb_k sites add 'x.org;reboot' --via zapret
check "odd input refused"      equal x "$RC" 1
check "nothing added"          hasnt x "$K/etc/nfqws2/lists/user.list" "reboot"
sb_k sites add api.anthropic.com --via zapret
check "built-in not added"     has x "$K/out" "встроен в switchback"
sb_k sites add api.anthropic.com --via vpn       # an AI service through VPN: the reserve's switch is offered
check "AI site via VPN: offer" has x "$K/out" "Claude через VPN"
check "AI site via VPN: not added" hasnt x "$K/etc/switchback/sites" "api.anthropic.com"
printf '10.1.1.1\n10.1.1.2\n' > "$K/dns-blocked.example"; : > "$K/ndmc.log"
sb_k sites add blocked.example --via vpn
check "vpn site: route 1"      has x "$K/ndmc.log" "ip route 10.1.1.1 255.255.255.255 Wireguard0 auto"
check "vpn site: route 2"      has x "$K/ndmc.log" "ip route 10.1.1.2 255.255.255.255 Wireguard0 auto"
check "refresh job installed"  exists x "$K/etc/cron.1min/sb-sites"
echo 10.1.1.3 >> "$K/dns-blocked.example"; : > "$K/ndmc.log"
sb_k sites refresh
check "new address routed"     has x "$K/ndmc.log" "ip route 10.1.1.3 255.255.255.255 Wireguard0 auto"
check "old ones not again"     hasnt x "$K/ndmc.log" "ip route 10.1.1.1 "
# the router shows routes to one address without the mask
printf 'ip route 10.1.1.1 Wireguard0 auto\n' > "$K/rc.extra"
sb_k sites --progress
check "list events"            has x "$K/out" "@@sb	site	vpn	blocked.example"
check "tunnel offered"         has x "$K/out" "@@sb	site_way	vpn	Wireguard0"
: > "$K/ndmc.log"; sb_k sites del blocked.example
check "routes removed"         has x "$K/ndmc.log" "no ip route 10.1.1.3 255.255.255.255 Wireguard0"
check "out of the list"        hasnt x "$K/etc/switchback/sites" "blocked.example"
check "out of the journal"     hasnt x "$K/etc/switchback/state" "site vpn blocked.example"
# YouTube video servers the provider cuts off: found in the table of connections, checked directly and through
# the tunnel, routed there. .5 silent directly, answers through the tunnel; .6 stuck but answers directly;
# .7 works; .8 silent both ways
cat > "$K/conntrack" <<'EOF'
ipv4     2 tcp      6 100 ESTABLISHED src=192.168.1.9 dst=203.0.113.5 sport=40000 dport=443 packets=6 bytes=2300 src=203.0.113.5 dst=100.64.0.2 sport=443 dport=40000 packets=3 bytes=324 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 100 ESTABLISHED src=192.168.1.9 dst=203.0.113.6 sport=40001 dport=443 packets=6 bytes=2300 src=203.0.113.6 dst=100.64.0.2 sport=443 dport=40001 packets=3 bytes=324 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 100 ESTABLISHED src=192.168.1.9 dst=203.0.113.7 sport=40002 dport=443 packets=90 bytes=9000 src=203.0.113.7 dst=100.64.0.2 sport=443 dport=40002 packets=80 bytes=900000 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 50 SYN_SENT src=192.168.1.9 dst=203.0.113.8 sport=40003 dport=443 packets=3 bytes=180 [UNREPLIED] src=203.0.113.8 dst=100.64.0.2 sport=443 dport=40003 packets=0 bytes=0 mark=0 use=1
ipv4     2 tcp      6 100 ESTABLISHED src=192.168.1.9 dst=192.168.1.1 sport=40004 dport=443 packets=6 bytes=2300 src=192.168.1.1 dst=192.168.1.9 sport=443 dport=40004 packets=3 bytes=324 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 50 SYN_SENT src=192.168.1.9 dst=198.51.100.9 sport=40005 dport=443 packets=3 bytes=180 [UNREPLIED] src=198.51.100.9 dst=100.64.0.2 sport=443 dport=40005 packets=0 bytes=0 mark=0 use=1
ipv4     2 tcp      6 50 SYN_SENT src=192.168.1.9 dst=198.51.100.10 sport=40006 dport=443 packets=3 bytes=180 [UNREPLIED] src=198.51.100.10 dst=100.64.0.2 sport=443 dport=40006 packets=0 bytes=0 mark=0 use=1
ipv4     2 tcp      6 100 ESTABLISHED src=192.168.1.9 dst=198.51.100.11 sport=40007 dport=443 packets=6 bytes=2300 src=198.51.100.11 dst=100.64.0.2 sport=443 dport=40007 packets=3 bytes=324 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 100 ESTABLISHED src=192.168.1.9 dst=203.0.113.12 sport=40008 dport=443 packets=6 bytes=2300 src=203.0.113.12 dst=100.64.0.2 sport=443 dport=40008 packets=3 bytes=324 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 50 SYN_SENT src=192.168.1.9 dst=198.51.100.12 sport=40009 dport=443 packets=3 bytes=180 [UNREPLIED] src=198.51.100.12 dst=100.64.0.2 sport=443 dport=40009 packets=0 bytes=0 mark=0 use=1
EOF
# "Google's ranges" in this test: 203.0.113.0/24; 198.51.100.11 is stuck, answers by address, is not Google;
# 203.0.113.12 and 198.51.100.12 are silent directly once only (zapret switched its way): left alone
export SB_VIDEO_NETS="203.0.113.0/24" SB_VIDEO_PAUSE=0 SB_VIDEO_TRY=20 SB_WAN_DEV=ppp0
: > "$K/video-flaky-203.0.113.12"; : > "$K/ip-flaky-198.51.100.12"
: > "$K/video-dead-203.0.113.5"; : > "$K/video-dead-203.0.113.8"; : > "$K/video-novpn-203.0.113.8"
# any site: 198.51.100.9 is cut off by its address (answers through the tunnel), 198.51.100.10 is down for everyone
: > "$K/ip-dead-198.51.100.9"; : > "$K/ip-dead-198.51.100.10"; : > "$K/ip-novpn-198.51.100.10"
rm -f "$K/etc/switchback/tune.running"
# the control server (VIDEO_HOST's own address): answers the video name through zapret
echo 203.0.113.50 > "$K/dns-rr1---sn-4g5e6nzz.googlevideo.com"
export SB_CONNTRACK="$K/conntrack"
sb_k sites video on
check "video: turned on"        has x "$K/etc/switchback/sites" "rescue video"
check "video: job every minute" has x "$K/etc/cron.1min/sb-sites" "what=video"
check "video: in the journal"   has x "$K/etc/switchback/state" "site rescue video"
: > "$K/ndmc.log"; : > "$K/curl.log"
sb_k sites refresh video
check "video: cut-off routed"   has x "$K/ndmc.log" "ip route 203.0.113.5 255.255.255.255 Wireguard0 auto"
check "video: asked via tunnel" has x "$K/curl.log" "--interface nwg0"
check "video: route recorded"   has x "$K/etc/switchback/sites.routes" "203.0.113.5 video"
check "video: answers directly" hasnt x "$K/ndmc.log" "203.0.113.6"
check "video: healthy untouched" hasnt x "$K/curl.log" "203.0.113.7"
check "video: dead both ways"   hasnt x "$K/ndmc.log" "203.0.113.8"
check "video: home not probed"  hasnt x "$K/curl.log" ":192.168.1.1"
check "any site: cut off by address routed" has x "$K/ndmc.log" "ip route 198.51.100.9 255.255.255.255 Wireguard0 auto"
check "any site: down for everyone left"    hasnt x "$K/ndmc.log" "198.51.100.10"
check "any site: remembered as dead"        has x "$K/etc/switchback/video.seen" "198.51.100.10"
check "not Google: no video requests"       hasnt x "$K/curl.log" "googlevideo.com:443:198.51.100.11"
check "not Google: not routed"              hasnt x "$K/ndmc.log" "198.51.100.11"
check "silent once (video): not routed"     hasnt x "$K/ndmc.log" "203.0.113.12"
check "silent once (video): asked again"    missing x "$K/video-flaky-203.0.113.12"
check "silent once (address): not routed"   hasnt x "$K/ndmc.log" "198.51.100.12"
check "silent once (address): asked again"  missing x "$K/ip-flaky-198.51.100.12"
check "control: asked by the name"          has x "$K/curl.log" "googlevideo.com:443:203.0.113.50"
check "control: not routed"                 hasnt x "$K/ndmc.log" "203.0.113.50"
check "kind: cut off by name"   grep -q "^203.0.113.5 [0-9]* name$" "$K/etc/switchback/video.kind"
check "kind: cut off by address" grep -q "^198.51.100.9 [0-9]* addr$" "$K/etc/switchback/video.kind"
: > "$K/ndmc.log"; : > "$K/curl.log"
sb_k sites refresh video
check "video: not twice"        hasnt x "$K/ndmc.log" "ip route 203.0.113.5"
check "video: no recheck soon"  hasnt x "$K/curl.log" "203.0.113.6"
# zapret itself does not pass the video name (seen 2026-11-17): the control server is silent too - no route,
# a line in the log and one message to the owner (not again within hours); zapret works again - routed
mkdir -p "$K/etc/watchdog"; cp "$K/etc/watchdog/bot.conf" "$K/bot.conf.keep" 2>/dev/null
printf 'TOKEN=%s\nCHAT=1\n' "$TOKEN" > "$K/etc/watchdog/bot.conf"
echo 'ipv4     2 tcp      6 100 ESTABLISHED src=192.168.1.9 dst=203.0.113.13 sport=40010 dport=443 packets=6 bytes=2300 src=203.0.113.13 dst=100.64.0.2 sport=443 dport=40010 packets=3 bytes=324 [ASSURED] mark=0 use=1' >> "$K/conntrack"
: > "$K/video-dead-203.0.113.13"; : > "$K/video-dead-203.0.113.50"
: > "$K/ndmc.log"; : > "$K/curl.log"
sb_k sites refresh video
check "zapret down: not routed"     hasnt x "$K/ndmc.log" "203.0.113.13"
check "zapret down: control asked"  has x "$K/curl.log" "googlevideo.com:443:203.0.113.50"
check "zapret down: owner told"     has x "$K/curl.log" "zapret сейчас не пропускает YouTube"
check "zapret down: what to do"     has x "$K/curl.log" "«Подобрать zapret»"
check "zapret down: in the log"     has x "$K/var/log/switchback.log" "zapret does not pass YouTube now, not routed"
vs_age() { awk '{$2 = 1; print}' "$K/etc/switchback/video.seen" > "$K/vs"; mv "$K/vs" "$K/etc/switchback/video.seen"; }
vs_age; : > "$K/ndmc.log"; sb_k sites refresh video
check "zapret down: still no route" hasnt x "$K/ndmc.log" "203.0.113.13"
check "zapret down: told once"      equal x "$(grep -c "не пропускает YouTube" "$K/curl.log")" 1
rm -f "$K/video-dead-203.0.113.50"
vs_age; : > "$K/ndmc.log"; sb_k sites refresh video
check "zapret back: routed"         has x "$K/ndmc.log" "ip route 203.0.113.13 255.255.255.255 Wireguard0 auto"
if [ -f "$K/bot.conf.keep" ]; then mv "$K/bot.conf.keep" "$K/etc/watchdog/bot.conf"; else rm -f "$K/etc/watchdog/bot.conf"; fi
sb_k sites
check "video: in the list"      has x "$K/out" "сами уходят в VPN"
# a routed server that went silent through the tunnel too: an hour later it is marked, the next hour its route goes
: > "$K/video-novpn-203.0.113.5"
vs_age; : > "$K/ndmc.log"; sb_k sites refresh video
check "prune: once is not enough"   hasnt x "$K/ndmc.log" "no ip route 203.0.113.5"
check "prune: marked"               grep -q "^203.0.113.5 [0-9]* gone$" "$K/etc/switchback/video.seen"
check "prune: answering one kept"   grep -q "^198.51.100.9 [0-9]* ok$" "$K/etc/switchback/video.seen"
vs_age; : > "$K/ndmc.log"; sb_k sites refresh video
check "prune: route removed"        has x "$K/ndmc.log" "no ip route 203.0.113.5 255.255.255.255 Wireguard0"
check "prune: out of the routes"    hasnt x "$K/etc/switchback/sites.routes" "203.0.113.5 "
check "prune: not routed again"     hasnt x "$K/ndmc.log" "ip route 203.0.113.5 255.255.255.255 Wireguard0 auto"
check "prune: answering one stays"  has x "$K/etc/switchback/sites.routes" "198.51.100.9 video"
rm -f "$K/video-novpn-203.0.113.5"
# a route for the name only (.13) goes after 6 hours, to be checked anew; a route by address (.9) stays.
# Routes made before 0.7.5 have no line in video.kind: a Google one counts as "name" from now, any other as "addr"
printf '203.0.113.20 video\n198.51.100.20 video\n' >> "$K/etc/switchback/sites.routes"; : > "$K/ip-dead-198.51.100.20"
: > "$K/ndmc.log"; sb_k sites refresh video
check "old route: Google counts as name"   grep -q "^203.0.113.20 [0-9]* name$" "$K/etc/switchback/video.kind"
check "old route: other counts as address" grep -q "^198.51.100.20 [0-9]* addr$" "$K/etc/switchback/video.kind"
check "old route: not taken at once"       hasnt x "$K/ndmc.log" "no ip route 203.0.113.20"
check "kind: gone with its route"          hasnt x "$K/etc/switchback/video.kind" "203.0.113.5 "
awk '{$2 = 1; print}' "$K/etc/switchback/video.kind" > "$K/vk"; mv "$K/vk" "$K/etc/switchback/video.kind"
: > "$K/ndmc.log"; sb_k sites refresh video
check "name route: taken after 6 h"   has x "$K/ndmc.log" "no ip route 203.0.113.13 255.255.255.255 Wireguard0"
check "name route: old one too"       has x "$K/ndmc.log" "no ip route 203.0.113.20 255.255.255.255 Wireguard0"
check "name route: out of the routes" hasnt x "$K/etc/switchback/sites.routes" "203.0.113.13 "
check "name route: logged"            has x "$K/var/log/switchback.log" "server 203.0.113.13: routed for its name 6 h ago"
check "name route: not back at once"  hasnt x "$K/ndmc.log" "ip route 203.0.113.13 255.255.255.255 Wireguard0 auto"
check "address route: stays"          has x "$K/etc/switchback/sites.routes" "198.51.100.9 video"
check "old other route: stays"        has x "$K/etc/switchback/sites.routes" "198.51.100.20 video"
# 10 minutes later the cut-off one is checked again and comes back in the usual way
vs_age; : > "$K/ndmc.log"; sb_k sites refresh video
check "name route: back if cut off"   has x "$K/ndmc.log" "ip route 203.0.113.13 255.255.255.255 Wireguard0 auto"
# a server cut off by its address answers directly again (seen 2026-11-18): it is asked past its route (bound to
# the way to the internet), marked the first hour, its route goes the next one; a route for the name is not asked so
rm -f "$K/ip-dead-198.51.100.9"
vs_age; : > "$K/ndmc.log"; : > "$K/curl.log"; sb_k sites refresh video
check "direct again: asked past the route" has x "$K/curl.log" "--interface ppp0 -w %{time_appconnect} https://198.51.100.9/"
check "direct again: through zapret"       has x "$K/curl.log" "--local-port 61000-61099 --interface ppp0"
check "direct again: once is not enough"   hasnt x "$K/ndmc.log" "no ip route 198.51.100.9"
check "direct again: marked"               grep -q "^198.51.100.9 [0-9]* direct$" "$K/etc/switchback/video.seen"
check "direct again: name route not asked" equal x "$(grep -c 'ppp0.*203[.]0[.]113' "$K/curl.log")" 0
vs_age; : > "$K/ndmc.log"; sb_k sites refresh video
check "direct again: route removed"     has x "$K/ndmc.log" "no ip route 198.51.100.9 255.255.255.255 Wireguard0"
check "direct again: out of the routes" hasnt x "$K/etc/switchback/sites.routes" "198.51.100.9 "
check "direct again: kind gone"         hasnt x "$K/etc/switchback/video.kind" "198.51.100.9 "
check "direct again: seen ok"           grep -q "^198.51.100.9 [0-9]* ok$" "$K/etc/switchback/video.seen"
check "direct again: logged"            has x "$K/var/log/switchback.log" "server 198.51.100.9: answers directly again"
check "direct again: not routed back"   hasnt x "$K/ndmc.log" "ip route 198.51.100.9 255.255.255.255 Wireguard0 auto"
check "direct again: silent one stays"  has x "$K/etc/switchback/sites.routes" "198.51.100.20 video"
# while "tune" tries settings (and 15 minutes after its start) nothing is checked
date +%s > "$K/etc/switchback/tune.running"; rm -f "$K/etc/switchback/video.seen"; : > "$K/curl.log"
sb_k sites refresh video
check "video: waits for tune"   hasnt x "$K/curl.log" "203.0.113"
rm -f "$K/etc/switchback/tune.running"
: > "$K/ndmc.log"; sb_k sites video off
check "video: routes removed"   has x "$K/ndmc.log" "no ip route 198.51.100.20 255.255.255.255 Wireguard0"
check "video: out of the list"  hasnt x "$K/etc/switchback/sites" "rescue video"
check "video: out of journal"   hasnt x "$K/etc/switchback/state" "site rescue video"
unset SB_CONNTRACK SB_VIDEO_NETS SB_VIDEO_PAUSE SB_VIDEO_TRY SB_WAN_DEV
# a chosen device reaches Google/YouTube through the tunnel (a fake "ip" only: SB_IPCMD)
cat > "$K/ipfake" <<'EOF'
#!/bin/sh
echo "ip $*" >> "$IPD/ip.log"
case "$1 $2" in
  "neigh show") if [ -n "$3" ]; then grep "^$3 " "$IPD/neigh" 2>/dev/null; else cat "$IPD/neigh" 2>/dev/null; fi ;;
  "route get") if [ -f "$IPD/no-tunnel" ]; then echo "$3 via 100.64.0.1 dev eth3  src 100.64.0.2"; else echo "$3 dev nwg0  src 10.0.0.2"; fi ;;
  "route show") case "$*" in *default*) echo "default via 100.64.0.1 dev eth3" ;; *) cat "$IPD/tb" 2>/dev/null ;; esac ;;
  "route replace") echo "$3 dev $5 " >> "$IPD/tb" ;;
  "route flush") : > "$IPD/tb" ;;
  "rule add") echo "150:	from $4 lookup $6 " >> "$IPD/rules" ;;
  "rule del") grep -v "from $4 lookup" "$IPD/rules" > "$IPD/rules.t"; mv "$IPD/rules.t" "$IPD/rules" ;;
  "rule ") cat "$IPD/rules" 2>/dev/null ;;
esac
exit 0
EOF
echo "192.168.1.50 dev br0 lladdr AA:BB:CC:00:00:50 REACHABLE" > "$K/neigh"; : > "$K/rules"; : > "$K/tb"
export IPD="$K" SB_IPCMD="sh $K/ipfake"
sb_k sites tv add 192.168.1.77 tv
check "tv: unknown device refused" equal x "$RC" 1
sb_k sites tv add 192.168.1.50 tv
check "tv: added"               has x "$K/etc/switchback/tv.devices" "aa:bb:cc:00:00:50 tv"
check "tv: job installed"       exists x "$K/etc/cron.1min/sb-tv"
check "tv: in the journal"      has x "$K/etc/switchback/state" "tvvpn aa:bb:cc:00:00:50"
check "tv: rule for the device" has x "$K/rules" "from 192.168.1.50 lookup 109"
check "tv: Google net to tunnel" has x "$K/tb" "74.125.0.0/16 dev nwg0"
sh "$K/etc/cron.1min/sb-tv"
check "tv: rule not twice"      equal x "$(grep -c 'lookup 109' "$K/rules")" 1
check "tv: routes not twice"    equal x "$(grep -c '^74.125.0.0/16 ' "$K/tb")" 1
# the device is off: the rule stays for its last address; it comes back with another address: the rule moves
: > "$K/neigh"; sh "$K/etc/cron.1min/sb-tv"
check "tv: off, rule kept"      has x "$K/rules" "from 192.168.1.50 lookup 109"
echo "192.168.1.51 dev br0 lladdr aa:bb:cc:00:00:50 REACHABLE" > "$K/neigh"; sh "$K/etc/cron.1min/sb-tv"
check "tv: new address"         has x "$K/rules" "from 192.168.1.51 lookup 109"
check "tv: old address gone"    hasnt x "$K/rules" "from 192.168.1.50 "
# no tunnel now: the table is emptied, the device goes directly
touch "$K/no-tunnel"; sh "$K/etc/cron.1min/sb-tv"
check "tv: no tunnel, no routes" equal x "$(cat "$K/tb")" ""
check "tv: no tunnel, no rule"  hasnt x "$K/rules" "lookup 109"
rm -f "$K/no-tunnel"; sh "$K/etc/cron.1min/sb-tv"
check "tv: tunnel back, rule back" has x "$K/rules" "from 192.168.1.51 lookup 109"
sb_k sites tv
check "tv: in the list"         has x "$K/out" "[ok] tv"
sb_k sites tv del tv
check "tv: removed from the file" hasnt x "$K/etc/switchback/tv.devices" "aa:bb:cc"
check "tv: rule removed"        hasnt x "$K/rules" "lookup 109"
check "tv: out of the journal"  hasnt x "$K/etc/switchback/state" "tvvpn"
unset IPD SB_IPCMD
# bot: answers the owner only, takes "/cmd@BotName"
# Telegram sends Cyrillic as backslash-u escapes: the last message is «Статус» typed as a plain word
# (the escapes are put together here, so none is written out in this file)
B=$(printf '\134')
WORD="${B}u0421${B}u0442${B}u0430${B}u0442${B}u0443${B}u0441"
# (and, like the real Telegram, a line break after each update_id)
printf '%s\n' '{"ok":true,"result":[{"update_id":5,' '"message":{"chat":{"id":-100},"text":"/sites"}},{"update_id":6,' '"message":{"chat":{"id":999},"text":"/status"}},{"update_id":7,' '"message":{"chat":{"id":-100},"text":"/help@MyBot"}},{"update_id":8,' '"message":{"chat":{"id":-100},"text":"'"$WORD"'"}}]}' > "$K/updates"
: > "$K/curl.log"
SB_OPT=$K SB_BOT_ONCE=1 SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$K/etc/cron.1min/sb-bot" --run > /dev/null 2>&1
check "three answers"          equal x "$(grep -c sendMessage "$K/curl.log")" 3
check "stranger ignored"       equal x "$(grep -c status "$K/var/sb-bot/log")" 1
check "Russian word understood" has x "$K/var/sb-bot/log" "command /status"
check "offset saved"           equal x "$(cat "$K/var/sb-bot/offset")" 9
check "sites answered"         has x "$K/curl.log" "example.org"
# actions: list, ask, "да" (sent as escapes, put together here), done; a stale "yes" does nothing
YES="${B}u0434${B}u0430"
printf '10.3.3.3\n' > "$K/dns-viabot.example"
rm -f "$K/var/sb-bot/offset"
botmsg "/tunnel" "/site add viabot.example vpn" "$YES" "/restart zapret" "yes" "/node"
: > "$K/curl.log"; SB_OPT=$K SB_BOT_ONCE=1 SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$K/etc/cron.1min/sb-bot" > /dev/null 2>&1
check "bot: tunnels listed"    has x "$K/curl.log" "Wireguard0: подключено"
check "bot: asks first"        has x "$K/curl.log" "Добавить viabot.example (способ: vpn)? Ответьте"
check "bot: site added on yes" has x "$K/etc/switchback/sites" "vpn viabot.example"
check "bot: zapret restarted"  has x "$K/curl.log" "zapret перезапущен и работает"
check "bot: no node script"    has x "$K/curl.log" "Автосмена узлов Claude не установлена"
check "bot: actions logged"    has x "$K/var/sb-bot/log" "action site add viabot.example vpn"
echo "1 site del viabot.example" > "$K/var/sb-bot/pending"; botmsg "yes"
: > "$K/curl.log"; SB_OPT=$K SB_BOT_ONCE=1 SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$K/etc/cron.1min/sb-bot" > /dev/null 2>&1
check "bot: stale yes refused" has x "$K/curl.log" "Прошло больше 5 минут"
check "bot: site still there"  has x "$K/etc/switchback/sites" "vpn viabot.example"
botmsg "/tunnel nosuch1" "/site add bad_site vpn"
: > "$K/curl.log"; SB_OPT=$K SB_BOT_ONCE=1 SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$K/etc/cron.1min/sb-bot" > /dev/null 2>&1
check "bot: odd input refused" has x "$K/curl.log" "Нужно: /site add example.com vpn"
# buttons: the menu comes with the help; a question comes with Да/Нет; a pressed button (callback_query) is a
# command and gets acknowledged; «Нет» cancels; the menu word «Туннели» (escapes) lists the tunnels
printf '10.3.3.4\n' > "$K/dns-viabot2.example"
botmsg "/help" "/site add viabot2.example vpn"
: > "$K/curl.log"; SB_OPT=$K SB_BOT_ONCE=1 SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$K/etc/cron.1min/sb-bot" > /dev/null 2>&1
check "bot: menu with help"    has x "$K/curl.log" '"keyboard":[[{"text":"Что-то не работает"}]'
check "bot: Да/Нет buttons"    has x "$K/curl.log" '"callback_data":"no"'
printf '%s\n' '{"ok":true,"result":[{"update_id":201,"callback_query":{"id":"77","from":{"id":5},"message":{"message_id":3,"chat":{"id":-100},"text":"Добавить?","reply_markup":{"inline_keyboard":[[{"text":"Да","callback_data":"yes"}]]}},"chat_instance":"1","data":"yes"}}]}' > "$K/updates"
: > "$K/curl.log"; SB_OPT=$K SB_BOT_ONCE=1 SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$K/etc/cron.1min/sb-bot" > /dev/null 2>&1
check "bot: button pressed"    has x "$K/etc/switchback/sites" "vpn viabot2.example"
check "bot: button acknowledged" has x "$K/curl.log" "answerCallbackQuery"
NO="${B}u041d${B}u0435${B}u0442"; TUN="${B}u0422${B}u0443${B}u043d${B}u043d${B}u0435${B}u043b${B}u0438"
botmsg "/site del viabot2.example" "$NO" "$TUN"
: > "$K/curl.log"; SB_OPT=$K SB_BOT_ONCE=1 SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$K/etc/cron.1min/sb-bot" > /dev/null 2>&1
check "bot: «Нет» cancels"     has x "$K/curl.log" "Отменено"
check "bot: site kept"         has x "$K/etc/switchback/sites" "vpn viabot2.example"
check "bot: «Туннели» button"  has x "$K/curl.log" "Wireguard0: подключено"
# /ai (lib/ai.sh, off here): the menu word «Claude» and «клод» (escapes) lead to it, with the switch's buttons;
# asking for claude.ai «through VPN» as an own site ends with the same button, not a dead end
KLOD="${B}u041a${B}u043b${B}u043e${B}u0434"
botmsg "Claude" "$KLOD"
: > "$K/curl.log"; SB_OPT=$K SB_BOT_ONCE=1 SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$K/etc/cron.1min/sb-bot" > /dev/null 2>&1
check "bot: «Claude» -> /ai"   equal x "$(grep -c 'command /ai' "$K/var/sb-bot/log")" 2
check "bot: /ai buttons"       has x "$K/curl.log" '"callback_data":"ai vpn"'
botmsg "/site add claude.ai vpn"
: > "$K/curl.log"; SB_OPT=$K SB_BOT_ONCE=1 SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$K/etc/cron.1min/sb-bot" > /dev/null 2>&1
botmsg "/yes"
: > "$K/curl.log"; SB_OPT=$K SB_BOT_ONCE=1 SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$K/etc/cron.1min/sb-bot" > /dev/null 2>&1
check "bot: AI site via VPN -> the switch" has x "$K/curl.log" '"callback_data":"ai vpn"'
check "bot: no router command for a person" hasnt x "$K/curl.log" "sh+install.sh"
check "bot: no router command (plain)" hasnt x "$K/curl.log" "sh install.sh"
check "bot: AI site not added" hasnt x "$K/etc/switchback/sites" "claude.ai"
# /check: own sites are checked, the line of the cut-off servers job ("rescue video") is not a site
grep -qx 'rescue video' "$K/etc/switchback/sites" || echo 'rescue video' >> "$K/etc/switchback/sites"
botmsg "/check"
: > "$K/curl.log"; SB_OPT=$K SB_BOT_ONCE=1 SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$K/etc/cron.1min/sb-bot" > /dev/null 2>&1
check "bot: check own site"    has x "$K/curl.log" "https://viabot2.example"
check "bot: no «video» site"   hasnt x "$K/curl.log" "https://video"
# «Что-то не работает»: all fine; YouTube down -> the tune button; no internet at all -> the provider
printf 'MemTotal: 100000 kB\nMemAvailable: 50000 kB\n' > "$K/meminfo-ok"
DIAG="${B}u0427${B}u0442${B}u043e-${B}u0442${B}u043e ${B}u043d${B}u0435 ${B}u0440${B}u0430${B}u0431${B}u043e${B}u0442${B}u0430${B}u0435${B}u0442"
botmsg "$DIAG"; bot1
check "diag: menu word"        has x "$K/var/sb-bot/log" "command /diag"
check "diag: all fine"         has x "$K/curl.log" "Со стороны роутера всё в порядке"
check "diag: phone video button" has x "$K/curl.log" '"callback_data":"quic"'
touch "$K/site-dead-www.youtube.com"; botmsg "/diag"; bot1
check "diag: YouTube down"     has x "$K/curl.log" "YouTube не открывается, хотя zapret работает"
check "diag: tune button"      has x "$K/curl.log" '"callback_data":"tune"'
rm -f "$K/site-dead-www.youtube.com"; touch "$K/net-down"; botmsg "/diag"; bot1
check "diag: no internet"      has x "$K/curl.log" "Интернета нет"
rm -f "$K/net-down"
# an address sent as it is: checked; not opening -> buttons to add it
botmsg "https:${B}/${B}/Example.COM${B}/page?x=1"; bot1
check "diag: link understood"  has x "$K/curl.log" "example.com открывается с роутера"
printf '10.9.9.1\n' > "$K/dns-blocked.example"; printf '10.9.9.2\n' > "$K/dns-cut.example"
touch "$K/site-dead-blocked.example"; botmsg "blocked.example"; bot1
check "diag: offers zapret"    has x "$K/curl.log" '"callback_data":"site add blocked.example zapret"'
rm -f "$K/site-dead-blocked.example"
touch "$K/site-cut-cut.example"; botmsg "cut.example"; bot1
check "diag: cut site not open" has x "$K/curl.log" '"callback_data":"site add cut.example zapret"'
rm -f "$K/site-cut-cut.example"
# «Телевизор»: add (asks first), list with a button, remove, then a button to bring it back
botmsg "/tv add aa:bb:cc:dd:ee:01 tv" "yes"; bot1
check "tv: asks first"         has x "$K/curl.log" "Пустить Google и YouTube устройства tv через VPN"
check "tv: added"              has x "$K/etc/switchback/tv.devices" "aa:bb:cc:dd:ee:01 tv"
botmsg "/tv"; bot1
check "tv: remove button"      has x "$K/curl.log" '"callback_data":"tv del tv"'
botmsg "/tv del tv" "yes" "/tv"; bot1
check "tv: removed"            hasnt x "$K/etc/switchback/tv.devices" "aa:bb:cc:dd:ee:01"
check "tv: back button"        has x "$K/curl.log" '"callback_data":"tv add aa:bb:cc:dd:ee:01 tv"'
botmsg "/tv del x;reboot"; bot1
check "tv: odd name refused"   has x "$K/curl.log" "Нужно: /tv del"
# «Подобрать zapret»: asks, runs on its own, sends the result with «Вернуть как было»
botmsg "/tune" "yes"; bot1
check "tune: asks first"       has x "$K/curl.log" "Подобрать настройки zapret?"
check "tune: started"          has x "$K/curl.log" "Начинаю подбор"
check "tune: undo button"      has x "$K/curl.log" '"callback_data":"tune undo"'
# «Видео на телефоне тормозит» (/quic): what servers sent and a button for another way; it asks, then switches
botmsg "/quic"; bot1
check "quic: status shown"     has x "$K/curl.log" "способ для QUIC"
check "quic: next button"      has x "$K/curl.log" '"callback_data":"quic next"'
botmsg "/quic next" "yes"; bot1
check "quic: asks first"       has x "$K/curl.log" "Включить другой способ для QUIC"
check "quic: switched"         has x "$K/etc/nfqws2/nfqws2.conf" "fake:blob=fake_default_quic:repeats=12"
check "quic: undo button"      has x "$K/curl.log" '"callback_data":"quic undo"'
botmsg "/quic undo" "yes"; bot1
check "quic: undone"           has x "$K/etc/nfqws2/nfqws2.conf" "quic_initial:ip_autottl=-2,3-20:repeats=10"
# servers sent as files: kept until «Проверить и добавить», then checked on their own, the files wiped
printf '[Interface]\nPrivateKey = %s\nAddress = 10.8.0.2/32\n[Peer]\nPublicKey = SERVERpubKEYforTESTSonly0123456789abcdefgh=\nEndpoint = 203.0.113.51:51820\n' "$PRIV" > "$K/tg-file"
botdoc "photo.jpg"; bot1
check "file: other kind refused" has x "$K/curl.log" "Этот файл мне не подходит"
botdoc "nl.conf"; bot1
check "file: its own id asked"   has x "$K/curl.log" "file_id=F1"
check "file: kept for later"     exists x "$K/var/sb-bot/wg-in/1.conf"
check "file: check button"       has x "$K/curl.log" '"callback_data":"wgb go"'
check "file: key not in the log" hasnt x "$K/var/sb-bot/log" "$PRIV"
export SB_WG_SLEEP=0; botmsg "/wgb go" "yes"; bot1; unset SB_WG_SLEEP
check "file: asks first"         has x "$K/curl.log" "Проверить серверы из присланных файлов (1)"
check "file: started"            has x "$K/curl.log" "Начинаю проверку серверов"
check "file: result sent"        has x "$K/curl.log" "Итог: проверено 1 из 1"
check "file: wiped after"        missing x "$K/var/sb-bot/wg-job"
check "file: none left waiting"  missing x "$K/var/sb-bot/wg-in"
check "file: not running"        missing x "$K/etc/switchback/wgb.running"
botdoc "de.zip"; bot1; botmsg "/wgb drop"; bot1
check "file: drop wipes"         missing x "$K/var/sb-bot/wg-in"
# update: scripts rewritten from the new text, settings kept
# watchdog: a broken /dev/null (here a stand-in file) is noticed and reported
check "watchdog checks /dev/null" has x "$K/etc/cron.5mins/watchdog" "devnull"
check "zapret restart path filled" hasnt x "$K/etc/cron.5mins/watchdog" "__NFQINIT__"
echo junk > "$K/fake-null"; : > "$K/curl.log"
SB_DEVNULL=$K/fake-null "$SH" -c "sed '/^check /d' '$K/etc/cron.5mins/watchdog' > '$K/wd-only'; SB_OPT=$K sh '$K/wd-only'" > /dev/null 2>&1
check "broken /dev/null reported" has x "$K/curl.log" "системный файл /dev/null"
echo "# old text" >> "$K/etc/cron.5mins/watchdog"; echo old > "$K/etc/switchback/app/VERSION"
cp "$K/etc/switchback/sites" "$K/sites.before"
# a copy from before 0.7.5 has app/lists without VERSION (seen 2026-11-18): no "can't open" on the screen
rm -f "$K/etc/switchback/app/lists/VERSION"
sb_k update --progress
check "update exit 0"          equal x "$RC" 0
check "update: no lists VERSION, quiet" hasnt x "$K/out" "lists/VERSION"
check "update event"           has x "$K/out" "@@sb	updated	old	"
check "watchdog rewritten"     hasnt x "$K/etc/cron.5mins/watchdog" "# old text"
check "sites kept"             equal x "$(cat "$K/sites.before")" "$(cat "$K/etc/switchback/sites")"
check "doctor shows version"   has x "$(sb_k doctor --progress; echo "$K/out")" "@@sb	installed	"
# lists apply: the program put newer lists into the copy and runs the copy; only additions, own routes kept
A=$K/etc/switchback/app
echo 7 > "$A/lists/VERSION"
echo "203.0.113.0/255.255.255.0" >> "$A/lists/telegram.nets"
echo "lists-new.example" >> "$A/lists/zapret.domains"
: > "$K/ndmc.log"
sb_a() { SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$A/install.sh" "$@" > "$K/out" 2>&1; RC=$?; }
sb_a lists apply --progress
check "lists apply exit 0"      equal x "$RC" 0
check "lists apply event"       has x "$K/out" "@@sb	lists_applied	7"
check "lists: new Telegram net" has x "$K/ndmc.log" "ip route 203.0.113.0 255.255.255.0 Wireguard0 auto"
check "lists: old net not again" hasnt x "$K/ndmc.log" "ip route 91.108.56.0 255.255.252.0"
check "lists: new zapret domain" has x "$K/etc/nfqws2/lists/user.list" "lists-new.example"
check "lists: kept for uninstall" has x "$K/etc/switchback/state" "list lists-new.example"
check "lists: sites kept"       equal x "$(cat "$K/sites.before")" "$(cat "$K/etc/switchback/sites")"
sb_a lists --progress
check "lists status: version"   has x "$K/out" "@@sb	lists	7	0"
sb_a lists bogus
check "lists: unknown -> 2"     equal x "$RC" 2
# a newer version of switchback keeps lists downloaded later than its own (a higher lists/VERSION)
sb_k update
check "update keeps newer lists" has x "$A/lists/zapret.domains" "lists-new.example"
# lists put: the program sends the lists as tar.gz on stdin; the old ones go to lists.prev, then apply
L=$K/lists-in; rm -rf "$L"; mkdir -p "$L"; cp "$A"/lists/* "$L/"; echo 8 > "$L/VERSION"
echo "198.51.100.0/255.255.255.0" >> "$L/telegram.nets"
(cd "$L" && tar czf "$K/lists.tgz" *)
: > "$K/ndmc.log"
sb_k lists put --progress < "$K/lists.tgz"
check "lists put exit 0"        equal x "$RC" 0
check "lists put: applied 8"    has x "$K/out" "@@sb	lists_applied	8"
check "lists put: in the copy"  has x "$A/lists/telegram.nets" "198.51.100.0"
check "lists put: old kept"     has x "$K/etc/switchback/lists.prev/VERSION" "7"
check "lists put: routed"       has x "$K/ndmc.log" "ip route 198.51.100.0 255.255.255.0 Wireguard0 auto"
check "lists put: no temp left" missing x "$K/etc/switchback/lists.new"
sb_k lists put < "$K/lists.tgz"
check "same version refused"    equal x "$RC" 1
check "refused: copy unchanged" has x "$A/lists/VERSION" "8"
echo 9 > "$L/VERSION"; echo "rm -rf /" > "$L/evil.sh"; (cd "$L" && tar czf "$K/lists.tgz" *)
sb_k lists put < "$K/lists.tgz"
check "extra file refused"      equal x "$RC" 1
check "extra: nothing put"      missing x "$A/lists/evil.sh"
rm -f "$L/evil.sh"
# what left the lists comes off the router, but only what switchback put there itself
lput() { echo "$1" > "$L/VERSION"; (cd "$L" && tar czf "$K/lists.tgz" *); : > "$K/ndmc.log"; : > "$K/curl.log"; sb_k lists put --progress < "$K/lists.tgz"; }
echo "hand.example" >> "$K/etc/nfqws2/lists/user.list"; echo "hand.example" >> "$L/zapret.domains"
lput 10
check "lists 10 applied"        equal x "$RC" 0
check "hand domain not ours"    hasnt x "$K/etc/switchback/state" "list hand.example"
check "bot told: updated"       has x "$K/curl.log" "Списки обновлены до версии 10"
grep -v "^203.0.113.0/" "$L/telegram.nets" > "$L/t" && mv "$L/t" "$L/telegram.nets"
grep -v "^lists-new.example\$\|^hand.example\$" "$L/zapret.domains" > "$L/t" && mv "$L/t" "$L/zapret.domains"
lput 11
check "lists 11 applied"        equal x "$RC" 0
check "gone net: route removed" has x "$K/ndmc.log" "no ip route 203.0.113.0 255.255.255.0 Wireguard0"
check "gone net: forgotten"     hasnt x "$K/etc/switchback/state" "route 203.0.113.0 "
check "gone domain removed"     hasnt x "$K/etc/nfqws2/lists/user.list" "lists-new.example"
check "gone domain: forgotten"  hasnt x "$K/etc/switchback/state" "list lists-new.example"
check "hand domain kept"        has x "$K/etc/nfqws2/lists/user.list" "hand.example"
check "hand route kept"         hasnt x "$K/ndmc.log" "no ip route 91.108.56.0"
check "kept nets stay"          hasnt x "$K/ndmc.log" "no ip route 198.51.100.0"
check "bot told: removed"       has x "$K/curl.log" "убрано: 2"
# lists restore: the previous lists back, what they had comes back on the router
: > "$K/ndmc.log"; : > "$K/curl.log"
sb_k lists restore --progress
check "restore exit 0"          equal x "$RC" 0
check "restore event"           has x "$K/out" "@@sb	lists_restored	10"
check "restore: copy is 10"     has x "$A/lists/VERSION" "10"
check "restore: 11 kept as prev" has x "$K/etc/switchback/lists.prev/VERSION" "11"
check "restore: domain back"    has x "$K/etc/nfqws2/lists/user.list" "lists-new.example"
check "restore: route back"     has x "$K/ndmc.log" "ip route 203.0.113.0 255.255.255.0 Wireguard0 auto"
check "restore: bot told"       has x "$K/curl.log" "Вернул прежние списки (версия 10"
sb_k lists --progress
check "status: prev version"    has x "$K/out" "@@sb	lists	10	11"
# automatic rollback: a new route breaks Telegram -> the previous lists come back by themselves
cp "$A"/lists/* "$L/"; echo "192.0.2.0/255.255.255.0" >> "$L/telegram.nets"
lput 12
check "worse: refused (1)"      equal x "$RC" 1
check "worse: rollback event"   has x "$K/out" "@@sb	lists_rollback	10"
check "worse: copy back to 10"  has x "$A/lists/VERSION" "10"
check "worse: bad route removed" has x "$K/ndmc.log" "no ip route 192.0.2.0 255.255.255.0 Wireguard0"
check "worse: Telegram back"    missing x "$K/tg-down"
check "worse: not in journal"   hasnt x "$K/etc/switchback/state" "route 192.0.2.0 "
check "worse: told (ntfy/bot)"  has x "$K/curl.log" "сам вернул прежние"
# automatic rollback: the router refuses a route in the middle of "lists apply"
cp "$A"/lists/* "$L/"; echo "203.0.113.128/255.255.255.128" >> "$L/telegram.nets"; echo "mid.example" >> "$L/zapret.domains"
lput 13
check "broken: refused (1)"     equal x "$RC" 1
check "broken: rollback event"  has x "$K/out" "@@sb	lists_rollback	10"
check "broken: copy back to 10" has x "$A/lists/VERSION" "10"
check "broken: nothing left"    hasnt x "$K/etc/nfqws2/lists/user.list" "mid.example"
check "broken: told"            has x "$K/curl.log" "применение прервалось"
rm -rf "$K/etc/switchback/lists.prev"
sb_k lists restore
check "restore without prev: 1" equal x "$RC" 1
# tuning: the fast way goes first under circular; nothing better -> nothing changes; undo
printf 'NFQWS_ARGS="--filter-tcp=443\n            --lua-desync=multisplit:pos=1\n            --payload=http_req"\nNFQWS_EXTRA_ARGS="$MODE_LIST"\n' > "$K/etc/nfqws2/nfqws2.conf"
printf 'youtube.com\ngooglevideo.com\ndiscord.com\n' >> "$K/etc/nfqws2/lists/user.list"
echo "fakeddisorder:pos=midsld:tcp_md5" > "$K/tune-best"
sb_k tune --progress
check "tune exit 0"            equal x "$RC" 0
check "tune: busy mark gone"   missing x "$K/etc/switchback/tune.running"
check "all ways tried"         equal x "$(ev_count "$K/out" tune_try)" 12
check "new ways tried"         has x "$K/out" "fake-google8+multisplit-seqovl"
check "new ways: noack too"    has x "$K/out" "fake-noack+fakeddisorder"
check "lone multisplit gone"   equal x "$(grep -cE 'tune_try.[0-9]+.[0-9]+.multisplit$' "$K/out")" 0
check "fast way first"         has x "$K/etc/nfqws2/nfqws2.conf" "--lua-desync=circular:fails=2:time=300:retrans=3:nld=2 --lua-desync=fakeddisorder:pos=midsld:tcp_md5:strategy=1"
check "Google way always last" has x "$K/etc/nfqws2/nfqws2.conf" "--lua-desync=hostfakesplit:host=www.google.com:tcp_ts=-600000:strategy=4 --payload=http_req"
check "one NFQWS_ARGS line"    equal x "$(grep -c '^ ' "$K/etc/nfqws2/nfqws2.conf")" 0
check "other settings kept"    has x "$K/etc/nfqws2/nfqws2.conf" 'NFQWS_EXTRA_ARGS="$MODE_LIST"'
cp "$K/etc/nfqws2/nfqws2.conf" "$K/tuned"
sb_k tune
check "nothing better: kept"   equal x "$(cat "$K/tuned")" "$(cat "$K/etc/nfqws2/nfqws2.conf")"
check "kept: busy mark gone"   missing x "$K/etc/switchback/tune.running"
sb_k tune --undo
check "undo: as before"        has x "$K/etc/nfqws2/nfqws2.conf" "--lua-desync=multisplit:pos=1"
# ways of their own for YouTube video servers: on, again, off; settings written by hand are left alone
sb_k tune video on --progress
check "video ways: on"          has x "$K/out" "@@sb	tune_video	on	done"
check "video ways: profile"     has x "$K/etc/nfqws2/nfqws2.conf" "--hostlist-domains=googlevideo.com --out-range=-d8 --payload=tls_client_hello --lua-desync=circular"
check "video ways: all seven"   has x "$K/etc/nfqws2/nfqws2.conf" "seqovl_pattern=tls_clienthello:strategy=7"
check "video ways: two steps"   has x "$K/etc/nfqws2/nfqws2.conf" "fake:blob=0x00000000:tcp_flags_unset=ack:strategy=6 --lua-desync=fakeddisorder:pos=midsld:tcp_flags_unset=ack:strategy=6"
check "video ways: per server"  has x "$K/etc/nfqws2/nfqws2.conf" "--payload=tls_client_hello --lua-desync=circular:fails=2:time=300:retrans=3 --lua-desync="
check "video ways: no nld"      equal x "$(grep '^NFQWS_ARGS_CUSTOM=' "$K/etc/nfqws2/nfqws2.conf" | grep -c nld)" 0
check "video ways: no hostfake" hasnt x "$K/etc/nfqws2/nfqws2.conf" "hostfakesplit:host=www.google.com:tcp_ts=-600000:strategy="
check "video ways: main kept"   has x "$K/etc/nfqws2/nfqws2.conf" "--lua-desync=multisplit:pos=1"
sb_k tune video on --progress
check "video ways: not twice"   has x "$K/out" "@@sb	tune_video	on	exists"
# a profile of an earlier version (one circle by site, nld=2): "on" puts this one in, "off" takes it away
vold='NFQWS_ARGS_CUSTOM="--filter-tcp=443 --filter-l7=tls --hostlist-domains=googlevideo.com --out-range=-d8 --payload=tls_client_hello --lua-desync=circular:fails=2:time=300:retrans=3:nld=2 --lua-desync=multisplit:pos=2:strategy=1"'
sed -i "s|^NFQWS_ARGS_CUSTOM=.*|$vold|" "$K/etc/nfqws2/nfqws2.conf"
sb_k tune video on --progress
check "video ways: old updated" has x "$K/out" "@@sb	tune_video	on	done"
check "video ways: old said"    has x "$K/out" "обновлено: 7 способов"
check "video ways: old gone"    equal x "$(grep '^NFQWS_ARGS_CUSTOM=' "$K/etc/nfqws2/nfqws2.conf" | grep -c nld)" 0
sed -i "s|^NFQWS_ARGS_CUSTOM=.*|$vold|" "$K/etc/nfqws2/nfqws2.conf"
sb_k tune video off --progress
check "video ways: old off"     has x "$K/etc/nfqws2/nfqws2.conf" 'NFQWS_ARGS_CUSTOM=""'
sb_k tune video on --progress
sb_k tune video off --progress
check "video ways: off"         has x "$K/etc/nfqws2/nfqws2.conf" 'NFQWS_ARGS_CUSTOM=""'
sed -i 's|^NFQWS_ARGS_CUSTOM=.*|NFQWS_ARGS_CUSTOM="--filter-tcp=80 --lua-desync=fake"|' "$K/etc/nfqws2/nfqws2.conf"
sb_k tune video on --progress
check "video ways: hand-made stays" has x "$K/etc/nfqws2/nfqws2.conf" 'NFQWS_ARGS_CUSTOM="--filter-tcp=80 --lua-desync=fake"'
check "video ways: refused"     equal x "$RC" 1
sb_k tune video sideways
check "video ways: bad action"  equal x "$RC" 2
# QUIC: the package's way gives way to the working one on an update (once); next goes round the list, undo back to
# what was before the first next; status counts what servers sent over UDP 443; a way written by hand stays
NQ=$K/etc/nfqws2/nfqws2.conf
sed -i '/^NFQWS_ARGS_QUIC=/d' "$NQ"
printf 'NFQWS_ARGS_QUIC="--filter-udp=443 --filter-l7=quic\n   --payload=quic_initial --lua-desync=fake:blob=quic_initial:repeats=11"\n' >> "$NQ"
sb_k update
check "quic update: replaced"   has x "$NQ" 'NFQWS_ARGS_QUIC="--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=quic_initial:ip_autottl=-2,3-20:repeats=10"'
check "quic update: one line"   hasnt x "$NQ" "   --payload=quic_initial"
check "quic update: logged"     has x "$K/var/log/switchback.log" "quic: the package's way replaced"
check "quic update: other kept" has x "$NQ" 'NFQWS_ARGS_CUSTOM="--filter-tcp=80 --lua-desync=fake"'
sb_k update
check "quic update: once"       hasnt x "$K/out" "новый способ для QUIC"
sb_k tune quic next
check "quic next: exit 0"       equal x "$RC" 0
check "quic next: way 2"        has x "$NQ" '--payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=12"'
check "quic next: copy kept"    exists x "$K/etc/switchback/nfqws2.conf.before-quic"
check "quic next: said"         has x "$K/out" "способ 2 из 4"
sb_k tune quic next; sb_k tune quic next
check "quic next: two steps"    has x "$NQ" '--lua-desync=fake:blob=fake_default_quic:repeats=6 --lua-desync=udplen:increment=2"'
sb_k tune quic undo
check "quic undo: as before"    has x "$NQ" 'quic_initial:ip_autottl=-2,3-20:repeats=10"'
check "quic undo: copy gone"    missing x "$K/etc/switchback/nfqws2.conf.before-quic"
sb_k tune quic undo
check "quic undo: nothing left" equal x "$RC" 1
cat > "$K/conntrack-quic" <<'EOF'
ipv4     2 udp      17 170 src=192.168.1.50 dst=142.250.1.1 sport=51000 dport=443 packets=10 bytes=2000 src=142.250.1.1 dst=100.64.0.2 sport=443 dport=51000 packets=900 bytes=3145728 [ASSURED] mark=0 use=2
ipv4     2 udp      17 170 src=192.168.1.50 dst=74.125.1.1 sport=51001 dport=443 packets=10 bytes=2000 src=74.125.1.1 dst=100.64.0.2 sport=443 dport=51001 packets=9 bytes=10240 [ASSURED] mark=0 use=2
ipv4     2 udp      17 170 src=100.64.0.2 dst=8.8.8.8 sport=51002 dport=443 packets=10 bytes=2000 src=8.8.8.8 dst=100.64.0.2 sport=443 dport=51002 packets=9 bytes=9999999 [ASSURED] mark=0 use=2
EOF
SB_CONNTRACK="$K/conntrack-quic" sb_k tune quic status
check "quic status: the way"    has x "$K/out" "способ 1 из 4"
check "quic status: bytes"      has x "$K/out" "142.250.1.1 — 3072 КБ"
check "quic status: small too"  has x "$K/out" "74.125.1.1 — 10 КБ"
check "quic status: home only"  hasnt x "$K/out" "8.8.8.8"
check "quic status: passes"     has x "$K/out" "QUIC проходит"
sed -i '/142.250.1.1/d' "$K/conntrack-quic"
SB_CONNTRACK="$K/conntrack-quic" sb_k tune quic status
check "quic status: fails"      has x "$K/out" "похоже, QUIC не проходит"
sed -i 's|^NFQWS_ARGS_QUIC=.*|NFQWS_ARGS_QUIC="--filter-udp=443 --lua-desync=fake:blob=quic_initial:repeats=3"|' "$NQ"
sb_k tune quic next
check "quic hand-made: refused" equal x "$RC" 1
check "quic hand-made: stays"   has x "$NQ" 'NFQWS_ARGS_QUIC="--filter-udp=443 --lua-desync=fake:blob=quic_initial:repeats=3"'
sb_k update
check "quic hand-made: update"  has x "$NQ" 'NFQWS_ARGS_QUIC="--filter-udp=443 --lua-desync=fake:blob=quic_initial:repeats=3"'
# uninstall takes all of it away
printf 'uninstall_confirm=y\n' > "$K/u"; sb_k uninstall --answers "$K/u"
check "copy removed"           missing x "$K/etc/switchback/app"
check "bot job removed"        missing x "$K/etc/cron.1min/sb-bot"
check "own site removed"       hasnt x "$K/etc/nfqws2/lists/user.list" "example.org"

# reserve channel ntfy: alone (no bot), as the fallback when Telegram does not answer, in a bot.conf that is not ours
keenetic ntfy-only
printf 'profile=custom\nmodules=watchdog\nntfy_url=https://ntfy.sh/sb-testchannel1234\n' > "$K/a"
sb_k install --answers "$K/a"
check "ntfy: exit 0"           equal x "$RC" 0
check "ntfy: saved"            has x "$K/etc/watchdog/bot.conf" "NTFY=https://ntfy.sh/sb-testchannel1234"
check "ntfy: no bot commands"  missing x "$K/etc/cron.1min/sb-bot"
check "ntfy: watchdog there"   exists x "$K/etc/cron.5mins/watchdog"
check "ntfy: test sent"        has x "$K/curl.log" "https://ntfy.sh/sb-testchannel1234"
keenetic ntfy-bad; printf 'profile=custom\nmodules=watchdog\nntfy_url=https://ntfy.sh/short\n' > "$K/a2"
sb_k install --answers "$K/a2"
check "ntfy: short name refused" has x "$K/out" "запасной канал пропущен"
keenetic ntfy-fallback
mkdir -p "$K/etc/watchdog"; printf 'TOKEN=%s\nCHAT=-100\n' "$TOKEN" > "$K/etc/watchdog/bot.conf.user"
cp "$K/etc/watchdog/bot.conf.user" "$K/etc/watchdog/bot.conf"           # the user's own bot.conf
printf 'profile=custom\nmodules=watchdog\nntfy_url=https://ntfy.sh/sb-fallbackchan99\n' > "$K/a"
sb_k install --answers "$K/a"
check "fallback: token kept"   has x "$K/etc/watchdog/bot.conf" "TOKEN=$TOKEN"
check "fallback: line journaled" has x "$K/etc/switchback/state" "conf_line $K/etc/watchdog/bot.conf NTFY"
sed '/^check /d; /^devnull$/d' "$K/etc/cron.5mins/watchdog" > "$K/wd-fn"; echo 'send "TEST ALERT"' >> "$K/wd-fn"
touch "$K/tg-down"; : > "$K/curl.log"; SB_OPT=$K "$SH" "$K/wd-fn" > /dev/null 2>&1
check "fallback: Telegram tried" has x "$K/curl.log" "api.telegram.org"
check "fallback: ntfy got it"  has x "$K/curl.log" "TEST ALERT https://ntfy.sh/sb-fallbackchan99"
rm -f "$K/tg-down"; : > "$K/curl.log"; SB_OPT=$K "$SH" "$K/wd-fn" > /dev/null 2>&1
check "Telegram up: no ntfy"   hasnt x "$K/curl.log" "ntfy.sh"
# a site that is down for one run only (ChatGPT blinks for 5 minutes several times a day): no messages;
# down two runs in a row: DOWN, then BACK
sed '/^check /d; /^devnull$/d' "$K/etc/cron.5mins/watchdog" > "$K/wd-b"
echo 'check chatgpt test -f "$SB_OPT/site-up"' >> "$K/wd-b"
wdb() { SB_WD_STATE=$K/wdstate SB_OPT=$K "$SH" "$K/wd-b" > /dev/null 2>&1; }
: > "$K/curl.log"; : > "$K/var/watchdog-events.log"; rm -f "$K/site-up"; wdb
check "blip: first failure silent" hasnt x "$K/curl.log" "Не работает"
touch "$K/site-up"; wdb
check "blip: recovery silent"   hasnt x "$K/curl.log" "chatgpt"
check "blip: in the events log" has x "$K/var/watchdog-events.log" "BACK chatgpt"
rm -f "$K/site-up"; wdb
check "down again: silent once" hasnt x "$K/curl.log" "Не работает"
wdb
check "two runs down: DOWN sent" has x "$K/curl.log" "Не работает: ChatGPT"
touch "$K/site-up"; wdb
check "then BACK sent"          has x "$K/curl.log" "Снова работает: ChatGPT"
# zapret that is not running is started again and it is reported; little free memory is noticed
# (only the fake pidof and the fake init script of this fake router are used)
cp "$K/bin/pidof" "$K/pidof.orig"; cp "$K/etc/init.d/S51nfqws2" "$K/init.orig"
printf '#!/bin/sh\n[ -f "$SB_OPT/zapret-on" ]\n' > "$K/bin/pidof"
printf '#!/bin/sh\n[ "$1" = start ] && touch "$SB_OPT/zapret-on"\nexit 0\n' > "$K/etc/init.d/S51nfqws2"
sed '/^check /d; /^devnull$/d' "$K/etc/cron.5mins/watchdog" > "$K/wd-z"
printf '%s\n' 'zapret_up; echo "up=$?" > "$SB_OPT/zu.out"' 'mem_ok; echo "mem=$?" >> "$SB_OPT/zu.out"' >> "$K/wd-z"
printf 'MemTotal: 125444 kB\nMemFree: 3000 kB\nMemAvailable: 9000 kB\n' > "$K/mem-low"
printf 'MemTotal: 125444 kB\nMemFree: 9000 kB\nMemAvailable: 64000 kB\n' > "$K/mem-fine"
: > "$K/curl.log"; SB_MEMINFO=$K/mem-low SB_OPT=$K "$SH" "$K/wd-z" > /dev/null 2>&1
check "zapret started again"   exists x "$K/zapret-on"
check "the start is reported"  has x "$K/curl.log" "запустил его заново"
check "zapret counts as up"    has x "$K/zu.out" "up=0"
check "little memory noticed"  has x "$K/zu.out" "mem=1"
: > "$K/curl.log"; SB_MEMINFO=$K/mem-fine SB_OPT=$K "$SH" "$K/wd-z" > /dev/null 2>&1
check "running: no message"    hasnt x "$K/curl.log" "zapret was not running"
check "enough memory: fine"    has x "$K/zu.out" "mem=0"
check "watchdog has both checks" has x "$K/etc/cron.5mins/watchdog" "check free-memory mem_ok"
cp "$K/pidof.orig" "$K/bin/pidof"; cp "$K/init.orig" "$K/etc/init.d/S51nfqws2"; rm -f "$K/zapret-on"
printf 'uninstall_confirm=y\n' > "$K/u"; sb_k uninstall --answers "$K/u"
check "undo: only our line"    equal x "$(cat "$K/etc/watchdog/bot.conf")" "$(cat "$K/etc/watchdog/bot.conf.user")"

# Meta through the VPN: networks, 1.1.1.1 itself, DNS per domain (no "on WireguardN"); uninstall takes it out
keenetic meta
printf 'profile=custom\nmodules=vpn meta\nvpn_iface=Wireguard0\n' > "$K/a"
sb_k install --answers "$K/a"
check "meta: exit 0"           equal x "$RC" 0
check "meta: Meta network"     has x "$K/ndmc.log" "ip route 157.240.0.0 255.255.0.0 Wireguard0 auto"
check "meta: 1.1.1.1 kept (routed already)" has x "$K/out" "1.1.1.1 уже через Wireguard0"
check "meta: DNS for Instagram" has x "$K/ndmc.log" "ip name-server 1.1.1.1 instagram.com"
check "meta: no 'on' suffix"   hasnt x "$K/ndmc.log" "instagram.com on"
check "meta: journaled"        has x "$K/etc/switchback/state" "ns 1.1.1.1 whatsapp.com"
printf 'profile=custom\nmodules=vpn meta\nvpn_iface=Wireguard0\nmeta_vpn=n\n' > "$K/a2"; : > "$K/ndmc.log"
sb_k install --answers "$K/a2"
check "meta: 'no' leaves it"   hasnt x "$K/ndmc.log" "name-server"
printf 'uninstall_confirm=y\n' > "$K/u"; : > "$K/ndmc.log"; sb_k uninstall --answers "$K/u"
check "meta: DNS removed"      has x "$K/ndmc.log" "no ip name-server 1.1.1.1 instagram.com"
check "meta: routes removed"   has x "$K/ndmc.log" "no ip route 157.240.0.0 255.255.0.0"
openwrt meta-owrt
printf 'profile=custom\nmodules=vpn meta\nvpn_iface=wg1\n' > "$R/a"
sb_o install --answers "$R/a"
check "owrt meta: dnsmasq server" has x "$R/uci.log" "server=/instagram.com/1.1.1.1"

openwrt v06-owrt
printf 'profile=custom\nmodules=zapret vpn\nvpn_iface=wg1\n' > "$R/a"
sb_o install --answers "$R/a"
printf '10.2.2.2\n' > "$R/dns-blocked.example"
sb_o sites add blocked.example --via vpn
check "owrt: route in uci"     has x "$R/uci.log" "uci set network.sb_tg_10_2_2_2.netmask=255.255.255.255"
check "owrt: job in cron1"     exists x "$R/etc/switchback/cron1/sb-sites"
check "owrt: copy kept on upgrade" has x "$R/etc/sysupgrade.conf" "/etc/switchback/app/"
check "owrt: sites kept"       has x "$R/etc/sysupgrade.conf" "/etc/switchback/sites"
sb_o sites del blocked.example
check "owrt: route removed"    has x "$R/uci.log" "uci -q delete network.sb_tg_10_2_2_2"

# ---------- lists/: the values come from the files and are the same as the ones written in the code before ---------- [lists]
CASE=lists
lv() { "$SH" -c ". '$SRC/lib/common.sh'; lists_load '$1' && eval \"printf %s \\\"\$$2\\\"\""; }
check "lists: TG_NETS as before" equal x "$(lv "$SRC/lists" TG_NETS)" "91.108.56.0/255.255.252.0 91.108.4.0/255.255.252.0 91.108.8.0/255.255.252.0 91.108.16.0/255.255.252.0 91.108.12.0/255.255.252.0 149.154.160.0/255.255.240.0 91.105.192.0/255.255.254.0 91.108.20.0/255.255.252.0 185.76.151.0/255.255.255.0"
check "lists: META_NETS as before" equal x "$(lv "$SRC/lists" META_NETS)" "31.13.24.0/255.255.248.0 31.13.64.0/255.255.192.0 45.64.40.0/255.255.252.0 57.144.0.0/255.252.0.0 66.220.144.0/255.255.240.0 69.63.176.0/255.255.240.0 69.171.224.0/255.255.224.0 74.119.76.0/255.255.252.0 102.132.96.0/255.255.240.0 103.4.96.0/255.255.252.0 129.134.0.0/255.255.0.0 147.75.208.0/255.255.240.0 157.240.0.0/255.255.0.0 163.70.128.0/255.255.128.0 173.252.64.0/255.255.192.0 179.60.192.0/255.255.252.0 185.60.216.0/255.255.252.0 185.89.216.0/255.255.252.0 204.15.20.0/255.255.252.0"
check "lists: META_DOMAINS as before" equal x "$(lv "$SRC/lists" META_DOMAINS)" "instagram.com cdninstagram.com facebook.com facebook.net fbcdn.net fbsbx.com threads.com threads.net whatsapp.com whatsapp.net"
check "lists: TV_NETS as before" equal x "$(lv "$SRC/lists" TV_NETS)" "64.233.160.0/19 66.102.0.0/20 72.14.192.0/18 74.125.0.0/16 108.177.0.0/17 142.250.0.0/15 172.217.0.0/16 172.253.0.0/16 173.194.0.0/16 192.178.0.0/15 209.85.128.0/17 216.58.192.0/19 216.239.32.0/19 208.117.224.0/19 208.65.152.0/22 64.15.112.0/20"
check "lists: ZAPRET_DOMAINS as before" equal x "$(lv "$SRC/lists" ZAPRET_DOMAINS)" "instagram.com cdninstagram.com fbcdn.net facebook.com facebook.net fb.com fbsbx.com"
check "lists: DNS_CLAUDE as before" equal x "$(lv "$SRC/lists" DNS_CLAUDE)" "claude.ai claude.com claudeusercontent.com anthropic.com"
check "lists: DNS_CHATGPT as before" equal x "$(lv "$SRC/lists" DNS_CHATGPT)" "chatgpt.com openai.com oaistatic.com oaiusercontent.com"
check "lists: TUNE_WAYS as before" equal x "$(lv "$SRC/lists" TUNE_WAYS)" "$(cat <<'LISTEOF'
fake-sni-google+multisplit|fake:blob=tls_clienthello:tls_mod=rnd,dupsid,sni=fonts.google.com:tcp_seq=10000 multisplit:pos=1,midsld:seqovl=1:seqovl_pattern=tls_clienthello:tcp_ts_up
fake-ack+multisplit|fake:blob=0x00000000:tcp_ack=-66000:tls_mod=rnd,dupsid,sni=www.google.com:repeats=2 multisplit:pos=1,midsld
hostfakesplit|hostfakesplit:host=ozon.ru:midhost=host-2:seqovl=sniext+3:seqovl_pattern=tls_clienthello:badsum:tcp_md5:tcp_ts_up hostfakesplit:tcp_md5:tcp_ts_up
multidisorder|multidisorder:pos=1,midsld
fake-md5+multidisorder|fake:blob=tls_clienthello:tls_mod=rnd,dupsid,sni=www.google.com:tcp_md5:repeats=4 multidisorder:pos=1,midsld
fakedsplit|fakedsplit:pos=midsld:tcp_md5
fakeddisorder|fakeddisorder:pos=midsld:tcp_md5
hostfakesplit-ozon-md5|hostfakesplit:host=ozon.ru:tcp_ts=-600000:tcp_md5:repeats=4
fake-noack+fakeddisorder|fake:blob=0x00000000:tcp_flags_unset=ack fakeddisorder:pos=midsld:tcp_flags_unset=ack
multidisorder-seqovl800|multidisorder:pos=1,midsld:seqovl=800:seqovl_pattern=tls_clienthello
send+fake+fakedsplit-md5|send:repeats=1:tcp_md5 fake:blob=tls_clienthello:tcp_md5:tcp_ack=-10000000:tcp_ts_up fakedsplit:pos=midsld:tcp_md5:tcp_ack=-10000000:tcp_ts_up
fake-google8+multisplit-seqovl|fake:blob=tls_clienthello:tcp_seq=10000000:repeats=8:tls_mod=rnd,dupsid,sni=www.google.com multisplit:pos=1:seqovl=681:seqovl_pattern=tls_clienthello
LISTEOF
)"
check "lists: TUNE_VIDEO_WAYS as before" equal x "$(lv "$SRC/lists" TUNE_VIDEO_WAYS)" "$(cat <<'LISTEOF'
multisplit:pos=sniext+1,midsld:seqovl=652
fake:blob=tls_clienthello:repeats=6:tcp_ts=-600000
multidisorder:pos=1,host+2,sld+2,sld+5,sniext+1,sniext+2,endhost-2:seqovl=1
multisplit:pos=2:seqovl=681:seqovl_pattern=tls_clienthello:repeats=8:tcp_ts=-600000
fake:blob=tls_clienthello:repeats=6:tcp_seq=2
fake:blob=0x00000000:tcp_flags_unset=ack fakeddisorder:pos=midsld:tcp_flags_unset=ack
multidisorder:pos=1,midsld:seqovl=800:seqovl_pattern=tls_clienthello
LISTEOF
)"
check "lists: 12 tune ways"         equal x "$(lv "$SRC/lists" TUNE_WAYS | grep -c .)" 12
# comments and blank lines are skipped, trailing spaces too
mkdir -p "$WORK/lists-x"; cp "$SRC"/lists/* "$WORK/lists-x/"
printf '# c\n\n1.2.3.0/255.255.255.0   # first\n  \n4.5.6.0/255.255.255.0\n' > "$WORK/lists-x/telegram.nets"
check "lists: comments skipped"     equal x "$(lv "$WORK/lists-x" TG_NETS)" "1.2.3.0/255.255.255.0 4.5.6.0/255.255.255.0"
# a missing or empty list stops install.sh before anything is done
mkdir -p "$WORK/nolist-src"; cp -r "$SRC/install.sh" "$SRC/lib" "$SRC/platforms" "$SRC/lists" "$WORK/nolist-src/"
rm "$WORK/nolist-src/lists/google.nets"
keenetic nolist
SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$WORK/nolist-src/install.sh" status > "$K/out" 2>&1; RC=$?
check "lists: missing file stops"   equal x "$RC" 1
check "lists: missing file named"   has x "$K/out" "Не найден lists/google.nets"
printf '# nothing\n\n' > "$WORK/nolist-src/lists/google.nets"
SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$WORK/nolist-src/install.sh" status > "$K/out" 2>&1; RC=$?
check "lists: empty file stops"     equal x "$RC" 1
check "lists: empty file named"     has x "$K/out" "Пустой список lists/google.nets"


# ---------- the site doctor: sites doctor DOMAIN ---------- [sites]
keenetic doctorsite
sb_k sites doctor https://Example.COM/page --progress
check "doctor: opens -> device"     has x "$K/out" "example.com открывается с роутера"
check "doctor: device verdict"      has x "$K/out" "@@sb	doc_end	device"
check "doctor: no fix offered"      hasnt x "$K/out" "doc_fix"
touch "$K/site-dead-blocked.example"; printf '10.9.9.1\n' > "$K/dns-blocked.example"
sb_k sites doctor blocked.example --progress
check "doctor: tunnel helps"        has x "$K/out" "Через туннель открывается"
check "doctor: vpn first, zapret"   has x "$K/out" "@@sb	doc_fix	vpn	zapret"
check "doctor: tunnel interface"    has x "$K/curl.log" "--interface nwg0"
check "doctor: changes nothing"     missing x "$K/etc/switchback/sites"
touch "$K/site-novpn-blocked.example"; sb_k sites doctor blocked.example --progress
check "doctor: only zapret left"    has x "$K/out" "@@sb	doc_fix	zapret"
echo blocked.example >> "$K/etc/nfqws2/lists/user.list"; sb_k sites doctor blocked.example --progress
check "doctor: site itself down"    has x "$K/out" "@@sb	doc_end	down"
touch "$K/site-dead-nodns.example"; sb_k sites doctor nodns.example --progress
check "doctor: no address"          has x "$K/out" "Адрес сайта не находится"
check "doctor: offers DNS"          has x "$K/out" "@@sb	doc_fix	dns"
touch "$K/net-down"; sb_k sites doctor blocked.example --progress
check "doctor: no internet"         has x "$K/out" "@@sb	doc_end	nonet"
rm -f "$K/net-down"
sb_k sites doctor 'a;reboot' --progress
check "doctor: odd input refused"   equal x "$RC" 1
check "doctor: says why"            has x "$K/out" "не похоже на адрес сайта"

# ---------- the panel: on, its program (login, CSRF, input), next tunnel, off, uninstall ---------- [panel]
keenetic panel
export SB_LAN_IP=192.168.1.1
sb_k panel on
check "panel: no server -> refused" equal x "$RC" 1
check "panel: tried busybox"        has x "$K/opkg.log" "install busybox"
printf '#!/bin/sh\necho "httpd $*" >> "$SB_OPT/httpd.log"\n' > "$K/bin/httpd"; chmod +x "$K/bin/httpd"
SB_LAN_IP=8.8.8.8; sb_k panel on
check "panel: public address no"    has x "$K/out" "не нашёл адрес роутера в домашней сети"
SB_LAN_IP=192.168.1.1; sb_k panel on --progress
P=$K/etc/switchback/panel; CGI=$P/www/cgi-bin/sb
check "panel: on"                   equal x "$RC" 0
check "panel: link event"           has x "$K/out" "@@sb	panel	on	http://192.168.1.1:8088/#t="
check "panel: page"                 exists x "$P/www/index.html"
check "panel: program filled in"    hasnt x "$CGI" "__"
check "panel: token is 32 hex"      equal x "$(tr -dc 0-9a-f < "$P/token" | wc -c | tr -d ' ')" 32
check "panel: home address only"    has x "$P/conf" "IP=192.168.1.1"
check "panel: start job"            has x "$K/etc/cron.1min/sb-panel" 'netstat -ltn'
check "panel: journal"              has x "$K/etc/switchback/state" "panel 192.168.1.1:8088"
check "panel: page has no CDN"      hasnt x "$P/www/index.html" "https://"
cgi() {   # cgi METHOD QUERY BODY [COOKIE] [ADDRESS] [LENGTH]
  printf '%s' "$3" | REQUEST_METHOD=$1 QUERY_STRING=$2 CONTENT_LENGTH=${6:-${#3}} HTTP_COOKIE=$4 REMOTE_ADDR=${5:-192.168.1.20} \
    SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic SB_PANEL_CACHE=$K/pcache "$SH" "$CGI" > "$K/cgi.out" 2>&1
}
cgi GET a=state "" "" 203.0.113.9
check "cgi: outside home refused"   has x "$K/cgi.out" "только из домашней сети"
cgi GET a=state ""
check "cgi: needs login"            has x "$K/cgi.out" "401 Unauthorized"
cgi GET a=login ""
check "cgi: login only by POST"     has x "$K/cgi.out" "405"
cgi POST a=login "t=00000000000000000000000000000000"
check "cgi: wrong token refused"    has x "$K/cgi.out" "Ссылка неверная"
check "cgi: no cookie for it"       hasnt x "$K/cgi.out" "Set-Cookie"
cgi POST a=login "t=$(cat "$P/token")"
check "cgi: cookie HttpOnly Strict" has x "$K/cgi.out" "HttpOnly; SameSite=Strict"
SID=$(sed -n 's/^Set-Cookie: sb=\([0-9a-f]*\);.*/\1/p' "$K/cgi.out" | tr -d '\r')
CS=$(sed -n 's/.*"csrf":"\([0-9a-f]*\)".*/\1/p' "$K/cgi.out")
check "cgi: session and csrf"       equal x "${#SID}${#CS}" 3232
cgi GET a=state "" "sb=$SID"
check "cgi: services"               has x "$K/cgi.out" '"name":"YouTube","color":"green","how":"zapret"'
check "cgi: tunnels"                has x "$K/cgi.out" '"name":"Wireguard0","up":true,"active":true'
check "cgi: no switch without fo"   has x "$K/cgi.out" '"switch":false'
check "cgi: cached"                 exists x "$K/pcache"
cgi POST a=doctor "d=example.com" "sb=$SID"
check "cgi: POST needs csrf"        has x "$K/cgi.out" "Страница устарела"
cgi POST a=doctor "d=example.com&csrf=$CS" "sb=$SID"
check "cgi: doctor answers"         has x "$K/cgi.out" "открывается с роутера"
cgi POST a=doctor "d=x%3Breboot&csrf=$CS" "sb=$SID"
check "cgi: bad domain refused"     has x "$K/cgi.out" "400 Bad Request"
cgi POST a=doctor "d=\$(id)&csrf=$CS" "sb=$SID"
check "cgi: no shell from input"    has x "$K/cgi.out" "400 Bad Request"
cgi POST a=fix "d=blocked.example&way=rm&csrf=$CS" "sb=$SID"
check "cgi: bad way refused"        has x "$K/cgi.out" "способ: zapret, vpn или dns"
cgi POST a=fix "d=blocked.example&way=zapret&csrf=$CS" "sb=$SID"
check "cgi: fix adds the site"      has x "$K/etc/switchback/sites" "zapret blocked.example"
check "cgi: fix result shown"       has x "$K/cgi.out" "blocked.example добавлен в zapret"
check "cgi: cache dropped"          missing x "$K/pcache"
printf '10.9.9.1\n' > "$K/dns-blocked.example"
cgi POST a=fix "d=blocked.example&way=vpn&csrf=$CS" "sb=$SID"
check "cgi: other way replaces"     has x "$K/etc/switchback/sites" "vpn blocked.example"
check "cgi: old way gone"           hasnt x "$K/etc/switchback/sites" "zapret blocked.example"
cgi POST a=next "csrf=$CS" "sb=$SID"
check "cgi: next without failover"  has x "$K/cgi.out" "Автосмена туннеля не установлена"
printf 'TUNNELS="Wireguard0 Wireguard1"\n' > "$K/etc/switchback/failover.conf"
printf '#!/bin/sh\necho "$*" > "$SB_OPT/fo.args"\n' > "$K/etc/cron.1min/wg-failover"; chmod +x "$K/etc/cron.1min/wg-failover"
cgi POST a=next "csrf=$CS" "sb=$SID"
check "cgi: next picks the next"    equal x "$(cat "$K/fo.args")" "--force Wireguard1"
check "cgi: says it did not take"   has x "$K/cgi.out" "Wireguard1 не заработал"
cgi GET "a=state&f=1" "" "sb=$SID"
check "cgi: switch offered"         has x "$K/cgi.out" '"switch":true'
cgi POST a=reboot "csrf=$CS" "sb=$SID"
check "cgi: unknown action"         has x "$K/cgi.out" "404 Not Found"
cgi POST a=doctor "d=example.com&csrf=$CS" "sb=$SID" 192.168.1.20 5000
check "cgi: long body refused"      has x "$K/cgi.out" "413"
cgi POST a=logout "csrf=$CS" "sb=$SID"
cgi GET a=state "" "sb=$SID"
check "cgi: logged out"             has x "$K/cgi.out" "401 Unauthorized"
old=$(cat "$P/token"); sb_k panel token
check "panel: new token"            equal x "$([ "$old" != "$(cat "$P/token")" ] && echo new)" new
sb_k panel off
check "panel: off removes files"    missing x "$P"
check "panel: job gone"             missing x "$K/etc/cron.1min/sb-panel"
check "panel: journal clean"        hasnt x "$K/etc/switchback/state" "panel "
sb_k panel on
printf 'uninstall_confirm=y\n' > "$K/a"; sb_k uninstall --answers "$K/a"
check "uninstall: panel stopped"    has x "$K/out" "панель на роутере выключена"
check "uninstall: panel files gone" missing x "$P"
# a module of its own, chosen by hand only (not in the full set: see the plan event of the dry run above)
keenetic panelmod
printf '#!/bin/sh\n' > "$K/bin/httpd"; chmod +x "$K/bin/httpd"
printf 'profile=custom\nmodules=panel\n' > "$K/a"; sb_k install --answers "$K/a" --progress
check "module: panel step"          has x "$K/out" "@@sb	step	1	1	panel"
check "module: panel on"            exists x "$K/etc/switchback/panel/www/cgi-bin/sb"
unset SB_LAN_IP

# ---------- the AI reserve (lib/ai.sh): DNS service -> Zapret DNS -> spare proxies -> VPN ---------- [ai]
keenetic ai
echo 161.104.89.59 > "$K/zdns-ip"; touch "$K/zdns-cname"; echo 160.79.104.10 > "$K/vpn-ip"
echo 10.0.0.5 > "$K/dns-claude.ai"; echo 10.0.0.6 > "$K/dns-chatgpt.com"   # the DoT service's nodes
# the fake running-config keeps nothing by itself: Claude's DoT record is there already (ChatGPT's is built in)
printf 'dns-proxy\n    tls upstream 5.6.7.8 sni dns.claude.example domain claude.ai\n!\n' > "$K/rc.extra"
# the kernel's table: the route through the tunnel is there unless route-missing
cat > "$K/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in "route get "*)
  if [ -f "$SB_OPT/route-missing" ]; then echo "$3 via 1.1.1.254 dev eth2.2"; else echo "$3 dev nwg0 src 10.8.0.2"; fi ;;
"-4 addr show dev nwg0") [ -f "$SB_OPT/ip-src" ] && echo "    inet 10.8.0.2/32 scope global nwg0" ;;   # ai_bind
esac
EOF
chmod +x "$K/bin/ip"
cat > "$K/a" <<EOF
profile=custom
modules=zapret dns
dns_claude=y
dns_claude_ip=5.6.7.8
dns_claude_sni=dns.claude.example
ai_reserve=y
EOF
sb_k install --answers "$K/a"
AI=$K/var/ai-path; J=$K/etc/cron.1min/ai-path
NC=$(( $(grep -vc '^#' "$SRC/lists/ai-claude.domains") - 1 ))   # claude.com stays the DNS service's (ai_svc_probe)
check "ai: exit 0"                  equal x "$RC" 0
check "ai: job installed"           exists x "$J"
check "ai: no placeholders"         hasnt x "$J" "__"
check "ai: Zapret DNS in zapret list" has x "$K/etc/nfqws2/lists/user.list" "dns.zapret.moe"
check "ai: Claude stays on its DNS service" equal x "$(cat "$AI/cur.claude")" dns
check "ai: Claude not pinned"       hasnt x "$K/ndmc.log" "ip host claude.ai"
check "ai: ChatGPT stays on its DNS service" equal x "$(cat "$AI/cur.gpt")" dns
check "ai: journal"                 has x "$K/etc/switchback/state" "ai"
mkdir -p "$K/etc/watchdog"; printf 'TOKEN=%s\nCHAT=-100\nNTFY=https://ntfy.sh/sb-test\n' "$TOKEN" > "$K/etc/watchdog/bot.conf"
aj() { SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$J" > "$K/aj.out" 2>&1; }
date +%s > "$AI/refresh"; date +%s > "$AI/back"
: > "$K/ndmc.log"; aj
check "ai: alive: nothing done"     hasnt x "$K/ndmc.log" "ip host"
# a slow node: the answer at once, the whole page too late (20.11.2026): the job judges by the answer
touch "$K/node-slowbody-10.0.0.5"; aj; aj
check "ai: slow node: still alive"  missing x "$AI/bad.claude"
check "ai: slow node: headers only" has x "$K/curl.log" "curl -s -I -o /dev/null --connect-timeout 4 --max-time 8"
rm -f "$K/node-slowbody-10.0.0.5"
# GeoHide dies: two dead runs, then Zapret DNS
touch "$K/node-dead-10.0.0.5"; aj
check "ai: one dead run: waits"     equal x "$(cat "$AI/bad.claude")" 1
: > "$K/curl.log"; aj
check "ai: Claude moved to Zapret DNS" equal x "$(cat "$AI/cur.claude")" zdns
check "ai: Claude pinned"           has x "$K/ndmc.log" "ip host claude.ai 161.104.89.59"
check "ai: every Claude name"       equal x "$(grep -c '^ndmc -c ip host .* 161.104.89.59$' "$K/ndmc.log")" "$NC"
export SB_T_AI_FEW=1            # from here a switch pins a few names: ~100 pins are 20-40 s of processes on Windows
check "ai: ChatGPT left alone"      hasnt x "$K/ndmc.log" "ip host chatgpt.com"
check "ai: the service's probe name not pinned" hasnt x "$K/ndmc.log" "ip host claude.com "
check "ai: asked through zapret"    has x "$K/curl.log" 'local-port = "61000-61099"'
check "ai: stops at the first failure" has x "$K/curl.log" "fail-early"
check "ai: told the bot"            has x "$K/curl.log" "sendMessage"
check "ai: with buttons"            has x "$K/curl.log" "ai vpn"
check "ai: and ntfy"                has x "$K/curl.log" "ntfy.sh/sb-test"
check "ai: says what it did"        has x "$K/var/log/switchback.log" "Переключил на: Zapret DNS"
check "ai: old value kept"          has x "$AI/pinned" "claude.ai -"
# the router's DNS now answers the pin
echo 161.104.89.59 > "$K/dns-claude.ai"; date +%s > "$AI/refresh"; aj
check "ai: on Zapret DNS, alive"    missing x "$AI/bad.claude"
# Zapret DNS's address dies too: the first spare proxy that answers (161... is first in the list: dead too)
touch "$K/node-dead-161.104.89.59"; aj; : > "$K/ndmc.log"; aj
check "ai: spare proxy taken"       equal x "$(cat "$AI/cur.claude")" proxy:159.194.200.33
check "ai: pinned to it"            has x "$K/ndmc.log" "ip host claude.ai 159.194.200.33"
# every proxy dead; the tunnel's route does not get into the kernel: nothing works -> alarm, routes taken back
echo 159.194.200.33 > "$K/dns-claude.ai"
for ip in $(grep -v '^#' "$SRC/lists/ai-claude-proxies.nets" | sed 's#/32##'); do touch "$K/node-dead-$ip"; done
touch "$K/route-missing"; aj; : > "$K/curl.log"; : > "$K/ndmc.log"; aj
check "ai: VPN route added"         has x "$K/ndmc.log" "ip route 160.79.104.10 255.255.255.255 Wireguard0 auto"
check "ai: not in the kernel: taken back" has x "$K/ndmc.log" "no ip route 160.79.104.10 255.255.255.255 Wireguard0"
check "ai: alarm"                   has x "$K/var/log/switchback.log" "не открывается ни одним путём"
check "ai: alarm says what to do"   has x "$K/var/log/switchback.log" "Что сделать"
check "ai: still on the last path"  equal x "$(cat "$AI/cur.claude")" proxy:159.194.200.33
check "ai: route problem logged"    has x "$K/var/log/switchback.log" "не встал"
: > "$K/curl.log"; aj
check "ai: alarm not repeated at once" hasnt x "$K/curl.log" "sendMessage"
# the route gets in: VPN
touch "$K/vpn-none-api.anthropic.com"   # a name without an answer: the names after it keep their own answers
rm -f "$K/route-missing"; : > "$K/ndmc.log"; : > "$K/curl.log"; aj
check "ai: no answer, no pin"       hasnt x "$K/ndmc.log" "ip host api.anthropic.com 160.79.104.10"
check "ai: the next name is its own" has x "$K/ndmc.log" "ip host a-api.anthropic.com 160.79.104.10"
check "ai: the last name too"       has x "$K/ndmc.log" "ip host www.claudeusercontent.com 160.79.104.10"
rm -f "$K/vpn-none-api.anthropic.com"
check "ai: Claude through VPN"      equal x "$(cat "$AI/cur.claude")" vpn
check "ai: real address pinned"     has x "$K/ndmc.log" "ip host claude.ai 160.79.104.10"
check "ai: plain DNS 1.1.1.1 asked"  has x "$K/nslookup.log" "nslookup claude.ai 1.1.1.1"
check "ai: no DoH bound to the tunnel" hasnt x "$K/curl.log" "1.1.1.1/dns-query"
check "ai: the site checked through the tunnel" has x "$K/curl.log" "--interface nwg0 --resolve claude.ai:443:160.79.104.10"
check "ai: route kept"              has x "$AI/routes" "claude 160.79.104.10"
check "ai: back after the alarm"    has x "$K/var/log/switchback.log" "Claude снова открывается"
# no "ip name-server 1.1.1.1 DOMAIN" for the group's domains any more: on a real Keenetic (20.11.2026) six of them
# next to Meta's ten killed the router's own DNS; what that version added is taken back
check "ai subs: none added on vpn"   hasnt x "$K/ndmc.log" "ip name-server 1.1.1.1 claudeusercontent.com"
printf 'claude claudeusercontent.com
claude claude.ai
' > "$AI/subs"
# by hand: Zapret DNS again (alive again) for 24 h
rm -f "$K/node-dead-161.104.89.59"; : > "$K/ndmc.log"; sb_k ai via zdns
check "ai via zdns: exit 0"         equal x "$RC" 0
check "ai via zdns: Claude"         equal x "$(cat "$AI/cur.claude")" zdns
check "ai via zdns: VPN route gone" has x "$K/ndmc.log" "no ip route 160.79.104.10"
check "ai via zdns: subs taken back" has x "$K/ndmc.log" "no ip name-server 1.1.1.1 claudeusercontent.com"
check "ai via zdns: subs journal clean" hasnt x "$AI/subs" "claude"
check "ai via zdns: held by hand"   has x "$K/etc/switchback/ai.conf" "MODE=zdns"
check "ai via zdns: says for how long" has x "$K/out" "вручную на 24 ч"
printf 'claude anthropic.com\n' > "$AI/subs"; : > "$K/ndmc.log"; sb_k update
check "ai update: subs taken back"   has x "$K/ndmc.log" "no ip name-server 1.1.1.1 anthropic.com"
check "ai update: subs journal clean" hasnt x "$AI/subs" "claude"
# a path that does not work is not taken by hand
echo 1.2.3.4 > "$K/vpn-ip"; touch "$K/node-dead-1.2.3.4"; sb_k ai via vpn
check "ai via vpn (dead): refused"  has x "$K/out" "сайт сейчас не открывается"
check "ai via vpn (dead): unchanged" equal x "$(cat "$AI/cur.claude")" zdns
sb_k ai auto
check "ai auto: back to auto"       has x "$K/etc/switchback/ai.conf" "MODE=auto"
sb_k ai status
check "ai status: Claude's path"    has x "$K/out" "Claude: Zapret DNS"
check "ai status: only the reserve" hasnt x "$K/out" "·  статус"
check "ai status: its own title"    has x "$K/out" "·  резерв для нейросетей"
check "ai status: last check"       has x "$K/out" "последняя проверка: "
check "ai status: last switch"      has x "$K/out" ", VPN (туннель Wireguard0) → Zapret DNS"
check "ai status: since when"       has x "$K/out" "Claude: Zapret DNS (с "
sb_k status
check "ai: in the status"           has x "$K/out" "Резерв для нейросетей"
sb_k sites add claude.ai --via vpn
check "ai: own site via VPN -> the switch" has x "$K/out" "Claude через VPN"
check "ai: own site not added"      hasnt x "$K/etc/switchback/sites" "claude.ai"
# DoH answers are read with hexdump (busybox od on KeeneticOS has no -A/-t: the stub od refuses them as it does);
# without hexdump, busybox's "od -b"
check "ai: no od -A on the router"  hasnt x "$K/var/log/switchback.log" "invalid option"
# readers that close early ("| head -1", "grep -q") left "sh: write error: Broken pipe" in the job's log (19.11.2026)
check "ai: job log clean"           hasnt x "$K/var/ai-path/log" "write error"
rm -f "$K/bin/hexdump"; : > "$K/ndmc.log"; sb_k ai via zdns
check "ai: read without hexdump"    has x "$K/ndmc.log" "ip host claude.ai 161.104.89.59"
# Zapret DNS answers 0.0.0.0 (seen 19.11.2026): no address, nothing pinned to it
echo 0.0.0.0 > "$K/zdns-claude.ai"; : > "$K/ndmc.log"; sb_k ai via zdns
check "ai: 0.0.0.0 is no address"   hasnt x "$K/ndmc.log" "0.0.0.0"
check "ai: 0.0.0.0: path refused"   has x "$K/out" "сайт сейчас не открывается"
rm -f "$K/zdns-claude.ai"
# a reliable check (21.11.2026: VLESS let new connections through now and then: false alarms, needless switches)
sb_k ai auto; date +%s > "$AI/refresh"; date +%s > "$AI/back"; rm -f "$AI"/bad.* "$AI"/alarm.* "$AI"/fell.*
P=10.0.0.77; echo $P > "$K/dns-claude.ai"; C0=$(cat "$AI/cur.claude"); echo 1 > "$AI/since.claude"
echo 2 > "$K/node-miss-$P"; aj
check "ai check: drop-outs: flaky"    equal x "$(cat "$AI/state.claude")" flaky
check "ai check: drop-outs: not dead" missing x "$AI/bad.claude"
check "ai check: drop-outs: logged"   has x "$AI/log" "claude.ai answered, not at once"
check "ai check: drop-outs: stays"    equal x "$(cat "$AI/cur.claude")" "$C0"
aj; check "ai check: healthy: ok"     equal x "$(cat "$AI/state.claude")" ok
echo 3 > "$K/node-miss-$P"; aj
check "ai check: a whole bad run counts" equal x "$(cat "$AI/bad.claude")" 1
aj
check "ai check: no flapping: forgiven" missing x "$AI/bad.claude"
check "ai check: no flapping: stays"  equal x "$(cat "$AI/cur.claude")" "$C0"
rm -f "$K/node-miss-$P"
echo 451 > "$K/node-code-$P"; aj
check "ai check: 451 is not dead"     missing x "$AI/bad.claude"
check "ai check: 451 state"           equal x "$(cat "$AI/state.claude")" "geo 451"
sb_k ai status
check "ai check: 451 in the status"   has x "$K/out" "отказом по стране"
echo 403 > "$K/node-code-$P"; aj
check "ai check: 403 is not dead"     missing x "$AI/bad.claude"
check "ai check: 403 state"           equal x "$(cat "$AI/state.claude")" "geo 403"
rm -f "$K/node-code-$P"
# runs of the job never overlap; the lock is gone after a run
mkdir "$AI/job"; rm -f "$AI/checked"; aj
check "ai check: a running job: no second" missing x "$AI/checked"
rmdir "$AI/job"; aj
check "ai check: the job ran"         exists x "$AI/checked"
check "ai check: its lock is gone"    missing x "$AI/job"
# a real death moves in DEAD_RUNS runs; a path just taken holds one run more
export SB_T_HOLD=10; touch "$K/node-dead-$P"; echo 1 > "$AI/since.claude"; aj
check "ai death: first run waits"     equal x "$(cat "$AI/cur.claude")" "$C0"
aj
check "ai death: moved at the threshold" differ x "$(cat "$AI/cur.claude")" "$C0"
check "ai death: the path is remembered" has x "$AI/fell.claude" "$C0 "
echo "$C0" > "$AI/cur.claude"; date +%s > "$AI/since.claude"; echo 0 > "$AI/bad.claude"; aj; aj
check "ai hold: just taken: still waits" equal x "$(cat "$AI/cur.claude")" "$C0"
aj
check "ai hold: then it moves"        differ x "$(cat "$AI/cur.claude")" "$C0"
rm -f "$K/node-dead-$P" "$AI/bad.claude"
# the way back waits for a path that fell; without the hold it comes back
echo vless > "$AI/cur.claude"; rm -f "$AI/best.claude"; echo "dns $(date +%s)" > "$AI/fell.claude"; echo "zdns $(date +%s)" >> "$AI/fell.claude"
sb_k ai tick back
check "ai back: a fallen path waits"  has x "$K/var/log/switchback.log" "fell recently"
check "ai back: not to the fallen dns" differ x "$(cat "$AI/cur.claude")" dns
check "ai back: not to the fallen zdns" differ x "$(cat "$AI/cur.claude")" zdns
export SB_T_HOLD=0; echo vless > "$AI/cur.claude"; rm -f "$AI/best.claude"; sb_k ai tick back
check "ai back: after the hold: returns" differ x "$(cat "$AI/cur.claude")" vless
# the owner's choice is not moved by dead runs
sb_k ai via zdns; touch "$K/node-dead-$P"; aj; aj; aj
check "ai by hand: stays on a dead path" equal x "$(cat "$AI/cur.claude")" zdns
rm -f "$K/node-dead-$P" "$AI/bad.claude" "$K/dns-claude.ai"; sb_k ai auto
# a test by the tunnel skips the redirect into Xray (the real cause of 000 through nwg2, 21.11.2026)
# by the tunnel's address: the router's curl ignores --local-port together with a device name
echo 10.0.0.78 > "$K/vpn-ip"; touch "$K/ip-src"; : > "$K/curl.log"; sb_k ai via vpn
check "ai check: by the tunnel's address, past the redirect" has x "$K/curl.log" "--interface 10.8.0.2 --local-port 61100-61119 --resolve claude.ai:443:10.0.0.78"
check "ai check: never a device name with the ports" hasnt x "$K/curl.log" "--interface nwg0 --local-port"
touch "$K/route-missing"; : > "$K/curl.log"; sb_k ai via vpn
check "ai check: the kernel sends it elsewhere: by the device" has x "$K/curl.log" "--interface nwg0 --resolve claude.ai:443:10.0.0.78"
rm -f "$K/route-missing" "$K/ip-src" "$K/vpn-ip"; sb_k ai auto
: > "$K/ndmc.log"; sb_k ai off
check "ai off: exit 0"              equal x "$RC" 0
check "ai off: job gone"            missing x "$J"
check "ai off: settings gone"       missing x "$K/etc/switchback/ai.conf"
check "ai off: pins taken back"     has x "$K/ndmc.log" "no ip host claude.ai"
check "ai off: journal clean"       hasnt x "$K/etc/switchback/state" "ai-path"
sb_k ai on
check "ai on again: job"            exists x "$J"
# the DNS service's node moved while Claude went by VPN (19.11.2026: 161.104.89.59 died, the node auto-switch
# went on with 2.27.31.124; the test kept asking the dead node and the reserve never came back). An older
# version's pin of the probe name goes too
echo vpn > "$AI/cur.claude"; rm -f "$AI/best.claude"; echo 0 > "$AI/back"; touch "$K/node-dead-10.0.0.5"
printf 'claude.ai 10.0.0.5\nclaudeusercontent.com 10.0.0.5\napi.anthropic.com -\nclaude.com -\n' > "$AI/pinned"
unset SB_T_AI_FEW               # the whole list comes back: every name, and the journal empties
echo 10.0.0.7 > "$K/dns-claude.com"; touch "$K/node-slowbody-10.0.0.7"; : > "$K/ndmc.log"; sb_k ai tick back
check "ai node moved: back on its DNS service" equal x "$(cat "$AI/cur.claude")" dns
check "ai node moved: the live node"  has x "$K/ndmc.log" "ip host claude.ai 10.0.0.7"
check "ai node moved: same group"     has x "$K/ndmc.log" "ip host claudeusercontent.com 10.0.0.7"
check "ai node moved: not the dead one" hasnt x "$K/ndmc.log" "ip host claude.ai 10.0.0.5"
check "ai node moved: no pin of its own" hasnt x "$K/ndmc.log" "ip host api.anthropic.com 10"
check "ai node moved: probe name freed" has x "$K/ndmc.log" "no ip host claude.com"
check "ai node moved: logged"         has x "$K/var/log/switchback.log" "node 10.0.0.5 is dead, back by 10.0.0.7"
check "ai node moved: journal clean"  hasnt x "$AI/pinned" "claude"
export SB_T_AI_FEW=1
# the service gives nothing alive: stays where it is
echo vpn > "$AI/cur.claude"; rm -f "$AI/best.claude"; echo 0 > "$AI/back"; touch "$K/node-dead-10.0.0.7"
printf 'claude.ai 10.0.0.5\n' > "$AI/pinned"; sb_k ai tick back
check "ai node dead too: not back on it" equal x "$(grep -cx dns "$AI/cur.claude")" 0
# the node answers only through our VPN route to it (20.11.2026: 2.27.31.124 by Wireguard25; "dns" takes the route
# away, the node falls silent, back to vpn every hour): the dns path is asked past the tunnel, by the WAN device
ai_routed() {
  echo vpn > "$AI/cur.claude"; rm -f "$AI/best.claude"; echo 0 > "$AI/back"
  printf 'claude.ai 10.0.0.11
' > "$AI/pinned"; echo "claude 10.0.0.11 Wireguard0" > "$AI/routes"
  : > "$K/curl.log"; : > "$K/ndmc.log"; sb_k ai tick back
}
touch "$K/node-tunnelonly-10.0.0.11"; export SB_WAN_DEV=ppp0; ai_routed
check "ai routed node: asked by WAN"    has x "$K/curl.log" "--interface ppp0 --resolve claude.ai:443:10.0.0.11"
check "ai routed node: not back on dns" equal x "$(grep -cx dns "$AI/cur.claude")" 0
check "ai routed node: logged"          has x "$K/var/log/switchback.log" "10.0.0.11 (claude.ai) answers only through our VPN route"
rm -f "$K/node-tunnelonly-10.0.0.11"; ai_routed
check "ai routed node, direct too: back" equal x "$(cat "$AI/cur.claude")" dns
check "ai routed node, direct too: route gone" has x "$K/ndmc.log" "no ip route 10.0.0.11"
unset SB_WAN_DEV; ai_routed
check "ai routed node, WAN unknown: not back" equal x "$(grep -cx dns "$AI/cur.claude")" 0
check "ai routed node, WAN unknown: logged" has x "$K/var/log/switchback.log" "the WAN device is unknown"
rm -f "$AI/routes"
# pins by hand point at the dead node, the probe name among them (18.11.2026): the router answers the dead node for
# it; the service's own DoH (its DoT server's name, by its IP) gives the live one. Every pin on the dead node goes
# there; a name the reserve holds (ChatGPT is on VPN) keeps its pin and gets the new "before" value
cp "$K/rc.extra" "$K/rc.keep"
printf 'ip host claude.com 10.0.0.5\nip host cdn.auth0.com 10.0.0.5\nip host chatgpt.com 10.0.0.5\n' >> "$K/rc.extra"
aiback() { echo vpn > "$AI/cur.claude"; rm -f "$AI/best.claude"; echo 0 > "$AI/back"; : > "$K/ndmc.log"; : > "$K/curl.log"; }
aiback; echo vpn > "$AI/cur.gpt"; touch "$AI/best.gpt"
printf 'claude.ai 10.0.0.5\nclaude.com 10.0.0.5\nchatgpt.com 10.0.0.5\n' > "$AI/pinned"
echo 10.0.0.5 > "$K/dns-claude.com"; echo 10.0.0.8 > "$K/svc-ip"; sb_k ai tick back
check "ai past pins: back on its DNS service" equal x "$(cat "$AI/cur.claude")" dns
check "ai past pins: asked the service's DoH" has x "$K/curl.log" 'url = "https://dns.claude.example/dns-query"'
check "ai past pins: by its DoT address" has x "$K/curl.log" 'resolve = "dns.claude.example:443:5.6.7.8"'
check "ai past pins: the live node"   has x "$K/ndmc.log" "ip host claude.ai 10.0.0.8"
check "ai past pins: probe name moved" has x "$K/ndmc.log" "ip host claude.com 10.0.0.8"
check "ai past pins: pins by hand moved" has x "$K/ndmc.log" "ip host cdn.auth0.com 10.0.0.8"
check "ai past pins: the reserve's name left" hasnt x "$K/ndmc.log" "ip host chatgpt.com 10.0.0.8"
check "ai past pins: its before value" has x "$AI/pinned" "chatgpt.com 10.0.0.8"
mv "$K/rc.keep" "$K/rc.extra"; rm -f "$AI/best.gpt" "$K/svc-ip"
# with the node auto-switch: a node of its reserve service (EXTRA_DOH, Zapret DNS) needs no QUIC rule
printf 'EXTRA_DOH=%s\n' https://dns.zapret.moe/dns-query > "$K/etc/switchback/nodes.conf"
aiback; printf 'claude.ai 10.0.0.5\n' > "$AI/pinned"; echo 10.0.0.9 > "$K/zdns-claude.ai"; sb_k ai tick back
check "ai reserve node: taken"        has x "$K/ndmc.log" "ip host claude.ai 10.0.0.9"
check "ai reserve node: no QUIC worry" hasnt x "$K/var/log/switchback.log" "no QUIC block rule"
# the service's node without a QUIC rule: taken (it opens the site), and said so in the log
aiback; printf 'claude.ai 10.0.0.5\n' > "$AI/pinned"; echo 10.0.0.10 > "$K/svc-ip"; sb_k ai tick back
check "ai node without QUIC rule: taken" has x "$K/ndmc.log" "ip host claude.ai 10.0.0.10"
check "ai node without QUIC rule: logged" has x "$K/var/log/switchback.log" "node 10.0.0.10 has no QUIC block rule"
rm -f "$K/etc/switchback/nodes.conf" "$K/zdns-claude.ai" "$K/svc-ip"
# the DNS service is silent directly (20.11.2026: the provider cuts TCP to all its servers); through the live tunnel
# it answers: its addresses are known and shown, the dns path still only when one opens directly (by the WAN device)
touch "$K/svc-down" "$K/node-tunnelonly-10.0.0.21"; echo 10.0.0.21 > "$K/svctun-ip"; export SB_WAN_DEV=ppp0
aiback; printf 'claude.ai 10.0.0.5\n' > "$AI/pinned"; rm -f "$AI/svc.claude"; sb_k ai tick back
check "ai svc by tunnel: asked through it"  has x "$K/curl.log" 'interface = "nwg0"'
check "ai svc by tunnel: its addresses kept" has x "$AI/svc.claude" "Wireguard0 10.0.0.21"
check "ai svc by tunnel: logged"            has x "$K/var/log/switchback.log" "through Wireguard0 it gives: 10.0.0.21"
check "ai svc by tunnel: tested directly"   has x "$K/curl.log" "--interface ppp0 --resolve claude.ai:443:10.0.0.21"
check "ai svc by tunnel: dns not taken"     equal x "$(grep -cx dns "$AI/cur.claude")" 0
check "ai svc by tunnel: not pinned to it"  hasnt x "$K/ndmc.log" "ip host claude.ai 10.0.0.21"
echo vpn > "$AI/cur.claude"; sb_k ai status --plain
check "ai svc by tunnel: in the status"     has x "$K/out" "DNS-сервис отвечает через туннель Wireguard0"
check "ai svc by tunnel: addresses shown"   has x "$K/out" "адреса 10.0.0.21; напрямую недоступны"
# within AI_SVC_TUN_MIN: not asked through the tunnel again
echo 10.0.0.22 > "$K/svctun-ip"; aiback; printf 'claude.ai 10.0.0.5\n' > "$AI/pinned"; sb_k ai tick back
check "ai svc by tunnel: not every time"    hasnt x "$K/curl.log" 'interface = "nwg0"'
# the provider lets the address through again: back on the dns path at once
rm -f "$K/node-tunnelonly-10.0.0.21"; aiback; printf 'claude.ai 10.0.0.5\n' > "$AI/pinned"; sb_k ai tick back
check "ai svc by tunnel, open directly: back" equal x "$(cat "$AI/cur.claude")" dns
check "ai svc by tunnel, open directly: pinned" has x "$K/ndmc.log" "ip host claude.ai 10.0.0.21"
# the answer grown old: asked through the tunnel again, the new address kept
echo vpn > "$AI/cur.claude"; echo "0 Wireguard0 10.0.0.21" > "$AI/svc.claude"; aiback
printf 'claude.ai 10.0.0.5\n' > "$AI/pinned"; touch "$K/node-dead-10.0.0.21" "$K/node-dead-10.0.0.22"; sb_k ai tick back
check "ai svc by tunnel, old answer: asked again" has x "$AI/svc.claude" "Wireguard0 10.0.0.22"
# silent through the tunnel too: said so
touch "$K/svctun-down"; echo "0 Wireguard0 10.0.0.22" > "$AI/svc.claude"; aiback; printf 'claude.ai 10.0.0.5\n' > "$AI/pinned"; sb_k ai tick back
echo vpn > "$AI/cur.claude"; sb_k ai status --plain
check "ai svc silent both ways: in the status" has x "$K/out" "не отвечает ни напрямую, ни через туннель Wireguard0"
rm -f "$K/svc-down" "$K/svctun-down" "$K/svctun-ip" "$K/node-dead-10.0.0.21" "$K/node-dead-10.0.0.22" "$AI/svc.claude"; unset SB_WAN_DEV
rm -f "$K/etc/switchback/nodes.conf" "$K/zdns-claude.ai" "$K/svc-ip"
printf 'uninstall_confirm=y\n' > "$K/u"; sb_k uninstall --answers "$K/u"
check "ai uninstall: job gone"      missing x "$J"
check "ai uninstall: Zapret DNS out of zapret list" hasnt x "$K/etc/nfqws2/lists/user.list" "dns.zapret.moe"
# OpenWrt: the same, dnsmasq pins
openwrt ai-owrt
echo 161.104.89.59 > "$R/zdns-ip"
printf 'profile=custom\nmodules=zapret dns\ndisable_offload=y\nai_reserve=y\n' > "$R/a"
sb_o install --answers "$R/a"
check "openwrt ai: exit 0"          equal x "$RC" 0
check "openwrt ai: pinned"          has x "$R/uci.db" "/claude.ai/161.104.89.59"
check "openwrt ai: minute job"      exists x "$R/etc/switchback/cron1/ai-path"

# ---------- VLESS through Xray (lib/vless.sh): the link, Xray's settings, the service, the AI path, the bot ---------- [vless]
# Every link here is made up (no real server, no real key); none of its secret parts may show anywhere
keenetic vless
printf 'profile=custom\nmodules=zapret vpn watchdog\nvpn_iface=Wireguard0\nbot_token=%s\nbot_chat=-100\n' "$TOKEN" > "$K/a"
sb_k install --answers "$K/a"
check "vless: base install"          equal x "$RC" 0
export SB_XRAY_WAIT=0 SB_IPT=$K/bin/fipt SB_IPSET=$K/bin/fipset
cat > "$K/bin/fipt" <<'EOF'
#!/bin/sh
echo "iptables $*" >> "$SB_OPT/ipt.log"
case " $* " in *" -C "*|*" -D "*) exit 1 ;; esac
exit 0
EOF
cat > "$K/bin/fipset" <<'EOF'
#!/bin/sh
echo "ipset $*" >> "$SB_OPT/ipt.log"
[ "$2" = restore ] && cat >> "$SB_OPT/ipt.log"
exit 0
EOF
chmod +x "$K/bin/fipt" "$K/bin/fipset"
UUID=0f1e2d3c-4b5a-4987-8a6b-5c4d3e2f1a0b
PBK=TestPublicKeyOnlyForTests_abcdefghijklmnopq
SID=6ba85179e30d4fc2
LINK="vless://$UUID@203.0.113.80:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.example.com&fp=chrome&pbk=$PBK&sid=$SID&type=tcp&headerType=none#%D0%94%D0%BE%D0%BC"
X=$K/etc/switchback/xray.json; VI=$K/etc/init.d/S99switchback-xray; VH=$K/etc/ndm/netfilter.d/103-switchback-vless.sh
printf '%s\n' "$LINK" > "$K/link"; : > "$K/curl.log"
sb_k vless set --conf "$K/link"
check "vless: exit 0"                equal x "$RC" 0
check "vless: kind named"            has x "$K/out" "VLESS (Reality, tcp, vision)"
check "vless: Reality"               has x "$X" '"security":"reality"'
check "vless: the server's key"      has x "$X" "\"publicKey\":\"$PBK\""
check "vless: shortId"               has x "$X" "\"shortId\":\"$SID\""
check "vless: the user"              has x "$X" "\"id\": \"$UUID\""
check "vless: vision"                has x "$X" '"flow": "xtls-rprx-vision"'
check "vless: own mark"              has x "$X" '"mark": 23387'
check "vless: redirect inbound"      has x "$X" '"protocol": "dokodemo-door"'
check "vless: sniffing (the server resolves)" has x "$X" '"destOverride": ["http", "tls"]'
check "vless: SOCKS for checks on localhost only" has x "$X" '"listen": "127.0.0.1", "port": 10809'
check "vless: name after # dropped"  hasnt x "$X" "%D0"
check "vless: checked by Xray first" has x "$K/xray.log" "xray run -test -c ${X%.json}.new.json"
[ "$(stat -c %a "$K/probe" 2>/dev/null)" = 600 ] && check "vless: settings private" equal x "$(stat -c %a "$X")" 600
check "vless: UUID not shown"        hasnt x "$K/out" "$UUID"
check "vless: key not shown"         hasnt x "$K/out" "$PBK"
check "vless: UUID not in the log"   hasnt x "$K/var/log/switchback.log" "$UUID"
check "vless: key not in the log"    hasnt x "$K/var/log/switchback.log" "$PBK"
check "vless: nothing secret in the journal" hasnt x "$K/etc/switchback/state" "$UUID"
check "vless: journal"               has x "$K/etc/switchback/state" "vless"
check "vless: link not kept"         hasnt x "$K/etc/switchback/vless.conf" "$UUID"
check "vless: server address remembered (never redirected)" has x "$K/etc/switchback/vless.conf" 'SERVER_IPS="203.0.113.80"'
check "vless: service installed"     exists x "$VI"
check "vless: service paths filled"  hasnt x "$VI" "__"
check "vless: hook installed"        exists x "$VH"
check "vless: hook paths filled"     hasnt x "$VH" "__"
check "vless: Xray started"          has x "$K/xray.log" "xray run -c $X"
check "vless: running"               exists x "$K/var/run/sb-xray.pid"
check "vless: checked through it"    has x "$K/curl.log" "--socks5-hostname 127.0.0.1:10809 https://claude.ai/"
check "vless: says it works"         has x "$K/out" "VLESS работает"
check "vless: not the program's file: left" exists x "$K/link"
check "vless: nothing chosen: no rule" hasnt x "$K/ipt.log" "-I PREROUTING"
check "vless: the copy on the router has it" exists x "$K/etc/switchback/app/lib/vless.sh"
# TLS + ws (from the program or the bot: the file is wiped once read), TLS + grpc with an IPv6 server
WS="vless://$UUID@cdn.example.net:443?type=ws&security=tls&path=%2Fws%3Fed%3D2048&host=cdn.example.net&sni=cdn.example.net&alpn=h2%2Chttp%2F1.1#ws"
printf '%s\n' "$WS" > "$K/link"; export SB_ANSWERS_RM=1; sb_k vless set --conf "$K/link"; unset SB_ANSWERS_RM
check "vless ws: exit 0"             equal x "$RC" 0
check "vless ws: network"            has x "$X" '"network":"ws","wsSettings":{"path":"/ws?ed=2048","host":"cdn.example.net"}'
check "vless ws: TLS with alpn"      has x "$X" '"tlsSettings":{"serverName":"cdn.example.net","fingerprint":"chrome","alpn":["h2","http/1.1"]}'
check "vless ws: no vision"          hasnt x "$X" "flow"
check "vless ws: file wiped"         missing x "$K/link"
printf '%s\n' "vless://$UUID@[2001:db8::7]:8443?type=grpc&security=tls&serviceName=gsvc&mode=multi&sni=g.example.net" > "$K/link"
sb_k vless set --conf "$K/link"
check "vless grpc: exit 0"           equal x "$RC" 0
check "vless grpc: service"          has x "$X" '"grpcSettings":{"serviceName":"gsvc","multiMode":true}'
check "vless grpc: IPv6 server"      has x "$X" '"address": "2001:db8::7", "port": 8443'
# broken links: refused with a reason, the settings before stay, nothing secret shown
cp "$X" "$K/x.before"
vbad() {   # vbad "description" "words of the reason" LINK
  printf '%s\n' "$3" > "$K/link"; : > "$K/xray.log"; sb_k vless set --conf "$K/link"
  check "vless bad ($1): refused"       equal x "$RC" 1
  check "vless bad ($1): says why"      has x "$K/out" "$2"
  check "vless bad ($1): settings kept" equal x "$(cat "$K/x.before")" "$(cat "$X")"
  check "vless bad ($1): UUID not shown" hasnt x "$K/out" "$UUID"
  check "vless bad ($1): UUID not logged" hasnt x "$K/var/log/switchback.log" "$UUID"
}
vbad "vmess"          "ссылки vless:// не нашёл" "vmess://$UUID@203.0.113.80:443"
vbad "empty"          "ссылки vless:// не нашёл" "nothing here"
vbad "no pbk"         "нет открытого ключа сервера (pbk)" "vless://$UUID@203.0.113.80:443?security=reality&sni=www.example.com&sid=$SID"
vbad "short pbk"      "открытый ключ сервера (pbk) в ссылке неверный" "vless://$UUID@203.0.113.80:443?security=reality&sni=a.example&pbk=abc"
vbad "no sni"         "нет имени сайта для Reality" "vless://$UUID@203.0.113.80:443?security=reality&pbk=$PBK"
vbad "bad sid"        "shortId" "vless://$UUID@h.example:443?security=reality&sni=a.example&pbk=$PBK&sid=zz"
vbad "no TLS"         "без шифрования" "vless://$UUID@203.0.113.80:80?type=ws&security=none"
vbad "vision on ws"   "только с type=tcp" "vless://$UUID@h.example:443?type=ws&security=tls&flow=xtls-rprx-vision"
vbad "port too big"   "порт сервера" "vless://$UUID@203.0.113.80:70000?security=tls"
vbad "no port"        "нет порта" "vless://$UUID@203.0.113.80?security=tls"
vbad "no user"        "нет идентификатора" "vless://203.0.113.80:443?security=tls"
vbad "quote in user"  "UUID" "vless://ab\"cd@h.example:443?security=tls"
vbad "unknown type"   "способ передачи" "vless://$UUID@h.example:443?security=tls&type=kcp"
vbad "JSON in path"   "недопустимые знаки" "vless://$UUID@h.example:443?type=ws&security=tls&path=%2F%22%7D%2C%22x%22%3A%22"
vbad "space in sni"   "недопустимые знаки" "vless://$UUID@h.example:443?security=tls&sni=a%20b"
vbad "bad host"       "адрес сервера" "vless://$UUID@h_x.example:443?security=tls"
vbad "encryption"     "encryption" "vless://$UUID@h.example:443?security=tls&encryption=aes-128-gcm"
touch "$K/xray-bad"
vbad "Xray refuses"   "Xray не принял" "$WS"
check "vless bad: Xray's draft removed" missing x "$X.new"
rm -f "$K/xray-bad"
# a newer Xray calls dokodemo-door "tunnel": the new name is used when the old one is refused
touch "$K/xray-tunnel"; printf '%s\n' "$LINK" > "$K/link"; sb_k vless set --conf "$K/link"; rm -f "$K/xray-tunnel"
check "vless: newer Xray: tunnel"    has x "$X" '"protocol": "tunnel"'
printf '%s\n' "$LINK" > "$K/link"; sb_k vless set --conf "$K/link"
check "vless: back to Reality"       has x "$X" '"security":"reality"'
# status, report (a link that somehow got into a log is masked there)
sb_k status
check "vless status: section"        has x "$K/out" "VLESS через Xray"
check "vless status: kind"           has x "$K/out" "VLESS настроен: Reality, tcp, vision"
check "vless status: no site by default" has x "$K/out" "свои сайты через VLESS не выбраны"
echo "pasted by mistake: $LINK" >> "$K/var/log/switchback.log"
sb_k report
check "vless report: given out"      equal x "$RC" 0
check "vless report: link masked"    has x "$K/out" "vless://<скрыто>"
check "vless report: no UUID"        hasnt x "$K/out" "$UUID"
check "vless report: no key"         hasnt x "$K/out" "$PBK"
sed -i '/pasted by mistake/d' "$K/var/log/switchback.log"
# the AI reserve: "vless" is the fifth path, the last one
cat > "$K/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in "route get "*) echo "$3 dev nwg0 src 10.8.0.2" ;; esac
EOF
chmod +x "$K/bin/ip"
echo 160.79.104.10 > "$K/vless-ip"
sb_k ai on
check "ai+vless: on"                 equal x "$RC" 0
export SB_T_AI_FEW=1
check "ai+vless: the job keeps Xray up" has x "$K/etc/cron.1min/ai-path" "$VI ensure"
: > "$K/ndmc.log"; : > "$K/curl.log"; : > "$K/ipt.log"; sb_k ai via vless 2
check "ai via vless: exit 0"         equal x "$RC" 0
check "ai via vless: Claude"         equal x "$(cat "$K/var/ai-path/cur.claude")" vless
check "ai via vless: real address pinned" has x "$K/ndmc.log" "ip host claude.ai 160.79.104.10"
check "ai via vless: names asked through Xray" has x "$K/curl.log" 'proxy = "socks5h://127.0.0.1:10809"'
check "ai via vless: address to Xray" has x "$K/etc/switchback/vless.ips" "160.79.104.10/32 ai:claude"
check "ai via vless: set filled"     has x "$K/ipt.log" "add sb-vless-new 160.79.104.10/32"
check "ai via vless: home devices redirected" has x "$K/ipt.log" "-I PREROUTING -p tcp -m set --match-set sb-vless dst -m mark ! --mark 0x5b5b -j REDIRECT --to-ports 10808"
check "ai via vless: the router too" has x "$K/ipt.log" "-I OUTPUT -p tcp ! --sport 61100:61119 -m set --match-set sb-vless dst -m mark ! --mark 0x5b5b -j REDIRECT --to-ports 10808"
check "ai via vless: home devices have no port exception" hasnt x "$K/ipt.log" "PREROUTING -p tcp ! --sport"
check "ai via vless: the older router rule goes" has x "$K/ipt.log" "-D OUTPUT -p tcp -m set --match-set sb-vless dst"
check "ai via vless: held by hand"   has x "$K/etc/switchback/ai.conf" "MODE=vless"
check "ai via vless: for 2 h"        has x "$K/out" "вручную на 2 ч"
sb_k ai status
check "ai status: VLESS named"       has x "$K/out" "Claude: VLESS (Xray)"
# leaving the path takes its addresses out
echo 161.104.89.59 > "$K/zdns-ip"; : > "$K/ipt.log"; sb_k ai via zdns
check "ai leaves vless: Claude"      equal x "$(cat "$K/var/ai-path/cur.claude")" zdns
check "ai leaves vless: address out" hasnt x "$K/etc/switchback/vless.ips" "ai:claude"
check "ai leaves vless: set synced"  has x "$K/ipt.log" "swap sb-vless-new sb-vless"
# automatic choice: VLESS only when nothing before it works; a working VPN path comes first
rm -f "$K/zdns-ip"; touch "$K/zdns-down"
for ip in $(grep -v '^#' "$SRC/lists/ai-claude-proxies.nets" | sed 's#/32##'); do touch "$K/node-dead-$ip"; done
sb_k ai auto
check "ai auto: nothing else works -> vless" equal x "$(cat "$K/var/ai-path/cur.claude")" vless
echo 160.79.104.10 > "$K/vpn-ip"; sb_k ai auto
check "ai auto: VPN before VLESS"    equal x "$(cat "$K/var/ai-path/cur.claude")" vpn
# Claude's artifacts answer 451 by the VPN path (20.11.2026: every tunnel let claudeusercontent.com out in Russia):
# not "dead" (claude.ai opens): the job asks for another path at once, the VPN path fails its test, VLESS is taken
AJ() { SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$K/etc/cron.1min/ai-path" > "$K/aj.out" 2>&1; }
touch "$K/frame-451-vpn" "$K/frame-451-dns"; echo 160.79.104.10 > "$K/dns-claude.ai"; : > "$K/curl.log"; AJ
check "ai frame 451: the job saw it"  has x "$K/var/ai-path/log" "artifacts (claudeusercontent.com) answer 451 by vpn"
check "ai frame 451: not dead"        missing x "$K/var/ai-path/bad.claude"
check "ai frame 451: -> vless at once" equal x "$(cat "$K/var/ai-path/cur.claude")" vless
check "ai frame 451: told"            has x "$K/var/log/switchback.log" "через VPN (туннель Wireguard0) не открывались"
echo 160.79.104.10 > "$K/vpn-ip"; sb_k ai auto
check "ai frame 451: auto keeps vless" equal x "$(cat "$K/var/ai-path/cur.claude")" vless
check "ai frame 451: VPN refused"     has x "$K/var/log/switchback.log" "answer 451 this way"
# VLESS dead too: the VPN path opens the site at least, it is taken anyway (21.11.2026: refused, Claude stayed on dead VLESS)
touch "$K/vless-dead"; sb_k ai auto
check "ai frame 451, VLESS dead: VPN anyway" equal x "$(cat "$K/var/ai-path/cur.claude")" vpn
check "ai frame 451, VLESS dead: logged" has x "$K/var/log/switchback.log" "opens the site at least"
rm -f "$K/vless-dead"; sb_k ai auto
# no other path opens them: stays, no alarm, said in the status; tried again only after BACK_MIN
touch "$K/vless-dead"; echo vpn > "$K/var/ai-path/cur.claude"; rm -f "$K/var/ai-path/frame.claude"; : > "$K/curl.log"; AJ
check "ai frame 451, nothing else: stays" equal x "$(cat "$K/var/ai-path/cur.claude")" vpn
check "ai frame 451, nothing else: no alarm" hasnt x "$K/curl.log" "sendMessage"
check "ai frame 451, nothing else: logged" has x "$K/var/log/switchback.log" "no other path opens them"
sb_k ai status
check "ai frame 451: in the status"   has x "$K/out" "артефакты (claudeusercontent.com) этим путём не открываются"
n=$(grep -c "tick frame" "$K/var/ai-path/log"); AJ
check "ai frame 451: not every minute" equal x "$(grep -c "tick frame" "$K/var/ai-path/log")" "$n"
rm -f "$K/frame-451-vpn" "$K/frame-451-dns" "$K/vless-dead"; AJ
check "ai frame open again: noted"    has x "$K/var/ai-path/log" "claude: artifacts open again"
check "ai frame open again: status clean" missing x "$K/var/ai-path/frame.claude"
rm -f "$K/dns-claude.ai"; sb_k ai auto
check "ai frame open again: VPN back" equal x "$(cat "$K/var/ai-path/cur.claude")" vpn
# one address for both groups, Claude on VLESS, ChatGPT on VPN (21.11.2026: ChatGPT, shown as VPN, really went into Xray)
AP=$K/var/ai-path; VI2=$K/etc/switchback/vless.ips
echo 10.9.9.1 > "$K/vless-ip"; echo 10.9.9.1 > "$K/vpn-ip"; sb_k ai via vless
echo vpn > "$AP/cur.gpt"; echo "gpt 10.9.9.1 Wireguard0" >> "$AP/routes"; echo 10.9.9.1 > "$K/dns-chatgpt.com"
sed -i "/ ai:gpt$/d" "$VI2"   # what leaving VLESS does to the group's tag
echo "203.0.113.9/32 sos:telegram" >> "$VI2"; date +%s > "$AP/vpn.gpt"; echo 0 > "$AP/vless.claude"; sb_k ai tick refresh
check "ai shared: no address of its own: said" exists x "$AP/shared.claude"
sb_k ai status
check "ai shared: the status: really VLESS" has x "$K/out" "ChatGPT: на деле идёт через VLESS"
check "ai shared: the status: Claude's side" has x "$K/out" "общий с другой группой"
# Claude has an address of its own: its names move there, ChatGPT's address leaves the redirect
echo "10.9.9.2/32 ai:claude" >> "$VI2"; echo 0 > "$AP/vless.claude"; : > "$K/ndmc.log"; sb_k ai tick refresh
check "ai shared: Claude on its own address" has x "$VI2" "10.9.9.2/32 ai:claude"
check "ai shared: the common address left" hasnt x "$VI2" "10.9.9.1/32"
check "ai shared: Claude's names moved" has x "$K/ndmc.log" "ip host claude.ai 10.9.9.2"
check "ai shared: ChatGPT not repinned to it" hasnt x "$K/ndmc.log" "ip host chatgpt.com 10.9.9.2"
check "ai shared: the mark gone"      missing x "$AP/shared.claude"
check "ai shared: ChatGPT's route stays" has x "$AP/routes" "gpt 10.9.9.1 Wireguard0"
check "ai shared: vless sos untouched" has x "$VI2" "203.0.113.9/32 sos:telegram"
check "ai shared: Claude stays on VLESS" equal x "$(cat "$AP/cur.claude")" vless
sb_k ai status
check "ai shared: the status is clean" hasnt x "$K/out" "на деле идёт через VLESS"
# ChatGPT's VPN address becomes the one Claude holds: found after ChatGPT's own change, and said
printf 'ip host claude.ai 10.9.9.2\n' >> "$K/rc.extra"   # the fake router's config does not keep pins by itself
echo 10.9.9.2 > "$K/vpn-ip"; echo 10.9.9.2 > "$K/dns-chatgpt.com"; echo 0 > "$AP/vpn.gpt"; date +%s > "$AP/vless.claude"; sb_k ai tick refresh
check "ai shared: found after the other's change" exists x "$AP/shared.claude"
# with an address of its own, Claude lets go of the one ChatGPT took
echo "10.9.9.3/32 ai:claude" >> "$VI2"; echo 0 > "$AP/vpn.gpt"; : > "$K/ndmc.log"; sb_k ai tick refresh
check "ai shared: moved after the other's change" has x "$K/ndmc.log" "ip host claude.ai 10.9.9.3"
check "ai shared: ChatGPT's address out of the set" hasnt x "$VI2" "10.9.9.2/32"
check "ai shared: moved: the mark gone" missing x "$AP/shared.claude"
sed -i '/ sos:telegram$/d' "$VI2"; sed -i '/^ip host claude.ai 10.9.9.2$/d' "$K/rc.extra"; rm -f "$K/dns-chatgpt.com" "$AP/shared.claude"
echo 160.79.104.10 > "$K/vless-ip"; echo 160.79.104.10 > "$K/vpn-ip"; sb_k ai auto
check "ai shared: Claude back on VPN" equal x "$(cat "$AP/cur.claude")" vpn
rm -f "$K/vpn-ip"
touch "$K/vless-dead"; sb_k ai via vless
check "ai via vless (dead): refused" has x "$K/out" "сайт сейчас не открывается"
rm -f "$K/vless-dead"
# the bot: a link as text (Telegram escapes "/"), applied, never logged or repeated, the message deleted
SL='\/'
botlink() { printf '{"ok":true,"result":[{"update_id":%s,"message":{"message_id":77,"chat":{"id":-100},"text":"%s"}}]}\n' "$1" "$2" > "$K/updates"; }
botlink 401 "vless:${SL}${SL}$UUID@203.0.113.81:443?security=reality&sni=bot.example.com&pbk=$PBK&sid=$SID&type=tcp&flow=xtls-rprx-vision#home"
bot1
check "bot vless: applied"           has x "$X" '"serverName":"bot.example.com"'
check "bot vless: case kept"         has x "$X" "\"publicKey\":\"$PBK\""
check "bot vless: slashes unescaped" has x "$K/etc/switchback/vless.conf" 'SERVER_IPS="203.0.113.81"'
check "bot vless: logged without it" has x "$K/var/sb-bot/log" "vless link received"
check "bot vless: UUID not in its log" hasnt x "$K/var/sb-bot/log" "$UUID"
check "bot vless: key not in its log" hasnt x "$K/var/sb-bot/log" "$PBK"
check "bot vless: not repeated"      hasnt x "$K/curl.log" "$UUID"
check "bot vless: message deleted"   has x "$K/curl.log" "deleteMessage -d chat_id=-100 -d message_id=77"
check "bot vless: says so"           has x "$K/curl.log" "Сообщение со ссылкой удалено"
check "bot vless: no copy left"      missing x "$K/var/sb-bot/vless-in"
check "bot vless: no batch left"     missing x "$K/var/sb-bot/batch"
check "bot vless: not a command"     hasnt x "$K/var/sb-bot/log" "command /"
# a broken link: the reason, no values
botlink 402 "vless:${SL}${SL}$UUID@203.0.113.81:443?security=reality&sni=bot.example.com"; bot1
check "bot vless bad: reason"        has x "$K/curl.log" "нет открытого ключа сервера"
check "bot vless bad: not repeated"  hasnt x "$K/curl.log" "$UUID"
# a link in a .txt file
printf 'my server:\n%s\n' "vless://$UUID@203.0.113.82:443?security=reality&sni=file.example.com&pbk=$PBK&sid=$SID" > "$K/tg-file"
botdoc "link.txt"; bot1
check "bot vless file: applied"      has x "$X" '"serverName":"file.example.com"'
check "bot vless file: wiped"        missing x "$K/var/sb-bot/vless-in"
check "bot vless file: not repeated" hasnt x "$K/curl.log" "$UUID"
# /ai has the VLESS button; /vless: nothing through it by default, a button per site, the CPU warning
botmsg "/ai"; bot1
check "bot /ai: VLESS button"        has x "$K/curl.log" '"callback_data":"ai vless"'
botmsg "/vless"; bot1
check "bot /vless: state"            has x "$K/curl.log" "VLESS настроен"
check "bot /vless: Telegram button"  has x "$K/curl.log" '"callback_data":"vless on telegram"'
check "bot /vless: Instagram button" has x "$K/curl.log" '"callback_data":"vless on instagram"'
check "bot /vless: CPU warning"      has x "$K/curl.log" "процессор роутера"
botmsg "/vless on telegram" "yes"; bot1
check "bot vless telegram: asks first" has x "$K/curl.log" "Пустить telegram через VLESS?"
check "bot vless telegram: warns"    has x "$K/curl.log" "15–20 Мбит/с"
check "bot vless telegram: on"       has x "$K/etc/switchback/sites" "vless telegram"
check "bot vless telegram: its networks" has x "$K/etc/switchback/vless.ips" "91.108.56.0/22 site:telegram"
printf '10.4.4.4\n' > "$K/dns-viav.example"
botmsg "/site add viav.example vless" "yes"; bot1
check "bot vless site: asks with the warning" has x "$K/curl.log" "Пустить viav.example через VLESS?"
check "bot vless site: on"           has x "$K/etc/switchback/sites" "vless viav.example"
check "bot vless site: its address"  has x "$K/etc/switchback/vless.ips" "10.4.4.4/32 site:viav.example"
check "bot vless site: refresh job"  exists x "$K/etc/cron.1min/sb-sites"
check "bot vless site: job keeps Xray up" has x "$K/etc/cron.1min/sb-sites" "$VI ensure"
sb_k sites
check "sites: Telegram via VLESS"    has x "$K/out" "Telegram — через VLESS"
check "sites: own site via VLESS"    has x "$K/out" "viav.example — через VLESS (адресов: 1)"
printf '10.4.4.4\n10.4.4.5\n' > "$K/dns-viav.example"; sb_k sites refresh
check "sites refresh: new address to VLESS" has x "$K/etc/switchback/vless.ips" "10.4.4.5/32 site:viav.example"
botmsg "/vless off telegram" "yes"; bot1
check "bot vless telegram: off"      hasnt x "$K/etc/switchback/sites" "vless telegram"
check "bot vless telegram: networks out" hasnt x "$K/etc/switchback/vless.ips" "site:telegram"
sb_k sites add claude.ai --via vless
check "sites: AI site via VLESS -> the reserve" has x "$K/out" "Claude через VLESS"
# off: the AI reserve leaves the path, everything of VLESS goes
sb_k ai via vless
check "ai via vless again"           equal x "$(cat "$K/var/ai-path/cur.claude")" vless
: > "$K/ipt.log"; sb_k vless off
check "vless off: exit 0"            equal x "$RC" 0
check "vless off: AI moved away"     hasnt x "$K/var/ai-path/cur.claude" vless
check "vless off: AI back to auto"   has x "$K/etc/switchback/ai.conf" "MODE=auto"
check "vless off: settings gone"     missing x "$X"
check "vless off: service gone"      missing x "$VI"
check "vless off: hook gone"         missing x "$VH"
check "vless off: Xray stopped"      missing x "$K/var/run/sb-xray.pid"
check "vless off: rules out"         has x "$K/ipt.log" "-D PREROUTING -p tcp -m set --match-set sb-vless"
check "vless off: own sites out"     hasnt x "$K/etc/switchback/sites" "vless "
check "vless off: journal clean"     equal x "$(grep -c -e "^vless$" -e "^site vless " -e "netfilter.d/103-switchback-vless.sh$" "$K/etc/switchback/state")" 0
sb_k ai via vless
check "ai via vless (none): says how" has x "$K/out" "пришлите боту ссылку vless://"
# dry run changes nothing; uninstall takes everything back
printf '%s\n' "$LINK" > "$K/link"; sb_k vless set --conf "$K/link" --dry-run
check "vless dry: nothing written"   missing x "$X"
sb_k vless set --conf "$K/link"
printf 'uninstall_confirm=y\n' > "$K/u"; sb_k uninstall --answers "$K/u"
check "vless uninstall: settings gone" missing x "$X"
check "vless uninstall: service gone" missing x "$VI"
check "vless uninstall: Xray stopped" missing x "$K/var/run/sb-xray.pid"
unset SB_XRAY_WAIT SB_IPT SB_IPSET
# OpenWrt: not yet
openwrt vless-owrt
printf '%s\n' "$LINK" > "$R/link"; sb_o vless set --conf "$R/link"
check "openwrt vless: refused"       has x "$R/out" "только на Keenetic"
check "openwrt vless: UUID not shown" hasnt x "$R/out" "$UUID"

# ---------- a VLESS subscription (lib/vsub.sh): parsed, checked in batches, the best behind a balancer ---------- [vsub]
# Every link, key and address here is made up; none of their secret parts may show anywhere
keenetic vsub
printf 'profile=custom\nmodules=zapret vpn watchdog\nvpn_iface=Wireguard0\nbot_token=%s\nbot_chat=-100\n' "$TOKEN" > "$K/a"
sb_k install --answers "$K/a"
check "vsub: base install"           equal x "$RC" 0
export SB_XRAY_WAIT=0 SB_IPT=$K/bin/fipt SB_IPSET=$K/bin/fipset VSUB_SHUFFLE=0
printf '#!/bin/sh\necho "iptables $*" >> "$SB_OPT/ipt.log"\ncase " $* " in *" -C "*|*" -D "*) exit 1 ;; esac\nexit 0\n' > "$K/bin/fipt"
printf '#!/bin/sh\necho "ipset $*" >> "$SB_OPT/ipt.log"\n[ "$2" = restore ] && cat >> "$SB_OPT/ipt.log"\nexit 0\n' > "$K/bin/fipset"
chmod +x "$K/bin/fipt" "$K/bin/fipset"
PBK=TestPublicKeyOnlyForTests_abcdefghijklmnopq
SUBTOK=SubTokenForTestsOnly0123456789abcdef
SUBURL="https://sub.example.net/api/sub/$SUBTOK"
uuid() { printf '1f1e2d3c-4b5a-4987-8a6b-5c4d3e2f1a%02x' "$1"; }
key() {   # key N [NAME]: a made-up Reality key to 203.0.113.N
  s=www.microsoft.com; [ $(($1 % 2)) = 0 ] && s=www.ozon.ru
  printf 'vless://%s@203.0.113.%s:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=6ba8517%s&type=tcp#%s\n' \
    "$(uuid "$1")" "$1" "$s" "$PBK" "$(printf %x $(($1 % 16)))" "${2:-%F0%9F%87%B3%F0%9F%87%B1%20NL-$1}"
}
# 20 keys (1-5 dead, 6 no Claude, 7 no ChatGPT, 8 refused by Xray, 9 no Telegram), 2 repeats, 3 broken, 4 of other kinds
{ i=1; while [ $i -le 20 ]; do key $i; i=$((i+1)); done
  key 9 "again"; key 10 "%D0%B5%D1%89%D1%91"
  echo "vless://$(uuid 30)@203.0.113.30:443?security=reality&sni=x.example&sid=ab"
  echo "vless://$(uuid 31)@203.0.113.31?security=reality&pbk=$PBK&sni=x.example"
  echo "vless://not a link"
  echo "vmess://eyJhZGQiOiIyMDMuMC4xMTMuNDAifQ=="; echo "vmess://eyJhZGQiOiIyMDMuMC4xMTMuNDEifQ=="
  echo "trojan://secretpass@203.0.113.42:443#t"; echo "ss://YWVzLTI1Ni1nY206cGFzcw@203.0.113.43:8388#s"
} > "$K/sub.plain"
base64 < "$K/sub.plain" | tr -d '\n' > "$K/sub-body"            # one blob, no line breaks
for h in 1 2 3 4 5; do touch "$K/vsub-dead-203.0.113.$h"; done
touch "$K/vsub-noclaude-203.0.113.6" "$K/vsub-nogpt-203.0.113.7" "$K/xray-refuse-203.0.113.8" "$K/vsub-notg-203.0.113.9"
i=9; while [ $i -le 20 ]; do printf '0.%03d\n' $((400 - i * 10)) > "$K/vsub-ms-203.0.113.$i"; i=$((i+1)); done
echo 1.2 > "$K/vsub-sec-203.0.113.19"                            # 20 Mbit/s: before .20 (same 50 ms step, 6 Mbit/s)
touch "$K/vsub-noovh-203.0.113.18"                               # the first address gives nothing: the second one
echo "20.000 1000000" > "$K/vsub-cut-203.0.113.17"               # cut at 20 s: 1 MB came, 0.4 Mbit/s (after .16)
X=$K/etc/switchback/xray.json; P=$K/etc/switchback/vless.pool; J=$K/etc/cron.5mins/sb-vless-sub
printf '%s\n' "$SUBURL" > "$K/sub"; : > "$K/curl.log"; : > "$K/xray.log"
sb_k vless sub set --conf "$K/sub"
check "vsub: exit 0"                 equal x "$RC" 0
check "vsub: address kept"           has x "$K/etc/switchback/vless.sub" "$SUBURL"
[ "$(stat -c %a "$K/probe" 2>/dev/null)" = 600 ] && check "vsub: address private" equal x "$(stat -c %a "$K/etc/switchback/vless.sub")" 600
check "vsub: fetched in a config file, not a command line" hasnt x "$K/curl.log" "$SUBTOK"
check "vsub: base64 decoded, kinds counted" has x "$K/out" "в подписке ссылок: 29 — VLESS 25, других 4"
check "vsub: other kinds named"      has x "$K/out" "vmess 2"
check "vsub: other kinds skipped"    has x "$K/out" "пропущены, нужен VLESS"
check "vsub: repeats and broken"     has x "$K/out" "разных ключей VLESS: 20 (повторы 2, не разобрать 3)"
check "vsub: the best checked again in one batch" has x "$K/xray.log" "batch 10"
check "vsub: the batch checked by Xray first" has x "$K/xray.log" "run -test -c $SB_TMP/switchback-vsub."
check "vsub: the refused batch split" has x "$K/xray.log" "batch 5"
check "vsub: one SOCKS port a key"   has x "$K/curl.log" "--socks5-hostname 127.0.0.1:10821 https://www.gstatic.com/generate_204"
check "vsub: Claude checked"         has x "$K/curl.log" "127.0.0.1:10821 https://claude.ai/"
check "vsub: Claude's API checked"   has x "$K/curl.log" "127.0.0.1:10821 https://api.anthropic.com/"
check "vsub: ChatGPT checked"        has x "$K/curl.log" "127.0.0.1:10821 https://chatgpt.com/"
check "vsub: Telegram checked"       has x "$K/curl.log" "127.0.0.1:10821 https://api.telegram.org/"
check "vsub: light speed check"     has x "$K/curl.log" "-r 0-2999999 --connect-timeout 6 --max-time 20"
check "vsub: speed from OVH first"   has x "$K/curl.log" "https://proof.ovh.net/files/10Mb.dat"
check "vsub: speed of 5 only"        equal x "$(grep -c 'proof.ovh.net' "$K/curl.log")" 5
check "vsub: the next address when one gives nothing" equal x "$(grep -c 'speed.cloudflare.com/__down?bytes=3000000' "$K/curl.log")" 1
check "vsub: summary"                has x "$K/out" "Итог: проверено 20 из 20 за "
check "vsub: counts"                 has x "$K/out" "живые 14, Claude открывается через 13, ChatGPT через 13, Telegram через 13, подходят 12; Xray не принял 1; оставлено 8, лучшая задержка 200 мс."
check "vsub: 8 kept"                 equal x "$(wc -l < "$P" | tr -d ' ')" 8
check "vsub: pool private"           has x "$K/etc/switchback/vless.pool" "203.0.113.19"
check "vsub: first: same step, faster" equal x "$(head -n 1 "$P" | cut -f1-3)" "210	20.0	www.microsoft.com"
check "vsub: second"                 equal x "$(sed -n 2p "$P" | cut -f1-2)" "200	6.0"
check "vsub: next step by speed, then delay" equal x "$(cut -f1 "$P" | tr '\n' ' ')" "210 200 220 240 230 250 260 270 "
check "vsub: speed by the second address" equal x "$(sed -n 3p "$P" | cut -f1-2)" "220	6.0"
check "vsub: a cut download: what came" equal x "$(sed -n 5p "$P" | cut -f1-2)" "230	0.4"
check "vsub: no dead one kept"       hasnt x "$P" "@203.0.113.5:"
check "vsub: no key without Claude"  hasnt x "$P" "@203.0.113.6:"
check "vsub: no key without ChatGPT" hasnt x "$P" "@203.0.113.7:"
check "vsub: name shown"             has x "$K/out" "1. 🇳🇱 NL-19 (www.microsoft.com) — 210 мс, 20.0 Мбит/с"
check "vsub: the 6th without speed"  has x "$K/out" "6. 🇳🇱 NL-15 (www.microsoft.com) — 250 мс"
check "vsub: balancer outbounds"     has x "$X" '"tag": "vless-8"'
check "vsub: no more than 8"         hasnt x "$X" '"tag": "vless-9"'
check "vsub: best first"             has x "$X" '"address": "203.0.113.19", "port": 443'
check "vsub: leastPing"              has x "$X" '"balancers": [{"tag": "pool", "selector": ["vless-"], "strategy": {"type": "leastPing"}, "fallbackTag": "vless-1"}]'
check "vsub: everything through it"  has x "$X" '"inboundTag": ["redirect", "check"], "balancerTag": "pool"'
check "vsub: observatory"            has x "$X" '"observatory": {"subjectSelector": ["vless-"], "probeURL": "https://www.gstatic.com/generate_204", "probeInterval": "3m"'
# Xray's settings must be valid JSON (the fake Xray takes anything): the working one and a batch's
PY=""; for c in python3 python; do "$c" -c '' >/dev/null 2>&1 && { PY=$c; break; }; done
jsonok() { "$PY" -c 'import json,sys; json.load(sys.stdin)' < "$2"; }
if [ -n "$PY" ]; then
  check "vsub: settings are JSON"    jsonok x "$X"
  check "vsub: a batch is JSON"      jsonok x "$K/batch-last.json"
fi
check "vsub: own mark on each"       equal x "$(grep -c '"mark": 23387' "$X")" 8
check "vsub: redirect and SOCKS kept" has x "$X" '"listen": "127.0.0.1", "port": 10809'
check "vsub: servers never redirected" has x "$K/etc/switchback/vless.conf" "203.0.113.19"
check "vsub: kind"                   has x "$K/etc/switchback/vless.conf" 'KIND="подписка, ключей: 8 (балансировщик)"'
check "vsub: service started"        has x "$K/xray.log" "xray run -c $X"
check "vsub: works through it"       has x "$K/out" "VLESS работает"
check "vsub: daily job"              exists x "$J"
check "vsub: job paths filled"       hasnt x "$J" "__"
check "vsub: job in the journal"     has x "$K/etc/switchback/state" "file $J"
check "vsub: work files gone"        equal x "$(ls -d "$SB_TMP"/switchback-vsub.* 2>/dev/null)" ""
check "vsub: lock gone"              missing x "$K/var/run/sb-vsub.lock"
check "vsub: list kept for a refill" equal x "$(wc -l < "$K/etc/switchback/vless.list" | tr -d ' ')" 20
for f in "$K/out" "$K/var/log/switchback.log" "$K/etc/switchback/state" "$K/etc/switchback/vless.stat" "$K/etc/switchback/vless.conf"; do
  n=${f##*/}
  check "vsub: no UUID in $n"        hasnt x "$f" "1f1e2d3c-4b5a"
  check "vsub: no key in $n"         hasnt x "$f" "$PBK"
  check "vsub: no address of it in $n" hasnt x "$f" "$SUBTOK"
done
check "vsub: no link in the output"  hasnt x "$K/out" "vless://"
check "vsub: no trojan password"     hasnt x "$K/out" "secretpass"
check "vsub: logged as numbers"      has x "$K/var/log/switchback.log" "vless sub: links 29, vless 25, unique 20 (dup 2, broken 3), checked 20"
# the status
sb_k vless status
check "vsub status: pool"            has x "$K/out" "ключи подписки: 8 в балансировщике, лучшая задержка 200 мс"
check "vsub status: names"           has x "$K/out" "NL-20 (www.ozon.ru) — 200 мс"
check "vsub status: kind"            has x "$K/out" "VLESS настроен: подписка, ключей: 8 (балансировщик)"
check "vsub status: no UUID"         hasnt x "$K/out" "1f1e2d3c-4b5a"
sb_k vless sub status
check "vsub sub status"              has x "$K/out" "адрес подписки сохранён"
# the AI reserve's path and own sites through VLESS work through the balancer unchanged
echo 160.79.104.10 > "$K/vless-ip"; cat > "$K/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in "route get "*) echo "$3 dev nwg0 src 10.8.0.2" ;; esac
EOF
chmod +x "$K/bin/ip"
sb_k ai on; sb_k ai via vless 2
check "vsub+ai: Claude through the pool" equal x "$(cat "$K/var/ai-path/cur.claude")" vless
check "vsub+ai: address to Xray"     has x "$K/etc/switchback/vless.ips" "160.79.104.10/32 ai:claude"
# plain text on stdin; a link a line, each in base64; a blob wrapped at 76; a subscription that answers only to a client
sb_k vless sub set --conf - < "$K/sub.plain"
check "vsub plain: read"             has x "$K/out" "в подписке ссылок: 29 — VLESS 25"
check "vsub plain: address kept from before" has x "$K/etc/switchback/vless.sub" "$SUBTOK"
{ key 19 | tr -d '\n' | base64 | tr -d '\n'; echo; key 20 | tr -d '\n' | base64 | tr -d '\n'; echo; key 9 x | tr -d '\n' | base64 | tr -d '=\n'; echo; } > "$K/lines.b64"
sb_k vless sub set --conf "$K/lines.b64"
check "vsub b64 lines: read"         has x "$K/out" "в подписке ссылок: 3 — VLESS 3"
check "vsub b64 lines: all kept"     equal x "$(wc -l < "$P" | tr -d ' ')" 3
base64 < "$K/sub.plain" | fold -w 76 > "$K/sub-body"
touch "$K/sub-ua"; sb_k vless sub set --conf "$K/sub"; rm -f "$K/sub-ua"
check "vsub wrapped: read"           has x "$K/out" "в подписке ссылок: 29 — VLESS 25"
check "vsub: asked again as a client" has x "$K/curl.log" "-A v2rayNG/1.8.5"
# the same blob without base64 -d (the awk decoder); the link per line above never takes base64 -d
export VSUB_NO_B64=1; sb_k vless sub set --conf "$K/sub-body"; unset VSUB_NO_B64
check "vsub wrapped, awk decoder: read" has x "$K/out" "в подписке ссылок: 29 — VLESS 25"
base64 < "$K/sub.plain" | tr -d '\n' > "$K/blob1"; sb_k vless sub set --conf "$K/blob1"
check "vsub one-line blob: read"     has x "$K/out" "в подписке ссылок: 29 — VLESS 25"
# bad inputs: nothing found, a page, broken only; the working settings stay
cp "$X" "$K/x.before"
printf 'nothing here\n' > "$K/bad"; sb_k vless sub set --conf "$K/bad"
check "vsub bad: refused"            equal x "$RC" 1
check "vsub bad: says why"           has x "$K/out" "в подписке не нашёл ссылок"
printf '<html><body>login</body></html>\n' > "$K/bad"; sb_k vless sub set --conf "$K/bad"
check "vsub page: says why"          has x "$K/out" "вместо подписки пришла веб-страница"
printf 'vless://%s@203.0.113.30:443?security=none\nvmess://abc\n' "$(uuid 30)" > "$K/bad"; sb_k vless sub set --conf "$K/bad"
check "vsub broken only: refused"    has x "$K/out" "ни одной годной ссылки VLESS"
check "vsub broken only: no UUID"    hasnt x "$K/out" "1f1e2d3c"
check "vsub bad: settings kept"      equal x "$(cat "$K/x.before")" "$(cat "$X")"
# all dead: nothing kept, the old keys stay
for h in 7 9 10 11 12 13 14 15 16 17 18 19 20; do touch "$K/vsub-dead-203.0.113.$h"; done
sb_k vless sub set --conf "$K/sub.plain"
check "vsub all dead: says so"       has x "$K/out" "подходящих ключей нет"
check "vsub all dead: old ones kept" equal x "$(cat "$K/x.before")" "$(cat "$X")"
for h in 7 9 10 11 12 13 14 15 16 17 18 19 20; do rm -f "$K/vsub-dead-203.0.113.$h"; done
# too little memory: no check started
printf 'MemTotal: 131072 kB\nMemAvailable: 20480 kB\n' > "$K/meminfo-low"
export SB_MEMINFO=$K/meminfo-low; sb_k vless sub set --conf "$K/sub.plain"; unset SB_MEMINFO
check "vsub low memory: stops"       has x "$K/out" "мало свободной памяти (20 МБ)"
check "vsub low memory: nothing changed" equal x "$(cat "$K/x.before")" "$(cat "$X")"
rm -f "$K/xray-refuse-203.0.113.8"; : > "$K/xray.log"; sb_k vless sub set --conf "$K/sub"
check "vsub: a batch of 10"          has x "$K/xray.log" "batch 10"
check "vsub: never more than 10"     hasnt x "$K/xray.log" "batch 20"
printf 'MemTotal: 131072 kB\nMemAvailable: 40960 kB\n' > "$K/meminfo-low"; : > "$K/xray.log"
export SB_MEMINFO=$K/meminfo-low; sb_k vless sub set --conf "$K/sub"; unset SB_MEMINFO
check "vsub less memory: batches of 5" has x "$K/xray.log" "batch 5"
check "vsub less memory: never 20"   hasnt x "$K/xray.log" "batch 20"
touch "$K/xray-refuse-203.0.113.8"
# the recheck: one key died -> out; fewer than 3 alive -> the subscription again (the saved list when it does not answer)
cp "$X" "$K/x.before"
touch "$K/vsub-dead-203.0.113.19"; sb_k vless sub check
check "vsub check: exit 0"           equal x "$RC" 0
check "vsub check: one died"         has x "$K/out" "Итог: живы 7 из 8"
check "vsub check: removed from Xray" hasnt x "$X" '"tag": "vless-8"'
check "vsub check: 7 left"           equal x "$(wc -l < "$P" | tr -d ' ')" 7
check "vsub check: the dead one out" hasnt x "$P" "@203.0.113.19:"
for h in 20 18 17 16 15; do touch "$K/vsub-dead-203.0.113.$h"; done
touch "$K/sub-down"; : > "$K/curl.log"; sb_k vless sub check auto
check "vsub refill: again"           has x "$K/out" "прохожу подписку заново"
check "vsub refill: the saved list"  has x "$K/out" "беру список ключей, сохранённый при прошлой проверке"
check "vsub refill: checked"         has x "$K/out" "Итог: проверено 20 из 20"
check "vsub refill: kept the living" equal x "$(wc -l < "$P" | tr -d ' ')" 6
check "vsub refill: told the owner"  has x "$K/curl.log" "прошёл подписку заново"
check "vsub refill: no UUID sent"    hasnt x "$K/curl.log" "1f1e2d3c"
rm -f "$K/sub-down"
# the daily job: nothing before a day has passed
n0=$(wc -l < "$K/var/log/switchback.log"); sh "$J"
check "vsub job: not yet"            equal x "$(wc -l < "$K/var/log/switchback.log")" "$n0"
# the bot: the address as text (not a site: a token), asked first, checked, the message deleted
SL='\/'
printf '{"ok":true,"result":[{"update_id":501,"message":{"message_id":88,"chat":{"id":-100},"text":"https:%s%ssub.example.net%sapi%ssub%s%s"}}]}\n' "$SL" "$SL" "$SL" "$SL" "$SL" "$SUBTOK" > "$K/updates"
bot1
check "bot vsub: recognised"         has x "$K/curl.log" "Похоже на ссылку на подписку VLESS"
check "bot vsub: message deleted"    has x "$K/curl.log" "deleteMessage -d chat_id=-100 -d message_id=88"
check "bot vsub: check button"       has x "$K/curl.log" '"callback_data":"vsub go"'
check "bot vsub: kept for the check" has x "$K/var/sb-bot/vsub-in" "$SUBURL"
check "bot vsub: not repeated"       hasnt x "$K/curl.log" "$SUBTOK"
check "bot vsub: not logged"         hasnt x "$K/var/sb-bot/log" "$SUBTOK"
botmsg "/vsub go" "yes"; bot1
check "bot vsub: asks first"         has x "$K/curl.log" "Проверить ключи подписки на роутере"
check "bot vsub: result sent"        has x "$K/curl.log" "Итог: проверено"
check "bot vsub: wiped"              missing x "$K/var/sb-bot/vsub-job"
check "bot vsub: nothing waiting"    missing x "$K/var/sb-bot/vsub-in"
check "bot vsub: no UUID sent"       hasnt x "$K/curl.log" "1f1e2d3c"
# a .txt file with a list: the same question; one link in a file: set at once as before
cp "$K/sub.plain" "$K/tg-file"; botdoc "keys.txt"; bot1
check "bot vsub file: a list"        has x "$K/curl.log" "Получил файл со списком ключей"
check "bot vsub file: kept"          exists x "$K/var/sb-bot/vsub-in"
botmsg "/vsub drop"; bot1
check "bot vsub file: dropped"       missing x "$K/var/sb-bot/vsub-in"
# /vless: the recheck button; /vless check
botmsg "/vless"; bot1
check "bot /vless: recheck button"   has x "$K/curl.log" '"callback_data":"vsub check"'
check "bot /vless: names"            has x "$K/curl.log" "ключи подписки:"
botmsg "/vless check"; bot1
check "bot /vless check: result"     has x "$K/curl.log" "Итог: живы"
# off: everything of the subscription goes
sb_k vless off
check "vsub off: address gone"       missing x "$K/etc/switchback/vless.sub"
check "vsub off: list gone"          missing x "$K/etc/switchback/vless.list"
check "vsub off: pool gone"          missing x "$P"
check "vsub off: job gone"           missing x "$J"
check "vsub off: journal clean"      hasnt x "$K/etc/switchback/state" "sb-vless-sub"
unset SB_XRAY_WAIT SB_IPT SB_IPSET VSUB_SHUFFLE
openwrt vsub-owrt
printf '%s\n' "$SUBURL" > "$R/sub"; sb_o vless sub set --conf "$R/sub"
check "openwrt vsub: refused"        has x "$R/out" "только на Keenetic"

# ---------- every WireGuard tunnel dead: Telegram, Meta and the VPN sites through VLESS for a while ("vless sos") ---------- [vsub]
keenetic vsos
printf 'profile=custom\nmodules=vpn watchdog failover\nvpn_iface=Wireguard0\nfailover_tunnels=Wireguard0 Wireguard1\nbot_token=%s\nbot_chat=-100\n' "$TOKEN" > "$K/a"
sb_k install --answers "$K/a"
check "vsos: base install"           equal x "$RC" 0
export SB_XRAY_WAIT=0 SB_IPT=$K/bin/fipt SB_IPSET=$K/bin/fipset
printf '#!/bin/sh\necho "iptables $*" >> "$SB_OPT/ipt.log"\ncase " $* " in *" -C "*|*" -D "*) exit 1 ;; esac\nexit 0\n' > "$K/bin/fipt"
printf '#!/bin/sh\necho "ipset $*" >> "$SB_OPT/ipt.log"\n[ "$2" = restore ] && cat >> "$SB_OPT/ipt.log"\nexit 0\n' > "$K/bin/fipset"
chmod +x "$K/bin/fipt" "$K/bin/fipset"
printf 'vless://%s@203.0.113.80:443?security=reality&sni=www.example.com&pbk=%s&sid=6ba85179e30d4fc2&type=tcp&flow=xtls-rprx-vision\n' \
  0f1e2d3c-4b5a-4987-8a6b-5c4d3e2f1a0b TestPublicKeyOnlyForTests_abcdefghijklmnopq > "$K/link"
sb_k vless set --conf "$K/link"
check "vsos: VLESS set"              equal x "$RC" 0
echo "vpn site.example" >> "$K/etc/switchback/sites"; printf '10.7.7.7\n' > "$K/dns-site.example"
echo "zapret other.example" >> "$K/etc/switchback/sites"; printf '10.7.7.8\n' > "$K/dns-other.example"
sed -i 's/^DEAD_RUNS=.*/DEAD_RUNS=1/; s/^UP_WAIT=.*/UP_WAIT=5/' "$K/etc/switchback/failover.conf"
FO=$K/etc/cron.1min/wg-failover; VI=$K/etc/switchback/vless.ips
fo() { SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$FO" "$@" > "$K/fo.out" 2>&1; }
# normal times: nothing but the AI services may use VLESS
fo
check "vsos: healthy: nothing to VLESS" hasnt x "$VI" "sos:"
# every tunnel dead -> Telegram, Meta and the VPN site to VLESS, the owner told with a button
touch "$K/wg-dead-Wireguard0"; : > "$K/curl.log"; : > "$K/ipt.log"; fo
check "vsos on: Telegram"            has x "$VI" "91.108.56.0/22 sos:telegram"
check "vsos on: Meta"                has x "$VI" "sos:instagram"
check "vsos on: the VPN site"        has x "$VI" "10.7.7.7/32 sos:site.example"
check "vsos on: not other sites"     hasnt x "$VI" "10.7.7.8"
check "vsos on: the set filled"      has x "$K/ipt.log" "add sb-vless-new 91.108.56.0/22"
check "vsos on: redirected"          has x "$K/ipt.log" "-I PREROUTING -p tcp -m set --match-set sb-vless dst"
check "vsos on: marked"              exists x "$K/etc/switchback/vless.sos"
check "vsos on: told"                has x "$K/curl.log" "Ни один туннель WireGuard не отвечает. Временно пустил через VLESS"
check "vsos on: the no button"       has x "$K/curl.log" '"callback_data":"vsos no"'
check "vsos on: button text"         has x "$K/curl.log" "Не надо, оставить как есть"
check "vsos on: no 'nothing works' alarm" hasnt x "$K/curl.log" "Telegram и Instagram сейчас не работают"
check "vsos on: logged"              has x "$K/var/wg-failover/log" "every tunnel dead: Telegram, Meta and VPN sites through VLESS"
check "vsos on: the site not named"  hasnt x "$K/curl.log" "site.example"
sb_k vless status
check "vsos status: said"            has x "$K/out" "временно идут через VLESS"
# still dead: told once only
rm -f "$K/var/wg-failover/last_try"; : > "$K/curl.log"; fo
check "vsos on: told once"           hasnt x "$K/curl.log" "Временно пустил"
check "vsos on: still on"            has x "$VI" "sos:telegram"
# the tunnel is back but Telegram through it goes into Xray (dead) while VLESS holds it (21.11.2026): Google's 204
rm -f "$K/wg-dead-Wireguard0"; touch "$K/site-novpn-api.telegram.org"; fo
check "vsos, Telegram held by Xray: back" hasnt x "$VI" "sos:"
touch "$K/wg-dead-Wireguard0"; rm -f "$K/site-novpn-api.telegram.org" "$K/var/wg-failover/last_try" "$K/var/wg-failover/last_switch" "$K/var/wg-failover/nostandby.sent"; fo
check "vsos on again"                has x "$VI" "sos:telegram"
# a tunnel answers again -> all back on WireGuard by itself, the owner told
rm -f "$K/wg-dead-Wireguard0"; : > "$K/curl.log"; fo
check "vsos back: out of VLESS"      hasnt x "$VI" "sos:"
check "vsos back: mark gone"         missing x "$K/etc/switchback/vless.sos"
check "vsos back: told"              has x "$K/curl.log" "Туннель WireGuard снова работает"
check "vsos back: logged"            has x "$K/var/wg-failover/log" "a tunnel works again"
# a standby answering is a way back too
touch "$K/wg-dead-Wireguard0"; rm -f "$K/var/wg-failover/last_try" "$K/var/wg-failover/last_switch" "$K/var/wg-failover/nostandby.sent"; fo
check "vsos again: on"               has x "$VI" "sos:telegram"
touch "$K/wg-alive-Wireguard1"; rm -f "$K/var/wg-failover/last_try"; : > "$K/curl.log"; fo
check "vsos switch: moved to the standby" has x "$K/var/wg-failover/log" "SWITCHED Wireguard0"
check "vsos switch: back from VLESS" hasnt x "$VI" "sos:"
check "vsos switch: told"            has x "$K/curl.log" "Туннель WireGuard снова работает"
# the owner says no: back from VLESS and not again until a tunnel has answered
rm -f "$K/wg-alive-Wireguard1" "$K/var/wg-failover/last_try" "$K/var/wg-failover/last_switch" "$K/var/wg-failover/nostandby.sent"; fo
check "vsos no: on first"            has x "$VI" "sos:telegram"
botmsg "/vsos no"; bot1
check "vsos no: out of VLESS"        hasnt x "$VI" "sos:"
check "vsos no: answered"            has x "$K/curl.log" "пока туннель WireGuard не оживёт, сам не включу"
check "vsos no: remembered"          exists x "$K/etc/switchback/vless.sos.no"
rm -f "$K/var/wg-failover/last_try"; fo
check "vsos no: not again while dead" hasnt x "$VI" "sos:"
rm -f "$K/wg-dead-Wireguard0"; fo
check "vsos no: forgotten once a tunnel works" missing x "$K/etc/switchback/vless.sos.no"
# off and uninstall take it all
touch "$K/wg-dead-Wireguard0"; rm -f "$K/var/wg-failover/last_try" "$K/var/wg-failover/last_switch" "$K/var/wg-failover/nostandby.sent"; fo
check "vsos: on before off"          exists x "$K/etc/switchback/vless.sos"
sb_k vless off
check "vsos off: mark gone"          missing x "$K/etc/switchback/vless.sos"
rm -f "$K/var/wg-failover/last_try"; fo
check "vsos off: no VLESS, nothing to send" missing x "$K/etc/switchback/vless.sos"
unset SB_XRAY_WAIT SB_IPT SB_IPSET

# ---------- a subscription's keys that open slowly: the first request through a key is its connection ---------- [vsub]
# (20.11.2026, on the router: TLS + grpc or ws on one core takes 3-8 s the first time, 1-3 s after; a short limit on
# the first request found 1 of 518 alive)
keenetic vsubslow
printf 'profile=custom\nmodules=zapret vpn watchdog\nvpn_iface=Wireguard0\n' > "$K/a"
sb_k install --answers "$K/a"
check "vsub slow: base install"      equal x "$RC" 0
export SB_XRAY_WAIT=0 SB_IPT=$K/bin/fipt SB_IPSET=$K/bin/fipset VSUB_SHUFFLE=0
printf '#!/bin/sh\necho "iptables $*" >> "$SB_OPT/ipt.log"\ncase " $* " in *" -C "*|*" -D "*) exit 1 ;; esac\nexit 0\n' > "$K/bin/fipt"
printf '#!/bin/sh\necho "ipset $*" >> "$SB_OPT/ipt.log"\n[ "$2" = restore ] && cat >> "$SB_OPT/ipt.log"\nexit 0\n' > "$K/bin/fipset"
chmod +x "$K/bin/fipt" "$K/bin/fipset"
{ i=1; while [ $i -le 6 ]; do key $i; i=$((i+1)); done; } > "$K/sub.plain"
# the first request: 7.5, 3, 12, 19 s (alive), 25 s (more than the warm-up allows: dead); .6 quick
echo 7.5 > "$K/vsub-slow-203.0.113.1"; echo 3.0 > "$K/vsub-slow-203.0.113.2"; echo 12.0 > "$K/vsub-slow-203.0.113.3"
echo 19.0 > "$K/vsub-slow-203.0.113.4"; echo 25.0 > "$K/vsub-slow-203.0.113.5"
i=1; while [ $i -le 6 ]; do printf '0.%03d\n' $((200 + i * 30)) > "$K/vsub-ms-203.0.113.$i"; i=$((i+1)); done
# nice where there is one: the check's Xray and curl at the lowest priority
printf '#!/bin/sh\necho "nice $*" >> "$SB_OPT/nice.log"\nshift 2\nexec "$@"\n' > "$K/bin/nice"; chmod +x "$K/bin/nice"   # $OPT/bin is on PATH
P=$K/etc/switchback/vless.pool; : > "$K/curl.log"; : > "$K/xray.log"
sb_k vless sub set --conf "$K/sub.plain"
check "vsub slow: exit 0"            equal x "$RC" 0
check "vsub slow: slow ones alive"   has x "$K/out" "живые 5, Claude открывается через 5, ChatGPT через 5, Telegram через 5, подходят 5"
check "vsub slow: kept, 12 s the first time" has x "$P" "@203.0.113.3:"
check "vsub slow: kept, 19 s the first time" has x "$P" "@203.0.113.4:"
check "vsub slow: more than 20 s: dead" hasnt x "$P" "@203.0.113.5:"
check "vsub slow: delay by the next request" equal x "$(cut -f1 "$P" | tr '\n' ' ')" "230 260 290 320 380 "
check "vsub slow: first request has time" has x "$K/curl.log" "--connect-timeout 15 --max-time 20 -w %{http_code} %{time_total} %{size_download} --socks5-hostname 127.0.0.1:10821 https://www.gstatic.com/generate_204"
check "vsub slow: then the usual limits" has x "$K/curl.log" "--connect-timeout 6 --max-time 8 -w %{http_code} %{time_total} %{size_download} --socks5-hostname 127.0.0.1:10821 https://www.gstatic.com/generate_204"
check "vsub slow: sites by HEAD"     has x "$K/curl.log" "-I --connect-timeout 6 --max-time 12 -w %{http_code} %{time_total} %{size_download} --socks5-hostname 127.0.0.1:10821 https://claude.ai/"
check "vsub slow: two at once, at most 10 a batch" has x "$K/xray.log" "batch 6"
check "vsub slow: curl at the lowest priority" has x "$K/nice.log" "nice -n 19 curl -s -o /dev/null"
check "vsub slow: Xray at the lowest priority" has x "$K/nice.log" "xray run -c $SB_TMP/switchback-vsub."
check "vsub slow: the working Xray not niced" hasnt x "$K/nice.log" "xray.json"
# a nice that does not work: the check runs without it
printf '#!/bin/sh\necho "nice $*" >> "$SB_OPT/nice.log"\nexit 1\n' > "$K/bin/nice"; : > "$K/nice.log"
sb_k vless sub set --conf "$K/sub.plain"
check "vsub no nice: still checked"  has x "$K/out" "подходят 5"
check "vsub no nice: tried once"     equal x "$(cat "$K/nice.log")" "nice -n 19 true"
unset SB_XRAY_WAIT SB_IPT SB_IPSET VSUB_SHUFFLE

# ---------- the list of the best keys must reach Xray whole; when Xray refuses, why (20.11.2026, on the router) ---------- [vsub]
keenetic vsubpool
printf 'profile=custom\nmodules=zapret vpn watchdog\nvpn_iface=Wireguard0\n' > "$K/a"
sb_k install --answers "$K/a"
check "vsub pool: base install"      equal x "$RC" 0
export SB_XRAY_WAIT=0 SB_IPT=$K/bin/fipt SB_IPSET=$K/bin/fipset VSUB_SHUFFLE=0
printf '#!/bin/sh\necho "iptables $*" >> "$SB_OPT/ipt.log"\ncase " $* " in *" -C "*|*" -D "*) exit 1 ;; esac\nexit 0\n' > "$K/bin/fipt"
printf '#!/bin/sh\necho "ipset $*" >> "$SB_OPT/ipt.log"\n[ "$2" = restore ] && cat >> "$SB_OPT/ipt.log"\nexit 0\n' > "$K/bin/fipset"
chmod +x "$K/bin/fipt" "$K/bin/fipset"
# names with a tab, a new line, a zero byte, a DEL, a flag
{ key 1 "a%09b"; key 2 "a%0Ab"; key 3 "a%00b"; key 4 "a%7Fb"; key 5 "%F0%9F%87%A9%F0%9F%87%AA%20DE"; } > "$K/sub.plain"
P=$K/etc/switchback/vless.pool; X=$K/etc/switchback/xray.json
sb_k vless sub set --conf "$K/sub.plain"
check "vsub pool: odd names: kept"   has x "$K/out" "оставлены лучшие 5"
check "vsub pool: one line a key"    equal x "$(wc -l < "$P" | tr -d ' ')" 5
check "vsub pool: five fields each"  equal x "$(awk -F'\t' '{printf "%d", NF}' "$P")" 55555
check "vsub pool: the link last"     equal x "$(awk -F'\t' '$NF ~ /^vless:\/\// {n++} END {print n}' "$P")" 5
check "vsub pool: no control bytes in names" equal x "$(cut -f4 "$P" | tr -d '\n' | LC_ALL=C tr -d '[:print:]\200-\377' | wc -c | tr -d ' ')" 0
check "vsub pool: tab name"          equal x "$(sed -n 1p "$P" | cut -f4)" ab
check "vsub pool: Xray got them all" equal x "$(grep -c '"protocol": "vless"' "$X")" 5
# Xray refuses the balancer: its reason shown and logged, masked; nothing kept, the old settings stay
cp "$X" "$K/x.before"; touch "$K/xray-refuse-pool"
sb_k vless sub set --conf "$K/sub.plain"
check "vsub refused: said"           has x "$K/out" "Xray не принял настройки с ключами подписки — рабочие настройки не тронуты"
check "vsub refused: Xray's reason"  has x "$K/out" "Xray: Failed to start: main: failed to load config files: [CONF] > infra/conf: failed to build outbound config with tag vless-3 > address ADDR (HOST) id UUID pbk KEY: invalid"
check "vsub refused: no address"     hasnt x "$K/out" "203.0.113.19"
check "vsub refused: no UUID"        hasnt x "$K/out" "1f1e2d3c"
check "vsub refused: no key"         hasnt x "$K/out" "TestPublicKey"
check "vsub refused: no name"        hasnt x "$K/out" "cdn.example.net"
L=$K/var/log/switchback.log
check "vsub refused: logged with the count" has x "$L" "vless: xray -test refused (pool, outbounds 5): Failed to start"
check "vsub refused: log masked"     hasnt x "$L" "1f1e2d3c"
check "vsub refused: nothing kept"   has x "$K/out" "оставлено 0"
check "vsub refused: not 'none fit'" hasnt x "$K/out" "подходящих ключей нет"
check "vsub refused: the old ones kept" has x "$K/out" "прежние ключи оставлены"
check "vsub refused: settings kept"  equal x "$(cat "$K/x.before")" "$(cat "$X")"
check "vsub refused: no temp left"   missing x "$X.new.err"
rm -f "$K/xray-refuse-pool"
# a list of the best without a single link (it broke on its way): said so, not blamed on Xray
mkdir -p "$K/gw"; printf '230\t6.0\tsni.example\t-\n260\t0\tsni.example\tDE\n' > "$K/gw/pool"
gp=$(SB_TEST=1 "$SH" -c ". '$SRC/lib/common.sh'; . '$SRC/lib/vless.sh'; . '$SRC/lib/vsub.sh'; W='$K/gw'; LOG='$K/gw/log'; vsub_apply; echo rc=\$?" 2>&1)
echo "$gp" > "$K/gw/out"
check "vsub empty pool: said"        has x "$K/gw/out" "не собрал список лучших ключей"
check "vsub empty pool: not Xray"    hasnt x "$K/gw/out" "Xray не принял"
check "vsub empty pool: failed"      has x "$K/gw/out" "rc=1"
check "vsub empty pool: its shape logged" has x "$K/gw/log" "the pool has no key to parse: lines 2, fields 4/4, vless:// last 0"
unset SB_XRAY_WAIT SB_IPT SB_IPSET VSUB_SHUFFLE

# ========== the result ==========
echo ""
echo "Тесты: прошло $PASS, не прошло $FAILED  (оболочка: $SH)"
[ "$FAILED" = 0 ] && rm -rf "$WORK" || echo "Файлы упавших проверок: $WORK"
[ "$FAILED" = 0 ]
