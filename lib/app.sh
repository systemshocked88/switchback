# switchback's own copy on the router, and "install.sh update".
# The copy ($SB_DIR/app) is what the jobs on the router run: the bot commands (status, report), the
# VPN-sites refresh. The Windows program uploads the installer to /tmp (gone after a reboot); the
# copy stays. "update" replaces the copy with the uploaded version and rewrites the scripts switchback
# installed (watchdog, backup, failover, nodes, bot, sites job) with this version's text. Settings
# (failover.conf, nodes.conf, bot.conf, sites) and router settings are not touched.

app_dir() { echo "$SB_DIR/app"; }
installed_version() { cat "$(app_dir)/VERSION" 2>/dev/null; }

self_install() {
  a=$(app_dir)
  [ "$SB_SRC" = "$a" ] && return 0                 # running from the copy itself
  if [ "$DRY" = 1 ]; then dry "сохранить копию switchback $VERSION на роутере ($a)"; return 0; fi
  old=$(installed_version)
  rm -rf "$a.new"
  if mkdir -p "$a.new/lib" "$a.new/platforms" "$a.new/lists" && cp "$SB_SRC/install.sh" "$a.new/" &&
     cp "$SB_SRC"/lib/*.sh "$a.new/lib/" && cp "$SB_SRC"/platforms/*.sh "$a.new/platforms/" &&
     cp "$SB_SRC"/lists/* "$a.new/lists/" &&
     { [ ! -d "$SB_SRC/panel" ] || { mkdir -p "$a.new/panel" && cp "$SB_SRC"/panel/* "$a.new/panel/"; }; } &&
     echo "$VERSION" > "$a.new/VERSION"; then
    # lists the program downloaded later than this version's own ones stay (a higher lists/VERSION)
    lo=$(cat "$a/lists/VERSION" 2>/dev/null | tr -dc 0-9); ln=$(cat "$a.new/lists/VERSION" 2>/dev/null | tr -dc 0-9)
    if [ -n "$lo" ] && [ "$lo" -gt "${ln:-0}" ] 2>/dev/null; then cp "$a"/lists/* "$a.new/lists/"; fi
    rm -rf "$a"; mv "$a.new" "$a"
  else
    rm -rf "$a.new"; warn "не удалось сохранить копию switchback в $a"; return 1
  fi
  remember "appdir $a"
  [ "$old" = "$VERSION" ] || ok "копия switchback $VERSION сохранена на роутере"
  return 0
}

ours() { grep -qxF "file $1" "$STATE" 2>/dev/null || grep -qxF "replaced $1" "$STATE" 2>/dev/null; }

# refresh_file DEST "what" SRC: rewrite one of OUR installed scripts with the new text
refresh_file() {
  if cmp -s "$3" "$1"; then skip "$2: уже новый"
  else write_file "$1" < "$3" && run chmod +x "$1" && ok "$2: обновлён"; fi
  rm -f "$3"
}

refresh_scripts() {
  tmp=/tmp/switchback.new.$$
  if [ -f "$CRON5/watchdog" ] && ours "$CRON5/watchdog"; then
    watchdog_script "$(watchdog_checks)" > "$tmp"; refresh_file "$CRON5/watchdog" "сторож" "$tmp"
  fi
  if [ -f "$CRONW/backup" ] && ours "$CRONW/backup"; then
    pf_backup_job > "$tmp"; refresh_file "$CRONW/backup" "еженедельный бэкап" "$tmp"
  fi
  if [ -n "$CRON1" ] && [ -f "$CRON1/wg-failover" ] && ours "$CRON1/wg-failover"; then
    failover_script > "$tmp"; refresh_file "$CRON1/wg-failover" "автосмена туннеля" "$tmp"
  fi
  if [ -n "$CRON1" ] && [ -f "$CRON1/claude-nodes" ] && ours "$CRON1/claude-nodes"; then
    nodes_script > "$tmp"; refresh_file "$CRON1/claude-nodes" "автосмена узлов Claude" "$tmp"
  fi
  if [ -n "$CRON1" ] && [ -f "$CRON1/ai-path" ] && ours "$CRON1/ai-path"; then
    ai_job > "$tmp"; refresh_file "$CRON1/ai-path" "резерв для нейросетей" "$tmp"
    ai_subs_off all; save_if_changed   # what a version of 20.11.2026 added (lib/ai.sh: it broke the router's DNS)
  fi
  # the router's own connections past zapret (own_script): refreshed, or added where zapret runs and this
  # version is the first to know about the leak
  if [ -n "$OWN_HOOK" ] && [ -f "$OWN_HOOK" ]; then
    own_script > "$tmp"; refresh_file "$OWN_HOOK" "запросы самого роутера мимо zapret" "$tmp"
    if own_can_run; then "$OWN_HOOK" >/dev/null 2>&1; fi
  elif [ -n "$OWN_HOOK" ] && pf_zapret_installed && [ -s "$STATE" ]; then
    own_install
  fi
  # VLESS (lib/vless.sh): its service and its rules
  if [ -n "$VLESS_HOOK" ] && [ -f "$VLESS_INIT" ] && ours "$VLESS_INIT"; then
    vless_init_script > "$tmp"; refresh_file "$VLESS_INIT" "служба Xray" "$tmp"
  fi
  if [ -n "$VLESS_HOOK" ] && [ -f "$VLESS_HOOK" ] && ours "$VLESS_HOOK"; then
    vless_hook_script > "$tmp"; refresh_file "$VLESS_HOOK" "правила VLESS" "$tmp"; vless_sync
  fi
  if [ -n "$VSUB_JOB" ] && [ -f "$VSUB_JOB" ] && ours "$VSUB_JOB"; then
    vsub_job > "$tmp"; refresh_file "$VSUB_JOB" "перепроверка ключей подписки VLESS" "$tmp"
  fi
  if [ -n "$CRON1" ] && [ -f "$CRON1/sb-panel" ] && ours "$CRON1/sb-panel"; then
    panel_job > "$tmp"; refresh_file "$CRON1/sb-panel" "запуск панели" "$tmp"
    panel_files; panel_install_files && ok "страница панели: обновлена"
  fi
  if [ -n "$CRON1" ] && [ -f "$CRON1/sb-tv" ] && ours "$CRON1/sb-tv"; then
    tv_job > "$tmp"; refresh_file "$CRON1/sb-tv" "Google и YouTube выбранных устройств через VPN" "$tmp"
  fi
  if [ -n "$QUIC_HOOK" ] && [ -f "$QUIC_HOOK" ]; then
    quic_script > "$tmp"; refresh_file "$QUIC_HOOK" "запрет QUIC для устройств дома" "$tmp"
    if own_can_run; then "$QUIC_HOOK" >/dev/null 2>&1; fi
  fi
  # zapret's QUIC way (the YouTube app on a phone): the package's old one gives way to a working one (lib/tune.sh)
  quic_default_apply
  if [ -n "$CRON1" ] && [ -f "$CRON1/sb-load" ] && ours "$CRON1/sb-load"; then
    load_job > "$tmp"; refresh_file "$CRON1/sb-load" "запись нагрузки" "$tmp"
  elif [ -n "$CRON1" ] && [ -s "$STATE" ]; then
    load_install
  fi
  if [ -n "$CRON1" ] && [ -f "$CRON1/sb-digest" ] && ours "$CRON1/sb-digest"; then
    digest_job > "$tmp"; refresh_file "$CRON1/sb-digest" "сводка за неделю" "$tmp"
  elif [ -n "$CRON1" ] && [ -s "$STATE" ]; then
    digest_install
  fi
  if [ -n "$CRON1" ] && [ -f "$CRON1/sb-heal" ] && ours "$CRON1/sb-heal"; then
    heal_job > "$tmp"; refresh_file "$CRON1/sb-heal" "самолечение" "$tmp"
  elif [ -n "$CRON1" ] && [ -f "$CRON5/watchdog" ] && [ -s "$STATE" ]; then
    heal_install
  fi
  if [ -n "$CRON1" ] && [ -f "$CRON1/sb-sites" ] && ours "$CRON1/sb-sites"; then
    sites_job > "$tmp"; refresh_file "$CRON1/sb-sites" "обновление адресов своих сайтов" "$tmp"
  fi
  # the bot: refreshed, or added if the bot is set up but this version's commands are not there yet
  if [ -n "$CRON1" ] && grep -q '^TOKEN=.' "$BOT" 2>/dev/null; then
    if [ -f "$CRON1/sb-bot" ] && ours "$CRON1/sb-bot"; then
      bot_script > "$tmp"
      if cmp -s "$tmp" "$CRON1/sb-bot"; then refresh_file "$CRON1/sb-bot" "команды боту" "$tmp"
      else
        refresh_file "$CRON1/sb-bot" "команды боту" "$tmp"
        # the running copy would only notice after its current wait for Telegram: stop it, cron starts the new one
        p=$(cat "$VAR_DIR/sb-bot/pid" 2>/dev/null)
        [ "$DRY" = 1 ] || { [ -n "$p" ] && grep -q sb-bot "/proc/$p/cmdline" 2>/dev/null && kill "$p" 2>/dev/null; }
      fi
    elif [ ! -f "$CRON1/sb-bot" ]; then
      bot_install
    fi
  fi
}

# "lists [status]": the version of the lists in this copy (lists/VERSION, a whole number; 0 = none).
# "lists apply": the Windows program put new, checked lists into the copy (the previous ones in
# $SB_DIR/lists.prev); this run is from the copy, so it has loaded them already. What a new entry needs is
# added, only where that part is set up: Telegram and Meta routes through the tunnel Telegram already uses,
# zapret domains, DNS records of ChatGPT and Claude (through the server their other domains use), the scripts
# that carry lists inside (the TV job, rescue of video). An entry that was in lists.prev and is not in the new
# lists is taken off the router, but only if switchback put it there itself (its line in $STATE): routes, Meta
# DNS, zapret domains, DNS records. Nothing made by hand is touched (a network that already goes somewhere is
# left alone, a domain that is also an own site stays).
# "lists restore": the previous lists back (the two copies swap places, then "lists apply").
# "lists put": new lists as tar.gz on stdin (sent by the program, which checked their signature and every
# line). Only a newer version with every list in it is taken; the copy's lists go to $SB_DIR/lists.prev
# first, then the copy runs "lists apply" with the new ones. If that run fails, or the connection checks are
# worse after it than before, the previous lists come back by themselves (automatic rollback).
lists_version() { v=$(cat "$SB_SRC/lists/VERSION" 2>/dev/null | tr -dc 0-9); echo "${v:-0}"; }
# lists_old: O_TG, O_NETS, O_ZAPRET, O_META_DNS, O_DNS from lists.prev (empty when there is none or it is broken)
lists_old() {
  O_TG=""; O_NETS=""; O_ZAPRET=""; O_META_DNS=""; O_DNS=""
  [ -d "$SB_DIR/lists.prev" ] || return 0
  if lists_load "$SB_DIR/lists.prev" >/dev/null 2>&1; then
    O_TG=$TG_NETS; O_NETS="$TG_NETS $META_NETS"; O_ZAPRET=$ZAPRET_DOMAINS; O_META_DNS=$META_DOMAINS
    O_DNS="$DNS_CHATGPT $DNS_CLAUDE"
  fi
  lists_load "$SB_SRC/lists" >/dev/null
}
# lists_gone OLD NEW: the words of OLD that are not in NEW
lists_gone() { lg_new=" $(echo $2) "; for x in $1; do case $lg_new in *" $x "*) ;; *) echo "$x" ;; esac; done; }
# own_site DOMAIN: the owner added it as an own site (then it is theirs, not the list's)
own_site() { [ -f "$SB_DIR/sites" ] && awk -v d="$1" '$2 == d {f=1} END {exit !f}' "$SB_DIR/sites"; }
# state_drop LINE: undo one of switchback's own journal lines and forget it
state_drop() {
  undo_entry "$1"; n_gone=$((n_gone+1)); CLI_CHANGED=1
  [ "$DRY" = 1 ] && return 0
  grep -vxF "$1" "$STATE" > "$STATE.tmp"; mv "$STATE.tmp" "$STATE"
}
# lists_remove_gone: what left the lists comes off the router (only switchback's own entries)
lists_remove_gone() {
  g=$SB_DIR/lists.gone.$$
  for n in $(lists_gone "$O_NETS" "$TG_NETS $META_NETS"); do
    net=${n%/*}; mask=${n#*/}
    awk -v n="$net" '$1 == n {f=1} END {exit !f}' "$SB_DIR/sites.routes" 2>/dev/null && continue
    awk -v n="$net" -v m="$mask" '$1 == "route" && $2 == n && $3 == m' "$STATE" 2>/dev/null > "$g"
    while read -r line; do state_drop "$line"; done < "$g"
  done
  for d in $(lists_gone "$O_META_DNS" "$META_DOMAINS"); do
    grep -qxF "ns $META_DNS $d" "$STATE" 2>/dev/null && state_drop "ns $META_DNS $d"
  done
  for d in $(lists_gone "$O_ZAPRET" "$ZAPRET_DOMAINS"); do
    own_site "$d" && continue
    grep -qxF "list $d" "$STATE" 2>/dev/null && state_drop "list $d"
  done
  for d in $(lists_gone "$O_DNS" "$DNS_CHATGPT $DNS_CLAUDE"); do
    own_site "$d" && continue
    awk -v d="$d" '$1 == "dns" && $NF == d' "$STATE" 2>/dev/null > "$g"
    while read -r line; do state_drop "$line"; done < "$g"
  done
  rm -f "$g"
}
# lists_health CHECKS: "PASSED TOTAL" of the connection checks (zapret running + the sites "status" asks)
lists_health() {
  hp=0; ha=0
  if pf_zapret_installed; then ha=1; pf_zapret_running && hp=1; fi
  if command -v curl >/dev/null 2>&1; then
    for x in $1; do
      ha=$((ha+1))
      c=$(curl $ZCURL -s -o /dev/null --max-time 12 -w '%{http_code}' "${x#*|}" 2>/dev/null)
      [ -n "$c" ] && [ "$c" != 000 ] && hp=$((hp+1))
    done
  fi
  echo "$hp $ha"
}
# lists_tell TEXT: one message to the bot (Telegram, else ntfy); the same text not again within 10 minutes
lists_tell() {
  [ "$DRY" = 1 ] && return 0
  [ -f "$BOT" ] || return 0
  now=$(date +%s); last=$(sed -n 1p "$SB_DIR/lists.told" 2>/dev/null)
  case $last in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -lt 600 ] && [ "$(sed -n 2p "$SB_DIR/lists.told" 2>/dev/null)" = "$1" ] && return 0
  printf '%s\n%s\n' "$now" "$1" > "$SB_DIR/lists.told"
  ( . "$BOT"; eval "$(notify_func)"; sb_send "$1" ) >/dev/null 2>&1
  return 0
}
# lists_swap: the copy's lists and lists.prev change places
lists_swap() {
  a=$(app_dir)
  rm -rf "$a/lists.swap" && mv "$a/lists" "$a/lists.swap" && mv "$SB_DIR/lists.prev" "$a/lists" && mv "$a/lists.swap" "$SB_DIR/lists.prev"
}
# lists_changes: what the last "lists apply" did, in words
lists_changes() { set -- $(cat "$SB_DIR/lists.last" 2>/dev/null) 0 0; echo "добавлено записей: $1, убрано: $2"; }
# lists_back WHY: automatic rollback after a bad "lists put"
lists_back() {
  a=$(app_dir)
  say ""; bad "$1 — возвращаю прежние списки"
  log "lists rollback: $1"
  if ! lists_swap; then
    ev lists_rollback fail
    lists_tell "Новые списки не подошли ($1), а вернуть прежние сам не смог. Нажмите в программе «Вернуть прежние»."
    return 1
  fi
  sh "$a/install.sh" lists apply $LP
  v=$(cat "$a/lists/VERSION" 2>/dev/null | tr -dc 0-9)
  ev lists_rollback "${v:-0}"
  lists_tell "Новые списки не подошли ($1). Я сам вернул прежние (версия ${v:-0}), всё как было."
  log "lists rolled back to ${v:-0}"
}
lists_put() {
  a=$(app_dir); n=$SB_DIR/lists.new
  if [ ! -s "$STATE" ] || [ ! -f "$a/install.sh" ]; then
    say "  switchback на этом роутере ещё не ставился: списки положить некуда."; ev lists_applied none; return 1
  fi
  rm -rf "$n"; mkdir -p "$n"
  if ! tar xzf - -C "$n" 2>/dev/null; then rm -rf "$n"; bad "списки не распаковались — прежние остались"; ev lists_applied bad; return 1; fi
  for f in "$n"/* "$n"/.[!.]*; do
    [ -e "$f" ] || continue
    case ${f##*/} in VERSION|SHA256SUMS|SHA256SUMS.sig|*.nets|*.domains|*.ways) [ -f "$f" ] && continue ;; esac
    rm -rf "$n"; bad "в присланных списках лишний файл — прежние остались"; ev lists_applied bad; return 1
  done
  new=$(cat "$n/VERSION" 2>/dev/null | tr -dc 0-9); cur=$(cat "$a/lists/VERSION" 2>/dev/null | tr -dc 0-9)
  if [ -z "$new" ] || [ "$new" -le "${cur:-0}" ] 2>/dev/null; then
    rm -rf "$n"; bad "присланные списки не новее тех, что на роутере — прежние остались"; ev lists_applied old; return 1
  fi
  if ! ( lists_load "$n" ) >/dev/null 2>&1; then
    rm -rf "$n"; bad "в присланных списках чего-то не хватает — прежние остались"; ev lists_applied bad; return 1
  fi
  # the connection checks before; the same ones are asked after
  checks=$(link_checks); set -- $(lists_health "$checks"); h0=$1
  rm -rf "$SB_DIR/lists.prev"
  cp -r "$a/lists" "$SB_DIR/lists.prev" && cp "$n"/* "$a/lists/" || { rm -rf "$n"; fail "не удалось положить списки в $a/lists"; }
  rm -rf "$n"
  log "lists put ${cur:-0} -> $new"
  LP=""; [ "$PROGRESS" = 1 ] && LP=--progress
  if ! sh "$a/install.sh" lists apply $LP; then lists_back "применение прервалось"; return 1; fi
  w=${SB_LISTS_WAIT:-5}; [ -z "$SB_LISTS_WAIT" ] && [ -n "$SB_TEST" ] && w=0
  sleep "$w"; set -- $(lists_health "$checks")
  if [ "$1" -lt "$h0" ]; then    # once more: one lost answer is not "worse"
    sleep "$w"; set -- $(lists_health "$checks")
    if [ "$1" -lt "$h0" ]; then lists_back "после них стало хуже: проверок прошло $1 из $2, а было $h0"; return 1; fi
  fi
  lists_tell "Списки обновлены до версии $new ($(lists_changes)). Если что-то стало хуже — в программе есть кнопка «Вернуть прежние»."
  return 0
}
lists_restore() {
  a=$(app_dir)
  hr "Списки: вернуть прежние"
  if [ ! -s "$STATE" ] || [ ! -f "$a/install.sh" ]; then
    say "  switchback на этом роутере ещё не ставился."; ev lists_restored none; return 1
  fi
  if [ ! -f "$SB_DIR/lists.prev/VERSION" ] || ! ( lists_load "$SB_DIR/lists.prev" ) >/dev/null 2>&1; then
    say "  Прежних списков на роутере нет: возвращать нечего."; ev lists_restored none; return 1
  fi
  cur=$(cat "$a/lists/VERSION" 2>/dev/null | tr -dc 0-9)
  lists_swap || fail "не удалось вернуть прежние списки"
  log "lists restore ${cur:-0} -> $(cat "$a/lists/VERSION" 2>/dev/null | tr -dc 0-9)"
  LP=""; [ "$PROGRESS" = 1 ] && LP=--progress
  if ! sh "$a/install.sh" lists apply $LP; then
    lists_swap; sh "$a/install.sh" lists apply >/dev/null 2>&1
    ev lists_restored fail; lists_tell "Вернуть прежние списки не получилось — остались новые."; return 1
  fi
  v=$(cat "$a/lists/VERSION" 2>/dev/null | tr -dc 0-9)
  ev lists_restored "${v:-0}"
  lists_tell "Вернул прежние списки (версия ${v:-0}; $(lists_changes))."
  return 0
}
do_lists() {
  set -- $SITES_ARGS
  case ${1:-status} in
    status) v=$(cat "$(app_dir)/lists/VERSION" 2>/dev/null | tr -dc 0-9); [ -n "$v" ] || v=$(lists_version)
            p=$(cat "$SB_DIR/lists.prev/VERSION" 2>/dev/null | tr -dc 0-9)
            ev lists "$v" "${p:-0}"; say "  Списки: версия $v${p:+ (прежние: версия $p)}"; return 0 ;;
    apply) ;;
    put) lists_put; return $? ;;
    restore) lists_restore; return $? ;;
    *) say "  Неизвестная команда: lists $1 (есть: status, put, apply, restore)"; return 2 ;;
  esac
  hr "Списки: применить версию $(lists_version)"
  if [ ! -s "$STATE" ]; then
    say "  switchback на этом роутере ещё ничего не ставил: применять списки некуда."
    ev lists_applied none; return 1
  fi
  : > "$RUN_JOURNAL"
  trap on_interrupt INT TERM
  lists_old
  t=$(tg_via); [ -n "$t" ] || [ -z "$O_TG" ] || t=$(TG_NETS=$O_TG; tg_via)
  had_meta=0; meta_on && had_meta=1
  n_routes=0; n_add=0; n_gone=0
  if [ -n "$t" ]; then
    for n in $TG_NETS; do meta_route "${n%/*}" "${n#*/}" "$t"; done
    if [ "$had_meta" = 1 ]; then
      for n in $META_NETS; do meta_route "${n%/*}" "${n#*/}" "$t"; done
      for d in $META_DOMAINS; do
        pf_ns_has "$META_DNS" "$d" && continue
        pf_ns_add "$META_DNS" "$d" || fail "роутер не принял DNS-сервер для $d"
        remember "ns $META_DNS $d"; CLI_CHANGED=1; ok "$d $ARROW $META_DNS"; n_add=$((n_add+1))
      done
    fi
  fi
  [ "$n_routes" -gt 0 ] && ok "новых маршрутов через $t: $n_routes"
  n_add=$((n_add+n_routes))
  if pf_zapret_installed && [ -f "$NFQ_LIST" ]; then
    for d in $ZAPRET_DOMAINS; do
      grep -qx "$d" "$NFQ_LIST" 2>/dev/null && continue
      append_line "$NFQ_LIST" "$d"; remember "list $d"; ok "$d $ARROW список zapret"; n_add=$((n_add+1))
    done
  fi
  used=$(pf_dns_count)
  for list in "$DNS_CHATGPT" "$DNS_CLAUDE"; do
    srv=""
    for d in $list; do pf_dns_has "$d" && { srv=$(pf_dns_srv_of "$d"); break; }; done
    [ -n "$srv" ] || continue      # this service is not set up here
    for d in $list; do
      pf_dns_has "$d" && continue
      if [ "$used" -ge "$DNS_LIMIT" ]; then warn "лимит $DNS_LIMIT записей: $d не добавлен"; continue; fi
      pf_dns_add $srv "$d" || fail "роутер не принял DNS-запись для $d"
      remember "dns $srv $d"; ok "$d $ARROW DNS-сервис"; used=$((used+1)); CLI_CHANGED=1; n_add=$((n_add+1))
    done
  done
  # what left the lists: after the additions (the tunnel and "is Meta set up" were found above)
  z_gone=0
  if [ -n "$O_NETS$O_ZAPRET" ]; then
    z0=$(grep -c '^list ' "$STATE" 2>/dev/null); lists_remove_gone
    [ "$(grep -c '^list ' "$STATE" 2>/dev/null)" != "$z0" ] && z_gone=1
  fi
  [ "$n_gone" -gt 0 ] && ok "убрано записей, которых нет в новых списках: $n_gone"
  save_if_changed
  # zapret reads its list at start: restart it when a domain left (a new one is picked up as before)
  [ "$z_gone" = 1 ] && [ "$DRY" != 1 ] && pf_zapret_installed && pf_zapret_restart >/dev/null 2>&1
  refresh_scripts
  trap - INT TERM
  rm -f "$RUN_JOURNAL"
  [ "$DRY" = 1 ] || echo "$n_add $n_gone" > "$SB_DIR/lists.last"
  ev lists_applied "$(lists_version)"
  verdict 0 "Списки версии $(lists_version) применены. Ваши настройки не менялись"
  log "lists applied $(lists_version) +$n_add -$n_gone"
  return 0
}

do_update() {
  hr "Обновление switchback"
  if [ ! -s "$STATE" ]; then
    say "  switchback на этом роутере ещё ничего не ставил: обновлять нечего, нужна установка."
    ev updated none "$VERSION"; return 1
  fi
  old=$(installed_version)
  say "  На роутере: ${old:-версия до 0.6.0}, новая: $VERSION"
  : > "$RUN_JOURNAL"
  trap on_interrupt INT TERM
  self_install || fail "не удалось сохранить новую копию switchback"
  refresh_scripts
  pf_keep_files
  trap - INT TERM
  rm -f "$RUN_JOURNAL"
  ev updated "${old:-old}" "$VERSION"
  verdict 0 "switchback обновлён до $VERSION. Ваши настройки не менялись"
  log "updated ${old:-old} -> $VERSION"
  return 0
}
