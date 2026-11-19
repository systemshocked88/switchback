# Shared helpers: output, logging, dry-run, change journal, rollback. Sourced by install.sh.
# Plain POSIX sh: must run in BusyBox ash (routers) and dash (tests).

# ---------- output ----------
say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
skip() { printf '  [--] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*"; WARNINGS=$((WARNINGS+1)); }
bad()  { printf '  [XX] %s\n' "$*"; PROBLEMS=$((PROBLEMS+1)); }
hr()   { printf '\n=== %s ===\n' "$*"; }
mod_skip() { skip "$@"; MOD_SKIP=1; }
# zapret_wait: after a (re)start nfqws2 can take a few seconds to appear (a slow router CPU, the first start of
# a fresh package): ask once a second, up to SB_ZAPRET_WAIT seconds (10; tests: short), before calling it dead
zapret_wait() {
  zw=${SB_ZAPRET_WAIT:-10}; [ -z "$SB_ZAPRET_WAIT" ] && [ -n "$SB_TEST" ] && zw=1
  zi=0
  until pf_zapret_running; do
    [ "$zi" -ge "$zw" ] && return 1
    sleep 1; zi=$((zi+1))
  done
  return 0
}   # a whole module skipped: the summary says so, not "already set up"
WARNINGS=0; PROBLEMS=0

log() { [ "$DRY" = 1 ] && return 0; mkdir -p "${LOG%/*}" 2>/dev/null; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# ---------- machine-readable progress (--progress) ----------
# One line per event: "@@sb<TAB>event<TAB>field...". The Windows program reads these;
# the human text is printed as usual around them. Format: docs/answers.md.
ev() {
  [ "$PROGRESS" = 1 ] || return 0
  _ev="@@sb"; for _a; do _ev="$_ev	$_a"; done
  printf '%s\n' "$_ev"
}

# rand_hex BYTES: that many random bytes as hex digits. KeeneticOS's busybox od has no -A/-t (19.11.2026), OpenWrt's
# busybox may have no od at all: hexdump first, then a full od, then tr
rand_hex() {
  r=$(head -c "$1" /dev/urandom 2>/dev/null | hexdump -v -e '/1 "%02x"' 2>/dev/null)
  [ ${#r} -ge $(($1 * 2)) ] || r=$(head -c "$1" /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
  [ ${#r} -ge $(($1 * 2)) ] || r=$(tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c $(($1 * 2)))
  echo "$r"
}

# ---------- answers file (--answers FILE, or - for stdin) ----------
# KEY=VALUE lines, # comments. Every question has a key; a question whose key is not in the
# file gets its default answer, nothing is read from the keyboard. Format: docs/answers.md.
ANSWER_KEYS="continue_with_warnings continue_with_problems profile modules start
zapret_exclude_policy disable_offload no_quic
dns_chatgpt dns_chatgpt_ip dns_chatgpt_sni dns_chatgpt_doh
dns_claude dns_claude_ip dns_claude_sni dns_claude_doh ai_reserve
vpn_iface meta_vpn replace_watchdog replace_backup replace_bot bot_token bot_chat ntfy_url failover_tunnels replace_failover replace_nodes
uninstall_confirm uninstall_packages uninstall_feeds"
ANS_KEYS=""
ans_has() { case " $ANS_KEYS " in *" $1 "*) return 0 ;; esac; return 1; }
ans()     { eval "printf '%s' \"\$ANS_$1\""; }

load_answers() {   # load_answers FILE|-   (values are never printed: the file may hold the bot token)
  # "-" reads standard input directly: KeeneticOS has no /dev/stdin to redirect from
  if [ "$1" = - ]; then parse_answers
  else [ -r "$1" ] || { say "Не найден файл ответов: $1"; exit 2; }; parse_answers < "$1"; fi
  ASSUME_YES=1      # unanswered questions take their default: nobody is at the keyboard
}
parse_answers() {   # KEY=VALUE lines on standard input
  cr=$(printf '\r'); n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1)); line=${line%"$cr"}
    case $line in ''|'#'*) continue ;; esac
    case $line in *=*) ;; *) say "Файл ответов, строка $n: нужно КЛЮЧ=ЗНАЧЕНИЕ"; exit 2 ;; esac
    key=${line%%=*}; val=${line#*=}
    key=$(printf '%s' "$key" | tr -d ' \t')
    case $key in ''|*[!a-z0-9_]*) say "Файл ответов, строка $n: странный ключ"; exit 2 ;; esac
    case " $(echo $ANSWER_KEYS) " in *" $key "*) ;; *) say "Файл ответов, строка $n: неизвестный ключ $key"; exit 2 ;; esac
    case $val in \"*\") val=${val#\"}; val=${val%\"} ;; esac
    eval "ANS_$key=\$val"
    ans_has "$key" || ANS_KEYS="$ANS_KEYS $key"
  done
}

