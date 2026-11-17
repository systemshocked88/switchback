# Install modules. Platform-independent: everything router-specific goes through pf_* functions.

# Save router settings only when this module actually changed something.
CLI_CHANGED=0
save_if_changed() {
  [ "$CLI_CHANGED" = 1 ] || return 0
  pf_save || fail "роутер не сохранил настройки"
  pf_reload; CLI_CHANGED=0
}

# ---------- backup before anything ----------
backup_start() {
  hr "Снимок настроек до установки"
  BACKUP_DIR=$SB_DIR/backups/$(date +%Y%m%d-%H%M%S)
  if [ "$DRY" = 1 ]; then dry "сохранить снимок в $BACKUP_DIR"; return 0; fi
  mkdir -p "$BACKUP_DIR" && chmod 700 "$SB_DIR/backups"
  pf_backup "$BACKUP_DIR" || fail "не удалось сохранить снимок настроек: без него не продолжаю"
  ok "снимок сохранён: $BACKUP_DIR"
  ev backup "$BACKUP_DIR"
  pf_restore_help "$BACKUP_DIR"
  ls -dt "$SB_DIR/backups"/*/ 2>/dev/null | tail -n +6 | xargs -r rm -rf   # keep 5 newest
}

# ---------- 1. package sources over https ----------
mod_https() {
  hr "Источники пакетов по https"
  pf_feeds_https; r=$?
  case $r in
    0) remember "https_feeds"; ok "источники переведены на https" ;;
    2) skip "уже https (или источники нестандартные)" ;;
    *) warn "по https обновить список пакетов не удалось, возвращаю как было"; pf_feeds_restore ;;
  esac
}

# ---------- 2. zapret ----------
ZAPRET_DOMAINS="instagram.com cdninstagram.com fbcdn.net facebook.com facebook.net fb.com fbsbx.com"

conf_set() {   # conf_set KEY VALUE in $NFQ_CONF
  if grep -qx "$1=$2" "$NFQ_CONF" 2>/dev/null; then skip "$1 уже $2"; return; fi
  if grep -q "^$1=" "$NFQ_CONF" 2>/dev/null; then run sed -i "s|^$1=.*|$1=$2|" "$NFQ_CONF"
  else append_line "$NFQ_CONF" "$1=$2"; fi
  ok "$1=$2"
}

mod_zapret() {
  hr "zapret: YouTube, Discord, Instagram"
  if pf_zapret_installed; then skip "zapret уже установлен"
  else
    pf_zapret_install || fail "не удалось установить zapret"
    remember "pkg nfqws2-keenetic"; ok "zapret установлен"
  fi
  if [ "$DRY" = 0 ] && [ ! -f "$NFQ_CONF" ]; then fail "после установки нет $NFQ_CONF"; fi
  pf_zapret_conf_backup; remember "nfqws_conf"
  conf_set NFQWS_EXTRA_ARGS '"$MODE_LIST"'
  conf_set UDP_PORTS '443,19294:19344,50000:50100'
  # YouTube video servers: ways of their own by "circular" (lib/tune.sh, "tune video"), unless something is there
  if [ -z "$(nfq_get NFQWS_ARGS_CUSTOM)" ] && ! grep -q '^NFQWS_ARGS_CUSTOM="[^"]*$' "$NFQ_CONF" 2>/dev/null; then
    if [ "$DRY" = 1 ]; then dry "отдельные способы zapret для серверов видео YouTube"
    else nfq_set_key "$NFQ_CONF" NFQWS_ARGS_CUSTOM "$(tune_video_args)"; ok "отдельные способы для серверов видео YouTube"; fi
  fi
  for d in $ZAPRET_DOMAINS; do
    grep -qx "$d" "$NFQ_LIST" 2>/dev/null && continue
    append_line "$NFQ_LIST" "$d"; remember "list $d"
  done
  ok "Instagram/Meta в списке сайтов"
  say ""
  say "  Если на каком-то компьютере уже работает свой обход (zapret для Windows, GoodbyeDPI),"
  say "  его надо исключить: два обхода на одном трафике ломают соединения."
  pf_exclude_hint
  if [ "$EXCLUDE_BY_POLICY" = 1 ]; then
    ask "  Имя политики для исключения (Enter, если никого исключать не надо):" "" zapret_exclude_policy
    if [ -n "$REPLY" ]; then conf_set POLICY_NAME "\"$REPLY\""; conf_set POLICY_EXCLUDE 1; fi
  fi
  pf_zapret_prepare      # platform: e.g. turn off hardware offloading that bypasses zapret
  pf_zapret_restart
  if [ "$DRY" = 1 ] || pf_zapret_running; then ok "zapret работает"; else fail "zapret не запустился после настройки"; fi
  own_install
  say ""
  say "  Приложение YouTube (телевизор, приставка, телефон) ходит за видео по QUIC (UDP 443). Провайдер такой"
  say "  запрос замечает и на время глушит сервер целиком — ролик не грузится. Без QUIC приложение сразу идёт"
  say "  обычным путём, с которым zapret справляется. Не включайте, если дома есть свой VPN через UDP 443."
  if yes_no "  Запретить устройствам дома QUIC?" y no_quic; then
    pf_noquic_on && ok "QUIC (UDP 443) из домашней сети запрещён"
  fi
}

# No QUIC for the devices at home. Seen on a real Keenetic (2026-11-15): the YouTube app on a TV asked the video
# servers over QUIC, zapret's QUIC desync no longer hid it, and the provider then dropped everything to that
# server for a long time, TCP included. With UDP 443 rejected the app goes over TCP at once.
# The rule is put on the interfaces zapret works on (the ones to the internet), so tunnels are not touched.
quic_script() {
sed -e "s|__PATH__|$SCRIPT_PATH|g" <<'EOF'
#!/bin/sh
# switchback: devices at home do not use QUIC (UDP 443) to the internet: the YouTube app then goes over TCP.
# Runs when the router rebuilds its firewall and from the installer; adds only what is missing.
[ -z "$table" ] || [ "$table" = filter ] || exit 0
[ -z "$type" ] || [ "$type" = iptables ] || exit 0
export PATH=__PATH__
IPT=${SB_IPT:-iptables}
for i in $($IPT -w -t mangle -S 2>/dev/null | grep NFQUEUE | sed -n 's/.* -o \([^ ]*\) .*/\1/p' | sort -u); do
  r="FORWARD -o $i -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable"
  $IPT -w -t filter -C $r 2>/dev/null || $IPT -w -t filter -I $r
done
exit 0
EOF
}
quic_hook_install() {   # the platform calls it when the rule is kept by a firewall hook (QUIC_HOOK)
  tmp=/tmp/switchback.quic.$$; quic_script > "$tmp"
  [ -f "$QUIC_HOOK" ] || remember "quicrule"
  install_file "$QUIC_HOOK" "запрет QUIC для устройств дома" "$tmp"
  if own_can_run && [ -x "$QUIC_HOOK" ]; then "$QUIC_HOOK" >/dev/null 2>&1; fi
  return 0
}
quic_off() {
  own_can_run || return 0
  ipt=${SB_IPT:-iptables}
  $ipt -w -t filter -S FORWARD 2>/dev/null | grep -- '^-A FORWARD -o [^ ]* -p udp .*--dport 443 -j REJECT' | sed 's/^-A /-D /' |
    while read -r l; do $ipt -w -t filter $l; done
  return 0
}

