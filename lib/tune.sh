# "install.sh tune": pick zapret's way of getting past the provider's filter (nfqws2, the TLS part).
# When the provider changes its filter, YouTube and the rest start to stall although zapret runs: the way
# it disguises the traffic stopped working. This command tries a set of known ways one by one: for each it
# restarts zapret and measures from the router how YouTube, Instagram and Discord open (the router's own
# traffic goes through zapret too). The best three that open everything are written in, best first, under
# "circular" — zapret moves to the next one by itself when one stops working for a site.
# If nothing is better than what is there now, nothing changes. During the test (2-6 minutes) those sites
# may stall for a few seconds at a time for everyone at home.
#   tune          pick and apply              tune --undo   back to the settings before the last pick

TUNE_PRE="--filter-tcp=443,80,1984,5222 --filter-l7=http,tls,mtproto --payload=tls_client_hello,mtproto_initial"
TUNE_POST="--payload=http_req --lua-desync=http_methodeol:badsum"
TUNE_CIRCULAR="--lua-desync=circular:fails=2:time=300:retrans=3:nld=2"
# always the last way of the mix, after the picked ones: seen on a real router (2026-11-16), the YouTube app's
# own server (youtubei.googleapis.com) opened with none of the picked ways and with this one at once (the way
# a working zapret on a computer at home used for Google); zapret gets to it by itself after the others fail
TUNE_ALWAYS="hostfakesplit:host=www.google.com:tcp_ts=-600000"
# name|desync steps (space-separated); in the final mix each step gets :strategy=N
TUNE_WAYS="fake-sni-google+multisplit|fake:blob=tls_clienthello:tls_mod=rnd,dupsid,sni=fonts.google.com:tcp_seq=10000 multisplit:pos=1,midsld:seqovl=1:seqovl_pattern=tls_clienthello:tcp_ts_up
fake-ack+multisplit|fake:blob=0x00000000:tcp_ack=-66000:tls_mod=rnd,dupsid,sni=www.google.com:repeats=2 multisplit:pos=1,midsld
hostfakesplit|hostfakesplit:host=ozon.ru:midhost=host-2:seqovl=sniext+3:seqovl_pattern=tls_clienthello:badsum:tcp_md5:tcp_ts_up hostfakesplit:tcp_md5:tcp_ts_up
multisplit|multisplit:pos=1,midsld
multidisorder|multidisorder:pos=1,midsld
fake-md5+multidisorder|fake:blob=tls_clienthello:tls_mod=rnd,dupsid,sni=www.google.com:tcp_md5:repeats=4 multidisorder:pos=1,midsld
fakedsplit|fakedsplit:pos=midsld:tcp_md5
fakeddisorder|fakeddisorder:pos=midsld:tcp_md5"
# name|url: what is measured (only sites that are in zapret's list count)
TUNE_SITES="YouTube|https://www.youtube.com/
YouTube-видео|https://redirector.googlevideo.com/report_mapping
YouTube-приложение|https://youtubei.googleapis.com/generate_204
Instagram|https://www.instagram.com/
Discord|https://discord.com/"

# YouTube video servers (googlevideo.com) get a zapret profile of their own: "circular" over ways taken from
# Zapret GUI's presets. Seen on a real router (2026-11-16): the provider cuts off far video servers by name
# and the main ways fail there now and then; the profile comes first in zapret (NFQWS_ARGS_CUSTOM), so it
# applies to those servers only. The first way is the one that worked on that router; zapret moves on by
# itself after two failures for a site. (hostfakesplit was taken out on 2026-11-16: a test of 468 ways on a
# computer at home found it failing for YouTube there; each dead way costs a stall before zapret moves on.)
#   tune video on|off
TUNE_VIDEO_PRE="--filter-tcp=443 --filter-l7=tls --hostlist-domains=googlevideo.com --out-range=-d8 --payload=tls_client_hello"
TUNE_VIDEO_WAYS="multisplit:pos=sniext+1,midsld:seqovl=652
fake:blob=tls_clienthello:repeats=6:tcp_ts=-600000
multidisorder:pos=1,host+2,sld+2,sld+5,sniext+1,sniext+2,endhost-2:seqovl=1
multisplit:pos=2:seqovl=681:seqovl_pattern=tls_clienthello:repeats=8:tcp_ts=-600000
fake:blob=tls_clienthello:repeats=6:tcp_seq=2"