# ---------- questions ----------
ask() {    # ask "question" default [answer-key] -> $REPLY
  printf '%s%s%s ' "$CB" "$1" "$C0"; [ -n "$2" ] && printf '%s[%s]%s ' "$CC" "$2" "$C0"
  if [ -n "$3" ] && ans_has "$3"; then REPLY=$(ans "$3"); printf '%s\n' "$REPLY"; return; fi
  if [ "$ASSUME_YES" = 1 ]; then REPLY=$2; printf '%s\n' "$REPLY"; return; fi
  read -r REPLY || REPLY=""; [ -z "$REPLY" ] && REPLY=$2
}
yes_no() { # yes_no "question" y|n [answer-key] -> 0 for yes
  ask "$1 (y/n)" "$2" "$3"
  case $REPLY in y|Y|yes|д|Д|да) return 0 ;; *) return 1 ;; esac
}

# ---------- doing things ----------
run() {    # run CMD... : execute, or only print in dry-run
  if [ "$DRY" = 1 ]; then dry "$*"; return 0; fi
  log "run: $*"
  "$@"
}
write_file() {   # write_file PATH  (content on stdin)
  if [ "$DRY" = 1 ]; then dry "записать $1"; cat >/dev/null; return 0; fi
  mkdir -p "${1%/*}" && cat > "$1" && log "write: $1"
}
append_line() {  # append_line FILE LINE
  if [ "$DRY" = 1 ]; then dry "добавить в $1: $2"; return 0; fi
  printf '%s\n' "$2" >> "$1" && log "append to $1: $2"
}

# ---------- change journal ----------
# Every change is one line in $STATE (all runs, used by uninstall) and in $RUN_JOURNAL
# (this run only, used by automatic rollback). Formats:
#   https_feeds | nfqws_conf | list DOMAIN | dns SERVER... DOMAIN | route NET MASK IFACE
#   uci KEY OLD_VALUE|- (OpenWrt setting changed) | crontab (OpenWrt: our lines in /etc/crontabs/root)
#   file PATH | replaced PATH (original kept as PATH.before-switchback) | bot_conf | pkg NAME
#   pkgdeps NAME... (OpenWrt: packages an install of ours brought in) | pkgfile PATH (OpenWrt: package source/key we added)
#   cronfile (OpenWrt: /etc/crontabs/root did not exist before us: removed if empty after our lines are gone)
#   keep PATH (OpenWrt: our line in /etc/sysupgrade.conf, kept across firmware upgrades)
#   uci_list KEY VALUE (OpenWrt: a value added to a list) | wg NAME (WireGuard connection made from a .conf)
#   quic IP ACL | acl_bind IFACE ACL (Keenetic QUIC rules) | host DOMAIN OLD_IP|- (domain pinned to a node)
#   site WAY DOMAIN (own site: zapret|dns|vpn) | appdir PATH (switchback's own copy on the router)
#   ns SERVER DOMAIN (plain DNS server for a domain: Meta via VPN) | conf_line FILE KEY (our KEY= line in a file that is not ours)
#   ai (the AI reserve: its job, settings, the names it pinned and its routes; lib/ai.sh)
remember() {
  [ "$DRY" = 1 ] && return 0
  mkdir -p "$SB_DIR"
  # already recorded by an earlier run: not ours to roll back this time
  grep -qxF "$*" "$STATE" 2>/dev/null && return 0
  printf '%s\n' "$*" >> "$STATE"
  printf '%s\n' "$*" >> "$RUN_JOURNAL"
}

