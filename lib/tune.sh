# "install.sh tune": pick zapret's way of getting past the provider's filter (nfqws2, the TLS part).
# When the provider changes its filter, YouTube and the rest start to stall although zapret runs: the way
# it disguises the traffic stopped working. This command tries a set of known ways one by one: for each it
# restarts zapret and measures from the router how YouTube, Instagram and Discord open (the router's own
# traffic goes through zapret too). The best three that open everything are written in, best first, under
# "circular" — zapret moves to the next one by itself when one stops working for a site.
# If nothing is better than what is there now, nothing changes. During the test (4-11 minutes) those sites
# may stall for a few seconds at a time for everyone at home.
#   tune          pick and apply              tune --undo   back to the settings before the last pick
#   tune video on|off                         tune quic status|next|undo   (both further below)

TUNE_PRE="--filter-tcp=443,80,1984,5222 --filter-l7=http,tls,mtproto --payload=tls_client_hello,mtproto_initial"
TUNE_POST="--payload=http_req --lua-desync=http_methodeol:badsum"
TUNE_CIRCULAR="--lua-desync=circular:fails=2:time=300:retrans=3:nld=2"
# the circle of the video servers counts failures by the whole server name (no nld): each video server keeps
# the way that works for it (nfqws2 zapret-auto.lua standard_hostkey: the full host name unless nld is given)
TUNE_VIDEO_CIRCULAR="--lua-desync=circular:fails=2:time=300:retrans=3"
# always the last way of the mix, after the picked ones: seen on a real router (2026-11-16), the YouTube app's
# own server (youtubei.googleapis.com) opened with none of the picked ways and with this one at once (the way
# a working zapret on a computer at home used for Google); zapret gets to it by itself after the others fail
TUNE_ALWAYS="hostfakesplit:host=www.google.com:tcp_ts=-600000"
# TUNE_WAYS: lists/tune.ways, NAME|STEPS lines (lists_load in lib/common.sh)
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
# TUNE_VIDEO_WAYS: lists/tune-video.ways, one way per line (lists_load in lib/common.sh)

# QUIC (UDP 443: the YouTube app on a phone fetches video so): zapret's NFQWS_ARGS_QUIC. The router cannot test
# QUIC itself (its curl has no HTTP/3), but the kernel counts bytes per connection: seen on a real router
# (2026-11-18), with the package's way Google's far video servers sent a phone 0-15 KB over QUIC, with the first
# way below - megabytes. "tune quic next" moves to the next way of the list, "tune quic status" shows how many
# bytes each server sent the devices at home over UDP 443 (watch a video on the phone for a minute or two first).
#   tune quic status|next|undo
TUNE_QUIC_OLD="fake:blob=quic_initial:repeats=11"     # the package's way: replaced by the first one on update
# one way per line, its desync steps separated by spaces; ip_autottl (zapret-lib.lua) and the fake_default_quic
# blob (built into nfqws2) checked in nfqws2's own files; the udplen way is from Zapret GUI's catalog (udp.txt)
# with the built-in blob instead of its own file
TUNE_QUIC_WAYS="fake:blob=quic_initial:ip_autottl=-2,3-20:repeats=10
fake:blob=fake_default_quic:repeats=12
fake:blob=quic_initial:repeats=11
fake:blob=fake_default_quic:repeats=6 udplen:increment=2"

