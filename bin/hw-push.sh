#!/bin/bash
# hw-push.sh — pushes AltTron disk/RAM/swap health to Gatus external endpoints.
#
# Runs from the `agent` crontab every 2 min. Gatus heartbeat (5m) on each
# external endpoint turns it red if this script stops pushing (dead pusher
# detection). Thresholds live here (see ~/Uptime.md §Hardware on the
# OpenTerminal box).
#
# Push API: POST http://127.0.0.1:8069/api/v1/endpoints/<key>/external
#           ?success=true|false[&error=<url-encoded>]
#           Authorization: Bearer $GATUS_HW_TOKEN   (from ~/gatus/gatus.env)
# Keys are group_name slugs: hardware_disk-root, hardware_ram, ...
set -u
. /home/agent/gatus/gatus.env        # provides GATUS_HW_TOKEN

API="http://127.0.0.1:8069/api/v1/endpoints"
TH_DISK=90     # fail a filesystem at >= 90% used
TH_RAM=95      # fail when (MemTotal-MemAvailable)/MemTotal >= 95%
TH_SWAP=95     # fail when swap usage >= 95%

push() {  # <name> <true|false> [error]
  local name=$1 ok=$2 err=${3:-} code
  local url="$API/hardware_$name/external?success=$ok"
  [ -n "$err" ] && url="$url&error=$(printf %s "$err" | jq -sRr @uri)"
  code=$(curl -s -m 8 -o /dev/null -w "%{http_code}" -X POST \
         -H "Authorization: Bearer $GATUS_HW_TOKEN" "$url")
  echo "push $name success=$ok -> $code"
}

# ---- disks (df -P: 6 cols — FS 1K-blocks Used Avail Cap% Mount; -T adds Type) ----
df -PT -x tmpfs -x devtmpfs -x squashfs -x efivarfs 2>/dev/null | tail -n +2 |
while read -r fs type size used avail cap mount; do
  pct=${cap%\%}
  case "$mount" in
    /)         name=disk-root ;;
    /home)     name=disk-home ;;
    /boot)     name=disk-boot ;;
    /boot/efi) name=disk-boot-efi ;;
    /tank)     name=disk-tank ;;
    *)         continue ;;
  esac
  if [ "$pct" -ge "$TH_DISK" ]; then
    push "$name" false "$mount is ${pct}% used (threshold ${TH_DISK}%) — $fs"
  else
    push "$name" true
  fi
done

# ---- RAM (MemAvailable-based: counts reclaimable cache as free) ----
read -r mt ma < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo)
ram_pct=$(( (mt - ma) * 100 / mt ))
if [ "$ram_pct" -ge "$TH_RAM" ]; then
  push ram false "RAM ${ram_pct}% used — only $(( ma / 1024 )) MB available of $(( mt / 1024 )) MB"
else
  push ram true
fi

# ---- swap ----
read -r st sf < <(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print t, f}' /proc/meminfo)
if [ "$st" -eq 0 ]; then
  push swap true                      # no swap configured → N/A, don't alarm
else
  sw_pct=$(( (st - sf) * 100 / st ))
  if [ "$sw_pct" -ge "$TH_SWAP" ]; then
    push swap false "swap ${sw_pct}% used — only $(( sf / 1024 )) MB free of $(( st / 1024 )) MB"
  else
    push swap true
  fi
fi