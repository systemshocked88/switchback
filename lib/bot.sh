# Bot commands: the watchdog bot also answers in its chat, so the router can be checked from the phone.
#   /status  what is installed and whether it works      /check  do the sites open right now
#   /report  diagnostic report as a file (secrets cut)   /sites  own sites in the bypass
#   /help    the list
# Only the owner's chat (CHAT in bot.conf) gets answers; everything else is ignored.
# Cron starts the script every minute: it asks Telegram once for new messages, answers and exits, so an
# answer comes within a minute. (A copy waiting for Telegram all the time answered in seconds, but its curl
# held ~7 MB of a 128 MB router's memory.)

bot_install() {
  [ -n "$CRON1" ] || return 0
  # commands need the Telegram bot (ntfy only sends)
  if ! grep -q '^TOKEN=.' "$BOT" 2>/dev/null; then [ "$DRY" = 1 ] && [ ! -s "$BOT" ] && dry "поставить команды боту ($CRON1/sb-bot)"; return 0; fi
  self_install
  t=/tmp/switchback.bot.$$; bot_script > "$t"
  install_file "$CRON1/sb-bot" "команды боту: /status /check /report /sites /tunnel /node /site /restart" "$t" replace_bot
  [ "$DRY" = 1 ] || bot_menu
}

# the "/" menu in the Telegram chat
bot_menu() {
  T=$(sed -n 's/^TOKEN=//p' "$BOT")
  curl -s -o /dev/null --max-time 15 "https://api.telegram.org/bot$T/setMyCommands" -H 'Content-Type: application/json' \
    -d '{"commands":[{"command":"status","description":"Что установлено и работает ли"},{"command":"check","description":"Открываются ли сайты сейчас"},{"command":"report","description":"Отчёт для диагностики (файлом)"},{"command":"sites","description":"Свои сайты в обходе"},{"command":"tunnel","description":"Туннели; /tunnel ИМЯ — переключить"},{"command":"ai","description":"Claude и ChatGPT: путь, «через VPN»"},{"command":"node","description":"Узлы Claude; /node best — закрепить быстрый"},{"command":"site","description":"/site add сайт vpn — добавить сайт"},{"command":"restart","description":"/restart zapret — перезапустить zapret"},{"command":"week","description":"Сводка за неделю"},{"command":"help","description":"Список команд"}]}'
  unset T
  return 0
}

bot_script() {
script_subst <<'EOF' | sed "s|__NFQ__|$NFQ|g"
#!/bin/sh
# Telegram bot commands (switchback). Cron starts it every minute: one look for new messages, answers to
# the owner's chat only, exit. Commands: /status /check /report /sites /help
export PATH=__PATH__
BOT=__BOT__
APP=__CONF__/app/install.sh
SITES=__CONF__/sites
S=__STATE__/sb-bot
[ -f "$BOT" ] || exit 0
mkdir -p "$S"
TOKEN=""; . "$BOT"
[ -n "$TOKEN" ] || exit 0                          # only ntfy, no bot: nothing to answer
# one run at a time (a /report takes up to a minute); a lock left by a reboot is cleared after 10 min
if ! mkdir "$S/lock" 2>/dev/null; then
  t=$(cat "$S/lock/t" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - t )) -gt 600 ] || exit 0
  rm -rf "$S/lock"; mkdir "$S/lock" || exit 0
fi
date +%s > "$S/lock/t"
trap 'rm -rf "$S/lock"' EXIT
API="https://api.telegram.org/bot$TOKEN"
[ -f "$S/log" ] && [ "$(wc -l < "$S/log")" -gt 300 ] && tail -n 200 "$S/log" > "$S/log.tmp" && mv "$S/log.tmp" "$S/log"
log() { echo "$(date '+%F %T') $*" >> "$S/log"; }

