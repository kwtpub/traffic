#!/bin/bash
# traffic_noise.sh — непрерывный адаптивный шум через пул параллельных curl.
# Регулирует число параллельных скачиваний так, чтобы RX_rate = RATIO * TX_rate.

set -u

RATIO="${RATIO:-2.5}"
IFACE="${IFACE:-$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}"
MIN_WORKERS="${MIN_WORKERS:-0}"
MAX_WORKERS="${MAX_WORKERS:-32}"
CHUNK_MB="${CHUNK_MB:-200}"

FILES=(
  "https://speed.hetzner.de/10GB.bin"
  "https://speed.hetzner.de/1GB.bin"
  "http://speedtest.tele2.net/10GB.zip"
  "http://speedtest.tele2.net/1GB.zip"
  "https://proof.ovh.net/files/10Gb.dat"
  "https://proof.ovh.net/files/1Gb.dat"
  "http://ipv4.download.thinkbroadband.com/1GB.zip"
  "http://ipv4.download.thinkbroadband.com/512MB.zip"
  "https://releases.ubuntu.com/jammy/ubuntu-22.04.4-live-server-amd64.iso"
  "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.5.0-amd64-netinst.iso"
)

if [[ -z "$IFACE" ]]; then
  echo "Не удалось определить интерфейс. Задай IFACE=eth0." >&2
  exit 1
fi

TX_FILE="/sys/class/net/$IFACE/statistics/tx_bytes"
RX_FILE="/sys/class/net/$IFACE/statistics/rx_bytes"
[[ -r "$TX_FILE" && -r "$RX_FILE" ]] || { echo "Нет доступа к $TX_FILE/$RX_FILE" >&2; exit 1; }

WORKER_DIR="/run/traffic_noise.$$"
mkdir -p "$WORKER_DIR"

CHUNK_BYTES=$(( CHUNK_MB * 1024 * 1024 ))
END_OFFSET=$(( CHUNK_BYTES - 1 ))

cleanup() {
  echo "Остановка, убиваю воркеров..."
  for pidfile in "$WORKER_DIR"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    kill "$(<"$pidfile")" 2>/dev/null || true
  done
  rm -rf "$WORKER_DIR"
  exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# Один воркер: бесконечный цикл curl со случайным зеркалом.
# Запускается в фоне, PID пишется в pidfile, по завершении удаляет себя.
spawn_worker() {
  local id=$1
  local pidfile="$WORKER_DIR/$id.pid"

  (
    while true; do
      local url=${FILES[$RANDOM % ${#FILES[@]}]}
      curl -s --max-time 60 \
        --user-agent "Mozilla/5.0 (X11; Linux x86_64)" \
        -r "0-$END_OFFSET" \
        -o /dev/null \
        "$url" || sleep 1
    done
  ) &
  echo $! > "$pidfile"
}

kill_worker() {
  local pidfile=$1
  [[ -f "$pidfile" ]] || return
  local pid=$(<"$pidfile")
  kill "$pid" 2>/dev/null || true
  pkill -P "$pid" 2>/dev/null || true
  rm -f "$pidfile"
}

count_workers() {
  local n=0
  for pidfile in "$WORKER_DIR"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    local pid=$(<"$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      n=$((n+1))
    else
      rm -f "$pidfile"
    fi
  done
  echo "$n"
}

echo "Старт. Интерфейс=$IFACE RATIO=$RATIO MIN=$MIN_WORKERS MAX=$MAX_WORKERS CHUNK=${CHUNK_MB}MB"

# Стартовое количество воркеров
NEXT_ID=0
for ((i=0; i<MIN_WORKERS; i++)); do
  spawn_worker "$NEXT_ID"
  NEXT_ID=$((NEXT_ID+1))
done

TX_PREV=$(<"$TX_FILE")
RX_PREV=$(<"$RX_FILE")
T_PREV=$(date +%s.%N)

while true; do
  sleep 2

  TX_NOW=$(<"$TX_FILE")
  RX_NOW=$(<"$RX_FILE")
  T_NOW=$(date +%s.%N)

  read TX_RATE RX_RATE < <(awk \
    -v ta="$TX_PREV" -v tb="$TX_NOW" \
    -v ra="$RX_PREV" -v rb="$RX_NOW" \
    -v t1="$T_PREV"  -v t2="$T_NOW"  \
    'BEGIN{
       dt=t2-t1; if(dt<=0) dt=1;
       dtx=tb-ta; if(dtx<0) dtx=0;
       drx=rb-ra; if(drx<0) drx=0;
       printf "%.0f %.0f", dtx/dt, drx/dt;
     }')

  TX_PREV="$TX_NOW"; RX_PREV="$RX_NOW"; T_PREV="$T_NOW"

  TARGET_RX=$(awk -v r="$TX_RATE" -v k="$RATIO" 'BEGIN{printf "%.0f", r*k}')
  N=$(count_workers)

  # Решение: добавлять/убирать воркеров.
  # Деадзона ±10% чтобы не дрожать.
  LOW=$(awk -v t="$TARGET_RX"  'BEGIN{printf "%.0f", t*0.90}')
  HIGH=$(awk -v t="$TARGET_RX" 'BEGIN{printf "%.0f", t*1.10}')

  ACTION=""
  if (( RX_RATE < LOW )) && (( N < MAX_WORKERS )); then
    spawn_worker "$NEXT_ID"
    NEXT_ID=$((NEXT_ID+1))
    ACTION="+1"
  elif (( RX_RATE > HIGH )) && (( N > MIN_WORKERS )); then
    for pidfile in "$WORKER_DIR"/*.pid; do
      [[ -f "$pidfile" ]] || continue
      kill_worker "$pidfile"
      ACTION="-1"
      break
    done
  fi

  TX_MBIT=$(awk -v r="$TX_RATE" 'BEGIN{printf "%.1f", r*8/1000000}')
  RX_MBIT=$(awk -v r="$RX_RATE" 'BEGIN{printf "%.1f", r*8/1000000}')
  TGT_MBIT=$(awk -v r="$TARGET_RX" 'BEGIN{printf "%.1f", r*8/1000000}')

  echo "[$(date '+%H:%M:%S')] TX=${TX_MBIT}Mbit/s RX=${RX_MBIT}Mbit/s (target=${TGT_MBIT}) workers=$N ${ACTION}"
done
