#!/bin/bash
# traffic_noise.sh — непрерывный адаптивный шум.
# Раз в секунду измеряет скорость TX по интерфейсу и качает с публичных
# зеркал на скорости RATIO * TX. Без окон, idle-порогов и ручной настройки.

set -u

RATIO="${RATIO:-2.5}"
IFACE="${IFACE:-$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}"

FILES=(
  "https://speed.hetzner.de/10GB.bin"
  "https://speed.hetzner.de/1GB.bin"
  "http://speedtest.tele2.net/10GB.zip"
  "http://speedtest.tele2.net/1GB.zip"
  "https://proof.ovh.net/files/10Gb.dat"
  "https://proof.ovh.net/files/1Gb.dat"
  "https://releases.ubuntu.com/jammy/ubuntu-22.04.4-live-server-amd64.iso"
  "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.5.0-amd64-netinst.iso"
)

if [[ -z "$IFACE" ]]; then
  echo "Не удалось определить интерфейс. Задай IFACE=eth0." >&2
  exit 1
fi

TX_FILE="/sys/class/net/$IFACE/statistics/tx_bytes"
if [[ ! -r "$TX_FILE" ]]; then
  echo "Нет доступа к $TX_FILE" >&2
  exit 1
fi

CURL_PID=""
cleanup() {
  [[ -n "$CURL_PID" ]] && kill "$CURL_PID" 2>/dev/null
  exit 0
}
trap cleanup SIGINT SIGTERM EXIT

echo "Старт. Интерфейс=$IFACE RATIO=$RATIO (непрерывный режим)"

TX_PREV=$(<"$TX_FILE")
T_PREV=$(date +%s.%N)

while true; do
  sleep 1

  TX_NOW=$(<"$TX_FILE")
  T_NOW=$(date +%s.%N)

  TX_RATE_BPS=$(awk -v a="$TX_PREV" -v b="$TX_NOW" -v t1="$T_PREV" -v t2="$T_NOW" \
    'BEGIN{dt=t2-t1; if(dt<=0)dt=1; d=b-a; if(d<0)d=0; printf "%.0f", d/dt}')

  TX_PREV="$TX_NOW"
  T_PREV="$T_NOW"

  TARGET_KBPS=$(awk -v r="$TX_RATE_BPS" -v k="$RATIO" 'BEGIN{v=(r*k)/1024; if(v<1)v=1; printf "%.0f", v}')

  URL=${FILES[$RANDOM % ${#FILES[@]}]}
  HOST=$(echo "$URL" | awk -F/ '{print $3}')

  TX_MB=$(awk -v r="$TX_RATE_BPS" 'BEGIN{printf "%.2f", r/1048576}')
  TGT_MB=$(awk -v k="$TARGET_KBPS" 'BEGIN{printf "%.2f", k/1024}')
  echo "[$(date '+%H:%M:%S')] TX=${TX_MB}MB/s → RX=${TGT_MB}MB/s ← $HOST"

  curl -s --max-time 30 \
    --user-agent "Mozilla/5.0 (X11; Linux x86_64)" \
    --limit-rate "${TARGET_KBPS}k" \
    -r "0-5242879" \
    -o /dev/null \
    "$URL" || true
done