# The router's own connections go past zapret. Seen on a real Keenetic (KeeneticOS 3.8.7, 2026-11-11): every
# TCP connection the router itself opens (node checks, watchdog, bot: several a minute) that passed zapret's
# queue left a socket in the kernel for ever: ~25 MB a day, in 4 days the memory ran out and the kernel killed
# zapret. Such packets now get zapret's own "already handled" mark, so its rules skip them. A request that
# has to go through zapret (tune, site checks) takes a local port from SB_ZPORTS: curl $ZCURL.
# OWN_HOOK is set by the platform (empty: nothing to do there).
SB_ZPORTS=61000:61099
ZCURL="--local-port 61000-61099"
own_script() {
sed -e "s|__PATH__|$SCRIPT_PATH|g" -e "s|__PORTS__|$SB_ZPORTS|g" <<'EOF'
#!/bin/sh
# switchback: the router's own TCP connections go past zapret (in its queue they leak kernel memory).
# Runs when the router rebuilds its firewall, every 5 minutes and from the installer; adds only what is missing.
[ -z "$table" ] || [ "$table" = mangle ] || exit 0
[ -z "$type" ] || [ "$type" = iptables ] || exit 0
export PATH=__PATH__
IPT=${SB_IPT:-iptables}
rules=$($IPT -w -t mangle -S 2>/dev/null | grep NFQUEUE)
mark=$(echo "$rules" | sed -n 's/.* -m mark ! --mark \(0x[0-9a-f]*\)\/0x[0-9a-f]* .*/\1/p' | head -n 1)
[ -n "$mark" ] || exit 0          # zapret's rules are not there: nothing to go past
for i in $(echo "$rules" | sed -n 's/.* -o \([^ ]*\) .*/\1/p' | sort -u); do
  r="OUTPUT -o $i -p tcp ! --sport __PORTS__ -j MARK --or-mark $mark"
  $IPT -w -t mangle -C $r 2>/dev/null || $IPT -w -t mangle -I $r
done
exit 0
EOF
}
# in tests nothing may reach a real iptables: only a fake one named in SB_IPT is called
own_can_run() { [ "$DRY" != 1 ] && { [ -z "$SB_TEST" ] || [ -n "$SB_IPT" ]; }; }
own_install() {
  [ -n "$OWN_HOOK" ] || return 0
  tmp=/tmp/switchback.own.$$; own_script > "$tmp"
  [ -f "$OWN_HOOK" ] || remember "ownrule"
  install_file "$OWN_HOOK" "запросы самого роутера идут мимо zapret (иначе на Keenetic утекает память)" "$tmp"
  if own_can_run && [ -x "$OWN_HOOK" ]; then "$OWN_HOOK" >/dev/null 2>&1; fi
  return 0
}
own_off() {
  own_can_run || return 0
  ipt=${SB_IPT:-iptables}
  $ipt -w -t mangle -S OUTPUT 2>/dev/null | grep -- "--sport $SB_ZPORTS " | sed 's/^-A /-D /' |
    while read -r l; do $ipt -w -t mangle $l; done
  return 0
}

