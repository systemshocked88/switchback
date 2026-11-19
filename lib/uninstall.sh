# Uninstall: undo everything install.sh recorded in $STATE (all runs), newest first.

do_uninstall() {
  hr "Откат установки"
  [ -s "$STATE" ] || { say "Нечего откатывать: $STATE не найден или пуст."; return 0; }
  say "Будут отменены изменения:"
  sed 's/^/  /' "$STATE"
  say ""
  yes_no "Продолжить?" n uninstall_confirm || return 0
  rm_pkgs=0;  grep -q '^pkg' "$STATE" && yes_no "Удалять и установленные пакеты (zapret, curl, cron)?" n uninstall_packages && rm_pkgs=1
  rm_feeds=0; grep -q '^https_feeds' "$STATE" && yes_no "Вернуть источники пакетов на http?" n uninstall_feeds && rm_feeds=1

  sed '1!G;h;$!d' "$STATE" | while read -r line; do
    case $line in
      pkg\ *|pkgdeps\ *|pkgfile\ *) [ $rm_pkgs = 1 ] || continue ;;
      https_feeds) [ $rm_feeds = 1 ] || continue ;;
    esac
    undo_entry "$line"
  done
  [ "$DRY" = 1 ] || rm -f "$SB_DIR/tune.running"    # tune's "busy" mark (lib/tune.sh)
  pf_save && ok "настройки роутера сохранены"
  pf_zapret_installed && pf_zapret_restart
  [ "$DRY" = 1 ] || mv "$STATE" "$STATE.undone.$(date +%Y%m%d%H%M)"
  say ""
  say "Готово. Снимки настроек до установки остаются в $SB_DIR/backups (удалите вручную, если не нужны)."
}
