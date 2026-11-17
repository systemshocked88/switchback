# 3. zapret (nfqws2) для YouTube, Discord, Instagram

zapret не VPN: трафик идёт напрямую, но zapret хитро нарезает и подменяет первые пакеты соединения, чтобы система
блокировки провайдера (DPI) не узнала сайт. Скорость не теряется.

Для Keenetic есть готовый пакет **nfqws2-keenetic**: https://github.com/nfqws/nfqws2-keenetic. Там же актуальная
инструкция. Если она отличается от этой, верьте ей.

## 3.1. Установка

По SSH:
```
mkdir -p /opt/etc/opkg
echo "src/gz nfqws2-keenetic https://nfqws.github.io/nfqws2-keenetic/all" > /opt/etc/opkg/nfqws2-keenetic.conf
opkg update
opkg install nfqws2-keenetic
```
Проверка:
```
/opt/etc/init.d/S51nfqws2 status
```
Должно быть `Service NFQWS2 is running`.

## 3.2. Режим list

Файл настроек: `/opt/etc/nfqws2/nfqws2.conf`. Сначала копия:
```
cp /opt/etc/nfqws2/nfqws2.conf /opt/etc/nfqws2/nfqws2.conf.orig
```
Режим работы задаётся строкой `NFQWS_EXTRA_ARGS`:
- `$MODE_LIST`: обрабатывать **только сайты из списков**. Рекомендуется;
- `$MODE_AUTO`: zapret сам добавляет «подозрительные» сайты. Удобно, но иногда ломает то, что работало;
- `$MODE_ALL`: обрабатывать всё. Не надо.

```
sed -i 's/^NFQWS_EXTRA_ARGS=.*/NFQWS_EXTRA_ARGS="$MODE_LIST"/' /opt/etc/nfqws2/nfqws2.conf
grep '^NFQWS_EXTRA_ARGS' /opt/etc/nfqws2/nfqws2.conf
```

**UDP-порты.** Для YouTube (QUIC) нужен UDP 443, для голоса Discord ещё его диапазоны. Не ставьте «весь UDP»:
это лишняя нагрузка и риск сломать игры и звонки. В нашем случае хватило:
```
UDP_PORTS=443,19294:19344,50000:50100
```

## 3.3. Списки сайтов

`/opt/etc/nfqws2/lists/user.list`: свои домены, по одному на строку. Поддомены учитываются. Для Instagram:
```
instagram.com
cdninstagram.com
fbcdn.net
facebook.com
facebook.net
fb.com
fbsbx.com
```
YouTube и Discord обычно уже есть во встроенных списках пакета.

После правок:
```
/opt/etc/init.d/S51nfqws2 restart
```

## Исключить ПК

Если на каком-то компьютере уже работает свой обход (zapret для Windows, GoodbyeDPI, Zapret GUI), **его надо
исключить** из zapret на роутере. Два обхода на одном трафике ломают соединения.

1. Keenetic: **Сетевые правила → Политики доступа** → создайте политику с именем `nfqws`, отметьте в ней ваши
   подключения к интернету. В разделе **Устройства** перенесите туда этот ПК.
2. В `/opt/etc/nfqws2/nfqws2.conf`:
   ```
   POLICY_NAME="nfqws"
   POLICY_EXCLUDE=1
   ```
   `POLICY_EXCLUDE=1` значит «устройства этой политики **не** обрабатывать».
3. `/opt/etc/init.d/S51nfqws2 restart`

## 3.4. «Сетевой ускоритель»

Если после включения zapret что-то работает странно, попробуйте отключить аппаратное ускорение
(в командной строке Keenetic: `no ppe software`, затем `system configuration save`). На Extra это не сказалось на
скорости (~90 Мбит/с).

## Если не работает

- Стратегии обхода зависят от провайдера. Если YouTube не открылся, смотрите раздел про стратегии в README
  nfqws2-keenetic и обсуждения для вашего провайдера.
- Выключить zapret полностью: `/opt/etc/init.d/S51nfqws2 stop`.
