#!/bin/sh
# switchback: zapret, DNS per service, Telegram via VPN, watchdog — on home routers.
#
#   sh install.sh [command] [options]
#
# Commands:
#   install     (default) analyse the router, back up, install the chosen profile
#   doctor      only analyse the router: is it suitable, what may conflict
#   uninstall   undo everything this installer changed
#   status      what switchback installed here and whether it works now (changes nothing)
#   report      diagnostic report with passwords, keys and tokens cut out (changes nothing)
#   wg-import   create a WireGuard connection from a .conf file (--conf FILE [--name NAME] [--standby])
#   wg-batch    many servers at once: check each, keep the working ones as standbys (--conf ZIP|FILE|DIR [--keep N])
#   sites       own sites in the bypass: sites [list] | add DOMAIN --via zapret|dns|vpn | del DOMAIN | check DOMAIN
#               sites doctor DOMAIN: why a site does not open, step by step, and what fixes it
#   update      replace switchback's copy on the router and its scripts with this version (settings kept)
#   lists       lists [status] | put (new lists on stdin; rolls back by itself if worse) | apply | restore (the previous ones back)
#   panel       a page for phones at home: panel on|off|status|link|token (off by default)
#   ai          reserve for Claude and ChatGPT: ai on|off|status | via vpn|zdns|proxy|dns [HOURS] | auto | next
#   tune        pick the best zapret settings for this provider (--undo: back to the ones before;
#               tune video on|off: ways of their own for YouTube video servers;
#               tune quic status|next|undo: the way for QUIC, the YouTube app on a phone)
#
# Options:
#   --dry-run          show what would be done, change nothing
#   --profile NAME     full | zapret | dns | vpn | custom (default: ask)
#   --yes              accept the default answer to every question
#   --answers FILE     take answers from FILE (- = stdin), ask nothing (docs/answers.md)
#   --progress         also print machine-readable "@@sb" event lines (for the Windows program)
#   --plain            no colours or icons (also automatic when output is not a terminal)
#
# Supported: Keenetic / Netcraze (KeeneticOS + Entware), OpenWrt (opkg or apk).

VERSION=0.7.6
SB_SRC=$(cd "$(dirname "$0")" && pwd)
OPT=${SB_OPT:-/opt}                       # overridable for tests only
export PATH=$OPT/sbin:$OPT/bin:/usr/sbin:/usr/bin:/sbin:/bin

CMD=install; DRY=0; PROFILE=""; ASSUME_YES=0; PLAIN=0; ANSWERS=""; PROGRESS=0; CONF=""; WG_NAME=""
SITES_ARGS=""; SITE_VIA=""; SITE_DNS_LIKE=""; TUNE_UNDO=0; CMD_SET=0
while [ $# -gt 0 ]; do
  case $1 in
    install|doctor|uninstall|status|wg-import|wg-batch|sites|update|tune|act|lists|panel|ai)
      if [ "$CMD_SET" = 1 ] && { [ "$CMD" = sites ] || [ "$CMD" = tune ] || [ "$CMD" = ai ]; }; then SITES_ARGS="$SITES_ARGS $1"   # e.g. "sites check update.example", "tune quic status", "ai status" (the bot's /ai: not the router's whole status)
      else CMD=$1; CMD_SET=1; fi ;;
    --via) SITE_VIA=$2; shift ;;
    --dns-like) SITE_DNS_LIKE=$2; shift ;;
    --undo) TUNE_UNDO=1 ;;
    report) CMD=report; PLAIN=1 ;;
    --conf) CONF=$2; shift ;;
    --name) WG_NAME=$2; shift ;;
    --standby) WG_STANDBY=1 ;;
    --keep) WG_KEEP=$2; shift ;;
    --dry-run|-n) DRY=1 ;;
    --profile) PROFILE=$2; shift ;;
    --profile=*) PROFILE=${1#*=} ;;
    --yes|-y) ASSUME_YES=1 ;;
    --answers) ANSWERS=$2; shift ;;
    --answers=*) ANSWERS=${1#*=} ;;
    --progress) PROGRESS=1; PLAIN=1 ;;
    --plain) PLAIN=1 ;;
    --help|-h) sed -n '2,31p' "$0"; exit 0 ;;
    -*) echo "Неизвестный параметр: $1 (см. --help)"; exit 2 ;;
    *) if [ "$CMD" = sites ] || [ "$CMD" = act ] || [ "$CMD" = tune ] || [ "$CMD" = lists ] || [ "$CMD" = panel ] || [ "$CMD" = ai ]; then SITES_ARGS="$SITES_ARGS $1"
       else echo "Неизвестный параметр: $1 (см. --help)"; exit 2; fi ;;
  esac
  shift
