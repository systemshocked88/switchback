# "install.sh sites": your own sites in the bypass, each by one of three ways:
#   zapret  the site is slowed down or cut off by the provider's filter (like YouTube): add it to zapret's list
#   dns     the site says "not available in your country" (like ChatGPT): ask the DNS proxy service for it
#   vpn     the site is blocked outright (like Telegram): its addresses go through the VPN tunnel
# The VPN way works on any firmware version: the router looks up the site's addresses and routes each one
# through the tunnel Telegram uses; a job every 5 minutes adds the new addresses (big sites change them).
#
#   sites [list]              what was added (and what is built in)
#   sites add DOMAIN --via zapret|dns|vpn [--dns-like DOMAIN]
#   sites del DOMAIN          remove a site added here
#   sites check DOMAIN        does it open from the router now
#   sites refresh             (the 5-minute job) routes for new addresses of the VPN sites
#   sites video on|off        servers the provider cuts off go through the tunnel by themselves: every minute
#                             the router looks for HTTPS servers that devices at home get no answer from; a
#                             server that is silent directly but answers through the tunnel gets a route there
#                             ("rescue video" in the file, routes "IP video"). Two kinds are caught: a server
#                             cut off by its address (any site), and a YouTube video server cut off by name.
#                             The name "video" stays from the first version, which knew YouTube only.
# Files: $SB_DIR/sites ("WAY DOMAIN" lines), $SB_DIR/sites.routes ("IP DOMAIN": routes made for VPN sites).
# Journal: "site WAY DOMAIN" — uninstall takes the site out the same way "sites del" does.

SITES_MAX_IPS=24              # routes per VPN site at most (CDNs hand out many addresses)

VIDEO_HOST=rr1---sn-4g5e6nzz.googlevideo.com   # a name every YouTube video server answers to (its certificate fits)
VIDEO_MAX=60                  # routes for cut-off servers at most: the oldest one goes when a new one comes
VIDEO_TRY=${SB_VIDEO_TRY:-6}                  # servers checked in one run at most (a check is two or three requests)
VIDEO_AGAIN=600               # a server checked once is not checked again for this many seconds...
VIDEO_AGAIN_DEAD=3600         # ...and one that is silent through the tunnel too (it is simply down), for this many
VIDEO_QUIET=900               # no checks for this long after "tune" started: its trial settings look like a cut-off
VIDEO_DIRECT=3                # silent directly this many times in a row, a few seconds apart, before the tunnel:
                              # zapret switches its way after a failure or two (seen 2026-11-16: a test of settings
                              # on a computer at home made zapret fail for a while, and working Google servers went
                              # to the tunnel - YouTube then showed ads as abroad)
VIDEO_BUDGET=40               # seconds one run may spend on checks (the job runs every minute)
VIDEO_RECHECK=3600            # a routed server is checked through the tunnel again after this many seconds...
VIDEO_PRUNE=2                 # ...this many in one run at most; silent there twice in a row: the route goes
VIDEO_NAME_TTL=${SB_VIDEO_NAME_TTL:-21600}   # a server routed for its name (it answers by its address) goes back
                              # to the direct way after 6 hours and is checked anew: the provider's cut-off of a
                              # name comes and goes, and zapret may have found a way meanwhile
VIDEO_EXPIRE=10               # ...this many such routes taken away in one run at most
VIDEO_TELL_GAP=21600          # "zapret does not pass YouTube": a message once in this many seconds at most
# Seen 2026-11-17 00:02-00:25: zapret did not pass the video name for 25 minutes, and 11 ordinary Google
# servers (the sites, the YouTube app) went to the slow tunnel as "cut off". So a name that is silent through
# zapret is first asked of a control server too (VIDEO_HOST's own address or www.google.com's): silent as well
# means zapret itself fails - no route, a message to the owner instead.

sites_files() { SITES=$SB_DIR/sites; SITES_ROUTES=$SB_DIR/sites.routes; VIDEO_SEEN=$SB_DIR/video.seen; VIDEO_KIND=$SB_DIR/video.kind; }

site_norm() {   # what people paste: https://www.Site.com/path -> site.com
  printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -e 's#^[a-z]*://##' -e 's#[/?:#].*$##' -e 's/^www\.//' -e 's/\.$//'
}
site_valid() {
  case $1 in ''|*[!a-z0-9.-]*|.*|*..*|-*|*.-*|*-.*) return 1 ;; esac
  case $1 in *.*) return 0 ;; esac
  return 1
}
site_builtin() {   # built into switchback's own modules
  for b in $ZAPRET_DOMAINS $DNS_CHATGPT $DNS_CLAUDE telegram.org t.me; do
    [ "$1" = "$b" ] && return 0
    case $1 in *".$b") return 0 ;; esac
  done
  return 1
}
site_way() { awk -v d="$1" '$2 == d {print $1; exit}' "$SITES" 2>/dev/null; }

# site_ips DOMAIN: its IPv4 addresses as the router's DNS sees them
site_ips() {
  nslookup "$1" 127.0.0.1 2>/dev/null | awk '/^Name:/ {n=1}
    n && /^Address/ { for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print $i }' |
    grep -v '^127\.\|^0\.' | sort -u
}
# the tunnel for VPN sites: the one Telegram goes through now (follows the failover), else the first live one
sites_tunnel() {
  t=$(tg_via)
  [ -n "$t" ] && pf_vpn_ifaces | grep -qx "$t" && { echo "$t"; return; }
  for w in $(pf_vpn_ifaces); do pf_vpn_alive "$w" && { echo "$w"; return; }; done
}