# nfq_get_any KEY: the value of KEY="..." in $NFQ_CONF on one line, also when it is written on several
nfq_get_any() {
  awk -v k="$1" '
    on { v = v " " $0; if ($0 ~ /"[ \t]*$/) { on = 0; done = 1 }; next }
    !done && index($0, k "=\"") == 1 { v = substr($0, length(k) + 3); if (v ~ /"[ \t]*$/) done = 1; else on = 1 }
    END { sub(/"[ \t]*$/, "", v); gsub(/[ \t]+/, " ", v); sub(/^ /, "", v); sub(/ $/, "", v); print v }' "${2:-$NFQ_CONF}" 2>/dev/null
}
# quic_steps VALUE: its desync steps ("--lua-desync=" taken off), separated by spaces
quic_steps() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n 's/^--lua-desync=//p' | tr '\n' ' ' | sed 's/ *$//'; }
# quic_with VALUE "STEPS": VALUE with its desync steps replaced by STEPS (where the first one was)
quic_with() {
  printf '%s\n' "$1" | awk -v s="$2" '{
    for (i = 1; i <= NF; i++)
      if ($i ~ /^--lua-desync=/) { if (!d) { n = split(s, a, " "); for (j = 1; j <= n; j++) o = o " --lua-desync=" a[j]; d = 1 } }
      else o = o " " $i
    sub(/^ /, "", o); print o }'
}
# quic_index "STEPS": the number of this way in TUNE_QUIC_WAYS, 0 when it is not there
quic_index() { printf '%s\n' "$TUNE_QUIC_WAYS" | awk -v s="$1" '$0 == s { print NR; f = 1; exit } END { if (!f) print 0 }'; }
# quic_ours VALUE: one profile, its way one of the list (or none at all to compare with): may be changed
quic_ours() {
  case " $1 " in *" --new "*) return 1 ;; esac
  [ "$(quic_index "$(quic_steps "$1")")" -gt 0 ]
}

# quic_default: on install and update the package's QUIC way gives way to the first one of the list; a way someone
# chose (by hand or by "tune quic next") stays. 0 when it was changed (zapret then needs a restart)
quic_default() {
  [ -f "$NFQ_CONF" ] || return 1
  qd=$(nfq_get_any NFQWS_ARGS_QUIC)
  case " $qd " in *" --new "*) return 1 ;; esac
  [ -n "$qd" ] && [ "$(quic_steps "$qd")" = "$TUNE_QUIC_OLD" ] || return 1
  qn=$(quic_with "$qd" "$(printf '%s\n' "$TUNE_QUIC_WAYS" | head -n 1)")
  if [ "$DRY" = 1 ]; then dry "zapret: новый способ для QUIC (видео в приложении YouTube на телефоне)"; return 1; fi
  pf_zapret_conf_backup; remember "nfqws_conf"           # uninstall returns the original settings
  mkdir -p "$SB_DIR"; cp "$NFQ_CONF" "$SB_DIR/nfqws2.conf.before-quic-default"
  nfq_set_key "$NFQ_CONF" NFQWS_ARGS_QUIC "$qn"
  ok "zapret: новый способ для QUIC (видео в приложении YouTube на телефоне)"
  log "quic: the package's way replaced by $(printf '%s\n' "$TUNE_QUIC_WAYS" | head -n 1)"
  return 0
}
# quic_default_apply: quic_default on an update; zapret restarted if it runs, the settings back if it does not start
quic_default_apply() {
  pf_zapret_installed || return 0
  grep -q '^nfqws_conf\|^pkg nfqws2' "$STATE" 2>/dev/null || return 0     # zapret is not switchback's to tend
  quic_default || return 0
  pf_zapret_running || return 0
  pf_zapret_restart </dev/null; sleep 2
  pf_zapret_running && return 0
  tune_back "$SB_DIR/nfqws2.conf.before-quic-default" && warn "zapret не запустился с новым способом для QUIC: вернул как было"
  return 0
}

# quic_bytes: what each server sent the devices at home over UDP 443 (the kernel's table of connections, bytes
# counted when nf_conntrack_acct is on): the biggest 8, and a verdict
quic_bytes() {
  qf=${SB_CONNTRACK:-/proc/net/nf_conntrack}
  [ -r "$qf" ] || { warn "таблица соединений роутера недоступна: оценить нечем"; return 0; }
  [ "$(cat "${SB_CONNTRACK_ACCT:-/proc/sys/net/netfilter/nf_conntrack_acct}" 2>/dev/null)" = 0 ] &&
    { warn "роутер не считает байты соединений (nf_conntrack_acct=0): оценить нечем"; return 0; }
  qb=$(awk '$3 == "udp" && / dport=443 / {
      src = ""; dst = ""; nb = 0; b = 0
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^src=/ && src == "") src = substr($i, 5)
        if ($i ~ /^dst=/ && dst == "") dst = substr($i, 5)
        if ($i ~ /^bytes=/) { nb++; if (nb == 2) b = substr($i, 7) + 0 }
      }
      if (src ~ /^192[.]168[.]/ || src ~ /^10[.]/ || src ~ /^172[.](1[6-9]|2[0-9]|3[01])[.]/) s[dst] += b
    }
    END { for (d in s) print s[d], d }' "$qf" 2>/dev/null | sort -nr)
  if [ -z "$qb" ]; then say "  Соединений QUIC от устройств дома сейчас нет: включите видео на телефоне и проверьте через минуту."; return 0; fi
  say "  Сколько прислали серверы по QUIC (UDP 443) устройствам дома:"
  printf '%s\n' "$qb" | head -n 8 | while read -r b d; do say "    $d — $((b / 1024)) КБ"; done
  qbig=$(printf '%s\n' "$qb" | awk '$1 >= 1048576' | wc -l | tr -d ' ')
  qsmall=$(printf '%s\n' "$qb" | awk '$1 < 102400' | wc -l | tr -d ' ')
  if [ "$qbig" -gt 0 ]; then ok "серверов, приславших больше 1 МБ: $qbig — QUIC проходит"
  else warn "ни один сервер не прислал и 1 МБ (меньше 100 КБ: $qsmall) — похоже, QUIC не проходит: попробуйте другой способ (tune quic next)"; fi
  ev quic_bytes "$qbig" "$qsmall"
}

