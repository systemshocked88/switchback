#!/bin/sh
# Automatic tests of install.sh on fake routers (no real router is touched).
#   sh tests/run.sh            (uses dash if present: closest to BusyBox ash on routers)
# Each case builds a fresh fake Keenetic /opt or OpenWrt root in a temp folder.

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/.." && pwd)
SH=$(command -v dash || command -v sh)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sb-tests.XXXXXX")
PASS=0; FAILED=0
TOKEN=123456789:AAFakeTokenForTestsOnly_abcdefghijklmnop
export SB_WG_TRIES=1           # the WireGuard traffic check waits 5 s per try: one try in tests

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

keenetic() { CASE=$1; K=$WORK/$1; mkdir -p "$K"; sh "$HERE/fake-keenetic.sh" "$K" >/dev/null; }
sb_k() {    # run install.sh against the fake Keenetic $K; output in $K/out, exit code in $RC
  SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$SRC/install.sh" "$@" > "$K/out" 2>&1; RC=$?
}
openwrt() { CASE=$1; R=$WORK/$1; mkdir -p "$R"; sh "$HERE/fake-openwrt.sh" "$R" >/dev/null; }
sb_o() {
  SB_ROOT=$R SB_OPT=$R SB_TEST=1 SB_PLATFORM=openwrt "$SH" "$SRC/install.sh" "$@" > "$R/out" 2>&1; RC=$?
}
ev_count() { grep -c "^@@sb	$2" "$1"; }    # ev_count FILE EVENT

# ---------- doctor with progress events ----------
keenetic doctor
sb_k doctor --progress
check "doctor event"           has x "$K/out" "@@sb	doctor	"
check "end event"              has x "$K/out" "@@sb	end	$RC"
check "items as events"        has x "$K/out" "@@sb	item	ok	"
check "no colour codes"        hasnt x "$K/out" "$(printf '\033')"
check "auto-update noted"      has x "$K/out" "включено автообновление KeeneticOS"

# ---------- answers file: bad input is refused before anything happens ----------
keenetic badkey
printf 'profle=full\n' > "$K/a"; sb_k install --answers "$K/a"
check "unknown key -> exit 2"  equal x "$RC" 2
check "says which key"         has x "$K/out" "неизвестный ключ profle"
printf 'just-a-token-pasted\n' > "$K/a"; sb_k install --answers "$K/a"
check "line without = -> 2"    equal x "$RC" 2
check "value not echoed"       hasnt x "$K/out" "just-a-token-pasted"

# ---------- dry run with answers: nothing changes ----------
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

# ---------- real install from stdin answers, then uninstall ----------
keenetic full
printf 'src/gz entware http://bin.entware.net/mipselsf-k3.4\n' > "$K/etc/opkg.conf"
cp "$K/etc/nfqws2/nfqws2.conf" "$K/conf.before"
printf 'profile=full\r\nzapret_exclude_policy=nfqws\r\ndns_claude=y\r\ndns_claude_ip=5.6.7.8\r\ndns_claude_sni=dns.claude.example\r\nvpn_iface=Wireguard0\r\nbot_token=%s\r\nbot_chat=-100\r\n' "$TOKEN" |
  SB_OPT=$K SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$SRC/install.sh" install --progress --answers - > "$K/out" 2>&1; RC=$?
check "exit 0"                 equal x "$RC" 0
check "CRLF answers accepted"  has x "$K/etc/nfqws2/nfqws2.conf" 'POLICY_NAME="nfqws"'
check "video servers: own ways" has x "$K/etc/nfqws2/nfqws2.conf" 'NFQWS_ARGS_CUSTOM="--filter-tcp=443 --filter-l7=tls --hostlist-domains=googlevideo.com'
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

# ---------- KeeneticOS removes a DoT server with all its domains: the others are put back (real router, 2026-11-11) ----------
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

# ---------- another DNS service for a domain that already has one: replaced, not skipped ----------
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
printf 'profile=custom\nmodules=dns\ndns_chatgpt=y\ndns_chatgpt_doh=https://two.example/dns-query\n' > "$R/a"; : > "$R/svc.log"
sb_o install --answers "$R/a"
check "second service exit 0"  equal x "$RC" 0
check "new address in place"   has x "$R/uci.db" "$(printf 'https-dns-proxy.sb_chatgpt.resolver_url\thttps://two.example/dns-query')"
check "old address gone"       hasnt x "$R/uci.db" "one.example"
check "DoH proxy restarted"    has x "$R/svc.log" "https-dns-proxy restart"
check "domains left as they are" has x "$R/out" "chatgpt.com уже настроен"