# vpn_routes DOMAIN TUNNEL: a route through TUNNEL for each address not routed yet; how many: $added
# (called directly, not in $(...): CLI_CHANGED must reach save_if_changed)
vpn_routes() {
  added=0; covered=0
  have=$(awk -v d="$1" '$2 == d' "$SITES_ROUTES" 2>/dev/null | wc -l)
  for ip in $(site_ips "$1"); do
    [ "$have" -ge "$SITES_MAX_IPS" ] && break
    grep -q "^$ip " "$SITES_ROUTES" 2>/dev/null && { covered=$((covered+1)); continue; }   # made for another site already
    v=$(pf_route_via "$ip" 255.255.255.255)
    if [ "$v" = "$2" ]; then covered=$((covered+1)); continue; fi   # through this tunnel already (another site shares it)
    [ -n "$v" ] && continue      # routed elsewhere already (by hand or by someone else)
    pf_route_add "$ip" 255.255.255.255 "$2" || continue
    [ "$DRY" = 1 ] || printf '%s %s\n' "$ip" "$1" >> "$SITES_ROUTES"
    added=$((added+1)); have=$((have+1)); CLI_CHANGED=1
  done
}

# the job that adds new addresses of VPN sites (every minute by cron, works every 5th) and, when
# "sites video on" was given, looks every minute for YouTube video servers that got cut off
sites_job() {
script_subst <<'EOF'
#!/bin/sh
# Own sites through VPN (switchback): every 5 minutes, routes for new addresses of those sites;
# every minute, YouTube video servers that stopped answering directly (if "sites video on").
export PATH=__PATH__
[ -f __CONF__/app/install.sh ] || exit 0
m=$(date +%M); m=${m#0}
if [ $((m % 5)) = 0 ] && grep -q -e '^vpn ' -e '^rescue ' __CONF__/sites 2>/dev/null; then what=""
elif grep -q '^rescue ' __CONF__/sites 2>/dev/null; then what=video
else exit 0; fi
sh __CONF__/app/install.sh sites refresh $what --plain >/dev/null 2>&1
exit 0
EOF
}

# video_stuck: addresses of HTTPS servers that devices at home get no answer from, out of the kernel's table of
# connections: no reply at all, or a request went out (1000+ bytes) and next to nothing came back
video_stuck() {
  vf=${SB_CONNTRACK:-/proc/net/nf_conntrack}; [ -r "$vf" ] || return 0
  awk '$3 == "tcp" && / dport=443 / {
    dst = ""; nb = 0; b1 = 0; b2 = 0
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^dst=/ && dst == "") dst = substr($i, 5)
      if ($i ~ /^bytes=/) { nb++; if (nb == 1) b1 = substr($i, 7) + 0; if (nb == 2) b2 = substr($i, 7) + 0 }
    }
    if (/UNREPLIED/ || (nb == 2 && b1 >= 1000 && b2 <= 400)) print dst
  }' "$vf" 2>/dev/null |
    grep -v -e '^10[.]' -e '^192[.]168[.]' -e '^127[.]' -e '^172[.]1[6-9][.]' -e '^172[.]2[0-9][.]' -e '^172[.]3[01][.]' -e '^169[.]254[.]' |
    sort -u
}
# video_probe IP [DEVICE]: the answer code of a YouTube video server at IP (through DEVICE if given, else the
# way devices at home go: through zapret); 000 when there is no answer
video_probe() {
  vp=$1
  if [ -n "$2" ]; then set -- --interface "$2"; else set -- $ZCURL; fi
  curl -s -o /dev/null --max-time 6 "$@" --resolve "$VIDEO_HOST:443:$vp" -w '%{http_code}' "https://$VIDEO_HOST/generate_204" 2>/dev/null
}
# addr_probe IP [DEVICE]: does the server at IP finish a TLS handshake (by address alone, no site name)?
# Prints the handshake time, 0.000000 when there was none.
addr_probe() {
  ap=$1
  if [ -n "$2" ]; then set -- --interface "$2"; else set -- $ZCURL; fi
  curl -sk -o /dev/null --max-time 5 "$@" -w '%{time_appconnect}' "https://$ap/" 2>/dev/null
}
addr_answers() { awk -v t="$(addr_probe "$@")" 'BEGIN { sub(",", ".", t); exit !(t + 0 > 0) }'; }   # was there a handshake
addr_silent() { ! addr_answers "$1"; }                       # no handshake directly (through zapret)
video_silent() { [ "$(video_probe "$1")" = 000 ]; }          # no answer from the video server directly
# video_direct_dead CHECK IP: CHECK (addr_silent or video_silent) holds VIDEO_DIRECT times in a row, a pause between
video_direct_dead() {
  vd=0
  while [ "$vd" -lt "$VIDEO_DIRECT" ]; do
    "$1" "$2" || return 1
    vd=$((vd+1)); [ "$vd" -lt "$VIDEO_DIRECT" ] && sleep "${SB_VIDEO_PAUSE:-3}"
  done
  return 0
}
# in_nets IP "NET/BITS ...": is IP inside one of the address ranges
in_nets() {
  awk -v ip="$1" -v nets="$2" 'function n(a,  p) { split(a, p, "."); return ((p[1] * 256 + p[2]) * 256 + p[3]) * 256 + p[4] }
    BEGIN { x = n(ip); c = split(nets, l, " ")
      for (i = 1; i <= c; i++) { split(l[i], q, "/"); s = n(q[1]); if (x >= s && x < s + 2 ^ (32 - q[2])) exit 0 }
      exit 1 }'
}
# video_seen IP KIND: remember when IP was checked (KIND "dead": silent through the tunnel too)
video_seen() {
  [ "$DRY" = 1 ] && return 0
  { grep -v "^$1 " "$VIDEO_SEEN" 2>/dev/null | tail -n 200; echo "$1 $vnow $2"; } > "$VIDEO_SEEN.tmp"; mv "$VIDEO_SEEN.tmp" "$VIDEO_SEEN"
}
# video_rescue TUNNEL: stuck servers that are silent directly and answer through the tunnel get a route there; $vnew
video_rescue() {
  vnew=0; vn=0; vdev=$(pf_wg_dev "$1"); vnow=$(date +%s)
  vq=$(cat "$SB_DIR/tune.running" 2>/dev/null)
  [ -n "$vq" ] && [ $((vnow - vq)) -lt "$VIDEO_QUIET" ] && return 0      # "tune" is trying settings: wait
  video_prune "$1"
  video_expire "$1"
  vctl=; vkind=; vzlog=
  for vip in $(video_stuck); do
    [ "$vn" -ge "$VIDEO_TRY" ] && break
    [ $(($(date +%s) - vnow)) -ge "$VIDEO_BUDGET" ] && break
    grep -q "^$vip " "$SITES_ROUTES" 2>/dev/null && continue
    [ -n "$(pf_route_via "$vip" 255.255.255.255)" ] && continue          # routed already, by hand or by a site
    vlast=$(awk -v i="$vip" '$1 == i {print $2 " " $3}' "$VIDEO_SEEN" 2>/dev/null | tail -n 1)
    vwait=$VIDEO_AGAIN; case $vlast in *" dead") vwait=$VIDEO_AGAIN_DEAD ;; esac
    [ -n "$vlast" ] && [ $((vnow - ${vlast%% *})) -lt "$vwait" ] && continue
    vn=$((vn+1))
    if addr_answers "$vip"; then
      # reachable by its address: only a YouTube video server may still be cut off, by its name; an address
      # outside Google's ranges (Apple, Yandex...) is not one, so no requests are spent on it
      video_seen "$vip" ok
      in_nets "$vip" "${SB_VIDEO_NETS:-$TV_NETS}" || continue
      video_direct_dead video_silent "$vip" || continue                   # answers directly: not cut off
      vc=$(video_probe "$vip" "$vdev")
      [ -n "$vc" ] && [ "$vc" != 000 ] || continue                        # not a video server, or the tunnel does not reach it
      video_control                                                       # is it this server, or zapret itself?
      [ "$vctl" = ok ] || { video_zapret_down "$vip"; continue; }
      vkind=name
    else
      vkind=addr
      # silent by its address: cut off if it stays silent and the same request gets an answer through the tunnel
      if ! video_direct_dead addr_silent "$vip"; then video_seen "$vip" ok; continue; fi
      if addr_answers "$vip" "$vdev"; then video_seen "$vip" ok
      else video_seen "$vip" dead; continue; fi                           # down for everyone: nothing to do
    fi
    while [ "$(awk '$2 == "video"' "$SITES_ROUTES" 2>/dev/null | wc -l)" -ge "$VIDEO_MAX" ]; do   # room for the new one
      vold=$(awk '$2 == "video" {print $1; exit}' "$SITES_ROUTES")
      vvia=$(pf_route_via "$vold" 255.255.255.255); [ -n "$vvia" ] || vvia=$1
      pf_route_del "$vold" 255.255.255.255 "$vvia"
      [ "$DRY" = 1 ] && break
      awk -v i="$vold" '$1 != i' "$SITES_ROUTES" > "$SITES_ROUTES.tmp"; mv "$SITES_ROUTES.tmp" "$SITES_ROUTES"
    done
    pf_route_add "$vip" 255.255.255.255 "$1" || continue
    [ "$DRY" = 1 ] || { echo "$vip video" >> "$SITES_ROUTES"; echo "$vip $vnow $vkind" >> "$VIDEO_KIND"; }
    vnew=$((vnew+1)); CLI_CHANGED=1
    log "server $vip: silent directly, answers through $1 - routed there"
  done
  [ "$vnew" -gt 0 ] && [ "$DRY" != 1 ] && video_tell "$1"
  return 0
}
# video_prune TUNNEL: a routed server that went silent through the tunnel too goes back to the direct way (seen
# 2026-11-16: the provider's own video cache answered through the tunnel once, then never, and devices waited on it).
# Checked once an hour, VIDEO_PRUNE in a run at most; silent twice in a row: the route goes, and the server is
# remembered as "dead", so it is not routed again for VIDEO_AGAIN_DEAD seconds.
video_prune() {
  pdev=$(pf_wg_dev "$1"); pn=0
  for pip in $(awk '$2 == "video" {print $1}' "$SITES_ROUTES" 2>/dev/null); do
    [ "$pn" -ge "$VIDEO_PRUNE" ] && break
    plast=$(awk -v i="$pip" '$1 == i {print $2 " " $3}' "$VIDEO_SEEN" 2>/dev/null | tail -n 1)
    [ -n "$plast" ] && [ $((vnow - ${plast%% *})) -lt "$VIDEO_RECHECK" ] && continue
    pn=$((pn+1))
    if in_nets "$pip" "${SB_VIDEO_NETS:-$TV_NETS}"; then pc=$(video_probe "$pip" "$pdev"); [ -n "$pc" ] && [ "$pc" != 000 ]
    else addr_answers "$pip" "$pdev"; fi && { video_seen "$pip" ok; continue; }
    case $plast in *" gone") ;; *) video_seen "$pip" gone; continue ;; esac     # once may be a hiccup: next hour
    pvia=$(pf_route_via "$pip" 255.255.255.255); [ -n "$pvia" ] || pvia=$1
    pf_route_del "$pip" 255.255.255.255 "$pvia"
    [ "$DRY" = 1 ] || { awk -v i="$pip" '$1 != i' "$SITES_ROUTES" > "$SITES_ROUTES.tmp"; mv "$SITES_ROUTES.tmp" "$SITES_ROUTES"; }
    video_seen "$pip" dead; CLI_CHANGED=1
    log "server $pip: silent through $1 too - route removed"
  done
  return 0
}
# video_control: once a run, ask the video name through zapret of a control server - a Google address that
# works for everyone and is not routed to the tunnel: VIDEO_HOST's own addresses first, then www.google.com's
# (any Google front server answers that name). $vctl: ok (it answers: the stuck server is really cut off),
# bad (silent too: zapret itself does not pass the name now) or none (no such address: nothing is routed)
video_control() {
  [ -n "$vctl" ] && return 0
  vctl=none; vctl_ip=; vct=0
  for c in $(site_ips "$VIDEO_HOST") $(site_ips www.google.com); do
    [ "$vct" -ge 2 ] && break
    [ "$c" = "$vip" ] && continue
    in_nets "$c" "${SB_VIDEO_NETS:-$TV_NETS}" || continue
    [ -n "$(pf_route_via "$c" 255.255.255.255)" ] && continue
    grep -q "^$c " "$SITES_ROUTES" 2>/dev/null && continue
    vct=$((vct+1)); vctl=bad; vctl_ip=$c
    vcc=$(video_probe "$c"); [ -n "$vcc" ] && [ "$vcc" != 000 ] && { vctl=ok; break; }
  done
  return 0
}
# video_zapret_down IP: the control server is silent too (or there is none): no route; a line in the log once a
# run, a message to the owner once in VIDEO_TELL_GAP seconds at most
video_zapret_down() {
  [ -n "$vzlog" ] && return 0
  vzlog=1
  if [ "$vctl" = none ]; then
    log "server $1: silent directly by the video name, but no control server to compare with - not routed"; return 0
  fi
  log "server $1: silent directly by the video name, and so is the control server $vctl_ip - zapret does not pass YouTube now, not routed"
  [ "$DRY" = 1 ] && return 0
  [ -f "$BOT" ] || return 0
  vzt=$(cat "$SB_DIR/video.zapret.told" 2>/dev/null)
  case $vzt in ''|*[!0-9]*) vzt=0 ;; esac
  [ $((vnow - vzt)) -lt "$VIDEO_TELL_GAP" ] && return 0
  echo "$vnow" > "$SB_DIR/video.zapret.told"
  ( . "$BOT"; eval "$(notify_func)"
    sb_send "zapret сейчас не пропускает YouTube: серверы видео молчат напрямую, и обычный сервер Google для сравнения — тоже. Значит, сбой у zapret, а не у серверов, и в медленный туннель я их не увожу. Что делать: нажмите в боте «Подобрать zapret» (/tune) — он найдёт рабочие настройки за несколько минут. Если YouTube и так работает, ничего делать не нужно: это был короткий сбой." ) >/dev/null 2>&1
  return 0
}
# video_expire TUNNEL: what each route of a cut-off server is, in VIDEO_KIND ("IP TIME name|addr"): "name" - it
# answered by its address, only the video name was cut off; "addr" - silent by its address. A "name" route goes
# after VIDEO_NAME_TTL seconds, so the server is checked anew (a cut-off one comes back in the usual way).
# Routes with no line (made before 0.7.5, the night of 2026-11-17 among them) get one now: a Google one counts as
# "name" from this moment, any other as "addr" - so old Google routes are rechecked once, in 6 hours.
video_expire() {
  [ "$DRY" = 1 ] && return 0
  [ -f "$SITES_ROUTES" ] || return 0
  [ -f "$VIDEO_KIND" ] || : > "$VIDEO_KIND"
  awk -v now="$vnow" -v nets="${SB_VIDEO_NETS:-$TV_NETS}" -v kf="$VIDEO_KIND" '
    BEGIN { while ((getline l < kf) > 0) { split(l, a, " "); if (a[1] != "") k[a[1]] = l } }
    function n(a,  p) { split(a, p, "."); return ((p[1] * 256 + p[2]) * 256 + p[3]) * 256 + p[4] }
    function g(ip,  x, c, l, i, q, s) { x = n(ip); c = split(nets, l, " ")
      for (i = 1; i <= c; i++) { split(l[i], q, "/"); s = n(q[1]); if (x >= s && x < s + 2 ^ (32 - q[2])) return 1 }
      return 0 }
    $2 == "video" && !($1 in done) { done[$1] = 1; if ($1 in k) print k[$1]; else print $1, now, (g($1) ? "name" : "addr") }
  ' "$SITES_ROUTES" > "$VIDEO_KIND.tmp" && mv "$VIDEO_KIND.tmp" "$VIDEO_KIND"
  en=0
  for eip in $(awk -v now="$vnow" -v ttl="$VIDEO_NAME_TTL" '$3 == "name" && now - $2 >= ttl {print $1}' "$VIDEO_KIND"); do
    [ "$en" -ge "$VIDEO_EXPIRE" ] && break
    en=$((en+1))
    evia=$(pf_route_via "$eip" 255.255.255.255); [ -n "$evia" ] || evia=$1
    pf_route_del "$eip" 255.255.255.255 "$evia"
    awk -v i="$eip" '$1 != i' "$SITES_ROUTES" > "$SITES_ROUTES.tmp"; mv "$SITES_ROUTES.tmp" "$SITES_ROUTES"
    awk -v i="$eip" '$1 != i' "$VIDEO_KIND" > "$VIDEO_KIND.tmp"; mv "$VIDEO_KIND.tmp" "$VIDEO_KIND"
    video_seen "$eip" ok; CLI_CHANGED=1
    log "server $eip: routed for its name $((VIDEO_NAME_TTL / 3600)) h ago - back to the direct way, to be checked anew"
  done
  return 0
}
# video_tell TUNNEL: a message to the owner, once a day at most (the bot or ntfy, if they are set up)
video_tell() {
  [ -f "$BOT" ] || return 0
  [ "$(cat "$SB_DIR/video.told" 2>/dev/null)" = "$(date +%F)" ] && return 0
  date +%F > "$SB_DIR/video.told"
  ( . "$BOT"; eval "$(notify_func)"
    sb_send "Провайдер заглушил серверы, которыми пользуются устройства дома, — теперь они сами идут через туннель $1 (адресов: $(awk '$2 == "video"' "$SITES_ROUTES" | wc -l | tr -d ' ')). Скорость к ним — скорость туннеля. Делать ничего не нужно." ) >/dev/null 2>&1
  return 0
}
video_on() {
  if grep -qx 'rescue video' "$SITES" 2>/dev/null; then skip "уже включено"; ev site_res video exists rescue; return 0; fi
  [ -n "$(sites_tunnel)" ] || { bad "нет работающего VPN-подключения: подключите WireGuard (как для Telegram)"; return 1; }
  self_install
  pf_cron_setup || { bad "не удалось включить планировщик"; return 1; }
  vt=/tmp/switchback.new.$$; sites_job > "$vt"
  if [ -f "$CRON1/sb-sites" ] && ours "$CRON1/sb-sites"; then refresh_file "$CRON1/sb-sites" "обновление адресов своих сайтов" "$vt"
  else install_file "$CRON1/sb-sites" "обновление адресов (каждую минуту)" "$vt"; fi
  remember "file $SITES"; remember "file $SITES_ROUTES"
  append_line "$SITES" "rescue video"
  remember "site rescue video"
  pf_keep_files
  ok "серверы, которые глушит провайдер (YouTube и любые другие), будут сами уходить в VPN (проверка каждую минуту)"
  ev site_res video added rescue
  log "site added: rescue video"
}