# reply TEXT [BUTTONS]: BUTTONS is Telegram's reply_markup (JSON): the menu under the input field or buttons
# under the message
reply() {
  if [ -n "$2" ]; then curl -s -o /dev/null --max-time 20 "$API/sendMessage" -d chat_id="$CHAT" --data-urlencode text="$1" --data-urlencode reply_markup="$2"
  else curl -s -o /dev/null --max-time 20 "$API/sendMessage" -d chat_id="$CHAT" --data-urlencode text="$1"; fi
}
# the menu under the input field: a button sends its text, which command_of understands
MENU='{"keyboard":[[{"text":"Что-то не работает"}],[{"text":"Статус"},{"text":"Проверка"}],[{"text":"Сайты"},{"text":"Туннели"}],[{"text":"Телевизор"},{"text":"Подобрать zapret"}],[{"text":"Claude"},{"text":"Узлы Claude"}],[{"text":"Сводка"},{"text":"Отчёт"}],[{"text":"Помощь"}]],"resize_keyboard":true,"is_persistent":true}'
AI_KB='{"inline_keyboard":[[{"text":"Claude через VPN","callback_data":"ai vpn"},{"text":"Следующий путь","callback_data":"ai next"}],[{"text":"Авто","callback_data":"ai auto"},{"text":"Статус","callback_data":"ai"}]]}'
YESNO='{"inline_keyboard":[[{"text":"Да","callback_data":"yes"},{"text":"Нет","callback_data":"no"}]]}'
# buttons LABEL|DATA ...: one button per row under the message; pressing it sends DATA as a command
buttons() {
  b=""; for x; do b="$b${b:+,}[{\"text\":\"${x%%|*}\",\"callback_data\":\"${x#*|}\"}]"; done
  echo "{\"inline_keyboard\":[$b]}"
}
# installer output -> chat text: icons instead of markers, no banner, no empty lines, not too long
pretty() {
  sed -e '/^---/,/^---/d' -e 's/^=== \(.*\) ===$/\1:/' -e 's/^ *\[ok\]/✓/' -e 's/^ *\[--\]/·/' \
      -e 's/^ *\[!!\]/!/' -e 's/^ *\[XX\]/✗/' -e 's/^ *\[dry\]/»/' -e 's/^  *//' -e 's/^Итог: /Итог: /' |
    grep -v '^$' | head -c 3500
}
# nocmd: the AI reserve's words for a person in Telegram: no router commands, the buttons and /ai instead
# ("sh install.sh ai ..." stays in the installer's own output)
nocmd() {
  sed -e 's/sh install\.sh ai auto или //' -e 's/ или sh install\.sh ai [a-z ]*//' \
      -e 's/(включить: sh install\.sh ai on)/(включить: команда «\/ai on»)/' -e 's/sh install\.sh ai on (или кнопкой в боте)/командой «\/ai on»/'
}
chk() {   # chk NAME URL
  r=$(curl --local-port 61000-61099 -s -o /dev/null --max-time 10 -w '%{http_code} %{time_total}' "$2" 2>/dev/null)
  c=${r%% *}; t=${r#* }
  if [ -n "$c" ] && [ "$c" != 000 ]; then echo "✓ $1 — $(echo "$t" | cut -c1-4) с"; else echo "✗ $1 — не открывается"; fi
}
help_text() {
  printf '%s\n' "Кнопки меню внизу чата — главные команды. Их можно набрать и сами (со знаком / или просто словом):" \
    "«Что-то не работает» (/diag) — бот сам ищет, в чём дело, и говорит, что делать" \
    "Пришлите адрес сайта (например, example.com) — бот проверит его и предложит пустить в обход" \
    "«Телевизор» (/tv) — устройства, у которых YouTube идёт через VPN; «Подобрать zapret» (/tune) — если YouTube снова тормозит" \
    "/quic — видео в приложении YouTube на телефоне тормозит: сколько присылают серверы, другой способ для QUIC" \
    "/status или «статус» — что установлено и работает ли" "/check или «проверка» — открываются ли сайты сейчас" \
    "/report или «отчёт» — отчёт для диагностики файлом (пароли и ключи вырезаны)" "/sites или «сайты» — свои сайты в обходе" \
    "" "Действия (бот переспросит, ответьте «да»):" \
    "/tunnel — туннели; /tunnel Wireguard5 — пустить Telegram и Meta через него" \
    "/ai или «Claude» — каким путём идут Claude и ChatGPT; кнопки «Claude через VPN», «Следующий путь», «Авто»"     "/node — узлы Claude и их скорость; /node best или /node 5.175.161.3 — закрепить Claude (для API: /node api best)" \
    "/site add example.com vpn — пустить сайт через туннель (или zapret); /site del example.com — убрать" \
    "/restart zapret — перезапустить zapret" \
    "Пришлите архивы .zip (или файлы .conf) с серверами WireGuard — бот проверит каждый и добавит рабочие запасными туннелями" \
    "/week — сводка за неделю (сама приходит по субботам в 11:00)" "/help — этот список"
}
# the message text -> "COMMAND ARGS". Telegram sends Cyrillic as backslash-u escapes: lower-case it there too
# (capital letters are 0410-042f, small 0430-044f, capital YO 0401, small yo 0451), drop "/" and "@BotName"
# (the escapes are put together at run time: U is backslash + "u", so no escape is written out here)
U=$(printf '\134u')
cyr() { r=""; for c; do r="$r${U}04$c"; done; printf '%s' "$r"; }   # cyr 41 42 -> the escapes of those letters
W_STATUS=$(cyr 41 42 30 42 43 41); W_CHECK=$(cyr 3f 40 3e 32 35 40); W_SITES=$(cyr 41 30 39 42)
W_REPORT1=$(cyr 3e 42 47 51 42); W_REPORT2=$(cyr 3e 42 47 35 42); W_YES=$(cyr 34 30)
W_TUNNEL=$(cyr 42 43 3d 3d 35 3b); W_NODE=$(cyr 43 37 3b); W_WEEK=$(cyr 41 32 3e 34 3a); W_HELP=$(cyr 3f 3e 3c 3e 49)
W_AI=$(cyr 3a 3b 3e 34); W_NO=$(cyr 3d 35 42); W_DIAG=$(cyr 47 42 3e); W_TV=$(cyr 42 35 3b 35 32); W_TUNE=$(cyr 3f 3e 34 3e 31)
command_of() {
  t=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -e 's/^ *//' -e 's#^/##' -e 's/@[^ ]*//' \
      -e 's/[\]u041\([0-9a-f]\)/\\u043\1/g' -e 's/[\]u042\([0-9a-f]\)/\\u044\1/g' -e 's/[\]u0401/\\u0451/g')
  set -- $t; w=$1; [ $# -gt 0 ] && shift; a=$*
  case $w in
    status|"$W_STATUS"*|статус*|Статус*|СТАТУС*) echo /status ;;
    check|"$W_CHECK"*|провер*|Провер*|ПРОВЕР*) echo /check ;;
    report|"$W_REPORT1"*|"$W_REPORT2"*|отч*|Отч*|ОТЧ*) echo /report ;;
    sites|"$W_SITES"*|сайт*|Сайт*|САЙТ*) echo /sites ;;
    yes|y|ok|"$W_YES"|да|Да|ДА) echo /yes ;;
    no|n|cancel|"$W_NO"|нет|Нет|НЕТ) echo /no ;;
    tunnel|tunnels) echo "/tunnel $a" ;;
    "$W_TUNNEL"*|туннел*|Туннел*) echo /tunnel ;;          # the menu button "Туннели"
    ai|claude|chatgpt) echo "/ai $a" ;;
    "$W_AI"*|клод*|Клод*|нейрос*|Нейрос*) echo "/ai $a" ;;      # "Клод", "нейросети"
    node|nodes) echo "/node $a" ;;
    "$W_NODE"*|узл*|Узл*) echo /node ;;                    # "Узлы Claude"
    site) echo "/site $a" ;;
    restart) echo "/restart $a" ;;
    week|digest|"$W_WEEK"*|сводк*|Сводк*) echo /week ;;
    diag) echo "/diag $a" ;;
    "$W_DIAG"*|что*|Что*) echo /diag ;;                    # "Что-то не работает"
    tv) echo "/tv $a" ;;
    "$W_TV"*|телев*|Телев*) echo /tv ;;
    tune) echo "/tune $a" ;;
    quic) echo "/quic $a" ;;
    "$W_TUNE"*|подобр*|Подобр*) echo /tune ;;
    wgb) echo "/wgb $a" ;;
    *.*) d=$(echo "$w" | sed -e 's#^[a-z]*:[\]*/[\]*/##' -e 's#[\]*/.*##' -e 's/^www\.//')    # a link or an address: check it
         if site_ok "$d"; then echo "/diag $d"; else echo /help; fi ;;
    *) echo /help ;;
  esac
}

