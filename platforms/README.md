# Адаптеры прошивок

Всё, что зависит от прошивки, живёт в `platforms/<имя>.sh`. Общая логика (`lib/`) вызывает только эти функции,
поэтому новая прошивка = новый файл, остальное не меняется. Образцы: [`keenetic.sh`](keenetic.sh) (настройки через
`ndmc`), [`openwrt.sh`](openwrt.sh) (настройки через `uci`).

Прошивку определяет `lib/detect.sh` (`keenetic`, `openwrt`, `merlin`, `unknown`).

## Переменные

| Имя | Что это |
|---|---|
| `ETC_DIR`, `VAR_DIR` | где хранить свои файлы (`$ETC_DIR/switchback`) и журнал (`$VAR_DIR/log`) |
| `BOT` | файл с токеном бота и номером чата |
| `PKG_ROOT`, `MIN_FREE_MB` | где лежат пакеты и сколько там должно быть свободно (по умолчанию 20 МБ) |
| `EXCLUDE_BY_POLICY` | 1 — исключение ПК из zapret через политику (Keenetic), 0 — не поддерживается |
| `NFQ_CONF`, `NFQ_LIST` | файл настроек zapret и его список сайтов |
| `CRON5`, `CRONW` | папки «каждые 5 минут» и «раз в неделю» |
| `DNS_LIMIT` | сколько доменных DNS-записей допускает прошивка |

## Функции

| Функция | Что должна делать |
|---|---|
| `pf_init` | проверить, что всё нужное есть; загрузить настройки; при проблеме `fail` |
| `pf_describe`, `pf_doctor` | строки для анализа: модель/версия и проверки, специфичные для прошивки |
| `pf_backup DIR`, `pf_restore_help DIR` | сохранить снимок настроек в DIR; объяснить, как восстановиться |
| `pf_feeds_https`, `pf_feeds_restore` | перевести источники пакетов на https (код 2 = нечего делать); вернуть |
| `pf_pkg_installed/install/remove` | работа с пакетами |
| `pf_zapret_installed/install/restart/running` | zapret |
| `pf_zapret_conf_backup/restore`, `pf_list_del D` | копия и восстановление его настроек; убрать домен из списка |
| `pf_exclude_hint` | как исключить ПК со своим обходом на этой прошивке |
| `pf_zapret_prepare` | что сделать перед запуском zapret (OpenWrt: выключить flow offloading) |
| `OWN_HOOK` (переменная) | файл, который роутер запускает при пересборке правил: собственные соединения роутера мимо zapret (`own_script`); пусто — не нужно |
| `pf_dns_intro`, `pf_dns_ask SERVICE` | объяснить и спросить, какой сервер нужен; задать `DNS_SRV` (слова перед доменом) и `DNS_LABEL`. Каждый вопрос — через `ask "текст" "по умолчанию" КЛЮЧ` с ключом вида `dns_<service>_…`, добавленным в `ANSWER_KEYS` (`lib/common.sh`) и в [docs/answers.md](../docs/answers.md) |
| `pf_dns_count/has`, `pf_dns_add/del $DNS_SRV DOMAIN`, `pf_dns_srv_of DOMAIN` | DNS-запись «домен → сервер»; слова сервера уже настроенного домена (для своих сайтов) |
| `pf_uci_restore KEY OLD`, `pf_crontab_remove` | отмена записей журнала `uci` и `crontab` (на Keenetic — пустые) |
| `pf_failover_funcs`, `CRON1`, `SCRIPT_PATH` | платформенная часть скрипта автосмены туннеля (`fo_*`: туннели, маршруты, рукопожатие, включить/выключить, перенести, сохранить); папка ежеминутных заданий; PATH ставимых скриптов |
| `pf_report_config` | для отчёта: только нужные части настроек (туннели, маршруты, закрепления, DNS, правила) — никогда не всю конфигурацию; дальше `sanitize` и `report_leaks` |
| `pf_nodes_funcs`, `pf_quic_blocked/block/unblock`, `pf_host_pinned/pin/restore`, `pf_acl_unbind` | узлы Claude: платформенная часть скрипта (`nd_*`), правила запрета QUIC (Keenetic — список правил сегмента Home, OpenWrt — правило firewall), закрепление домена за узлом (Keenetic `ip host`, OpenWrt dnsmasq `address`); журнал `quic`, `acl_bind`, `host` |
| `pf_wg_free_name`, `pf_wg_create NAME`, `pf_wg_delete NAME`, `pf_uci_list_del KEY VALUE` | WireGuard из .conf (переменные `WG_*` из `wg_parse`): свободное имя, создать только для выбранных адресов (журнал `wg NAME`), удалить; ключи — без вывода и журнала |
| `pf_keep_files`, `pf_keep_del PATH` | сохранить файлы switchback при обновлении прошивки (OpenWrt: строки в `/etc/sysupgrade.conf`, журнал `keep`; без папок со снимками); отменить. На Keenetic пустые: Entware на флешке обновление не трогает |
| `pf_vpn_ifaces`, `pf_vpn_is_global IF`, `pf_vpn_hint` | VPN-подключения; идёт ли через него весь трафик |
| `pf_route_has/add/del NET MASK IF`, `pf_route_via NET MASK` | маршрут сети через VPN; через что идёт сеть сейчас. Маска 255.255.255.255 — маршрут к одному адресу (свои сайты через VPN) |
| `pf_save`, `pf_reload` | сохранить настройки роутера; перечитать их |
| `pf_cron_setup`, `pf_backup_job` | включить планировщик; текст еженедельного бэкапа |

Каждая функция, которая что-то меняет, должна уважать `DRY=1` (использовать `run`, `write_file` или свою обёртку).
Каждое изменение записывается вызывающим кодом через `remember`, отменяется через `undo_entry` (`lib/common.sh`).