site_add() {   # site_add DOMAIN WAY
  d=$(site_norm "$1"); way=$2
  site_valid "$d" || { bad "«$1» не похоже на адрес сайта (нужно вроде example.com)"; return 1; }
  if site_builtin "$d"; then skip "$d уже в обходе: он встроен в switchback"; ev site_res "$d" builtin; return 0; fi
  w=$(site_way "$d")
  if [ -n "$w" ]; then skip "$d уже добавлен (способ: $w)"; ev site_res "$d" exists "$w"; return 0; fi
  case $way in
    zapret)
      pf_zapret_installed || { bad "zapret не установлен: сначала поставьте его (модуль zapret)"; return 1; }
      if grep -qx "$d" "$NFQ_LIST" 2>/dev/null; then
        skip "$d уже есть в списке zapret (добавлен раньше вручную)"; ev site_res "$d" exists zapret; return 0
      fi
      append_line "$NFQ_LIST" "$d" || return 1
      pf_zapret_restart
      ok "$d добавлен в zapret" ;;
    dns)
      like=$SITE_DNS_LIKE
      [ -n "$like" ] || for c in claude.ai chatgpt.com; do pf_dns_has "$c" && { like=$c; break; }; done
      srv=""; [ -n "$like" ] && srv=$(pf_dns_srv_of "$like")
      [ -n "$srv" ] || { bad "нет DNS-сервера, через который пускать сайт: сначала настройте DNS для ChatGPT или Claude"; return 1; }
      used=$(pf_dns_count)
      if [ "$used" -ge "$DNS_LIMIT" ]; then
        bad "роутер допускает не больше $DNS_LIMIT таких DNS-записей, все заняты. Выберите способ zapret или VPN"; return 1
      fi
      pf_dns_add $srv "$d" || { bad "роутер не принял DNS-запись для $d"; return 1; }
      CLI_CHANGED=1; save_if_changed
      ok "$d $ARROW тот же DNS-сервер, что для $like" ;;
    vpn)
      t=$(sites_tunnel)
      [ -n "$t" ] || { bad "нет работающего VPN-подключения: подключите WireGuard (как для Telegram)"; return 1; }
      [ -n "$(site_ips "$d")" ] || { bad "не удалось узнать адреса $d: проверьте, что адрес написан верно"; return 1; }
      vpn_routes "$d" "$t"
      save_if_changed
      [ "$added" -gt 0 ] || [ "$covered" -gt 0 ] || [ "$DRY" = 1 ] || { bad "все адреса $d уже идут другими маршрутами: менять их не стал"; return 1; }
      ok "$d $ARROW $t (адресов: $added; новые будут добавляться сами каждые 5 минут)"
      self_install
      if [ ! -f "$CRON1/sb-sites" ]; then
        pf_cron_setup || { bad "не удалось включить планировщик"; return 1; }
        t=/tmp/switchback.new.$$; sites_job > "$t"
        install_file "$CRON1/sb-sites" "обновление адресов (каждые 5 минут)" "$t"
      fi ;;
    *) bad "способ должен быть zapret, dns или vpn"; return 1 ;;
  esac
  remember "file $SITES"
  [ "$way" = vpn ] && remember "file $SITES_ROUTES"
  append_line "$SITES" "$way $d"
  remember "site $way $d"
  pf_keep_files
  ev site_res "$d" added "$way"
  log "site added: $way $d"
  return 0
}

