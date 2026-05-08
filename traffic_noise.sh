#!/bin/bash
# traffic_noise.sh — адаптивный генератор шумового трафика.
# Раз в WINDOW секунд читает счетчики /sys/class/net/<iface>/statistics
# и скачивает (TX_delta * RATIO) байт с публичных файловых зеркал,
# выравнивая соотношение RX:TX до значения, характерного для обычного
# клиента, а не для proxy/VPN сервера.
#
# Параметры читаются из окружения (см. /etc/default/traffic-noise):
#   IFACE              — сетевой интерфейс (по умолчанию определяется автоматически)
#   RATIO              — во сколько раз RX должен превышать TX (по умолчанию 2.5)
#   WINDOW             — окно замера в секундах (по умолчанию 60)
#   MAX_DOWNLOAD_MB    — потолок на одно окно, МБ (по умолчанию 500)
#   MIN_TX_BYTES       — ниже этой дельты TX считаем idle, не качаем (по умолчанию 1 МБ)
#   LIMIT_RATE         — лимит скорости curl (по умолчанию 0 = без лимита)

set -u

IFACE="${IFACE:-$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}"
RATIO="${RATIO:-2.5}"
WINDOW="${WINDOW:-60}"
MAX_DOWNLOAD_MB="${MAX_DOWNLOAD_MB:-500}"
MIN_TX_BYTES="${MIN_TX_BYTES:-1048576}"
LIMIT_RATE="${LIMIT_RATE:-0}"

FILES=(
  "https://speed.hetzner.de/100MB.bin"
  "https://speed.hetzner.de/1GB.bin"
  "http://speedtest.tele2.net/100MB.zip"
  "http://speedtest.tele2.net/1GB.zip"
  "https://proof.ovh.net/files/100Mb.dat"
  "https://proof.ovh.net/files/1Gb.dat"
  "https://releases.ubuntu.com/jammy/ubuntu-22.04.4-live-server-amd64.iso"
  "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.5.0-amd64-netinst.iso"
)

if [[ -z "$IFACE" ]]; then
  echo "Не удалось определить сетевой интерфейс. Задай IFACE=eth0." >&2
  exit 1
fi

TX_FILE="/sys/class/net/$IFACE/statistics/tx_bytes"
RX_FILE="/sys/class/net/$IFACE/statistics/rx_bytes"

if [[ ! -r "$TX_FILE" ]]; then
  echo "Нет доступа к $TX_FILE (интерфейс $IFACE существует?)" >&2
  exit 1
fi

echo "Старт. Интерфейс=$IFACE RATIO=$RATIO Окно=${WINDOW}s Потолок=${MAX_DOWNLOAD_MB}MB"

cleanup() { echo "Остановка."; exit 0; }
trap cleanup SIGINT SIGTERM

while true; do
  TX_START=$(<"$TX_FILE")
  sleep "$WINDOW"
  TX_END=$(<"$TX_FILE")

  TX_DELTA=$(( TX_END - TX_START ))
  (( TX_DELTA < 0 )) && TX_DELTA=0

  TARGET_BYTES=$(awk -v d="$TX_DELTA" -v r="$RATIO" 'BEGIN{printf "%.0f", d*r}')
  MAX_BYTES=$(( MAX_DOWNLOAD_MB * 1024 * 1024 ))
  (( TARGET_BYTES > MAX_BYTES )) && TARGET_BYTES=$MAX_BYTES

  TS=$(date '+%F %H:%M:%S')
  TX_MB=$(awk -v b="$TX_DELTA"  'BEGIN{printf "%.2f", b/1048576}')
  TGT_MB=$(awk -v b="$TARGET_BYTES" 'BEGIN{printf "%.2f", b/1048576}')

  if (( TX_DELTA < MIN_TX_BYTES )); then
    echo "[$TS] TX=${TX_MB}MB — idle, пропуск"
    continue
  fi

  echo "[$TS] TX=${TX_MB}MB → качаю ${TGT_MB}MB"

  DOWNLOADED=0
  while (( DOWNLOADED < TARGET_BYTES )); do
    URL=${FILES[$RANDOM % ${#FILES[@]}]}
    REMAIN=$(( TARGET_BYTES - DOWNLOADED ))

    CURL_ARGS=(-s -o /dev/null
      --max-time 120
      --user-agent "Mozilla/5.0 (X11; Linux x86_64)"
      -r "0-$((REMAIN - 1))")
    if [[ "$LIMIT_RATE" != "0" ]]; then
      CURL_ARGS+=(--limit-rate "$LIMIT_RATE")
    fi

    BEFORE=$(<"$RX_FILE")
    curl "${CURL_ARGS[@]}" "$URL" || true
    AFTER=$(<"$RX_FILE")

    GOT=$(( AFTER - BEFORE ))
    (( GOT <= 0 )) && GOT=$REMAIN
    DOWNLOADED=$(( DOWNLOADED + GOT ))

    GOT_MB=$(awk -v b="$GOT" 'BEGIN{printf "%.2f", b/1048576}')
    echo "[$(date '+%H:%M:%S')]   +${GOT_MB}MB ← $URL"
  done

  DONE_MB=$(awk -v b="$DOWNLOADED" 'BEGIN{printf "%.2f", b/1048576}')
  echo "[$(date '+%F %H:%M:%S')] Окно: скачано ${DONE_MB}MB"
done