J=$(dirname "$0")                       # the other minute jobs (auto-switch scripts) live next to this one
ip_ok() { echo "$1" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; }
site_ok() { echo "$1" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; }
# an action waits for "yes" up to 5 minutes; meanwhile the bot answers within seconds
confirm() {   # confirm "ACTION ARGS" "question"
  echo "$(( $(date +%s) + 300 )) $1" > "$S/pending"
  reply "$2 Ответьте «да» или нажмите кнопку в течение 5 минут." "$YESNO"
  END=$(( $(date +%s) + 300 ))
}
# job SCRIPT ARGS: run one of the minute jobs; while its own minute run holds the lock it prints nothing:
# try again for up to a minute
job() {
  i=0
  while [ $i -lt 6 ]; do
    o=$(sh "$@" 2>&1)
    [ -n "$o" ] && { echo "$o"; return 0; }
    sleep 10; i=$((i+1))
  done
}
node_list() {
  job "$J/claude-nodes" --list | while read -r ip ms kind groups; do
    case $ms in 9999) t="не отвечает" ;; *) t="$ms мс" ;; esac
    case $kind in reserve) k=" (Zapret DNS)" ;; noquic) k=" (нет правила QUIC — не используется)" ;; *) k="" ;; esac
    [ -n "$groups" ] && groups=" ← сейчас: $groups"
    echo "$ip — $t$k$groups"
  done
}