# site_undo WAY DOMAIN: take the site out (used by "sites del" and by uninstall)
site_undo() {
  sites_files
  case $1 in
    zapret) pf_list_del "$2"; pf_zapret_restart ;;
    dns)    srv=$(pf_dns_srv_of "$2"); [ -n "$srv" ] && pf_dns_del $srv "$2" ;;
    vpn|rescue)
            for ip in $(awk -v d="$2" '$2 == d {print $1}' "$SITES_ROUTES" 2>/dev/null); do
              via=$(pf_route_via "$ip" 255.255.255.255)
              [ -n "$via" ] || via=$(sites_tunnel)            # not in the cached settings yet: the usual tunnel
              [ -n "$via" ] && pf_route_del "$ip" 255.255.255.255 "$via"
            done
            [ "$DRY" = 1 ] || { awk -v d="$2" '$2 != d' "$SITES_ROUTES" > "$SITES_ROUTES.tmp" 2>/dev/null; mv "$SITES_ROUTES.tmp" "$SITES_ROUTES"; } ;;
  esac
  [ "$DRY" = 1 ] || { awk -v d="$2" '$2 != d' "$SITES" > "$SITES.tmp" 2>/dev/null; mv "$SITES.tmp" "$SITES"; }
  return 0
}

site_del() {
  d=$(site_norm "$1")
  w=$(site_way "$d")
  if [ -z "$w" ]; then
    if site_builtin "$d"; then bad "$d встроен в switchback: убрать его можно только вместе со всем (Откатить всё)"
    else bad "$d не добавлялся через «Свои сайты»"; fi
    return 1
  fi
  site_undo "$w" "$d"
  [ "$DRY" = 1 ] || { grep -vxF "site $w $d" "$STATE" > "$STATE.tmp"; mv "$STATE.tmp" "$STATE"; }
  pf_save >/dev/null 2>&1
  ok "$d убран (способ: $w)"
  ev site_res "$d" removed "$w"
  log "site removed: $w $d"
}