# undo_entry LINE: reverse one journal line (uses the platform adapter). Shared by rollback and uninstall.
undo_entry() {
  set -f          # a saved value may be "*": split into words, but never expand it into file names
  set -- $1
  set +f
  kind=$1; shift
  case $kind in
    route)       # the failover may have moved it to another tunnel since: remove it wherever it is now
                 via=$(pf_route_via "$1" "$2"); [ -n "$via" ] || via=$3
                 pf_route_del "$1" "$2" "$via" && ok "маршрут $1 убран" ;;
    dns_was)     pf_dns_add "$@" && ok "прежний DNS для $3 возвращён" ;;
    dns)         eval "last=\${$#}"; pf_dns_del "$@" && ok "DNS для $last убран" ;;
    uci)         pf_uci_restore "$@" && ok "настройка $1 восстановлена" ;;
    crontab)     pf_crontab_remove && ok "задания switchback убраны из расписания" ;;
    list)        pf_list_del "$1" && ok "$1 убран из списка zapret" ;;
    nfqws_conf)  pf_zapret_conf_restore && ok "настройки zapret восстановлены" ;;
    file)        run rm -f "$1" && ok "удалён $1" ;;
    ownrule)     own_off && ok "запросы роутера снова идут через zapret" ;;
    quicrule)    quic_off && ok "QUIC из домашней сети снова разрешён" ;;
    tvvpn)       tv_undo "$1" && ok "устройство больше не ходит к Google через VPN" ;;
    replaced)    [ -f "$1.before-switchback" ] && run mv "$1.before-switchback" "$1" && run chmod +x "$1" && ok "возвращён ваш $1" ;;
    bot_conf)    run rm -f "$BOT" && ok "настройки бота удалены" ;;
    https_feeds) pf_feeds_restore && ok "источники пакетов восстановлены" ;;
    pkg)         pf_pkg_remove "$1" && ok "пакет $1 удалён" ;;
    pkgdeps)     pf_pkgs_remove "$@" && ok "пакеты, которые ставил switchback, удалены: $*" ;;
    pkgfile)     run rm -f "$1" && ok "источник пакетов убран: $1" ;;
    cronfile)    [ -s "$CRONTAB" ] || { run rm -f "$CRONTAB" && ok "пустое расписание $CRONTAB удалено"; } ;;
    keep)        pf_keep_del "$1" && ok "$1 больше не сохраняется при обновлении прошивки" ;;
    uci_list)    pf_uci_list_del "$1" "$2" && ok "$2 убран из $1" ;;
    wg)          pf_wg_delete "$1" && ok "подключение WireGuard $1 удалено" ;;
    quic)        pf_quic_unblock "$1" "$2" && ok "правило QUIC для $1 убрано" ;;
    acl_bind)    pf_acl_unbind "$1" "$2" && ok "список правил $2 отвязан от $1" ;;
    host)        pf_host_restore "$1" "$2" && ok "закрепление $1 убрано" ;;
    ai)          ai_undo ;;
    site)        site_undo "$1" "$2" && ok "свой сайт $2 убран" ;;
    ns)          pf_ns_del "$1" "$2" && ok "DNS-сервер $1 для $2 убран" ;;
    conf_line)   run sed -i "/^$2=/d" "$1" && ok "строка $2 убрана из $1" ;;
    panel)       panel_stop "$1" && ok "панель на роутере выключена" ;;
    appdir)      run rm -rf "$1" && ok "копия switchback на роутере удалена" ;;
    *)           warn "не знаю, как отменить: $kind $*" ;;
  esac
}

# Automatic rollback of THIS run (on error or Ctrl+C). Newest change first.
ROLLING_BACK=0
rollback() {
  [ "$DRY" = 1 ] && return 0
  [ "$ROLLING_BACK" = 1 ] && return 0; ROLLING_BACK=1
  [ -s "$RUN_JOURNAL" ] || { say "Изменений в этом запуске не было, откатывать нечего."; return 0; }
  hr "Откат изменений этого запуска"
  sed '1!G;h;$!d' "$RUN_JOURNAL" | while read -r line; do
    case $line in
      pkg\ *) skip "пакет ${line#pkg } оставляю установленным" ; continue ;;
      pkgdeps\ *|pkgfile\ *) continue ;;   # they belong to the packages that stay installed
    esac
    undo_entry "$line"
    grep -vxF "$line" "$STATE" > "$STATE.tmp" 2>/dev/null; mv "$STATE.tmp" "$STATE"
  done
  pf_save >/dev/null 2>&1
  grep -q '^nfqws_conf' "$RUN_JOURNAL" && pf_zapret_installed && pf_zapret_restart
  say "Откат завершён. Полный снимок до установки: $BACKUP_DIR"
}

