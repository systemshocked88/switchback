#!/bin/sh
# switchback panel: the only program the web server runs (installed as www/cgi-bin/sb by "install.sh panel on").
# It checks who asks, then calls install.sh; the checks and changes themselves are install.sh's.
#   GET  ?a=state[&f=1]        services and tunnels (cached 60 s; f=1: check now)
#   POST ?a=login   t=TOKEN    the token from the link -> a session cookie (HttpOnly, SameSite=Strict)
#   POST ?a=doctor  d=DOMAIN   why the site does not open
#   POST ?a=fix     d=DOMAIN way=zapret|vpn|dns
#   POST ?a=next               Telegram and Meta to the next tunnel
#   POST ?a=logout
# Every POST but login carries csrf=... (given with the session). Values are checked against a whitelist and
# never reach eval or an unquoted command line.
export PATH=__PATH__
P=__CONF__/panel
APP=__CONF__/app/install.sh
CACHE=${SB_PANEL_CACHE:-/tmp/sb-panel.state}
umask 077

reply() {   # reply STATUS JSON [HEADER]
  printf 'Status: %s\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n' "$1"
  printf 'X-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n'
  [ -n "$3" ] && printf '%s\r\n' "$3"
  printf '\r\n%s\n' "$2"
  exit 0
}
err() { reply "$1" "{\"error\":\"$2\"}"; }

# devices at home only (the server listens on the home address too; this is the second lock)
ra=${REMOTE_ADDR#::ffff:}
case $ra in
  10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|127.0.0.1) ;;
  *) err "403 Forbidden" "Панель открывается только из домашней сети." ;;
esac