# ---------- 3. DNS per service ----------
DNS_CHATGPT="chatgpt.com openai.com oaistatic.com oaiusercontent.com"
DNS_CLAUDE="claude.ai claude.com claudeusercontent.com anthropic.com"

mod_dns() {
  hr "DNS по сервисам: ChatGPT, Claude"
  pf_dns_intro           # platform explains what server it needs (DoT on Keenetic, DoH on OpenWrt)
  say "  Он будет использоваться ТОЛЬКО для доменов этих сервисов, остальное идёт как раньше."
  used=$(pf_dns_count); swapped=0
  [ "$DNS_LIMIT" -lt 100 ] && say "  Занято доменных записей: $used из $DNS_LIMIT"
  for svc in ChatGPT Claude; do
    case $svc in ChatGPT) list=$DNS_CHATGPT ;; Claude) list=$DNS_CLAUDE ;; esac
    # without an answers file the question defaults to yes; with one, only services it names
    key=dns_$(echo "$svc" | tr 'A-Z' 'a-z')
    def=y; [ -n "$ANSWERS" ] && def=n
    yes_no "  Настроить $svc?" "$def" "$key" || continue
    # pf_dns_ask asks for the server and sets DNS_SRV: words that pf_dns_add/pf_dns_del
    # take before the domain (Keenetic: "IP SNI", OpenWrt: "127.0.0.1#PORT")
    pf_dns_ask "$svc" || continue
    for d in $list; do
      if pf_dns_has "$d"; then
        cur=""; [ "$DNS_REPLACE" = 1 ] && cur=$(pf_dns_srv_of "$d")
        if [ -z "$cur" ] || [ "$cur" = "$DNS_SRV" ]; then skip "$d уже настроен"; continue; fi
        # another DNS service is asked for this domain: replace. The old record goes first (the router has
        # a limit of records); "dns_was" is for the rollback of this run only, not for a later uninstall
        pf_dns_del $cur "$d" || fail "роутер не убрал прежнюю DNS-запись для $d"
        if [ "$DRY" != 1 ]; then
          echo "dns_was $cur $d" >> "$RUN_JOURNAL"
          grep -vxF "dns $cur $d" "$STATE" > "$STATE.tmp" 2>/dev/null; mv "$STATE.tmp" "$STATE"
        fi
        pf_dns_add $DNS_SRV "$d" || fail "роутер не принял DNS-запись для $d"
        remember "dns $DNS_SRV $d"; ok "$d: DNS-сервис заменён $ARROW $DNS_LABEL"; CLI_CHANGED=1; swapped=1
        continue
      fi
      if [ "$used" -ge "$DNS_LIMIT" ]; then warn "лимит $DNS_LIMIT записей: $d не добавлен"; continue; fi
      pf_dns_add $DNS_SRV "$d" || fail "роутер не принял DNS-запись для $d"
      remember "dns $DNS_SRV $d"; ok "$d $ARROW $DNS_LABEL"; used=$((used+1)); CLI_CHANGED=1
    done
  done
  save_if_changed
  if [ "$swapped" = 1 ]; then
    say "  Сервис закреплён за узлом прежнего DNS-сервиса, пока автосмена узлов не выберет новый."
    say "  Чтобы выбрать сразу — команды боту: /node best, /node api best (Claude), /node gpt best (ChatGPT)."
  fi
}