# ---------- the router's own connections go past zapret (kernel memory leak, real Keenetic 2026-11-11) ----------
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
# ---------- devices at home do not use QUIC (the YouTube app on a TV, real Keenetic 2026-11-15) ----------
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

# ---------- answers without bot token: watchdog skipped, not a failure ----------
keenetic notoken
printf 'profile=custom\nmodules=watchdog\n' > "$K/a"
sb_k install --answers "$K/a"
check "exit 0"                 equal x "$RC" 0
check "explains the skip"      has x "$K/out" "нет ни токена бота"
check "no watchdog installed"  missing x "$K/etc/cron.5mins/watchdog"

# ---------- found on the real Keenetic (2026-11-07) ----------
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

# ---------- failover: the module installs it; the script switches, and handles the edge cases ----------
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

# ---------- Claude nodes (Keenetic): QUIC rules, pin to the fastest node, the switch script ----------
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
rm -f "$K/node-dead-10.0.0.1"; : > "$K/curl.log"; nd
check "back: told so"          has x "$K/curl.log" "снова отвечает"
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

# ---------- report: useful parts in, every secret out ----------
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

# ---------- custom modules keep the safe order ----------
keenetic order
printf 'profile=custom\nmodules=vpn https\nvpn_iface=Wireguard0\n' > "$K/a"
sb_k install --dry-run --progress --answers "$K/a"
check "order https, vpn"       has x "$K/out" "@@sb	plan	https	vpn"

# ---------- failure in the middle rolls back this run ----------
keenetic fail
cp "$K/etc/nfqws2/nfqws2.conf" "$K/conf.before"
printf 'profile=full\ndns_claude=y\ndns_claude_ip=9.9.9.9\ndns_claude_sni=bad.example\nvpn_iface=Wireguard0\n' > "$K/a"
sb_k install --progress --answers "$K/a"
check "exit 1"                 equal x "$RC" 1
check "fail event"             has x "$K/out" "@@sb	fail	"
check "end 1"                  has x "$K/out" "@@sb	end	1"
check "zapret conf rolled back" equal x "$(cat "$K/conf.before")" "$(cat "$K/etc/nfqws2/nfqws2.conf")"
check "no Telegram routes"     hasnt x "$K/ndmc.log" "ip route 91.108.4.0"

# ---------- OpenWrt: install with answers, uninstall restores uci exactly ----------
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

# ---------- OpenWrt firmware upgrade: our files kept, lost packages found and reinstalled ----------
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
check "DoH proxy restarted"    has x "$R/svc.log" "https-dns-proxy restart"
check "no duplicate journal"   equal x "$(sort "$R/etc/switchback/state" | uniq -d)" ""
check "no duplicate keep lines" equal x "$(sort "$R/etc/sysupgrade.conf" | uniq -d)" ""
printf 'uninstall_confirm=y\nuninstall_packages=y\n' > "$R/u"
sb_o uninstall --answers "$R/u"
check "sysupgrade.conf restored" equal x "$(cat "$R/etc/sysupgrade.conf")" "/etc/my-own-file"

# ---------- status on a router where nothing was installed ----------
keenetic status-empty
sb_k status --progress
check "nothing installed yet"  has x "$K/out" "ещё ничего не ставил"
check "neutral status event"   has x "$K/out" "@@sb	status	none"

# ---------- WireGuard from a .conf: keys never shown, logged or journaled ----------
PRIV=aFakePrivateKeyForTestsOnly0123456789abcdE=
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

# ---------- many servers at once (wg-batch): checked one by one, working ones kept as standbys ----------
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
check "batch: no unpacked copy"  equal x "$(ls -d /tmp/switchback-wgb.* 2>/dev/null | wc -l | tr -d ' ')" 0
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

