# Module "meta": Instagram, Facebook, WhatsApp and Threads through the VPN tunnel (the one Telegram uses).
# Done by hand on a real Keenetic (2026-11-06) and working there; zapret alone was not enough for the apps.
#   1) Meta's networks are routed through the tunnel;
#   2) the router asks 1.1.1.1 for Meta's domains, and 1.1.1.1 itself goes through the tunnel: the
#      provider's DNS answers those names with stub addresses.
# Keenetic gotcha: "ip name-server 1.1.1.1 DOMAIN" WITHOUT "on WireguardN" — with it the router's DNS
# proxy failed its queries and silently fell back to the provider's DNS.

# META_NETS: lists/meta.nets (lists_load in lib/common.sh)
META_DNS=1.1.1.1
# META_DOMAINS: lists/meta.domains (lists_load in lib/common.sh)

meta_route() {   # meta_route NET MASK IFACE: a route through the tunnel unless that network already goes somewhere
  via=$(pf_route_via "$1" "$2")
  if [ "$via" = "$3" ]; then skip "$1 уже через $3"; return 0; fi
  if [ -n "$via" ]; then skip "$1 уже идёт через $via — не трогаю"; return 0; fi
  pf_route_add "$1" "$2" "$3" || fail "роутер не принял маршрут $1"
  remember "route $1 $2 $3"; CLI_CHANGED=1; n_routes=$((n_routes+1))
}

mod_meta() {
  hr "Instagram, Facebook, WhatsApp через VPN"
  t=$VPN_IF; [ -n "$t" ] || t=$(tg_via)
  if [ -z "$t" ]; then
    warn "нет туннеля, через который идёт Telegram: сначала «Telegram через VPN», модуль пропущен"; return 0
  fi
  say "  Сети Meta и её DNS (через $META_DNS) пойдут через $t. Приложения Instagram и WhatsApp так работают"
  say "  надёжнее, чем через zapret."
  yes_no "  Пускать Instagram, Facebook, WhatsApp и Threads через VPN?" y meta_vpn || { skip "оставляю как есть"; return 0; }
  n_routes=0
  for n in $META_NETS; do meta_route "${n%/*}" "${n#*/}" "$t"; done
  meta_route "$META_DNS" 255.255.255.255 "$t"
  if [ "$n_routes" -gt 0 ]; then ok "маршрутов через $t добавлено: $n_routes"; else skip "сети Meta уже идут через туннель"; fi
  n_dns=0
  for d in $META_DOMAINS; do
    if pf_ns_has "$META_DNS" "$d"; then continue; fi
    pf_ns_add "$META_DNS" "$d" || fail "роутер не принял DNS-сервер для $d"
    remember "ns $META_DNS $d"; CLI_CHANGED=1; n_dns=$((n_dns+1))
  done
  if [ "$n_dns" -gt 0 ]; then ok "домены Meta спрашивают $META_DNS через туннель: $n_dns"
  else skip "DNS для доменов Meta уже настроен"; fi
  save_if_changed
}

meta_on() { pf_ns_has "$META_DNS" instagram.com; }   # is it set up on this router (by switchback or by hand)