site_check() {
  d=$(site_norm "$1")
  site_valid "$d" || { bad "«$1» не похоже на адрес сайта"; return 1; }
  # the whole page must come (redirects followed): the provider may answer the first bytes and cut the rest
  r=$(curl $ZCURL -s -L --max-redirs 3 -o /dev/null --max-time 12 -w '%{http_code} %{time_total} %{size_download}' "https://$d/" 2>/dev/null); e=$?
  c=${r%% *}; t=${r#* }; sz=${t#* }; t=${t%% *}; sz=${sz%%.*}; case $sz in ''|*[!0-9]*) sz=0 ;; esac
  if [ -n "$c" ] && [ "$c" != 000 ] && [ "$e" = 28 ] && [ "$sz" -le 100000 ]; then
    warn "$d отвечает, но страница обрывается на ~$((sz / 1024)) КБ: провайдер режет сайт по объёму"; ev site_check "$d" cut "$c" "$t"
  elif [ -n "$c" ] && [ "$c" != 000 ]; then ok "$d открывается (код $c, $(printf '%.1f' "$t" 2>/dev/null || echo "$t") с)"; ev site_check "$d" ok "$c" "$t"
  else warn "$d с роутера не открывается"; ev site_check "$d" down 000 0; fi
}

# ---------- a chosen device reaches Google/YouTube through the tunnel ----------
# Seen on a real router (2026-11-15/16): the provider cut off YouTube video servers one after another, with any
# zapret setting; sending them through the tunnel one by one gave a pause every few minutes. What worked: all
# the requests of the TV to Google's address ranges go through the tunnel (the provider then sees the tunnel
# only, and YouTube hands out servers abroad). Everything else on that device, and all other devices, go as
# before. The speed of YouTube there is the speed of the tunnel.
#   sites tv                  the devices
#   sites tv add IP|MAC [NAME]
#   sites tv del IP|MAC
# Files: $SB_DIR/tv.devices ("MAC NAME" lines). Journal: "tvvpn MAC". The job sb-tv (every minute) keeps one
# routing rule per device ("from ADDRESS lookup TV_TABLE") and the routes of TV_NETS through the tunnel Telegram
# uses now in that table; a device is found by its MAC, its last address is remembered while it is off.
TV_TABLE=109
TV_NETS="64.233.160.0/19 66.102.0.0/20 72.14.192.0/18 74.125.0.0/16 108.177.0.0/17 142.250.0.0/15 172.217.0.0/16 172.253.0.0/16 173.194.0.0/16 192.178.0.0/15 209.85.128.0/17 216.58.192.0/19 216.239.32.0/19 208.117.224.0/19 208.65.152.0/22 64.15.112.0/20"

tv_files() { TV_CONF=$SB_DIR/tv.devices; }
# in tests nothing may reach the real "ip": only a fake one named in SB_IPCMD is called
tv_can_run() { [ "$DRY" != 1 ] && { [ -z "$SB_TEST" ] || [ -n "$SB_IPCMD" ]; }; }
tv_mac_ok() { echo "$1" | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; }
# tv_mac IP|MAC -> the MAC in lower case ("" when the device is not seen in the network now)
tv_mac() {
  m=$1
  tv_mac_ok "$m" || { tv_can_run || { echo ""; return; }; m=$(${SB_IPCMD:-ip} neigh show "$1" 2>/dev/null | awk '{print $5}' | head -n 1); }
  tv_mac_ok "$m" && echo "$m" | tr 'A-F' 'a-f'
}
tv_job() {
script_subst <<'EOF' | sed -e "s|__NETS__|$TV_NETS|g" -e "s|__TABLE__|$TV_TABLE|g"
#!/bin/sh
# switchback: the chosen devices reach Google/YouTube through the VPN tunnel Telegram uses now (it follows the
# tunnel failover); everything else on them and all other devices go as before. Runs every minute and only
# puts back what is missing: the rules vanish on a reboot and when the tunnel reconnects.
export PATH=__PATH__
IP=${SB_IPCMD:-ip}
F=__CONF__/tv.devices
TB=__TABLE__
rules() { $IP rule 2>/dev/null | sed -n "s/.*from \([0-9.]*\) lookup $TB.*/\1/p"; }
want=""
if [ -s "$F" ]; then
  # the tunnel: where Telegram goes now, if that is not the ordinary way to the internet
  dev=$($IP route get 91.108.56.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)
  wan=$($IP route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)
  if [ -n "$dev" ] && [ "$dev" != "$wan" ]; then
    for p in __NETS__; do
      $IP route show table $TB 2>/dev/null | grep -q "^$p dev $dev " || $IP route replace "$p" dev "$dev" table $TB 2>/dev/null
    done
    while read -r mac name; do
      [ -n "$mac" ] || continue
      c=__STATE__/sb-tv.$(echo "$mac" | tr -d :)
      a=$($IP neigh show 2>/dev/null | grep -i " $mac " | awk '{print $1}' | grep -v : | head -n 1)
      if [ -n "$a" ]; then [ "$(cat "$c" 2>/dev/null)" = "$a" ] || echo "$a" > "$c"
      else a=$(cat "$c" 2>/dev/null); fi          # the device is off: its last address, so the rule is there when it wakes
      [ -n "$a" ] && want="$want $a"
    done < "$F"
  else
    $IP route flush table $TB 2>/dev/null      # no tunnel now: the devices go directly, as without this job
  fi
else
  $IP route flush table $TB 2>/dev/null
fi
for old in $(rules); do
  case " $want " in *" $old "*) ;; *) $IP rule del from "$old" lookup $TB 2>/dev/null ;; esac
