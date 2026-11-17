#!/bin/sh
# Router watchdog: checks bypass services every 5 min (Entware cron.5mins),
# Telegram alert only when a state changes. Token and chat id live in
# /opt/etc/watchdog/bot.conf (TOKEN=..., CHAT=...), never in this file.
export PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
. /opt/etc/watchdog/bot.conf
S=/opt/var/watchdog
mkdir -p "$S"
now=$(date +%s)

send() {
  curl -s -o /dev/null --max-time 20 -w '%{http_code}' \
    "https://api.telegram.org/bot$TOKEN/sendMessage" \
    -d chat_id="$CHAT" --data-urlencode text="[router] $1" | grep -q 200
}

# Any HTTP answer counts as "up"; 000 means no connection. Two tries, 5 s apart.
web() {
  for i in 1 2; do
    c=$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' "$1")
    [ "$c" != "000" ] && return 0
    sleep 5
  done
  return 1
}

zapret() { pidof nfqws2 >/dev/null; }

# DOWN when it breaks, BACK when it recovers. If the alert could not be sent
# (e.g. Telegram itself goes through the tunnel that broke), WAS DOWN comes later.
check() {
  n=$1; shift
  if "$@"; then st=ok; else st=down; fi
  old=$(cat "$S/$n" 2>/dev/null || echo ok)
  if [ "$st" = down ]; then
    [ -f "$S/$n.down" ] || echo "$now" > "$S/$n.down"
    if [ "$old" != down ]; then
      send "DOWN: $n" && echo down > "$S/$n"
    fi
  elif [ -f "$S/$n.down" ]; then
    m=$(( (now - $(cat "$S/$n.down")) / 60 ))
    if [ "$old" = down ]; then
      msg="BACK: $n (was down ~$m min)"
    else
      msg="WAS DOWN: $n (~$m min, alert could not be sent)"
    fi
    send "$msg" && { echo ok > "$S/$n"; rm -f "$S/$n.down"; }
  fi
}

# What to check. Remove lines you do not use, add your own.
check zapret      zapret
check telegram-wg web https://api.telegram.org
check claude-site web https://claude.ai
check claude-app  web https://api.anthropic.com
check chatgpt     web https://chatgpt.com