# "Что-то не работает": the chain from the internet to the sites, in plain words, with buttons for the fixes
# A site "opens" when its page comes whole (redirects followed), or at least 100 KB of it come in the time.
# An answer code alone is not enough: the provider may let the first bytes through and cut the rest (seen
# 2026-11-17: a site's servers answered a short request at once, but no picture came through at all).
opens() {
  r=$(curl --local-port 61000-61099 -s -L --max-redirs 3 -o /dev/null --max-time 12 -w '%{http_code} %{size_download}' "$1" 2>/dev/null); e=$?
  c=${r%% *}; s=${r#* }; s=${s%%.*}; case $s in ''|*[!0-9]*) s=0 ;; esac
  [ -n "$c" ] && [ "$c" != 000 ] || return 1
  [ "$e" = 0 ] || { [ "$e" = 28 ] && [ "$s" -gt 100000 ]; }
}
diag() {
  if ! opens https://ya.ru && ! opens https://www.google.com; then
    reply "✗ Интернета нет: с роутера не открываются даже обычные сайты. Похоже, сбой у провайдера или с кабелем — роутер и обход тут ни при чём. Если не пройдёт за полчаса — звоните провайдеру."
    return
  fi
  o="✓ Интернет есть"; bad=0; b=""
  addb() { b="$b${b:+,}[{\"text\":\"$1\",\"callback_data\":\"$2\"}]"; }
  if [ -d __NFQ__ ]; then
    if pidof nfqws2 >/dev/null || pidof nfqws >/dev/null; then o="$o
✓ zapret (обход блокировок) работает"
      if opens https://www.youtube.com; then o="$o
✓ YouTube открывается"
        addb "Видео на телефоне тормозит" quic
      else bad=1; o="$o
✗ YouTube не открывается, хотя zapret работает: похоже, провайдер сменил блокировку. Помогает подбор настроек zapret (4–11 минут)."
        addb "Подобрать zapret" tune; fi
    else bad=1; o="$o
✗ zapret не работает — YouTube и другие сайты могут не открываться. Сторож перезапускает его сам раз в 5 минут; можно сейчас кнопкой."
      addb "Перезапустить zapret" "restart zapret"; fi
  fi
  if [ -x "$J/wg-failover" ]; then
    if opens https://www.instagram.com; then o="$o
✓ Туннель VPN работает (Telegram, Instagram)"
    else bad=1; o="$o
✗ Instagram не открывается — похоже, туннель VPN работает плохо. Автосмена сама переключит его, если он умрёт; можно и вручную."
      addb "Туннели" tunnel; fi
    f=__STATE__/wg-failover/standby
    if [ -f "$f" ]; then n=$(sed -n 's/^live//p' "$f" | wc -w | tr -d ' ')
      if [ "$n" -le 1 ]; then o="$o
! Запасных туннелей, которые отвечают, — $n: добавьте новый конфиг WireGuard (программа switchback → «WireGuard из файла»)."
      else o="$o
✓ Запасных туннелей отвечает: $n"; fi
    fi
  fi
  for s in claude.ai chatgpt.com; do
    opens "https://$s" || { bad=1; o="$o
✗ $s не открывается: обычно это сбой самого сервиса или его DNS, проходит само."; }
  done
  [ -f "$SITES" ] && while read -r w d; do
    [ "$w" != rescue ] && [ -n "$d" ] && ! opens "https://$d" && { bad=1; o="$o
✗ свой сайт $d не открывается"; }
  done < "$SITES"
  m=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {if (t && a * 100 / t < 12) printf "%d", a / 1024}' "${SB_MEMINFO:-/proc/meminfo}" 2>/dev/null)
  [ -n "$m" ] && { bad=1; o="$o
! Мало свободной памяти (${m} МБ) — если всё тормозит, перезагрузите роутер."; }
  if [ $bad = 0 ]; then o="$o

Со стороны роутера всё в порядке. Не работает на одном устройстве — выключите и включите на нём Wi-Fi или перезапустите приложение. Не открывается один сайт — пришлите его адрес, проверю."; fi
  if [ -n "$b" ]; then reply "$o" "{\"inline_keyboard\":[$b]}"
  else reply "$o"; fi
}
diag_site() {   # diag_site DOMAIN: the site doctor (install.sh sites doctor), with a button for each fix it offers
  o=$(sh "$APP" sites doctor "$1" --progress --plain 2>&1)
  fx=$(printf '%s\n' "$o" | sed -n 's/^@@sb	doc_fix	//p' | head -n 1 | tr '\t' ' ')
  t=$(printf '%s\n' "$o" | grep -v '^@@sb' | pretty)
  bl=""; for w in $fx; do
    case $w in vpn) bl="$bl|Через VPN|site add $1 vpn" ;; zapret) bl="$bl|Через zapret|site add $1 zapret" ;; dns) bl="$bl|Через DNS|site add $1 dns" ;; esac
  done
  if [ -n "$bl" ]; then
    set -f; IFS='|'; set -- ${bl#|}; unset IFS; set +f
    b=""; while [ $# -ge 2 ]; do b="$b${b:+,}[{\"text\":\"$1\",\"callback_data\":\"$2\"}]"; shift 2; done
    reply "${t:-Проверить не удалось.}" "{\"inline_keyboard\":[$b]}"
  else reply "${t:-Проверить не удалось.}"; fi
}

handle() {   # handle COMMAND [ARGS]
  case $1 in
    /status)  reply "$(sh "$APP" status --plain 2>&1 | pretty)" ;;
    /check)   reply "Проверяю, это до минуты…"
              out=$( { chk YouTube https://www.youtube.com; chk Instagram https://www.instagram.com
                       chk Discord https://discord.com; chk Telegram https://api.telegram.org
                       chk ChatGPT https://chatgpt.com; chk Claude https://claude.ai
                       # own sites only ("rescue video" is the cut-off servers job, not a site)
                       [ -f "$SITES" ] && while read -r w d; do [ "$w" != rescue ] && [ -n "$d" ] && chk "$d" "https://$d"; done < "$SITES"; } )
              reply "$out" ;;
    /report)  reply "Собираю отчёт, это до минуты…"
              if sh "$APP" report >/dev/null 2>&1 && [ -s __STATE__/switchback-report.txt ]; then
                curl -s -o /dev/null --max-time 60 -F chat_id="$CHAT" -F caption="switchback: отчёт для диагностики" \
                  -F document=@__STATE__/switchback-report.txt "$API/sendDocument"
              else reply "Отчёт собрать не удалось."; fi ;;
    /sites)   reply "$(sh "$APP" sites --plain 2>&1 | pretty)" ;;
    /tunnel)  list=$(sh "$APP" act tunnels --plain 2>/dev/null | grep -E '^[A-Za-z0-9_]+: ')
              if [ -z "$2" ]; then
                # a button for every connection Telegram can be moved to (up to 8; the list says which is in use)
                bl=""; [ -x "$J/wg-failover" ] && bl=$(echo "$list" | sed -n 's/^\([A-Za-z0-9_]*\): .*/\1/p' | head -n 8 |
                  awk '{ printf "%s[{\"text\":\"→ %s\",\"callback_data\":\"tunnel %s\"}]", (NR > 1 ? "," : ""), $1, $1 }')
                if [ -n "$list" ] && [ -n "$bl" ]; then
                  reply "$list