done
for a in $want; do
  rules | grep -qx "$a" || $IP rule add from "$a" lookup $TB pref 150
done
exit 0
EOF
}
tv_run() { if tv_can_run && [ -x "$CRON1/sb-tv" ]; then "$CRON1/sb-tv" >/dev/null 2>&1; fi; return 0; }
tv_add() {   # tv_add IP|MAC [NAME]
  tv_files
  [ -n "$(sites_tunnel)" ] || { bad "нет работающего VPN-подключения: подключите WireGuard (как для Telegram)"; return 1; }
  mac=$(tv_mac "$1")
  [ -n "$mac" ] || { bad "устройство «$1» сейчас не видно в домашней сети: включите его или укажите его MAC-адрес"; return 1; }
  if grep -qi "^$mac " "$TV_CONF" 2>/dev/null; then skip "это устройство уже добавлено"; return 0; fi
  name=$(echo "$2" | tr -cd 'A-Za-z0-9_.-' | cut -c1-30); [ -n "$name" ] || name=device
  pf_cron_setup || { bad "не удалось включить планировщик"; return 1; }
  jt=/tmp/switchback.new.$$; tv_job > "$jt"
  if [ -f "$CRON1/sb-tv" ] && ours "$CRON1/sb-tv"; then refresh_file "$CRON1/sb-tv" "Google и YouTube выбранных устройств через VPN" "$jt"
  else install_file "$CRON1/sb-tv" "Google и YouTube выбранных устройств через VPN (каждую минуту)" "$jt"; fi
  remember "file $TV_CONF"
  append_line "$TV_CONF" "$mac $name"
  remember "tvvpn $mac"
  pf_keep_files
  tv_run
  ok "$name: Google и YouTube этого устройства идут через VPN; остальное на нём — как раньше"
  note "Скорость YouTube на нём — скорость туннеля. Закройте приложение YouTube на устройстве и откройте заново."
  log "tv added: $name"
  return 0
}
# tv_undo MAC: take the device out (used by "sites tv del" and by uninstall)
tv_undo() {
  tv_files
  [ "$DRY" = 1 ] || { grep -vi "^$1 " "$TV_CONF" > "$TV_CONF.tmp" 2>/dev/null; mv "$TV_CONF.tmp" "$TV_CONF"; }
  if [ -x "$CRON1/sb-tv" ]; then tv_run
  elif tv_can_run; then          # the job is gone already (uninstall): clear what it kept
    for a in $(${SB_IPCMD:-ip} rule 2>/dev/null | sed -n "s/.*from \([0-9.]*\) lookup $TV_TABLE.*/\1/p"); do
      ${SB_IPCMD:-ip} rule del from "$a" lookup $TV_TABLE 2>/dev/null
    done
    ${SB_IPCMD:-ip} route flush table $TV_TABLE 2>/dev/null
  fi
  return 0
}
tv_del() {
  tv_files
  mac=$(tv_mac "$1"); [ -n "$mac" ] || mac=$(awk -v n="$1" '$2 == n {print $1; exit}' "$TV_CONF" 2>/dev/null)
  if [ -z "$mac" ] || ! grep -qi "^$mac " "$TV_CONF" 2>/dev/null; then bad "такого устройства в списке нет"; return 1; fi
  tv_undo "$mac"
  [ "$DRY" = 1 ] || { grep -vxF "tvvpn $mac" "$STATE" > "$STATE.tmp"; mv "$STATE.tmp" "$STATE"; }
  ok "устройство убрано: его Google и YouTube снова идут как у всех"
  log "tv removed"
}
tv_list() {
  tv_files
  hr "Google и YouTube через VPN — по устройствам"
  if [ -s "$TV_CONF" ]; then
    while read -r mac name; do [ -n "$mac" ] && { ok "$name"; ev tv "$name"; }; done < "$TV_CONF"
  else
    skip "устройств пока нет"
    note "Добавить: sites tv add АДРЕС-УСТРОЙСТВА ИМЯ (например: sites tv add 192.168.1.50 tv)"
  fi
  return 0
}