# tune_quic status|next|undo
tune_quic() {
  hr "zapret: способ для QUIC (видео в приложении YouTube на телефоне)"
  pf_zapret_installed || { bad "zapret не установлен"; return 1; }
  qs=$SB_DIR/nfqws2.conf.before-quic
  qnow=$(nfq_get_any NFQWS_ARGS_QUIC); qsteps=$(quic_steps "$qnow"); qi=$(quic_index "$qsteps")
  qt=$(printf '%s\n' "$TUNE_QUIC_WAYS" | wc -l | tr -d ' ')
  case $1 in
    ""|status)
      if [ -z "$qnow" ]; then say "  В настройках zapret нет NFQWS_ARGS_QUIC: QUIC он не трогает."
      elif [ "$qi" -gt 0 ]; then say "  Сейчас способ $qi из $qt: $qsteps"
      else say "  Сейчас свой способ (не из списка switchback): ${qsteps:-без подмены}"; fi
      quic_bytes; return 0 ;;
    next)
      [ -n "$qnow" ] || { bad "в настройках zapret нет NFQWS_ARGS_QUIC: менять нечего"; return 1; }
      quic_ours "$qnow" || { bad "в NFQWS_ARGS_QUIC свои настройки (не из списка switchback): не трогаю"; ev tune_quic next foreign; return 1; }
      qn=$((qi % qt + 1)); qw=$(printf '%s\n' "$TUNE_QUIC_WAYS" | sed -n "${qn}p")
      if [ "$DRY" = 1 ]; then dry "включить способ $qn из $qt: $qw и перезапустить zapret"; return 0; fi
      pf_zapret_conf_backup; remember "nfqws_conf"       # uninstall returns the original settings
      mkdir -p "$SB_DIR"
      # "undo" goes back to what was before the first "next" of a row
      [ -f "$qs" ] || { cp "$NFQ_CONF" "$qs"; remember "file $qs"; }
      cp "$NFQ_CONF" "$qs.now"
      nfq_set_key "$NFQ_CONF" NFQWS_ARGS_QUIC "$(quic_with "$qnow" "$qw")"
      pf_zapret_restart; sleep 2
      if pf_zapret_running; then
        rm -f "$qs.now"
        ok "включён способ $qn из $qt: $qw"
        say "  Посмотрите видео на телефоне минуту-две и проверьте (tune quic status): сколько прислали серверы."
        say "  Не лучше — следующий способ (tune quic next); вернуть как было — tune quic undo."
        ev tune_quic next "$qn"; log "tune quic: way $qn of $qt"; return 0
      fi
      tune_back "$qs.now"; rm -f "$qs.now"
      bad "zapret не запустился с этим способом: вернул как было"; ev tune_quic next failed; return 1 ;;
    undo)
      [ -f "$qs" ] || { bad "способ для QUIC ещё не меняли: возвращать нечего"; return 1; }
      if [ "$DRY" = 1 ]; then dry "вернуть способ для QUIC, какой был до перебора"; return 0; fi
      qold=$(nfq_get_any NFQWS_ARGS_QUIC "$qs")
      cp "$NFQ_CONF" "$qs.now"
      nfq_set_key "$NFQ_CONF" NFQWS_ARGS_QUIC "$qold"
      pf_zapret_restart; sleep 2
      if pf_zapret_running; then
        rm -f "$qs" "$qs.now"
        ok "способ для QUIC возвращён, какой был до перебора: $(quic_steps "$qold")"
        ev tune_quic undo done; log "tune quic undone"; return 0
      fi
      tune_back "$qs.now"; rm -f "$qs.now"
      bad "zapret не запустился с прежним способом: оставил текущий"; ev tune_quic undo failed; return 1 ;;
    *) say "Нужно: tune quic status, tune quic next или tune quic undo"; return 2 ;;
  esac
}

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
  a="$TUNE_VIDEO_PRE $TUNE_VIDEO_CIRCULAR"; n=0
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    n=$((n+1)); for s in $l; do a="$a --lua-desync=$s:strategy=$n"; done
  done <<EOF