# ---------- 4. Telegram via VPN ----------
# Official IPv4 list: https://core.telegram.org/resources/cidr.txt
TG_NETS="91.108.56.0/255.255.252.0 91.108.4.0/255.255.252.0 91.108.8.0/255.255.252.0
91.108.16.0/255.255.252.0 91.108.12.0/255.255.252.0 149.154.160.0/255.255.240.0
91.105.192.0/255.255.254.0 91.108.20.0/255.255.252.0 185.76.151.0/255.255.255.0"

tg_via() {   # the connection any Telegram network is already routed through (by switchback or by hand)
  for n in $TG_NETS; do
    v=$(pf_route_via "${n%/*}" "${n#*/}")
    [ -n "$v" ] && { echo "$v"; return; }
  done
}

mod_vpn() {
  hr "Telegram через VPN (WireGuard)"
  ifs=$(pf_vpn_ifaces)
  if [ -z "$ifs" ]; then warn "VPN-подключений нет, модуль пропущен"; pf_vpn_hint; return; fi
  say "  Найдены: $(echo $ifs)"
  # suggest the connection Telegram already uses, else the first one that is up, else the first
  def=$(tg_via)
  echo "$ifs" | grep -qx "$def" || def=""
  if [ -z "$def" ]; then for w in $ifs; do pf_vpn_alive "$w" && { def=$w; break; }; done; fi
  [ -n "$def" ] || def=$(echo "$ifs" | head -1)
  ask "  Через какое подключение пускать Telegram?" "$def" vpn_iface; VPN_IF=$REPLY
  echo "$ifs" | grep -qx "$VPN_IF" || { warn "нет подключения $VPN_IF, модуль пропущен"; VPN_IF=""; return; }
  pf_vpn_is_global "$VPN_IF" && warn "$VPN_IF используется для выхода в интернет: через VPN пойдёт всё, снимите эту галочку"
  pf_vpn_alive "$VPN_IF" || warn "$VPN_IF сейчас не подключено (нет свежего рукопожатия с сервером): Telegram через него работать не будет"
  for n in $TG_NETS; do
    net=${n%/*}; mask=${n#*/}
    via=$(pf_route_via "$net" "$mask")
    if [ "$via" = "$VPN_IF" ]; then skip "$net уже через $VPN_IF"; continue; fi
    # a route made by hand through another connection: not ours to replace
    if [ -n "$via" ]; then skip "$net уже идёт через $via — не трогаю"; continue; fi
    pf_route_add "$net" "$mask" "$VPN_IF" || fail "роутер не принял маршрут $net"
    remember "route $net $mask $VPN_IF"; ok "$net $ARROW $VPN_IF"; CLI_CHANGED=1
  done
  save_if_changed
  # with a tunnel at hand, YouTube video servers the provider cuts off go through it by themselves
  sites_files
  if [ -n "$(sites_tunnel)" ]; then video_on; fi
  return 0
}

# install_file DEST "what" SRC: put SRC at DEST (executable). A file that is already there and
# differs is never overwritten silently: ask, keep the original as DEST.before-switchback.
# SRC is a file, not stdin: the question below must read the keyboard, not a pipe.
install_file() {   # install_file DEST "what" SRC [answer-key]
  new=$3
  if [ -f "$1" ] && cmp -s "$new" "$1"; then skip "$2: уже установлен"; rm -f "$new"; return 0; fi
  if [ -f "$1" ]; then
    say "  Файл $1 уже есть и отличается от версии switchback (возможно, вы ставили его сами)."
    if ! yes_no "  Заменить? Оригинал сохраню как $1.before-switchback" n "$4"; then
      skip "$2: оставляю ваш файл"; rm -f "$new"; return 0
    fi
    # the copy must not run: run-parts (Keenetic) and the cron1 loop (OpenWrt) start every executable file there
    run cp "$1" "$1.before-switchback" && run chmod -x "$1.before-switchback" && remember "replaced $1"
  else
    remember "file $1"
  fi
  write_file "$1" < "$new" && run chmod +x "$1"
  rm -f "$new"
  ok "$2"
}