Кнопкой — пустить Telegram и Meta через другой туннель:" "{\"inline_keyboard\":[$bl]}"
                else reply "${list:-VPN-подключений нет.}"; fi
                return
              fi
              n=$2; case $n in wireguard*) n="Wireguard${n#wireguard}" ;; esac
              [ -x "$J/wg-failover" ] || { reply "Автосмена туннеля не установлена: переключать нечем."; return; }
              echo "$list" | grep -q "^$n: " || { reply "Нет подключения $n. Есть:
$list"; return; }
              confirm "tunnel $n" "Пустить Telegram и Meta через $n? Он включится, при успехе прежний выключится." ;;
    /node)    [ -x "$J/claude-nodes" ] || { reply "Автосмена узлов Claude не установлена."; return; }
              if [ -z "$2" ]; then reply "Измеряю узлы, это до минуты…"; out=$(node_list)
                if [ -n "$out" ]; then reply "$out" "$(buttons "Закрепить самый быстрый|node best")"
                else reply "Автосмена узлов сейчас занята — повторите через минуту."; fi
                return
              fi
              g=web; x=$2; case $2 in web|api) g=$2; x=$3 ;; esac
              { [ "$x" = best ] || ip_ok "$x"; } || { reply "Нужно: /node best или /node 1.2.3.4 (для API: /node api best)"; return; }
              confirm "node $g $x" "Закрепить Claude ($g) за $( [ "$x" = best ] && echo 'самым быстрым узлом' || echo "узлом $x")?" ;;
    /site)    case $2 in
                add) site_ok "$3" || { reply "Нужно: /site add example.com vpn"; return; }
                     way=${4:-vpn}; case $way in vpn|zapret|dns) ;; *) reply "Способ: vpn, zapret или dns"; return ;; esac
                     confirm "site add $3 $way" "Добавить $3 (способ: $way)?" ;;
                del) site_ok "$3" || { reply "Нужно: /site del example.com"; return; }
                     confirm "site del $3" "Убрать $3 из своих сайтов?" ;;
                *)   reply "Нужно: /site add example.com vpn или /site del example.com" ;;
              esac ;;
    /restart) if [ "$2" = zapret ]; then confirm "zapret" "Перезапустить zapret? YouTube и другие сайты замрут на несколько секунд."
              else reply "Можно перезапустить: /restart zapret"; fi ;;
    /week)    out=$(sh "$J/sb-digest" --now 2>&1); reply "${out:-Сводка пока не установлена.}" ;;
    /diag)    if site_ok "$2"; then reply "Проверяю $2…"; diag_site "$2"
              else reply "Ищу, в чём дело, это до минуты…"; diag; fi ;;
    /tv)      case $2 in
                add) { [ -n "$3" ] && echo "$3$4" | grep -qE '^[0-9a-f:.]+[a-z0-9_-]*$'; } || { reply "Нужно: /tv add 192.168.1.50 tv (адрес устройства и имя)"; return; }
                     confirm "tv add $3 ${4:-tv}" "Пустить Google и YouTube устройства ${4:-tv} через VPN? Скорость YouTube на нём станет скоростью туннеля." ;;
                del) echo "$3" | grep -qE '^[a-z0-9_.:-]+$' || { reply "Нужно: /tv del ИМЯ"; return; }
                     confirm "tv del $3" "Вернуть устройство $3 на обычный путь (Google и YouTube напрямую, через zapret)?" ;;
                *)   out=$(sh "$APP" sites tv --plain 2>&1 | pretty)
                     bl=""; for x in $(awk '{print $1 "=" $2}' __CONF__/tv.devices 2>/dev/null); do
                       bl="$bl${bl:+,}[{\"text\":\"Убрать ${x#*=} с VPN\",\"callback_data\":\"tv del ${x#*=}\"}]"; done
                     for x in $(cat "$S/tv.off" 2>/dev/null); do grep -qi "^${x%%=*} " __CONF__/tv.devices 2>/dev/null && continue
                       bl="$bl${bl:+,}[{\"text\":\"Вернуть ${x#*=} на VPN\",\"callback_data\":\"tv add ${x%%=*} ${x#*=}\"}]"; done
                     txt="$out