# nfq_set_key FILE KEY VALUE: replace KEY="..." (one line or several) with VALUE on one line; add it if missing
nfq_set_key() {
  awk -v k="$2" -v v="$3" '
    skip { if ($0 ~ /"[ \t]*$/) skip = 0; next }
    index($0, k "=\"") == 1 { print k "=\"" v "\""; done = 1; rest = substr($0, length(k) + 3); if (rest !~ /"[ \t]*$/) skip = 1; next }
    { print }
    END { if (!done) print k "=\"" v "\"" }' "$1" > "$1.sb" && mv "$1.sb" "$1"
}
# nfq_set_args FILE VALUE: replace NFQWS_ARGS with VALUE on one line
nfq_set_args() { nfq_set_key "$1" NFQWS_ARGS "$2"; }
# nfq_get KEY: the value of KEY="..." when it is on one line ("" when missing or empty)
nfq_get() { sed -n "s/^$1=\"\(.*\)\"[ \t]*$/\1/p" "$NFQ_CONF" 2>/dev/null | head -n 1; }

tune_video_args() {
  a="$TUNE_VIDEO_PRE $TUNE_CIRCULAR"; n=0
  for s in $TUNE_VIDEO_WAYS; do n=$((n+1)); a="$a --lua-desync=$s:strategy=$n"; done
  echo "$a"
}

in_list() {   # in_list HOST: HOST or a parent domain is in zapret's list
  h=$1
  while :; do
    grep -qx "$h" "$NFQ_LIST" 2>/dev/null && return 0
    case $h in *.*.*) h=${h#*.} ;; *) return 1 ;; esac
  done
}

# One measurement is noisy (the same settings gave 167 and 526 KB/s on a real router): every site is
# fetched TUNE_TRIES times; it counts as opened when most tries open it, and YouTube's speed is the median.
TUNE_TRIES=3
TUNE_GAIN=33          # new ways are written only if YouTube is this many % faster than now (or now fails)

# tune_measure -> "OPENED TOTAL SPEED": sites that opened, sites measured, YouTube page speed (bytes/s, median)
tune_measure() {
  opened=0; total=0; speed=0
  printf '%s\n' "$TUNE_SITES" | {
    while IFS='|' read -r name url; do
      host=${url#https://}; host=${host%%/*}
      in_list "$host" || continue
      total=$((total+1)); good=0; speeds=""; i=0
      while [ $i -lt "$TUNE_TRIES" ]; do
        i=$((i+1))
        r=$(curl $ZCURL -s -o /dev/null --max-time 8 -w '%{http_code} %{speed_download}' "$url" </dev/null 2>/dev/null)
        c=${r%% *}; s=${r#* }; s=${s%%.*}
        case $s in ''|*[!0-9]*) s=0 ;; esac
        if [ -n "$c" ] && [ "$c" != 000 ]; then good=$((good+1)); else s=0; fi
        speeds="$speeds $s"
      done
      [ $((good * 2)) -gt "$TUNE_TRIES" ] && opened=$((opened+1))
      # median: the middle one of the sorted speeds (a failed try counts as 0)
      [ "$name" = YouTube ] && speed=$(echo $speeds | tr ' ' '\n' | sort -n | sed -n "$(( (TUNE_TRIES + 1) / 2 ))p")
    done
    echo "$opened $total ${speed:-0}"
  }
}

tune_apply() {   # tune_apply ARGS -> restart zapret with these NFQWS_ARGS; 0 if it runs
  nfq_set_args "$NFQ_CONF" "$1" || return 1
  pf_zapret_restart </dev/null       # stdin is the list of ways being read: not for the init script
  sleep 2
  pf_zapret_running
}

tune_restore() {
  [ -f "$TUNE_SAVED" ] || return 0
  tune_back "$TUNE_SAVED"
}

# tune_back FILE: put these settings back and make sure zapret runs again; say so loudly if it does not
tune_back() {
  cp "$1" "$NFQ_CONF"
  pf_zapret_restart </dev/null
  i=0; while [ $i -lt 5 ]; do pf_zapret_running && return 0; sleep 1; i=$((i+1)); done
  pf_zapret_restart </dev/null; sleep 3
  pf_zapret_running && return 0
  bad "zapret не запустился даже с прежними настройками (они на месте). Перезагрузите роутер; если не поможет — отчёт для диагностики"
  return 1
}

tune_mix() {   # tune_mix "steps1" "steps2" ... -> NFQWS_ARGS with circular over the given ways
  a="$TUNE_PRE $TUNE_CIRCULAR"; n=0
  for steps; do
    n=$((n+1))
    for s in $steps; do a="$a --lua-desync=$s:strategy=$n"; done
  done
  case " $* " in *" $TUNE_ALWAYS "*) ;; *) a="$a --lua-desync=$TUNE_ALWAYS:strategy=$((n+1))" ;; esac
  echo "$a $TUNE_POST"
}

# tune_video on|off: the profile for YouTube video servers. Only an empty NFQWS_ARGS_CUSTOM or switchback's own
# profile is replaced: settings someone wrote there by hand stay.
tune_video() {
  hr "zapret: отдельные способы для серверов видео YouTube"
  pf_zapret_installed || { bad "zapret не установлен"; return 1; }
  want=$(tune_video_args); now=$(nfq_get NFQWS_ARGS_CUSTOM)
  if [ -z "$now" ] && grep -q '^NFQWS_ARGS_CUSTOM="[^"]*$' "$NFQ_CONF" 2>/dev/null; then now="(несколько строк)"; fi
  case $1 in
    on)  if [ "$now" = "$want" ]; then skip "уже включено"; ev tune_video on exists; return 0; fi
         [ -z "$now" ] || { bad "в NFQWS_ARGS_CUSTOM уже есть свои настройки: не трогаю (уберите их, если нужны способы switchback)"; ev tune_video on foreign; return 1; }
         new=$want ;;
    off) if [ -z "$now" ]; then skip "и так выключено"; ev tune_video off none; return 0; fi
         [ "$now" = "$want" ] || { bad "в NFQWS_ARGS_CUSTOM настройки не от switchback: не трогаю"; ev tune_video off foreign; return 1; }
         new="" ;;
    *)   say "Нужно: tune video on или tune video off"; return 2 ;;
  esac
  if [ "$DRY" = 1 ]; then dry "записать в NFQWS_ARGS_CUSTOM: ${new:-пусто} и перезапустить zapret"; return 0; fi
  pf_zapret_conf_backup; remember "nfqws_conf"           # uninstall returns the original settings
  mkdir -p "$SB_DIR"; cp "$NFQ_CONF" "$SB_DIR/nfqws2.conf.before-video"
  nfq_set_key "$NFQ_CONF" NFQWS_ARGS_CUSTOM "$new"
  pf_zapret_restart; sleep 2
  if pf_zapret_running; then
    if [ "$1" = on ]; then ok "включено: $(printf '%s\n' "$TUNE_VIDEO_WAYS" | wc -l | tr -d ' ') способов по кругу для googlevideo.com"
    else ok "выключено: серверы видео идут по общим настройкам zapret"; fi
    ev tune_video "$1" done; log "tune video $1"; return 0
  fi
  tune_back "$SB_DIR/nfqws2.conf.before-video"
  bad "zapret не запустился с новыми настройками: вернул как было"; ev tune_video "$1" failed; return 1
}

