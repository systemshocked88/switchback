# 5. Сторож с уведомлениями в Telegram

Каждые 5 минут проверяет zapret, Telegram (через туннель), Claude и ChatGPT. Пишет **только при изменениях**:
`DOWN: …`, когда сломалось, и `BACK: … (was down ~N min)`, когда починилось.

Хитрость: сообщения бота идут через тот же туннель, что и Telegram. Если упал сам туннель, сообщить сразу нельзя.
Поэтому скрипт запоминает время сбоя и, когда всё вернётся, присылает `WAS DOWN: … (~N min)`.

## 5.1. Программы

```
opkg install curl cron
/opt/etc/init.d/S10cron start
```
В Entware уже есть расписание: всё, что лежит в `/opt/etc/cron.5mins/`, запускается каждые 5 минут.

## 5.2. Свой бот

1. В Telegram: **@BotFather** (с синей галочкой) → `/newbot` → получите **токен** (`123456:ABC…`).
   **Токен никому не отправляйте.**
2. Откройте своего бота по ссылке из сообщения BotFather, нажмите **Start** и напишите ему что-нибудь.

## 5.3. Токен на роутер (так, чтобы он не светился на экране)

```
mkdir -p /opt/etc/watchdog
read -s -p "TOKEN: " T; echo "TOKEN=$T" > /opt/etc/watchdog/bot.conf; unset T; echo
chmod 600 /opt/etc/watchdog/bot.conf
```
После `TOKEN:` вставьте токен (символы не видны) и нажмите Enter. Проверка длины (сам токен не печатается),
должно быть около 46:
```
awk -F= '/^TOKEN=/{print "token length:", length($2)}' /opt/etc/watchdog/bot.conf
```

## 5.4. Номер чата

```
sed -i '/^CHAT=/d' /opt/etc/watchdog/bot.conf; . /opt/etc/watchdog/bot.conf; C=$(curl -s "https://api.telegram.org/bot$TOKEN/getUpdates" | grep -o '"chat":{"id":[0-9-]*' | head -1 | grep -o '[0-9-]*$'); echo "CHAT=$C" >> /opt/etc/watchdog/bot.conf; echo "chat: $C"
```
Пусто? Бот не видит вашего сообщения: нажмите Start, напишите ещё раз, повторите.

Тест:
```
. /opt/etc/watchdog/bot.conf; curl -s -o /dev/null -w "http: %{http_code}\n" "https://api.telegram.org/bot$TOKEN/sendMessage" -d chat_id="$CHAT" -d text="Test from router: OK"
```

## 5.5. Скрипт

Скопируйте содержимое [`scripts/watchdog.sh`](../scripts/watchdog.sh) в файл на роутере. Проще всего так:
```
cat > /opt/etc/cron.5mins/watchdog << 'EOF'
...сюда вставить весь скрипт...
EOF
chmod +x /opt/etc/cron.5mins/watchdog
```
Имя файла **без точки и расширения** (`watchdog`, не `watchdog.sh`), иначе cron его пропустит.

В конце скрипта список проверок. Уберите ненужные, добавьте свои.

## 5.6. Проверка «понарошку»

Притворимся, что Claude 10 минут назад был сломан. Должно прийти `BACK: claude-site (was down ~10 min)`:
```
mkdir -p /opt/var/watchdog; echo down > /opt/var/watchdog/claude-site; echo $(( $(date +%s) - 600 )) > /opt/var/watchdog/claude-site.down; /opt/etc/cron.5mins/watchdog
```

Выключить сторож: `rm /opt/etc/cron.5mins/watchdog`.