YouTube этих устройств идёт через VPN: стабильнее, но со скоростью туннеля. Добавить устройство: /tv add 192.168.1.50 tv"
                     if [ -n "$bl" ]; then reply "$txt" "{\"inline_keyboard\":[$bl]}"; else reply "$txt"; fi ;;
              esac ;;
    /ai)      # the AI reserve (lib/ai.sh): which path Claude and ChatGPT take; the buttons switch at once (no
              # "yes" step: the owner presses them when the service is down, and every path is checked first)
              case $2 in
                ""|status) reply "$(sh "$APP" ai status --plain 2>&1 | pretty | nocmd)" "$AI_KB" ;;
                on)   reply "Включаю резерв для нейросетей, это до двух минут…"
                      reply "$(sh "$APP" ai on --plain 2>&1 | pretty | nocmd | tail -n 8)" "$AI_KB" ;;
                vpn|zdns|proxy|dns|next|auto)
                      reply "$(case $2 in vpn) echo "Пускаю Claude и ChatGPT через VPN" ;; next) echo "Ищу следующий рабочий путь" ;;
                               auto) echo "Выбираю лучший рабочий путь" ;; *) echo "Переключаю" ;; esac), это до двух минут…"
                      reply "$(sh "$APP" ai "$2" --plain 2>&1 | pretty | nocmd)" "$AI_KB" ;;
                *)    reply "Можно: /ai, /ai vpn, /ai next, /ai auto" "$AI_KB" ;;
              esac ;;
    /tune)    if [ "$2" = undo ]; then confirm "tune undo" "Вернуть настройки zapret, какими они были до последнего подбора?"; return; fi
              if [ -f __CONF__/tune.running ] && [ $(( $(date +%s) - $(cat __CONF__/tune.running) )) -lt 900 ]; then
                reply "Подбор уже идёт — пришлю итог, когда закончится."; return; fi
              confirm "tune" "Подобрать настройки zapret? Это 4–11 минут, YouTube и другие сайты дома в это время могут подтормаживать. Если лучше не станет, ничего не изменится." ;;
    /quic)    case $2 in
                next) confirm "tune quic next" "Включить другой способ для QUIC (видео в приложении YouTube на телефоне)? zapret перезапустится, сайты дома замрут на пару секунд." ;;
                undo) confirm "tune quic undo" "Вернуть способ для QUIC, какой был до перебора?" ;;
                *)    if [ -f __CONF__/nfqws2.conf.before-quic ]; then set -- "Другой способ для QUIC|quic next" "Вернуть как было|quic undo"
                      else set -- "Другой способ для QUIC|quic next"; fi
                      reply "$(sh "$APP" tune quic status --plain 2>&1 | pretty)

Видео на телефоне тормозит, а серверы прислали мало? Включите другой способ, посмотрите видео минуту-две и снова нажмите «Видео на телефоне тормозит» (/quic)." "$(buttons "$@")" ;;
              esac ;;
    /wgb)     nf=$(ls "$S/wg-in" 2>/dev/null | wc -l | tr -d ' ')
              case $2 in
                drop) rm -rf "$S/wg-in"; reply "Присланные файлы удалены." ;;
                go)   if [ -f __CONF__/wgb.running ] && [ $(( $(date +%s) - $(cat __CONF__/wgb.running) )) -lt 10800 ]; then
                        reply "Проверка серверов уже идёт — пришлю итог, когда закончится."; return; fi
                      [ "$nf" -gt 0 ] || { reply "Сначала пришлите архивы .zip или файлы .conf с серверами WireGuard."; return; }
                      confirm "wgb" "Проверить серверы из присланных файлов ($nf) и оставить рабочие (до 6) запасными туннелями? Каждый сервер включается на несколько секунд; на всё уходит от нескольких минут до часа." ;;
                *)    reply "Пришлите архивы .zip (или файлы .conf) с серверами WireGuard, затем нажмите «Проверить и добавить». Сейчас получено файлов: $nf." ;;
              esac ;;
    /yes)     run_pending ;;
    /no)     if [ -f "$S/pending" ]; then rm -f "$S/pending"; reply "Отменено."; else reply "Нечего отменять."; fi ;;
    *)        reply "$(help_text)" "$MENU" ;;
  esac
}