hex32() { case $1 in *[!0-9a-f]*) return 1 ;; esac; [ ${#1} = 32 ]; }
# 32 random hex digits. KeeneticOS's busybox od has no -A/-t (19.11.2026): hexdump first, then od, then tr
rnd() {
  r=$(head -c 16 /dev/urandom 2>/dev/null | hexdump -v -e '/1 "%02x"' 2>/dev/null)
  [ ${#r} -ge 32 ] || r=$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
  [ ${#r} -ge 32 ] || r=$(tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c 32)
  echo "$r"
}
qarg() { printf '%s' "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1; }

act=$(qarg a)
case $act in state|login|doctor|fix|next|logout) ;; *) err "404 Not Found" "нет такого действия" ;; esac
case $act in state) [ "$REQUEST_METHOD" = GET ] || err "405 Method Not Allowed" "только GET" ;;
  *) [ "$REQUEST_METHOD" = POST ] || err "405 Method Not Allowed" "только POST" ;; esac

BODY=""
if [ "$REQUEST_METHOD" = POST ]; then
  n=${CONTENT_LENGTH:-0}
  case $n in ''|*[!0-9]*) err "400 Bad Request" "неверная длина" ;; esac
  [ "$n" -le 2048 ] || err "413 Payload Too Large" "слишком длинный запрос"
  [ "$n" -gt 0 ] && BODY=$(head -c "$n")
fi
field() { printf '%s\n' "$BODY" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1; }

# the session: "SID CSRF EXPIRES" lines; the cookie holds SID only
sid=$(printf '%s' "$HTTP_COOKIE" | tr ';' '\n' | sed -n 's/^ *sb=//p' | head -n 1)
session() {
  hex32 "$sid" || return 1
  awk -v s="$sid" -v n="$(date +%s)" '$1 == s && $3 > n { print $2; f = 1; exit } END { exit !f }' "$P/sessions" 2>/dev/null
}

if [ "$act" = login ]; then
  t=$(field t)
  tok=$(cat "$P/token" 2>/dev/null)
  if ! hex32 "$t" || [ "$t" != "$tok" ]; then sleep 2; err "403 Forbidden" "Ссылка неверная или устарела. Новая: sh install.sh panel token"; fi
  sid=$(rnd); csrf=$(rnd); exp=$(( $(date +%s) + 2592000 ))
  hex32 "$sid" && hex32 "$csrf" || err "500 Internal Server Error" "нет случайных чисел"
  { tail -n 9 "$P/sessions" 2>/dev/null; echo "$sid $csrf $exp"; } > "$P/sessions.new" && mv "$P/sessions.new" "$P/sessions"
  reply "200 OK" "{\"ok\":true,\"csrf\":\"$csrf\"}" "Set-Cookie: sb=$sid; Path=/; Max-Age=2592000; HttpOnly; SameSite=Strict"
fi

csrf=$(session) || err "401 Unauthorized" "Нужен вход: откройте ссылку панели ещё раз."
if [ "$REQUEST_METHOD" = POST ]; then
  [ "$(field csrf)" = "$csrf" ] || err "403 Forbidden" "Страница устарела — обновите её."
fi

# installer events and marked lines -> JSON (the fields that came)
to_json() {
  awk -F '\t' -v csrf="$csrf" '
    function q(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[\001-\037]/, " ", s); return "\"" s "\"" }
    function add(v, x) { return v (v == "" ? "" : ",") x }
    $1 == "@@sb" && $2 == "svc" { sv = add(sv, "{\"name\":" q($3) ",\"color\":" q($4) ",\"how\":" q($5) ",\"text\":" q($6) "}"); next }
    $1 == "@@sb" && $2 == "tun" { tu = add(tu, "{\"name\":" q($3) ",\"up\":" ($4 == "up" ? "true" : "false") ",\"active\":" ($5 == "active" ? "true" : "false") "}"); next }
    $1 == "@@sb" && $2 == "tun_switch" { sw = ($3 == "yes" ? "true" : "false"); next }
    $1 == "@@sb" && $2 == "doc_fix" { for (i = 3; i <= NF; i++) fx = add(fx, q($i)); next }
    $1 == "@@sb" && $2 == "doc_say" { say = $3; next }
    $1 == "@@sb" && $2 == "doc_end" { end = $3; next }
    $1 == "@@sb" { next }
    /^ *\[(ok|!!|XX|--)\] / { m = $0; sub(/^ *\[/, "", m); k = substr(m, 1, 2); sub(/^..\] /, "", m)
      k = (k == "ok" ? "ok" : (k == "--" ? "info" : (k == "!!" ? "warn" : "bad"))); st = add(st, "{\"mark\":\"" k "\",\"text\":" q(m) "}") }
    END {
      o = "\"csrf\":" q(csrf)
      if (sv != "") o = o ",\"services\":[" sv "]"
      if (tu != "" || sw != "") o = o ",\"tunnels\":[" tu "],\"switch\":" (sw == "" ? "false" : sw)
      o = o ",\"steps\":[" st "],\"fixes\":[" fx "]"
      if (say != "") o = o ",\"say\":" q(say)
      if (end != "") o = o ",\"end\":" q(end)
      print "{" o "}"
    }'
}
run_app() { sh "$APP" "$@" --progress 2>&1 </dev/null; }
domain() {
  d=$(field d)
  case $d in ''|*[!a-z0-9.-]*|.*|-*) err "400 Bad Request" "Адрес сайта — вроде example.com" ;; esac
  [ ${#d} -le 253 ] || err "400 Bad Request" "слишком длинный адрес"
}

case $act in
  state)
    if [ "$(qarg f)" != 1 ] && [ -s "$CACHE" ] && [ $(( $(date +%s) - $(date -r "$CACHE" +%s 2>/dev/null || echo 0) )) -lt 60 ]; then
      out=$(cat "$CACHE")
    else
      out=$(run_app panel state)
      printf '%s\n' "$out" > "$CACHE.$$" && mv "$CACHE.$$" "$CACHE"
    fi
    reply "200 OK" "$(printf '%s\n' "$out" | to_json)" ;;
  doctor)
    domain
    reply "200 OK" "$(run_app sites doctor "$d" | to_json)" ;;
  fix)
    domain
    way=$(field way)
    case $way in zapret|vpn|dns) ;; *) err "400 Bad Request" "способ: zapret, vpn или dns" ;; esac
    rm -f "$CACHE"
    reply "200 OK" "$(run_app panel fix "$d" "$way" | to_json)" ;;
  next)
    rm -f "$CACHE"
    reply "200 OK" "$(run_app panel next | to_json)" ;;
  logout)
    awk -v s="$sid" '$1 != s' "$P/sessions" > "$P/sessions.new" 2>/dev/null && mv "$P/sessions.new" "$P/sessions"
    reply "200 OK" '{"ok":true}' "Set-Cookie: sb=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict" ;;
esac