# ---------- 5. watchdog + weekly backup ----------
mod_watchdog() {
  hr "Сторож в Telegram и еженедельный бэкап"
  pf_cron_setup || fail "не удалось поставить curl/cron"
  ntfy_want                  # sets NTFY_URL: the reserve channel (or "")
  if [ -s "$BOT" ] && grep -q '^CHAT=[0-9-]' "$BOT"; then skip "бот уже настроен"
  elif [ -n "$ANSWERS" ] && ! ans_has bot_token && { [ -n "$NTFY_URL" ] || grep -q '^NTFY=.' "$BOT" 2>/dev/null; }; then
    skip "бота нет: уведомления только через ntfy (команды /status и другие — только у бота)"
  elif [ -n "$ANSWERS" ] && ! ans_has bot_token; then
    warn "в ответах нет ни токена бота (bot_token), ни ntfy (ntfy_url): сторож и бэкап пропущены"; return 0
  elif [ "$DRY" = 1 ]; then dry "запросить токен бота и номер чата, записать $BOT"
  else
    if ans_has bot_token; then T=$(ans bot_token)
    else
      say "  Создайте бота: Telegram -> @BotFather -> /newbot. Откройте его, нажмите Start и напишите"
      say "  ему что-нибудь. Вставьте токен ниже: на экране он виден не будет."
      printf '  TOKEN: '; stty -echo 2>/dev/null; read -r T; stty echo 2>/dev/null; echo
    fi
    [ ${#T} -ge 40 ] || fail "токен слишком короткий (${#T} символов): скопируйте только токен"
    if ans_has bot_chat; then C=$(ans bot_chat)
    else C=$(curl -s "https://api.telegram.org/bot$T/getUpdates" | grep -o '"chat":{"id":[0-9-]*' | head -1 | grep -o '[0-9-]*$'); fi
    case $C in ''|*[!0-9-]*) C="" ;; esac
    [ -n "$C" ] || fail "бот не видит ваших сообщений: нажмите Start, напишите ему и запустите снова"
    keep=$(grep '^NTFY=' "$BOT" 2>/dev/null)
    mkdir -p "${BOT%/*}"; printf 'TOKEN=%s\nCHAT=%s\n' "$T" "$C" > "$BOT"; chmod 600 "$BOT"; unset T
    [ -n "$keep" ] && echo "$keep" >> "$BOT"
    remember "bot_conf"; ok "бот настроен"
  fi
  ntfy_save
  checks=$(watchdog_checks)
  tmp=/tmp/switchback.new.$$
  watchdog_script "$checks" > "$tmp"
  install_file "$CRON5/watchdog" "сторож (каждые 5 минут)" "$tmp" replace_watchdog
  [ "$DRY" = 1 ] && printf '%s\n' "$checks" | sed 's/^/        /'
  pf_backup_job > "$tmp"
  install_file "$CRONW/backup" "еженедельный бэкап (хранит 8)" "$tmp" replace_backup
  bot_install
  load_install
  digest_install
  heal_install
  if [ "$DRY" = 0 ]; then
    TOKEN=""; CHAT=""; NTFY=""; . "$BOT"
    [ -n "$TOKEN" ] && curl -s -o /dev/null --max-time 20 "https://api.telegram.org/bot$TOKEN/sendMessage" \
      -d chat_id="$CHAT" --data-urlencode text="[роутер] Сторож включён: напишу, если что-то сломается. Команды — кнопками меню внизу чата (если их нет, напишите «помощь»)." && ok "тестовое сообщение отправлено"
    [ -n "$NTFY" ] && curl -s -o /dev/null --max-time 20 -H "Title: router" -d "switchback: запасной канал уведомлений работает" "$NTFY" &&
      ok "проверочное уведомление в ntfy отправлено"
    TOKEN=""
  fi
}

# ---------- reserve channel: ntfy (push notifications, app "ntfy" on the phone) ----------
# Telegram goes through the VPN here: when the tunnel is down, a "DOWN" cannot reach Telegram. ntfy.sh goes
# directly, so the scripts send there when Telegram does not answer. The channel is a long random name:
# whoever knows it can read the alerts (short texts like "DOWN: zapret", no passwords or addresses).
ntfy_valid() { case $1 in https://*/*) t=${1##*/}; [ ${#t} -ge 12 ] && case $t in *[!A-Za-z0-9_-]*) false ;; esac ;; *) false ;; esac; }
ntfy_new() { echo "https://ntfy.sh/sb-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
ntfy_want() {
  NTFY_URL=""
  if grep -q '^NTFY=.' "$BOT" 2>/dev/null; then return 0; fi    # already there: kept as it is
  if ans_has ntfy_url; then NTFY_URL=$(ans ntfy_url)
  elif [ -n "$ANSWERS" ]; then return 0                           # the program did not ask for it
  else
    say "  Запасной канал уведомлений — ntfy: если Telegram не отвечает (например, упал VPN), сообщение придёт"
    say "  push-уведомлением в приложение ntfy на телефоне. Enter — создать канал, n — не нужен."
    ask "  Канал ntfy:" "$(ntfy_new)" ntfy_url; NTFY_URL=$REPLY
  fi
  case $NTFY_URL in ''|n|no|N|нет) NTFY_URL=""; return 0 ;; esac
  ntfy_valid "$NTFY_URL" || { warn "адрес ntfy должен быть вида https://ntfy.sh/длинное-имя-канала: запасной канал пропущен"; NTFY_URL=""; }
}
ntfy_save() {
  if grep -q '^NTFY=.' "$BOT" 2>/dev/null; then skip "запасной канал ntfy уже настроен"; return 0; fi
  [ -n "$NTFY_URL" ] || return 0
  if [ "$DRY" = 1 ]; then dry "записать канал ntfy в $BOT"; return 0; fi
  if [ -f "$BOT" ]; then
    # a bot.conf switchback did not write (bot_conf in the journal removes the whole file): only our line goes on undo
    grep -qx bot_conf "$STATE" 2>/dev/null || remember "conf_line $BOT NTFY"
  else
    mkdir -p "${BOT%/*}"; : > "$BOT"; remember "bot_conf"
  fi
  echo "NTFY=$NTFY_URL" >> "$BOT"; chmod 600 "$BOT"
  ok "запасной канал ntfy: подпишитесь в приложении ntfy на канал ${NTFY_URL##*/}"
  ev ntfy "$NTFY_URL"
}

# ---------- the router's load, every 5 minutes (a modest router: worth watching) ----------
# One line per 5 minutes in $VAR_DIR/switchback-load.log: CPU busy % over those 5 minutes (from /proc/stat),
# load average, free memory (MemAvailable). A week is kept (2016 lines). Status sums up the last day.
load_job() {
script_subst <<'EOF'
#!/bin/sh
# Router load (switchback): every 5th minute, CPU busy % since the last run and free memory. A week kept.
export PATH=__PATH__
m=$(date +%M); m=${m#0}
[ $((m % 5)) = 0 ] || exit 0
[ -x "__OWN__" ] && "__OWN__"          # keeps the "own connections past zapret" rule in place (see own_script)
L=__STATE__/switchback-load.log
P=__STATE__/switchback-load.prev
set -- $(head -1 /proc/stat)            # cpu user nice system idle iowait irq softirq ...
total=0; for v in $2 $3 $4 $5 $6 $7 $8; do total=$((total + v)); done
idle=$(($5 + ${6:-0}))                 # some kernels show fewer fields
cpu=""
if [ -f "$P" ]; then
  read -r pt pi < "$P"
  dt=$((total - pt)); di=$((idle - pi))
  [ "$dt" -gt 0 ] && cpu=$(( (dt - di) * 100 / dt ))
fi
echo "$total $idle" > "$P"
[ -n "$cpu" ] || exit 0
free=$(awk '/^MemAvailable:/ {a=$2} /^MemFree:/ {f=$2} END {if (!a) a=f; printf "%d", a/1024}' /proc/meminfo)
echo "$(date '+%F %H:%M') cpu=$cpu load=$(cut -d' ' -f1 /proc/loadavg) free=$free" >> "$L"
[ "$(wc -l < "$L")" -gt 2100 ] && tail -n 2016 "$L" > "$L.tmp" && mv "$L.tmp" "$L"
exit 0
EOF
}
load_install() {
  [ -n "$CRON1" ] || return 0
  [ -f "$CRON1/sb-load" ] && return 0
  t=/tmp/switchback.load.$$; load_job > "$t"
  install_file "$CRON1/sb-load" "запись нагрузки роутера (каждые 5 минут, неделя)" "$t"
}
# the last day of the load log: "AVG MAX MINFREE COUNT" (CPU %, CPU %, MB, records)
load_day() {
  tail -n 288 "$VAR_DIR/switchback-load.log" 2>/dev/null | awk '{
    for (i = 3; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
    n++; s += v["cpu"]; if (v["cpu"] > mx) mx = v["cpu"]; if (mf == "" || v["free"] < mf) mf = v["free"] }
    END { if (n) printf "%d %d %d %d", s / n, mx, mf, n }'
}

# the send function of the installed scripts: Telegram first, ntfy when Telegram does not answer
notify_func() {
cat <<'EOF'
sb_send() {
  [ -n "$TOKEN" ] && curl -s -o /dev/null --max-time 20 -w '%{http_code}' "https://api.telegram.org/bot$TOKEN/sendMessage" \
    -d chat_id="$CHAT" --data-urlencode text="[роутер] $1" | grep -q 200 && return 0
  [ -n "$NTFY" ] && curl -s -o /dev/null --max-time 20 -w '%{http_code}' -H "Title: router" -d "$1" "$NTFY" | grep -q 200 && return 0
  return 1
}
EOF
}

# what the watchdog checks: only what is set up on this router
watchdog_checks() {
  echo "check zapret      zapret_up"
  echo "check free-memory mem_ok"
  { [ -n "$VPN_IF" ] || [ -n "$(tg_via)" ]; } && echo "check telegram-vpn web https://api.telegram.org"
  pf_dns_has claude.ai && printf '%s\n' "check claude-site web https://claude.ai" "check claude-app  web https://api.anthropic.com"
  pf_dns_has chatgpt.com && echo "check chatgpt     web https://chatgpt.com"
  meta_on && echo "check instagram   web https://www.instagram.com"
  return 0
}

watchdog_script() {
sed -e "s|__BOT__|$BOT|g" -e "s|__NFQINIT__|$NFQ_INIT|g" -e "s|__PATH__|$SCRIPT_PATH|g" <<'EOF'
#!/bin/sh
# Router watchdog (switchback): every 5 min, Telegram alert only on change.
export PATH=__PATH__
. __BOT__
S=/tmp/switchback-watchdog
[ -d /opt/var ] && S=/opt/var/watchdog
[ -n "$SB_WD_STATE" ] && S=$SB_WD_STATE
mkdir -p "$S"
now=$(date +%s)
EOF
notify_func
sed -e "s|__BOT__|$BOT|g" -e "s|__NFQINIT__|$NFQ_INIT|g" -e "s|__PATH__|$SCRIPT_PATH|g" -e "s|__STATE__|$VAR_DIR|g" <<'EOF'
send() { sb_send "$1"; }
# the check's name in a message, and what to do about it
title() {
  case $1 in
    zapret) echo "обход блокировок (zapret)" ;; free-memory) echo "свободная память роутера" ;;
    telegram-vpn) echo "Telegram через VPN" ;; claude-site) echo "сайт Claude" ;; claude-app) echo "приложение Claude" ;;
    chatgpt) echo "ChatGPT" ;; instagram) echo "Instagram" ;; *) echo "$1" ;;
  esac
}
hint() {
  case $1 in
    zapret) echo "Запустить его снова не получилось: YouTube и другие сайты могут не открываться. Перезагрузите роутер; не поможет — нажмите в боте «Отчёт»." ;;
    free-memory) echo "Если памяти не хватит, zapret упадёт. Обычно проходит само; не пройдёт за час — перезагрузите роутер." ;;
    telegram-vpn) echo "Туннель VPN не отвечает. Автосмена сама попробует запасной; если сообщения о переключении не будет — нужен новый конфиг WireGuard." ;;
    instagram) echo "Instagram идёт через VPN — скорее всего, дело в туннеле. Обычно проходит само." ;;
    *) echo "Часто это сбой самого сервиса или его DNS — обычно проходит само. Не прошло за час — нажмите в боте «Что-то не работает»." ;;
  esac
}
web() {
  for i in 1 2; do
    c=$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' "$1")
    [ "$c" != "000" ] && return 0
    sleep 5
  done
  return 1
}
zapret() { pidof nfqws2 >/dev/null || pidof nfqws >/dev/null; }
# zapret that is not running is started again (seen on a real router: the kernel killed it when the memory
# ran out, and it stayed down for hours); "DOWN: zapret" comes only if that did not help
zapret_up() {
  zapret && return 0
  [ -x __NFQINIT__ ] || return 1
  __NFQINIT__ start >/dev/null 2>&1; sleep 3
  zapret && send "Починилось само: zapret (обход блокировок) не работал — запустил его заново. Делать ничего не нужно."
  zapret
}
# less than 12% of the memory left: zapret and the other services are the next to be killed
mem_ok() {
  [ -r "${SB_MEMINFO:-/proc/meminfo}" ] || return 0
  awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} /^MemFree:/ {f=$2}
       END {if (!a) a=f; exit !(t == 0 || a * 100 / t >= 12)}' "${SB_MEMINFO:-/proc/meminfo}"
}
# A site that does not answer in one run only is not worth two messages (seen on a real router: ChatGPT
# "blinked" for 5 minutes two or three times a day): "DOWN" is sent when the next run fails too, and a blip
# that was never reported comes back silently. It is still written to the events log (the weekly digest
# counts it). zapret and the memory are reported at once.
check() {
  n=$1; shift
  if "$@"; then st=ok; else st=down; fi
  old=$(cat "$S/$n" 2>/dev/null || echo ok)
  if [ "$st" = down ]; then
    if [ ! -f "$S/$n.down" ]; then
      echo "$now" > "$S/$n.down"; echo "$(date '+%F %H:%M') DOWN $n" >> __STATE__/watchdog-events.log
      case $n in zapret|free-memory) ;; *) : > "$S/$n.first"; return 0 ;; esac
    fi
    rm -f "$S/$n.first"
    if [ "$old" != down ]; then send "✗ Не работает: $(title "$n"). $(hint "$n")" && echo down > "$S/$n"; fi
  elif [ -f "$S/$n.down" ]; then
    m=$(( (now - $(cat "$S/$n.down")) / 60 ))
    if [ -f "$S/$n.first" ]; then      # a blip: nothing was sent, nothing to take back
      rm -f "$S/$n.down" "$S/$n.first"; echo "$(date '+%F %H:%M') BACK $n $m" >> __STATE__/watchdog-events.log
      return 0
    fi
    if [ "$old" = down ]; then msg="✓ Снова работает: $(title "$n") (не работало ~$m мин). Делать ничего не нужно."
    else msg="Было: $(title "$n") не работало ~$m мин (сообщить сразу не получилось — не было связи). Сейчас работает."; fi
    send "$msg" && { echo ok > "$S/$n"; rm -f "$S/$n.down"; echo "$(date '+%F %H:%M') BACK $n $m" >> __STATE__/watchdog-events.log; }
  fi
}
# /dev/null must be the system device. Seen on a real router: a script turned it into a plain file; from
# then on zapret (and other services) could not start again. Put it back, restart zapret if it is down.
devnull() {
  DN=${SB_DEVNULL:-/dev/null}
  [ -c "$DN" ] && return 0
  if rm -f "$DN" && mknod -m 666 "$DN" c 1 3; then
    zapret || { [ -x __NFQINIT__ ] && __NFQINIT__ restart >/dev/null 2>&1; }
    send "Починилось само: сломался системный файл /dev/null (из-за него службы не могли перезапуститься) — восстановил$(zapret && echo ', zapret работает.' || echo '. zapret всё ещё не работает — перезагрузите роутер.')"
  else
    send "Сломан системный файл /dev/null, починить сам не смог: службы не смогут перезапуститься. Перезагрузите роутер."
  fi
}
devnull
EOF
printf '%s\n' "$1"
}

# ---------- after install ----------
verify() {
  hr "Проверка после установки"
  [ "$DRY" = 1 ] && { say "  (в пробном режиме не проверяется)"; return; }
  case " $MODULES " in *" zapret "*) if pf_zapret_running; then ok "zapret работает"; else bad "zapret не работает"; fi ;; esac
  case " $MODULES " in *" vpn "*)
    if [ -n "$VPN_IF" ]; then
      c=$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' https://api.telegram.org 2>/dev/null)
      [ "$c" != "000" ] && ok "Telegram отвечает (через $VPN_IF)" || bad "Telegram не отвечает: проверьте, что $VPN_IF подключён"
    fi ;;
  esac
  case " $MODULES " in *" dns "*)
    for d in claude.ai chatgpt.com; do pf_dns_has "$d" || continue
      c=$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' "https://$d" 2>/dev/null)
      [ "$c" != "000" ] && ok "$d отвечает" || bad "$d не отвечает: проверьте адрес DNS-сервера"
    done ;;
  esac
  case " $MODULES " in *" watchdog "*) [ -x "$CRON5/watchdog" ] && ok "сторож на месте" ;; esac
}