run_pending() {
  [ -f "$S/pending" ] || { reply "Нечего подтверждать."; return; }
  read -r exp act a1 a2 a3 < "$S/pending"; rm -f "$S/pending"
  [ "$(date +%s)" -le "$exp" ] || { reply "Прошло больше 5 минут — повторите команду."; return; }
  log "action $act $a1 $a2 $a3"
  case $act in
    tunnel) reply "Переключаю на $a1, это до минуты…"
            out=$(job "$J/wg-failover" --force "$a1" | tail -n 3)
            reply "${out:-Автосмена сейчас занята — повторите через минуту.}" ;;
    node)   out=$(job "$J/claude-nodes" --pin "$a1" "$a2" | tail -n 3)
            reply "${out:-Автосмена узлов сейчас занята — повторите через минуту.}" ;;
    site)   if [ "$a1" = add ]; then out=$(sh "$APP" sites add "$a2" --via "$a3" --plain 2>&1 | pretty)
              # a site of an AI service: the reserve's switch instead of a dead end
              case $out in *"Claude через VPN"*) reply "$(echo "$out" | nocmd)" "$AI_KB" ;; *) reply "$out" ;; esac
            else reply "$(sh "$APP" sites del "$a2" --plain 2>&1 | pretty)"; fi ;;
    zapret) reply "$(sh "$APP" act zapret-restart --plain 2>&1 | pretty)" ;;
    tv)     if [ "$a1" = add ]; then reply "$(sh "$APP" sites tv add "$a2" "$a3" --plain 2>&1 | pretty)"
            else
              # remembered, so the device list can offer "back on VPN" with one button
              x=$(awk -v n="$a2" '$2 == n || tolower($1) == tolower(n) {print $1 "=" $2; exit}' __CONF__/tv.devices 2>/dev/null)
              [ -n "$x" ] && { grep -v "^${x%%=*}=" "$S/tv.off" 2>/dev/null; echo "$x"; } > "$S/tv.off.new" && mv "$S/tv.off.new" "$S/tv.off"
              reply "$(sh "$APP" sites tv del "$a2" --plain 2>&1 | pretty)"
            fi ;;
    tune)   if [ "$a1" = quic ]; then
              reply "$(sh "$APP" tune quic "$a2" --plain 2>&1 | pretty)" "$(buttons "Проверить|quic" "Другой способ для QUIC|quic next" "Вернуть как было|quic undo")"
              return; fi
            if [ "$a1" = undo ]; then reply "$(sh "$APP" tune --undo --plain 2>&1 | pretty)"; return; fi
            reply "Начинаю подбор. Пришлю итог через 4–11 минут."
            # longer than the bot may stay: it goes on by itself and sends the result when done
            ( out=$(sh "$APP" tune --plain 2>&1 | pretty | tail -n 12)
              reply "${out:-Подбор не удался.}" "$(buttons "Вернуть как было|tune undo")" ) </dev/null >/dev/null 2>&1 &
            [ -n "$SB_BOT_ONCE" ] && wait          # tests: the result before the next check
            ;;
    wgb)    [ -d "$S/wg-in" ] || { reply "Файлов нет — пришлите их снова."; return; }
            rm -rf "$S/wg-job"; mv "$S/wg-in" "$S/wg-job"; date +%s > __CONF__/wgb.running
            reply "Начинаю проверку серверов. Пришлю итог, когда закончу."
            # can take an hour: it goes on by itself; the files with keys are wiped by wg-batch (SB_ANSWERS_RM)
            ( out=$(SB_ANSWERS_RM=1 sh "$APP" wg-batch --conf "$S/wg-job" --plain 2>&1 | pretty | tail -n 14)
              rm -rf "$S/wg-job" __CONF__/wgb.running
              reply "${out:-Проверка не удалась.}" ) </dev/null >/dev/null 2>&1 &
            [ -n "$SB_BOT_ONCE" ] && wait
            ;;
  esac
}

# a file sent to the bot: archives or .conf files with WireGuard servers are kept (only readable by root) until
# "Проверить и добавить"; anything else gets a hint. The file is fetched with the bot's own token.
doc_in() {
  d=$(echo "$1" | sed -e 's/"thumb[a-z]*":{[^}]*},\{0,1\}//g')       # thumbnails have file_id too
  fid=$(echo "$d" | sed -n 's/.*"document":{[^}]*"file_id":"\([^"]*\)".*/\1/p')
  fname=$(echo "$d" | sed -n 's/.*"document":{[^}]*"file_name":"\([^"]*\)".*/\1/p')
  case $fname in
    *.zip|*.ZIP) ext=zip ;;
    *.conf|*.CONF) ext=conf ;;
    *) reply "Этот файл мне не подходит. Пришлите архив .zip или файлы .conf с серверами WireGuard — проверю их и добавлю рабочие."; return ;;
  esac
  fp=$(curl -s --max-time 20 "$API/getFile" -d file_id="$fid" | sed -n 's/.*"file_path":"\([^"]*\)".*/\1/p' | sed 's#\\/#/#g')
  [ -n "$fp" ] || { reply "Не удалось получить файл (Telegram отдаёт ботам файлы до 20 МБ)."; return; }
  mkdir -p "$S/wg-in"; chmod 700 "$S/wg-in"
  k=$(( $(ls "$S/wg-in" | wc -l) + 1 )); out="$S/wg-in/$k.$ext"
  ( umask 077; curl -s --max-time 60 -o "$out" "https://api.telegram.org/file/bot$TOKEN/$fp" )
  [ -s "$out" ] || { rm -f "$out"; reply "Не удалось скачать файл — пришлите его ещё раз."; return; }
  log "file received ($ext)"
  reply "Получил файл ($k). Пришлите остальные, затем нажмите кнопку." "$(buttons "Проверить и добавить|wgb go" "Отменить|wgb drop")"
}