fail() {   # fail "message": stop, roll back this run, explain how to recover
  printf '\n[ОШИБКА] %s\n' "$*"
  ev fail "$*"
  log "FAIL: $*"
  rollback
  say ""
  say "Что делать дальше: docs/recovery.md (раздел для вашей прошивки)."
  [ -n "$BACKUP_DIR" ] && say "Снимок настроек до установки: $BACKUP_DIR"
  exit 1
}
on_interrupt() { printf '\n'; fail "установка прервана (Ctrl+C)"; }

# ---------- secrets ----------
# sanitize: strip things that must never leave the router (for logs and reports). Plain -E patterns,
# no "I" flag: BusyBox sed on routers may not have it. Covers "word VALUE" (Keenetic CLI) and
# "word=VALUE" / "word='VALUE'" (uci, config files).
sanitize() {
  sed -E \
    -e 's/(password|passwd|authentication|secret|wpa-psk|psk )( |=).*$/\1\2<скрыто>/' \
    -e "s/(password|passwd|psk|PSK|key|Key|KEY|token|TOKEN|secret|authentication)([A-Za-z_-]*)( +|=|: +)'?[^ '<]+'?/\1\2\3<скрыто>/g" \
    -e 's/bot[0-9]+:[A-Za-z0-9_-]+/bot<скрыто>/g' \
    -e 's#(NTFY=|ntfy\.sh/)[^ ]+#\1<скрыто>#g' \
    -e 's#[A-Za-z0-9+/]{42,43}=#<ключ>#g' \
    -e 's/\$[0-9a-z]+\$[^ ]+/<хэш>/g' \
    -e 's/([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/<mac>/g' \
    -e 's/(wireguard peer|endpoint|endpoint_host) +[^ ]+/\1 <скрыто>/g' \
    -e "s/(endpoint_host)='[^']*'/\1=<скрыто>/g"
}
# report_leaks FILE: still something that looks like a secret? (the report is not given out then)
report_leaks() {
  # a key/hash/token shape, or a secret word followed by anything but the mask (also after the mask)
  grep -nE "bot[0-9]{5,}:[A-Za-z0-9_-]{20,}|[A-Za-z0-9+/]{42,43}=|\\\$[0-9a-z]+\\\$[^ ]{8,}|(password|passwd|authentication|private[-_]key|preshared[-_]key|psk)( +|=)'?[^<' ]|(password|passwd|authentication|psk)[^ ]*( +|=)<скрыто> *[^ ]" "$1"
}

# ---------- lists ----------
# The addresses, domains and zapret ways switchback applies live in lists/ next to install.sh (one entry per
# line, "#" starts a comment, blank lines are skipped), so they can be changed without touching the code.
# There is no copy inside the code: a missing or empty file stops install.sh before it changes anything (an
# empty list would quietly mean "no Telegram routes", "no ways to try").
LISTS="telegram.nets:TG_NETS:w meta.nets:META_NETS:w meta.domains:META_DOMAINS:w google.nets:TV_NETS:w
zapret.domains:ZAPRET_DOMAINS:w claude.domains:DNS_CLAUDE:w chatgpt.domains:DNS_CHATGPT:w
ai-claude.domains:AI_CLAUDE:w ai-chatgpt.domains:AI_CHATGPT:w ai-claude-proxies.nets:AI_CLAUDE_PROXIES:w ai-chatgpt-proxies.nets:AI_CHATGPT_PROXIES:w
tune.ways:TUNE_WAYS:l tune-video.ways:TUNE_VIDEO_WAYS:l"
# list_lines FILE: the entries, one per line
list_lines() { sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"; }
# lists_load DIR: sets TG_NETS, TV_NETS, TUNE_WAYS... from DIR/*; "w" lists become one space-separated line
# (TV_NETS goes into sed and awk), "l" lists keep one entry per line (a way has spaces between its steps)
lists_load() {
  for x in $LISTS; do
    f=$1/${x%%:*}; v=${x#*:}; v=${v%:*}
    [ -f "$f" ] || { echo "Не найден lists/${x%%:*}: запускайте install.sh из папки проекта целиком"; return 1; }
    val=$(list_lines "$f") || return 1
    [ -n "$val" ] || { echo "Пустой список lists/${x%%:*}: запускайте install.sh из папки проекта целиком"; return 1; }
    [ "${x##*:}" = w ] && val=$(printf '%s\n' "$val" | tr '\n' ' ' | sed 's/ $//')
    eval "$v=\$val"
  done
}