done

ROOT=${SB_ROOT:-}                          # prefix for / on OpenWrt, overridable for tests only
RUN_JOURNAL=/tmp/switchback-run.$$
BACKUP_DIR=""
VPN_IF=""
STEP=""; STEPS=""; SUMMARY=""

for f in common ui detect doctor modules uninstall status wireguard failover nodes report app sites bot tune meta digest heal panel ai; do
  [ -f "$SB_SRC/lib/$f.sh" ] || { echo "Не найден lib/$f.sh: запускайте install.sh из папки проекта целиком"; exit 1; }
  . "$SB_SRC/lib/$f.sh"
done
lists_load "$SB_SRC/lists" || exit 1
ui_init
if [ -n "$ANSWERS" ]; then
  load_answers "$ANSWERS"
  # the Windows program passes the answers (bot token too) in a file: gone as soon as it is read
  [ "$SB_ANSWERS_RM" = 1 ] && [ "$ANSWERS" != - ] && rm -f "$ANSWERS"
fi
[ -z "$PROFILE" ] && ans_has profile && PROFILE=$(ans profile)
trap 'ev end $?' EXIT              # last event line: exit code of the whole run

[ "$(id -u 2>/dev/null)" = 0 ] || [ -n "$SB_TEST" ] || { say "Запустите от root (ssh root@192.168.1.1)."; exit 1; }

detect_platform
ev platform "$PLATFORM"
case $CMD in install) what="установка" ;; doctor) what="анализ роутера" ;; uninstall) what="откат" ;;
  status) what="статус" ;; wg-import) what="WireGuard из файла" ;; wg-batch) what="туннели из архивов" ;; report) what="отчёт для диагностики" ;;
  sites) what="свои сайты" ;; update) what="обновление" ;; lists) what="списки" ;; panel) what="панель" ;; ai) what="резерв для нейросетей" ;; tune) what="подбор настроек zapret" ;; act) what="действие" ;; esac
mode=""; [ "$DRY" = 1 ] && mode=" · пробный прогон, ничего не меняется"
banner "switchback $VERSION  ·  обход блокировок на роутере" "$(platform_title "$PLATFORM")  ·  $what$mode"

if ! load_platform; then
  say ""
  bad "Эта прошивка пока не поддерживается. Поддерживаются: Keenetic / Netcraze, OpenWrt."
  note "Роутеры TP-Link, Xiaomi и других брендов на заводской прошивке сначала нужно перепрошить на OpenWrt."
  exit 1
fi
# where this installer keeps its own files: set by the platform (ETC_DIR, VAR_DIR, BOT)
SB_DIR=$ETC_DIR/switchback
STATE=$SB_DIR/state
LOG=$VAR_DIR/log/switchback.log
pf_init

case $CMD in
  doctor)    doctor; exit $? ;;
  uninstall) do_uninstall; exit 0 ;;
  status)    do_status; exit $? ;;
  wg-import) do_wg_import; exit 0 ;;
  wg-batch)  do_wg_batch; exit $? ;;
  report)    do_report; exit $? ;;
  sites)     do_sites; exit $? ;;
  update)    do_update; exit $? ;;
  lists)     do_lists; exit $? ;;
  panel)     do_panel; exit $? ;;
  ai)        do_ai; exit $? ;;
  tune)     do_tune; exit $? ;;
  act)       do_act; exit $? ;;
esac

# ---------- install ----------
command -v pf_zapret_install >/dev/null 2>&1 || {
  doctor
  say ""; warn "Установка для этой прошивки ещё в разработке. Анализ выше уже можно использовать."
  exit 1
}

doctor; verdict=$?
say ""
if [ $verdict = 2 ]; then
  yes_no "Есть серьёзные проблемы. Всё равно продолжить?" n continue_with_problems || exit 1
elif [ $verdict = 1 ]; then
  yes_no "Продолжить установку?" y continue_with_warnings || exit 0
fi