do_tune() {
  TUNE_SAVED=$SB_DIR/nfqws2.conf.before-tune
  set -- $SITES_ARGS
  if [ "$1" = video ]; then tune_video "$2"; return $?; fi
  [ -z "$1" ] || { say "Неизвестное действие: $1 (tune, tune --undo, tune video on|off)"; return 2; }
  hr "Подбор настроек zapret"
  pf_zapret_installed || { bad "zapret не установлен"; return 1; }
  if [ "$TUNE_UNDO" = 1 ]; then
    [ -f "$TUNE_SAVED" ] || { bad "подбор ещё не делался: возвращать нечего"; return 1; }
    [ "$DRY" = 1 ] && { dry "вернуть настройки zapret до подбора"; return 0; }
    tune_restore; ok "настройки zapret возвращены как были до подбора"; ev tune_done undone
    log "tune undone"; return 0
  fi
  grep -q '^NFQWS_ARGS="' "$NFQ_CONF" 2>/dev/null || { bad "настройки zapret в незнакомом виде ($NFQ_CONF): подбирать не берусь"; return 1; }
  command -v curl >/dev/null 2>&1 || { bad "нет curl: нечем проверять сайты"; return 1; }
  # zapret that does not run now may not start again either: then do not touch it at all
  pf_zapret_running || { bad "zapret сейчас не работает: сначала разберитесь с этим (экран «Статус»), подбор не начинаю"; return 1; }
  n=$(printf '%s\n' "$TUNE_WAYS" | wc -l | tr -d ' ')
  say "  Проверю $n способов. Это займёт 3–8 минут; YouTube и другие сайты дома в это время могут"
  say "  подтормаживать на несколько секунд."
  if [ "$DRY" = 1 ]; then
    dry "по очереди включить $n способов, измерить YouTube, Instagram, Discord и записать лучшие три"
    return 0
  fi
  mkdir -p "$SB_DIR"
  pf_zapret_conf_backup; remember "nfqws_conf"          # uninstall still returns the original settings
  # the job that sends cut-off servers through the tunnel waits: trial settings that do not work look like a cut-off
  [ "$DRY" = 1 ] || date +%s > "$SB_DIR/tune.running"
  remember "file $TUNE_SAVED"
  cp "$NFQ_CONF" "$TUNE_SAVED.now"
  trap 'tune_back "$TUNE_SAVED.now"; rm -f "$TUNE_SAVED.now"; say ""; say "Прервано: настройки zapret возвращены."; exit 1' INT TERM HUP

  set -- $(tune_measure); b_open=$1; b_total=$2; b_speed=$3
  [ "$b_total" -gt 0 ] || { cp "$TUNE_SAVED.now" "$NFQ_CONF"; rm -f "$TUNE_SAVED.now"; trap - INT TERM HUP
    bad "ни одного из проверочных сайтов (YouTube, Instagram, Discord) нет в списке zapret"; return 1; }
  say "  Сейчас: открылось $b_open из $b_total, YouTube $((b_speed / 1024)) КБ/с"
  ev tune_res "сейчас" "$b_open" "$b_total" "$b_speed"

  i=0; results=""
  while IFS='|' read -r name steps; do
    [ -n "$name" ] || continue
    i=$((i+1)); ev tune_try "$i" "$n" "$name"
    args="$TUNE_PRE"; for s in $steps; do args="$args --lua-desync=$s"; done; args="$args $TUNE_POST"
    if ! tune_apply "$args"; then skip "$name: zapret с ним не запускается"; ev tune_res "$name" 0 "$b_total" 0; continue; fi
    set -- $(tune_measure)
    if [ "$1" = "$2" ]; then ok "$name: открылось $1 из $2, YouTube $(($3 / 1024)) КБ/с"
    else skip "$name: открылось $1 из $2"; fi
    ev tune_res "$name" "$1" "$2" "$3"
    results="$results
$1 $3 $name"
  done <<EOF
$TUNE_WAYS
EOF

  # the best: everything opened, fastest first
  best=$(printf '%s\n' "$results" | awk -v t="$b_total" 'NF && $1 == t' | sort -nr -k2,2 | head -3 | awk '{print $3}')
  top=$(echo "$best" | head -1)
  top_speed=$(printf '%s\n' "$results" | awk -v n="$top" '$3 == n {print $2}')
  if [ -z "$top" ] || { [ "$b_open" = "$b_total" ] && [ "${top_speed:-0}" -le $((b_speed + b_speed * TUNE_GAIN / 100)) ]; }; then
    tune_back "$TUNE_SAVED.now"; rm -f "$TUNE_SAVED.now"; trap - INT TERM HUP
    if [ -z "$top" ]; then warn "ни один способ не открыл все сайты: оставляю как было"
    else ok "лучше, чем сейчас, не нашлось: оставляю как было"; fi
    ev tune_done kept; log "tune: kept the current settings"
    return 0
  fi
  mix=""; names=""
  for nm in $best; do
    steps=$(printf '%s\n' "$TUNE_WAYS" | awk -F'|' -v n="$nm" '$1 == n {print $2}')
    mix="$mix|$steps"; names="$names $nm"
  done
  IFS='|'; set -- ${mix#|}; unset IFS
  if tune_apply "$(tune_mix "$@")"; then
    set -- $(tune_measure)
    mv "$TUNE_SAVED.now" "$TUNE_SAVED"; trap - INT TERM HUP
    ok "записано: $(echo $names | sed 's/ /, /g') (первый — основной, остальные — запасные)"
    say "  Проверка: открылось $1 из $2, YouTube $(($3 / 1024)) КБ/с"
    ev tune_done applied $names
    log "tune: applied$names"
  else
    tune_back "$TUNE_SAVED.now"; rm -f "$TUNE_SAVED.now"; trap - INT TERM HUP
    bad "zapret не запустился с подобранными настройками: вернул как было"; ev tune_done kept; return 1
  fi
  return 0
}
