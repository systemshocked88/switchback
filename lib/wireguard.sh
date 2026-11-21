# WireGuard from a .conf file: "install.sh wg-import --conf FILE".
# Creates the connection on the router for "Telegram via VPN": only for chosen addresses, never for all traffic.
# The private and preshared keys go only into the router settings: never printed, logged or journaled.

cidr2mask() {   # 32 -> 255.255.255.255
  b=$1; m=""
  for i in 1 2 3 4; do
    if [ "$b" -ge 8 ]; then o=255; b=$((b-8)); elif [ "$b" -gt 0 ]; then o=$((256 - (1 << (8-b)))); b=0; else o=0; fi
    m="$m${m:+.}$o"
  done
  echo "$m"
}

# wg_parse FILE: sets WG_PRIV WG_ADDR(ip/bits, IPv4) WG_MTU WG_PUB WG_PSK WG_EP_HOST WG_EP_PORT WG_KA
wg_parse() {
  WG_PRIV=""; WG_ADDR=""; WG_MTU=""; WG_PUB=""; WG_PSK=""; WG_EP_HOST=""; WG_EP_PORT=""; WG_KA=""
  sec=""; cr=$(printf '\r'); peers=0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%"$cr"}; line=${line%%#*}
    case $line in
      *\[Interface\]*) sec=i; continue ;;
      *\[Peer\]*) sec=p; peers=$((peers+1)); continue ;;
      *=*) ;;
      *) continue ;;
    esac
    k=$(printf '%s' "${line%%=*}" | tr -d ' \t'); v=$(printf '%s' "${line#*=}" | sed 's/^[ \t]*//; s/[ \t]*$//')
    [ "$peers" -gt 1 ] && continue          # only the first peer
    case $sec$k in
      iPrivateKey) WG_PRIV=$v ;;
      iAddress) for a in $(echo "$v" | tr ',' ' '); do case $a in *.*/*) WG_ADDR=$a; break ;; *.*) WG_ADDR=$a/32; break ;; esac; done ;;
      iMTU) WG_MTU=$v ;;
      pPublicKey) WG_PUB=$v ;;
      pPresharedKey) WG_PSK=$v ;;
      pEndpoint) WG_EP_HOST=${v%:*}; WG_EP_PORT=${v##*:} ;;
      pPersistentKeepalive) WG_KA=$v ;;
    esac
  done < "$1"
  [ -n "$WG_PRIV" ] || { bad "в файле нет PrivateKey (раздел [Interface])"; return 1; }
  [ -n "$WG_ADDR" ] || { bad "в файле нет IPv4-адреса (Address в разделе [Interface])"; return 1; }
  [ -n "$WG_PUB" ]  || { bad "в файле нет PublicKey сервера (раздел [Peer])"; return 1; }
  case $WG_EP_HOST in ""|\[*) bad "в файле нет адреса сервера (Endpoint) или он IPv6 — такой пока не поддерживается"; return 1 ;; esac
  case $WG_EP_PORT in ""|*[!0-9]*) bad "неверный порт сервера в Endpoint"; return 1 ;; esac
  case $WG_KA in *[!0-9]*) WG_KA="" ;; esac
  case $WG_MTU in *[!0-9]*) WG_MTU="" ;; esac
  [ "$peers" -gt 1 ] && warn "в файле несколько серверов ([Peer]): беру первый"
  return 0
}

do_wg_import() {
  hr "WireGuard из файла"
  [ -n "$CONF" ] && [ -r "$CONF" ] || { bad "нужен файл: install.sh wg-import --conf ФАЙЛ.conf"; exit 2; }
  wg_parse "$CONF"; r=$?
  [ "$SB_ANSWERS_RM" = 1 ] && rm -f "$CONF"           # the program's temporary copy: keys must not stay in /tmp
  [ $r = 0 ] || exit 2
  ok "сервер: $WG_EP_HOST:$WG_EP_PORT, адрес в туннеле: $WG_ADDR"
  name=$(pf_wg_free_name)
  [ -n "$WG_NAME" ] && name=$WG_NAME
  for w in $(pf_vpn_ifaces); do [ "$w" = "$name" ] && { bad "подключение $name уже есть: выберите другое имя (--name)"; exit 2; }; done
  say "  Создаю подключение $name: только для выбранных адресов (Telegram), не для всего интернета."

  T0=$(date +%s)
  : > "$RUN_JOURNAL"
  trap on_interrupt INT TERM
  backup_start
  pf_wg_create "$name" || fail "роутер не принял настройки WireGuard"
  pf_save || fail "роутер не сохранил настройки"
  pf_reload
  trap - INT TERM
  unset WG_PRIV WG_PSK
  if [ "$DRY" = 1 ]; then note "Это был пробный прогон: ничего не изменено."
  else
    ok "подключение $name создано"
    ev wg "$name"
    if [ "$WG_STANDBY" = 1 ]; then
      # a standby is kept off (VPN services drop parallel connections): on only for the check
      pf_wg_up "$name"; wg_traffic_check "$name"; pf_wg_down "$name"
    else wg_traffic_check "$name"; fi
    note "Теперь его можно выбрать для Telegram: install.sh install --profile vpn"
  fi
  rm -f "$RUN_JOURNAL"
}

# wg_traffic_check NAME: a handshake proves nothing (seen on a real router: many configs shake hands and pass
# no traffic) — wait for the handshake, then open Telegram through this tunnel only
wg_traffic_check() {
  dev=$(pf_wg_dev "$1")
  say "  Проверяю туннель настоящим трафиком (до 30 секунд)…"
  i=0; while [ $i -lt "${SB_WG_TRIES:-6}" ]; do pf_vpn_alive "$1" && break; sleep 5; i=$((i+1)); done
  if ! pf_vpn_alive "$1"; then
    warn "сервер не ответил за 30 секунд (нет рукопожатия): конфиг, скорее всего, не рабочий или подписка кончилась"
    ev wg_check "$1" nohandshake; return 0
  fi
  c=$(curl -s -o /dev/null --max-time 12 --interface "$dev" -w '%{http_code}' https://api.telegram.org 2>/dev/null)
  if [ -n "$c" ] && [ "$c" != 000 ]; then ok "через $1 идёт трафик: Telegram ответил"; ev wg_check "$1" ok
  else warn "рукопожатие есть, но трафик через $1 не идёт: такой конфиг не годится, возьмите другой (другой сервер или слот)"; ev wg_check "$1" notraffic; fi
}

# ---------- many servers at once: "install.sh wg-batch --conf PATH [--keep N]" ----------
# PATH: a .zip of .conf files, a .conf, or a folder with them (the bot puts the archives sent to it there).
# Each server becomes a standby tunnel, is switched on for a moment and checked with real traffic (Telegram
# through it only); the ones that pass stay (off, at the end of the failover list), the rest are removed at
# once. The archives are taken in turns (one server from each, then the next ones), so the working tunnels
# come from different slots and countries. A server already on the router (same address) is skipped while its
# tunnel works; a dead one (judged as the failover does) is checked anew: revived - back in the failover list.
# Keys are never shown; the unpacked copies are wiped at the end (and the given files too with SB_ANSWERS_RM=1).
WGB_KEEP=6          # working tunnels added in one run at most
WGB_CAP=20          # WireGuard connections on the router at most
WGB_TRIES=4         # handshake wait: this many x 5 s

wgb_free_name() {   # like pf_wg_free_name, but also skips the names this run kept ($RC is read once)
  n=0
  while [ $n -lt 50 ]; do
    c=Wireguard$n
    case " $WGB_USED " in *" $c "*) n=$((n+1)); continue ;; esac
    printf '%s\n' "$RC" | grep -qx "interface $c" || { echo "$c"; return; }
    n=$((n+1))
  done
}
wgb_forget() {   # the tunnel was removed again: out of the journals, so uninstall never touches that name
  for jf in "$STATE" "$RUN_JOURNAL"; do
    [ -f "$jf" ] && { grep -vxF "wg $1" "$jf" > "$jf.tmp"; mv "$jf.tmp" "$jf"; }
  done
}
wgb_works() {   # a handshake, then Telegram through this tunnel only
  i=0
  while [ $i -lt "${SB_WG_TRIES:-$WGB_TRIES}" ]; do pf_vpn_alive "$1" && break; sleep "${SB_WG_SLEEP:-5}"; i=$((i+1)); done
  pf_vpn_alive "$1" || return 1
  c=$(curl -s -o /dev/null --max-time 12 --interface "$(pf_wg_dev "$1")" -w '%{http_code}' https://api.telegram.org 2>/dev/null)
  [ -n "$c" ] && [ "$c" != 000 ]
}
# wgb_existing HOST: the tunnel on the router that goes to this server (its endpoint or switchback's description)
wgb_existing() {
  printf '%s\n' "$RC" | awk -v h="$1" '
    /^interface / { i = $2; next }
    /^[^ ]/ { i = "" }
    i != "" && (index($0, "endpoint " h ":") || $0 ~ ("description switchback-" h "$")) { print i; exit }'
}
# wgb_dead NAME: the tunnel does not work now, judged as the failover does: no fresh handshake now, and the last
# daily check of the standbys (wg-failover/standby, "live" line) did not find it answering either. A standby
# that answered then and is simply switched off now is not dead.
wgb_dead() {
  pf_vpn_alive "$1" && return 1
  sed -n 's/^live//p' "$VAR_DIR/wg-failover/standby" 2>/dev/null | tr ' ' '\n' | grep -qx "$1" && return 1
  return 0
}
# wgb_recheck NAME HOST: a dead tunnel already on the router, given again in the files: checked anew the same way
# as a new one (on for a moment, alone). Revived: kept, back in the failover list. Still dead: left as it is -
# removing a tunnel is the owner's decision. $rechecked, $revived_n, $revived
wgb_recheck() {
  rechecked=$((rechecked+1))
  ron=0; pf_vpn_on "$1" && ron=1                 # on already (the active one, say): not switched off after
  [ "$ron" = 1 ] || pf_wg_up "$1" >/dev/null 2>&1
  if wgb_works "$1"; then
    [ "$ron" = 1 ] || pf_wg_down "$1" >/dev/null 2>&1
    revived_n=$((revived_n+1)); revived="$revived $1"
    ok "$1 ($2) — был мёртв, снова работает: оставлен запасным"; ev wg_batch revived "$1" "$2"
  else
    [ "$ron" = 1 ] || pf_wg_down "$1" >/dev/null 2>&1
    skip "$1 ($2) — уже на роутере и по-прежнему не отвечает (не удаляю)"; ev wg_batch still_dead "$1" "$2"
  fi
}
wgb_wipe() { rm -rf "$WGB_DIR"; [ "$SB_ANSWERS_RM" = 1 ] && [ -n "$CONF" ] && rm -rf "$CONF"; }

do_wg_batch() {
  hr "Туннели из архивов"
  [ "$PLATFORM" = keenetic ] || { bad "пока только для Keenetic: на OpenWrt добавляйте по одному (wg-import)"; exit 2; }
  [ -n "$CONF" ] && [ -e "$CONF" ] || { bad "нужен архив, файл или папка: install.sh wg-batch --conf ПУТЬ"; exit 2; }
  keep=${WG_KEEP:-$WGB_KEEP}; case $keep in ''|*[!0-9]*) keep=$WGB_KEEP ;; esac
  WGB_DIR=${SB_TMP:-/tmp}/switchback-wgb.$$; rm -rf "$WGB_DIR"; mkdir -p "$WGB_DIR/x"; chmod 700 "$WGB_DIR"
  trap 'r=$?; wgb_wipe; ev end $r' EXIT
  # sources: each .zip is one (a slot); loose .conf files together are one more
  if [ -d "$CONF" ]; then find "$CONF" -type f > "$WGB_DIR/src"; else echo "$CONF" > "$WGB_DIR/src"; fi
  k=0; mkdir -p "$WGB_DIR/x/loose"
  while IFS= read -r f; do
    case $f in
      *.zip|*.ZIP) k=$((k+1)); mkdir -p "$WGB_DIR/x/$k"
                   # exit 1 is a warning only (an archive made on Windows: "\" in its paths): judge by what came out
                   unzip -qq -o "$f" -d "$WGB_DIR/x/$k" >/dev/null 2>&1
                   [ -n "$(find "$WGB_DIR/x/$k" -type f | head -n 1)" ] || warn "архив $(basename "$f") не открылся" ;;
      *.conf|*.CONF) cp "$f" "$WGB_DIR/x/loose/" ;;
    esac
  done < "$WGB_DIR/src"
  for d in "$WGB_DIR"/x/*; do find "$d" -type f \( -name '*.conf' -o -name '*.CONF' \) | sort > "$d.list"; done
  # in turns: the 1st server of every source, then the 2nd...
  for l in "$WGB_DIR"/x/*.list; do awk -v s="$l" '{print NR, s, $0}' "$l"; done | sort -k1,1n -k2,2 | cut -d' ' -f3- > "$WGB_DIR/order"
  total=$(wc -l < "$WGB_DIR/order" | tr -d ' ')
  [ "$total" -gt 0 ] || { bad "в присланном нет файлов .conf с серверами WireGuard"; exit 2; }
  have=$(pf_vpn_ifaces | wc -l | tr -d ' ')
  say "  Серверов в файлах: $total. Проверяю по одному настоящим трафиком; рабочие оставлю запасными (до $keep)."
  ev wg_batch start "$total"

  : > "$RUN_JOURNAL"
  trap on_interrupt INT TERM
  WGB_USED=""; n=0; good=0; dead=0; dup=0; broken=0; added=""; rechecked=0; revived_n=0; revived=""
  while IFS= read -r f <&3; do
    [ "$good" -ge "$keep" ] && break
    [ $((have + good)) -ge "$WGB_CAP" ] && { warn "на роутере уже $((have + good)) подключений WireGuard — больше не добавляю"; break; }
    n=$((n+1))
    [ $((n % 20)) = 0 ] && say "  …проверено $n из $total, работают $good"
    wg_parse "$f" >/dev/null 2>&1 || { broken=$((broken+1)); continue; }
    wh=$WG_EP_HOST                                  # ("h" is taken: pf_vpn_alive sets it)
    if grep -qxF "$wh" "$WGB_DIR/hosts" 2>/dev/null; then dup=$((dup+1)); continue; fi
    echo "$wh" >> "$WGB_DIR/hosts"
    if printf '%s\n' "$RC" | grep -qF -e "endpoint $wh:" -e "switchback-$wh"; then
      # on the router already: a working one is skipped, a dead one is checked anew (seen 2026-11-18: 320 of 351
      # servers were there already, part of them dead, and sending the archives again changed nothing)
      en=$(wgb_existing "$wh")
      if [ -n "$en" ] && wgb_dead "$en"; then wgb_recheck "$en" "$wh"; else dup=$((dup+1)); fi
      continue
    fi
    name=$(wgb_free_name)
    [ -n "$name" ] || { warn "нет свободного имени для подключения"; break; }
    WG_STANDBY=1                                    # made switched off: on only for the check
    if ! pf_wg_create "$name" >/dev/null 2>&1; then
      pf_wg_delete "$name" >/dev/null 2>&1; wgb_forget "$name"; broken=$((broken+1)); continue
    fi
    pf_wg_up "$name" >/dev/null 2>&1
    if wgb_works "$name"; then
      pf_wg_down "$name" >/dev/null 2>&1
      good=$((good+1)); added="$added $name"; WGB_USED="$WGB_USED $name"
      pf_save >/dev/null 2>&1
      ok "$name ($wh) — работает, оставлен запасным"; ev wg_batch ok "$name" "$wh"
    else
      pf_wg_down "$name" >/dev/null 2>&1; pf_wg_delete "$name" >/dev/null 2>&1; wgb_forget "$name"
      dead=$((dead+1)); ev wg_batch dead "$wh"
    fi
  done 3< "$WGB_DIR/order"
  unset WG_PRIV WG_PSK
  trap - INT TERM
  # revived ones back in the failover list, if they dropped out of it
  back=""; [ -f "$SB_DIR/failover.conf" ] && for t in $revived; do
    sed -n 's/^TUNNELS="\(.*\)"$/ \1 /p' "$SB_DIR/failover.conf" | grep -qF " $t " || back="$back $t"; done
  if [ -n "$added$back" ] && [ -f "$SB_DIR/failover.conf" ] && [ "$DRY" != 1 ]; then
    sed -i "s/^TUNNELS=\"\(.*\)\"\$/TUNNELS=\"\1$added$back\"/" "$SB_DIR/failover.conf"
    [ -n "$added" ] && ok "автосмена: новые туннели добавлены в конец списка запасных"
    [ -n "$back" ] && ok "автосмена: ожившие туннели вернулись в список запасных:$back"
  elif [ "$good" -gt 0 ]; then note "автосмены нет: туннели просто добавлены (выключены)"; fi
  pf_save >/dev/null 2>&1; pf_reload
  rm -f "$RUN_JOURNAL"
  say ""
  say "Итог: проверено $n из $total — работают $good, не работают $dead, повторы $dup, не разобрать $broken; перепроверено мёртвых $rechecked, ожило $revived_n."
  [ "$n" -lt "$total" ] && [ "$good" -ge "$keep" ] && note "остальные $((total - n)) не проверял: уже набрано $keep рабочих"
  [ "$good" = 0 ] && [ "$revived_n" = 0 ] && note "рабочих не нашлось: провайдер, похоже, глушит эти серверы — возьмите другие страны"
  ev wg_batch done "$n" "$good" "$dead" "$dup" "$broken" "$rechecked" "$revived_n"
  log "wg-batch: checked $n of $total, kept $good:$added, dead $dead, dup $dup, broken $broken, dead ones rechecked $rechecked, revived $revived_n:${revived:- none}"
  return 0
}

# secret_set: like run, but the command line holds a key: never shown or logged
secret_run() {   # secret_run "label for screen and log" CMD...
  label=$1; shift
  if [ "$DRY" = 1 ]; then dry "$label"; return 0; fi
  log "run: $label"
  "$@" >/dev/null
}