sites_refresh() {   # sites_refresh [video]: "video" = only the every-minute look for video servers
  t=$(sites_tunnel); [ -n "$t" ] || return 0
  total=0
  [ "$1" = video ] || for d in $(awk '$1 == "vpn" {print $2}' "$SITES" 2>/dev/null); do
    vpn_routes "$d" "$t"; total=$((total + added))
    [ "$added" -gt 0 ] && log "site $d: $added new address(es) via $t"
  done
  if grep -qx 'rescue video' "$SITES" 2>/dev/null; then video_rescue "$t"; total=$((total + vnew)); fi
  save_if_changed
  say "новых адресов: $total"
}

sites_list() {
  hr "Свои сайты"
  if [ -s "$SITES" ]; then
    while read -r w d; do
      [ -n "$d" ] || continue
      case $w in
        zapret) ok "$d — zapret" ;;
        dns)    ok "$d — DNS" ;;
        vpn)    n=$(awk -v d="$d" '$2 == d' "$SITES_ROUTES" 2>/dev/null | wc -l); ok "$d — через VPN (адресов: $(echo $n))" ;;
        rescue) n=$(awk -v d="$d" '$2 == d' "$SITES_ROUTES" 2>/dev/null | wc -l)
                ok "серверы, которые глушит провайдер (YouTube и любые другие), — сами уходят в VPN (сейчас адресов: $(echo $n))" ;;
      esac
      ev site "$w" "$d"
    done < "$SITES"
  else
    skip "своих сайтов пока нет"
  fi
  say ""
  note "Встроены: YouTube, Discord, Instagram (zapret), ChatGPT и Claude (DNS), Telegram (VPN)."
  # what the program can offer for each way
  pf_zapret_installed && ev site_way zapret
  for c in claude.ai chatgpt.com; do pf_dns_has "$c" && ev site_dns "$c"; done
  ev site_dnsfree $(( DNS_LIMIT - $(pf_dns_count) ))
  t=$(sites_tunnel); [ -n "$t" ] && ev site_way vpn "$t"
  return 0
}

