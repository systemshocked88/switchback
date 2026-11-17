#!/bin/sh
# Weekly backup (Entware cron.weekly): router config + Entware settings,
# without the bot token. Keeps the 8 latest of each. Alerts only on failure.
export PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
B=/opt/backup
mkdir -p "$B"; chmod 700 "$B"
d=$(date +%Y-%m-%d)

ndmc -c "show running-config" > "$B/router-$d.txt"
# Entware's tar is BusyBox: exclusions go in a file (-X), --exclude is not supported.
echo "etc/watchdog/bot.conf" > /tmp/backup.exclude
tar czf "$B/entware-$d.tar.gz" -C /opt -X /tmp/backup.exclude etc
chmod 600 "$B"/*

ls -t "$B"/router-*.txt      | tail -n +9 | xargs -r rm -f
ls -t "$B"/entware-*.tar.gz  | tail -n +9 | xargs -r rm -f

if [ ! -s "$B/router-$d.txt" ] || [ ! -s "$B/entware-$d.tar.gz" ]; then
  [ -f /opt/etc/watchdog/bot.conf ] || exit 1
  . /opt/etc/watchdog/bot.conf
  curl -s -o /dev/null --max-time 20 "https://api.telegram.org/bot$TOKEN/sendMessage" \
    -d chat_id="$CHAT" -d text="[router] BACKUP FAILED $d"
fi
