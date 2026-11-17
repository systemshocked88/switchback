# Platform detection. Sets PLATFORM to keenetic | openwrt | merlin | unknown.
# Tests may force a platform with SB_PLATFORM.

detect_platform() {
  if [ -n "$SB_PLATFORM" ]; then PLATFORM=$SB_PLATFORM; return; fi
  if command -v ndmc >/dev/null 2>&1; then
    PLATFORM=keenetic                      # Keenetic and Netcraze share KeeneticOS
  elif [ -f /etc/openwrt_release ]; then
    PLATFORM=openwrt                       # OpenWrt, iStoreOS, x-wrt, ImmortalWrt
  elif command -v nvram >/dev/null 2>&1 && nvram get buildinfo 2>/dev/null | grep -qi merlin; then
    PLATFORM=merlin
  else
    PLATFORM=unknown
  fi
}

platform_title() {
  case $1 in
    keenetic) echo "Keenetic / Netcraze (KeeneticOS)" ;;
    openwrt)  echo "OpenWrt" ;;
    merlin)   echo "Asus (Asuswrt-Merlin)" ;;
    *)        echo "неизвестная прошивка" ;;
  esac
}

# Load the adapter for $PLATFORM. Each adapter defines the pf_* functions (see platforms/README.md).
load_platform() {
  f=$SB_SRC/platforms/$PLATFORM.sh
  [ -f "$f" ] || return 1
  . "$f"
}