do_sites() {
  sites_files
  set -- $SITES_ARGS
  act=${1:-list}
  case $act in
    list)    sites_list ;;
    add)     [ -n "$2" ] || { say "Нужен адрес: sites add example.com --via zapret|dns|vpn"; return 2; }
             : > "$RUN_JOURNAL"; hr "Добавляю сайт"; site_add "$2" "${SITE_VIA:-zapret}" ;;
    del)     [ -n "$2" ] || { say "Нужен адрес: sites del example.com"; return 2; }
             hr "Убираю сайт"; site_del "$2" ;;
    check)   [ -n "$2" ] || { say "Нужен адрес: sites check example.com"; return 2; }
             site_check "$2" ;;
    refresh) sites_refresh "$2" ;;
    tv)      case $2 in
               ''|list) tv_list ;;
               add) [ -n "$3" ] || { say "Нужен адрес устройства: sites tv add 192.168.1.50 tv"; return 2; }
                    : > "$RUN_JOURNAL"; hr "Google и YouTube устройства через VPN"; tv_add "$3" "$4" ;;
               del) [ -n "$3" ] || { say "Нужен адрес или имя устройства: sites tv del tv"; return 2; }
                    hr "Google и YouTube устройства через VPN"; tv_del "$3" ;;
               *)   say "Нужно: sites tv, sites tv add АДРЕС ИМЯ или sites tv del АДРЕС"; return 2 ;;
             esac ;;
    video)   case $2 in
               on)  : > "$RUN_JOURNAL"; hr "Серверы видео YouTube через VPN"; video_on ;;
               off) hr "Серверы видео YouTube через VPN"; site_del video ;;
               *)   say "Нужно: sites video on или sites video off"; return 2 ;;
             esac ;;
    *)       say "Неизвестное действие: $act (list, add, del, check, video, tv)"; return 2 ;;
  esac
}