$TUNE_VIDEO_WAYS
EOF
  echo "$a"
}
# tune_video_ours VALUE: switchback's own video profile, this version's or an earlier one (same first part)
tune_video_ours() { case $1 in "$TUNE_VIDEO_PRE "*) return 0 ;; esac; return 1; }

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
         [ -z "$now" ] || tune_video_ours "$now" || { bad "в NFQWS_ARGS_CUSTOM уже есть свои настройки: не трогаю (уберите их, если нужны способы switchback)"; ev tune_video on foreign; return 1; }
         new=$want ;;
    off) if [ -z "$now" ]; then skip "и так выключено"; ev tune_video off none; return 0; fi
         tune_video_ours "$now" || { bad "в NFQWS_ARGS_CUSTOM настройки не от switchback: не трогаю"; ev tune_video off foreign; return 1; }
         new="" ;;
    *)   say "Нужно: tune video on или tune video off"; return 2 ;;
  esac
  if [ "$DRY" = 1 ]; then dry "записать в NFQWS_ARGS_CUSTOM: ${new:-пусто} и перезапустить zapret"; return 0; fi
  pf_zapret_conf_backup; remember "nfqws_conf"           # uninstall returns the original settings
  mkdir -p "$SB_DIR"; cp "$NFQ_CONF" "$SB_DIR/nfqws2.conf.before-video"
  nfq_set_key "$NFQ_CONF" NFQWS_ARGS_CUSTOM "$new"
  pf_zapret_restart; sleep 2
  if pf_zapret_running; then
    if [ "$1" = on ]; then vw=включено; [ -n "$now" ] && vw=обновлено; ok "$vw: $(printf '%s\n' "$TUNE_VIDEO_WAYS" | wc -l | tr -d ' ') способов по кругу для googlevideo.com (у каждого сервера видео — свой)"
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
  if [ "$1" = quic ]; then tune_quic "$2"; return $?; fi
  [ -z "$1" ] || { say "Неизвестное действие: $1 (tune, tune --undo, tune video on|off, tune quic status|next|undo)"; return 2; }
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
  say "  Проверю $n способов. Это займёт 4–11 минут; YouTube и другие сайты дома в это время могут"
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
  trap 'tune_back "$TUNE_SAVED.now"; rm -f "$TUNE_SAVED.now" "$SB_DIR/tune.running"; say ""; say "Прервано: настройки zapret возвращены."; exit 1' INT TERM HUP

  set -- $(tune_measure); b_open=$1; b_total=$2; b_speed=$3
  [ "$b_total" -gt 0 ] || { cp "$TUNE_SAVED.now" "$NFQ_CONF"; rm -f "$TUNE_SAVED.now"; trap - INT TERM HUP; rm -f "$SB_DIR/tune.running"
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
    tune_back "$TUNE_SAVED.now"; rm -f "$TUNE_SAVED.now"; trap - INT TERM HUP; rm -f "$SB_DIR/tune.running"
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
    mv "$TUNE_SAVED.now" "$TUNE_SAVED"; trap - INT TERM HUP; rm -f "$SB_DIR/tune.running"
    ok "записано: $(echo $names | sed 's/ /, /g') (первый — основной, остальные — запасные)"
    say "  Проверка: открылось $1 из $2, YouTube $(($3 / 1024)) КБ/с"
    ev tune_done applied $names
    log "tune: applied$names"
  else
    tune_back "$TUNE_SAVED.now"; rm -f "$TUNE_SAVED.now"; trap - INT TERM HUP; rm -f "$SB_DIR/tune.running"
    bad "zapret не запустился с подобранными настройками: вернул как было"; ev tune_done kept; return 1
  fi
  return 0
}
