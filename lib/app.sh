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
  if mkdir -p "$a.new/lib" "$a.new/platforms" && cp "$SB_SRC/install.sh" "$a.new/" &&
     cp "$SB_SRC"/lib/*.sh "$a.new/lib/" && cp "$SB_SRC"/platforms/*.sh "$a.new/platforms/" &&
     echo "$VERSION" > "$a.new/VERSION"; then
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
  # the router's own connections past zapret (own_script): refreshed, or added where zapret runs and this
  # version is the first to know about the leak
  if [ -n "$OWN_HOOK" ] && [ -f "$OWN_HOOK" ]; then
    own_script > "$tmp"; refresh_file "$OWN_HOOK" "запросы самого роутера мимо zapret" "$tmp"
    if own_can_run; then "$OWN_HOOK" >/dev/null 2>&1; fi
  elif [ -n "$OWN_HOOK" ] && pf_zapret_installed && [ -s "$STATE" ]; then
    own_install
  fi
  if [ -n "$CRON1" ] && [ -f "$CRON1/sb-tv" ] && ours "$CRON1/sb-tv"; then
    tv_job > "$tmp"; refresh_file "$CRON1/sb-tv" "Google и YouTube выбранных устройств через VPN" "$tmp"
  fi
  if [ -n "$QUIC_HOOK" ] && [ -f "$QUIC_HOOK" ]; then
    quic_script > "$tmp"; refresh_file "$QUIC_HOOK" "запрет QUIC для устройств дома" "$tmp"
    if own_can_run; then "$QUIC_HOOK" >/dev/null 2>&1; fi
  fi
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