if [ -z "$PROFILE" ]; then
  hr "Что установить"
  menu_item 1 "Полный набор" "zapret + DNS + Telegram и Instagram через VPN + сторож и бэкап + автосмена туннеля" recommended
  menu_item 2 "Только zapret" "YouTube, Discord, Instagram"
  menu_item 3 "Только DNS" "ChatGPT, Claude (+ быстрый узел Claude)"
  menu_item 4 "Только Telegram через VPN" "нужно уже настроенное подключение WireGuard"
  menu_item 5 "Выбрать модули вручную"
  say ""
  ask "Номер:" 1
  case $REPLY in 1) PROFILE=full ;; 2) PROFILE=zapret ;; 3) PROFILE=dns ;; 4) PROFILE=vpn ;; 5) PROFILE=custom ;; *) PROFILE=full ;; esac
fi

title_of() {
  case $1 in
    https) echo "Источники пакетов по https" ;; zapret) echo "zapret (YouTube, Discord, Instagram)" ;;
    dns) echo "DNS для ChatGPT и Claude" ;; vpn) echo "Telegram через VPN" ;; watchdog) echo "Сторож и бэкап" ;;
    failover) echo "Автосмена VPN-туннеля" ;;
    meta) echo "Instagram, Facebook, WhatsApp через VPN" ;;
    nodes) echo "Claude: быстрый узел и запрет QUIC" ;;
    panel) echo "Панель на роутере (страница для телефона)" ;;
  esac
}
case $PROFILE in
  full)   MODULES="https zapret dns nodes vpn meta watchdog failover" ;;
  zapret) MODULES="https zapret" ;;
  dns)    MODULES="dns nodes" ;;
  vpn)    MODULES="vpn" ;;
  custom)
    MODULES=""
    if ans_has modules; then
      for m in https zapret dns nodes vpn meta watchdog failover panel; do   # keep the safe order whatever order the file uses
        case " $(ans modules) " in *" $m "*) MODULES="$MODULES $m" ;; esac
      done
    else
      for m in https zapret dns nodes vpn meta watchdog failover; do yes_no "  $(title_of $m)?" y && MODULES="$MODULES $m"; done
      yes_no "  $(title_of panel)?" n && MODULES="$MODULES panel"
    fi ;;
  *) say "Неизвестный профиль: $PROFILE"; exit 2 ;;
esac
[ -n "$MODULES" ] || { say "Ничего не выбрано."; exit 0; }

hr "План"
n=0; for m in $MODULES; do n=$((n+1)); printf '  %s%d.%s %s\n' "$CC" "$n" "$C0" "$(title_of $m)"; done
say ""
note "Сначала сохраню снимок всех настроек. Если что-то пойдёт не так, изменения этого запуска откатятся сами."
ev plan $MODULES
yes_no "Начинаем?" y start || exit 0

T0=$(date +%s)
: > "$RUN_JOURNAL"
trap on_interrupt INT TERM
backup_start
STEPS=$(echo $MODULES | wc -w); STEP=0
for m in $MODULES; do
  STEP=$((STEP+1))
  ev step "$STEP" "$STEPS" "$m" "$(title_of $m)"
  before=$(wc -l < "$RUN_JOURNAL"); w0=$WARNINGS; MOD_SKIP=0
  "mod_$m"
  changed=$(( $(wc -l < "$RUN_JOURNAL") - before ))
  if [ "$DRY" = 1 ]; then summary_add skip "$(title_of $m)" "пробный прогон"
  elif [ "$WARNINGS" -gt "$w0" ]; then summary_add warn "$(title_of $m)" "есть предупреждения, см. выше"
  elif [ "$changed" -gt 0 ]; then summary_add ok "$(title_of $m)" "изменений: $changed"
  elif [ "$MOD_SKIP" = 1 ]; then summary_add skip "$(title_of $m)" "пропущено, см. выше"
  else summary_add skip "$(title_of $m)" "уже было настроено"; fi
done
STEP=""
self_install        # the copy the jobs on the router run (bot commands, own sites), and the version for updates
pf_keep_files       # OpenWrt: keep our files across firmware upgrades
trap - INT TERM
verify
summary_show

secs=$(( $(date +%s) - T0 ))
say ""
if [ "$DRY" = 1 ]; then
  note "Это был пробный прогон: ничего не изменено. Без --dry-run всё будет сделано по-настоящему."
else
  note "Готово за ${secs} с.  Журнал: $LOG"
  note "Снимок до установки: $BACKUP_DIR"
  note "Откатить всё: sh install.sh uninstall    Если что-то сломалось: docs/recovery.md"
fi
rm -f "$RUN_JOURNAL"