process() {   # the updates in $1 (Telegram's answer): answer the owner's ones
  # one update per line (Telegram's answer has line breaks inside an update: glue it first)
  printf '%s' "$1" | tr -d '\r\n' | awk '{ gsub(/\{"update_id":/, "\n{\"update_id\":"); print }' | grep '^{"update_id":' > "$S/batch"
  while IFS= read -r u; do
    id=$(echo "$u" | sed -n 's/^{"update_id":\([0-9]*\).*/\1/p')
    [ -n "$id" ] || continue
    off=$((id + 1)); echo "$off" > "$S/offset"
    chat=$(echo "$u" | grep -o '"chat":{"id":-\{0,1\}[0-9]*' | head -1 | grep -o -- '-\{0,1\}[0-9]*$')
    # not the owner: no answer at all (the log keeps only how long the number was, not the number)
    if [ "$chat" != "$CHAT" ]; then
      log "ignored: a message from another chat (${#chat} digits, ours has ${#CHAT})"
      # its shape only, for finding out why: digits, texts and names masked
      [ -n "$chat" ] || echo "$u" | sed -e 's/[0-9]/9/g' -e 's/":"[^"]*"/":"…"/g' | cut -c1-600 >> "$S/log"
      continue
    fi
    case $u in
      *'"callback_query":{"id":"'*)
        # a button under a message was pressed: its data is the command; Telegram waits for an acknowledgement
        cq=$(echo "$u" | sed -n 's/.*"callback_query":{"id":"\([^"]*\)".*/\1/p')
        curl -s -o /dev/null --max-time 10 "$API/answerCallbackQuery" -d callback_query_id="$cq"
        text=$(echo "$u" | sed -n 's/.*"data":"\([^"]*\)".*/\1/p') ;;
      *'"document":{'*) doc_in "$u" </dev/null; END=$(( $(date +%s) + 150 )); continue ;;
      *) text=$(echo "$u" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p' | head -1) ;;
    esac
    [ -n "$text" ] || continue                         # a sticker, a photo...: nothing to answer
    cmd=$(command_of "$text")
    log "command $cmd"
    handle $cmd </dev/null
    END=$(( $(date +%s) + 150 ))      # after a command: answer within seconds for a while
  done < "$S/batch"
}

set -f                                  # message text is never expanded into file names
# one quick look; after a command the bot stays and answers within seconds for ~2.5 minutes, then exits
off=$(cat "$S/offset" 2>/dev/null || echo 0)
END=0; wait=0
while :; do
  r=$(curl -s --max-time $((wait + 15)) "$API/getUpdates?offset=$off&timeout=$wait") || break
  case $r in '{"ok":true'*) ;; *) break ;; esac
  [ "$r" = '{"ok":true,"result":[]}' ] || process "$r"
  [ -n "$SB_BOT_ONCE" ] && break                     # tests: one round only
  [ "$(date +%s)" -lt "$END" ] || break               # nothing to talk about: back to sleep
  date +%s > "$S/lock/t"
  wait=25
done
exit 0
EOF
}

# "install.sh act ...": small actions the bot asks for (it confirms with the owner first)
#   act tunnels          the VPN connections, which is up, which one Telegram goes through
#   act zapret-restart   restart zapret and say whether it runs
do_act() {
  set -- $SITES_ARGS
  case $1 in
    tunnels)
      a=$(tg_via)
      for w in $(pf_vpn_ifaces); do
        if pf_vpn_alive "$w"; then s="подключено"; else s="не подключено"; fi
        m=""; [ "$w" = "$a" ] && m=" ← Telegram и Meta сейчас здесь"
        echo "$w: $s$m"
      done ;;
    zapret-restart)
      pf_zapret_installed || { bad "zapret не установлен"; return 1; }
      pf_zapret_restart </dev/null
      i=0; while [ $i -lt 5 ]; do pf_zapret_running && break; sleep 1; i=$((i+1)); done
      if pf_zapret_running; then ok "zapret перезапущен и работает"; log "zapret restarted by the bot"
      else bad "zapret не запустился — проверьте /status, при необходимости перезагрузите роутер"; return 1; fi ;;
    *) say "Неизвестное действие: $1 (tunnels, zapret-restart)"; return 2 ;;
  esac
}