# ---------- 0.6: own copy on the router, bot commands, own sites, update, zapret tuning ----------
keenetic v06
printf 'profile=custom\nmodules=zapret vpn watchdog\nvpn_iface=Wireguard0\nbot_token=%s\nbot_chat=-100\n' "$TOKEN" > "$K/a"
sb_k install --answers "$K/a"
check "install exit 0"         equal x "$RC" 0
check "copy on the router"     equal x "$(cat "$K/etc/switchback/app/VERSION")" "$(sed -n 's/^VERSION=//p' "$SRC/install.sh")"
check "copy is complete"       exists x "$K/etc/switchback/app/lib/sites.sh"
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
sb_k sites add api.anthropic.com --via vpn
check "built-in not added"     has x "$K/out" "встроен в switchback"
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
export SB_VIDEO_NETS="203.0.113.0/24" SB_VIDEO_PAUSE=0 SB_VIDEO_TRY=20
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
printf '203.0.113.20 video\n198.51.100.20 video\n' >> "$K/etc/switchback/sites.routes"
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
# while "tune" tries settings (and 15 minutes after its start) nothing is checked
date +%s > "$K/etc/switchback/tune.running"; rm -f "$K/etc/switchback/video.seen"; : > "$K/curl.log"
sb_k sites refresh video
check "video: waits for tune"   hasnt x "$K/curl.log" "203.0.113"
rm -f "$K/etc/switchback/tune.running"
: > "$K/ndmc.log"; sb_k sites video off
check "video: routes removed"   has x "$K/ndmc.log" "no ip route 198.51.100.9 255.255.255.255 Wireguard0"
check "video: out of the list"  hasnt x "$K/etc/switchback/sites" "rescue video"
check "video: out of journal"   hasnt x "$K/etc/switchback/state" "site rescue video"
unset SB_CONNTRACK SB_VIDEO_NETS SB_VIDEO_PAUSE SB_VIDEO_TRY
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
botmsg() { n=0; out='{"ok":true,"result":['; for m; do n=$((n+1)); [ $n -gt 1 ] && out="$out,"; out="$out{\"update_id\":$((100+n)),\"message\":{\"chat\":{\"id\":-100},\"text\":\"$m\"}}"; done; printf '%s]}\n' "$out" > "$K/updates"; }
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
# /check: own sites are checked, the line of the cut-off servers job ("rescue video") is not a site
grep -qx 'rescue video' "$K/etc/switchback/sites" || echo 'rescue video' >> "$K/etc/switchback/sites"
botmsg "/check"
: > "$K/curl.log"; SB_OPT=$K SB_BOT_ONCE=1 SB_TEST=1 SB_PLATFORM=keenetic "$SH" "$K/etc/cron.1min/sb-bot" > /dev/null 2>&1
check "bot: check own site"    has x "$K/curl.log" "https://viabot2.example"
check "bot: no «video» site"   hasnt x "$K/curl.log" "https://video"
# «Что-то не работает»: all fine; YouTube down -> the tune button; no internet at all -> the provider
bot1() { : > "$K/curl.log"; SB_OPT=$K SB_BOT_ONCE=1 SB_TEST=1 SB_PLATFORM=keenetic SB_MEMINFO="$K/meminfo-ok" "$SH" "$K/etc/cron.1min/sb-bot" > /dev/null 2>&1; }
printf 'MemTotal: 100000 kB\nMemAvailable: 50000 kB\n' > "$K/meminfo-ok"
DIAG="${B}u0427${B}u0442${B}u043e-${B}u0442${B}u043e ${B}u043d${B}u0435 ${B}u0440${B}u0430${B}u0431${B}u043e${B}u0442${B}u0430${B}u0435${B}u0442"
botmsg "$DIAG"; bot1
check "diag: menu word"        has x "$K/var/sb-bot/log" "command /diag"
check "diag: all fine"         has x "$K/curl.log" "Со стороны роутера всё в порядке"
touch "$K/site-dead-www.youtube.com"; botmsg "/diag"; bot1
check "diag: YouTube down"     has x "$K/curl.log" "YouTube не открывается, хотя zapret работает"
check "diag: tune button"      has x "$K/curl.log" '"callback_data":"tune"'
rm -f "$K/site-dead-www.youtube.com"; touch "$K/net-down"; botmsg "/diag"; bot1
check "diag: no internet"      has x "$K/curl.log" "Интернета нет"
rm -f "$K/net-down"
# an address sent as it is: checked; not opening -> buttons to add it
botmsg "https:${B}/${B}/Example.COM${B}/page?x=1"; bot1
check "diag: link understood"  has x "$K/curl.log" "example.com открывается с роутера"
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
# servers sent as files: kept until «Проверить и добавить», then checked on their own, the files wiped
botdoc() { printf '{"ok":true,"result":[{"update_id":301,"message":{"chat":{"id":-100},"document":{"file_name":"%s","mime_type":"x","thumbnail":{"file_id":"THUMB","file_unique_id":"T1","width":90},"file_id":"F1","file_unique_id":"U1","file_size":300}}}]}\n' "$1" > "$K/updates"; }
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
sb_k update --progress
check "update exit 0"          equal x "$RC" 0
check "update event"           has x "$K/out" "@@sb	updated	old	"
check "watchdog rewritten"     hasnt x "$K/etc/cron.5mins/watchdog" "# old text"
check "sites kept"             equal x "$(cat "$K/sites.before")" "$(cat "$K/etc/switchback/sites")"
check "doctor shows version"   has x "$(sb_k doctor --progress; echo "$K/out")" "@@sb	installed	"
# tuning: the fast way goes first under circular; nothing better -> nothing changes; undo
printf 'NFQWS_ARGS="--filter-tcp=443\n            --lua-desync=multisplit:pos=1\n            --payload=http_req"\nNFQWS_EXTRA_ARGS="$MODE_LIST"\n' > "$K/etc/nfqws2/nfqws2.conf"
printf 'youtube.com\ngooglevideo.com\ndiscord.com\n' >> "$K/etc/nfqws2/lists/user.list"
echo "fakeddisorder:pos=midsld" > "$K/tune-best"
sb_k tune --progress
check "tune exit 0"            equal x "$RC" 0
check "all ways tried"         equal x "$(ev_count "$K/out" tune_try)" 8
check "fast way first"         has x "$K/etc/nfqws2/nfqws2.conf" "--lua-desync=circular:fails=2:time=300:retrans=3:nld=2 --lua-desync=fakeddisorder:pos=midsld:tcp_md5:strategy=1"
check "Google way always last" has x "$K/etc/nfqws2/nfqws2.conf" "--lua-desync=hostfakesplit:host=www.google.com:tcp_ts=-600000:strategy=4 --payload=http_req"
check "one NFQWS_ARGS line"    equal x "$(grep -c '^ ' "$K/etc/nfqws2/nfqws2.conf")" 0
check "other settings kept"    has x "$K/etc/nfqws2/nfqws2.conf" 'NFQWS_EXTRA_ARGS="$MODE_LIST"'
cp "$K/etc/nfqws2/nfqws2.conf" "$K/tuned"
sb_k tune
check "nothing better: kept"   equal x "$(cat "$K/tuned")" "$(cat "$K/etc/nfqws2/nfqws2.conf")"
sb_k tune --undo
check "undo: as before"        has x "$K/etc/nfqws2/nfqws2.conf" "--lua-desync=multisplit:pos=1"
# ways of their own for YouTube video servers: on, again, off; settings written by hand are left alone
sb_k tune video on --progress
check "video ways: on"          has x "$K/out" "@@sb	tune_video	on	done"
check "video ways: profile"     has x "$K/etc/nfqws2/nfqws2.conf" "--hostlist-domains=googlevideo.com --out-range=-d8 --payload=tls_client_hello --lua-desync=circular"
check "video ways: all five"    has x "$K/etc/nfqws2/nfqws2.conf" "tcp_seq=2:strategy=5"
check "video ways: no hostfake" hasnt x "$K/etc/nfqws2/nfqws2.conf" "hostfakesplit:host=www.google.com:tcp_ts=-600000:strategy="
check "video ways: main kept"   has x "$K/etc/nfqws2/nfqws2.conf" "--lua-desync=multisplit:pos=1"
sb_k tune video on --progress
check "video ways: not twice"   has x "$K/out" "@@sb	tune_video	on	exists"
sb_k tune video off --progress
check "video ways: off"         has x "$K/etc/nfqws2/nfqws2.conf" 'NFQWS_ARGS_CUSTOM=""'
sed -i 's|^NFQWS_ARGS_CUSTOM=.*|NFQWS_ARGS_CUSTOM="--filter-tcp=80 --lua-desync=fake"|' "$K/etc/nfqws2/nfqws2.conf"
sb_k tune video on --progress
check "video ways: hand-made stays" has x "$K/etc/nfqws2/nfqws2.conf" 'NFQWS_ARGS_CUSTOM="--filter-tcp=80 --lua-desync=fake"'
check "video ways: refused"     equal x "$RC" 1
sb_k tune video sideways
check "video ways: bad action"  equal x "$RC" 2
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

echo ""
echo "Тесты: прошло $PASS, не прошло $FAILED  (оболочка: $SH)"
[ "$FAILED" = 0 ] && rm -rf "$WORK" || echo "Файлы упавших проверок: $WORK"
[ "$FAILED" = 0 ]
