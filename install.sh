#!/bin/bash
# install.sh — автоматическая установка traffic_noise (адаптивный шум
# с развязкой формы графика) как systemd-сервиса.
#
# Использование на сервере (Debian/Ubuntu, от root):
#   curl -fsSL https://raw.githubusercontent.com/strelkatech/traffic-noise/main/install.sh | sudo bash

set -euo pipefail

SCRIPT_PATH="/usr/local/bin/traffic_noise.sh"
SERVICE_PATH="/etc/systemd/system/traffic-noise.service"
ENV_PATH="/etc/default/traffic-noise"
LOG_PATH="/var/log/traffic_noise.log"
LOGROTATE_PATH="/etc/logrotate.d/traffic-noise"
SERVICE_NAME="traffic-noise"

if [[ $EUID -ne 0 ]]; then
  echo "Ошибка: запускай через sudo или от root." >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "Ошибка: systemd не найден. Скрипт рассчитан на Debian/Ubuntu." >&2
  exit 1
fi

echo "[1/6] Устанавливаю зависимости..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gawk iproute2 procps vnstat logrotate >/dev/null
systemctl enable --now vnstat >/dev/null 2>&1 || true

echo "[2/6] Записываю traffic_noise.sh в $SCRIPT_PATH..."
cat > "$SCRIPT_PATH" <<'NOISE_EOF'
#!/bin/bash
# Адаптивный шум с развязкой формы графика.
# Накапливает "долг" RX = RATIO * TX_total, тратит его плавно через окно
# SMOOTH_WINDOW + базовый шум BASE_MBIT + случайный jitter ±JITTER.
# График RX визуально не коррелирует с TX.

set -u

RATIO="${RATIO:-2.5}"
IFACE="${IFACE:-$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}"
MIN_WORKERS="${MIN_WORKERS:-1}"
MAX_WORKERS="${MAX_WORKERS:-32}"
CHUNK_MB="${CHUNK_MB:-200}"
SMOOTH_WINDOW="${SMOOTH_WINDOW:-300}"
BASE_MBIT="${BASE_MBIT:-10}"
MAX_NOISE_MBIT="${MAX_NOISE_MBIT:-400}"
JITTER="${JITTER:-0.30}"
VERBOSE="${VERBOSE:-0}"

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
  echo "Не удалось определить интерфейс. Задай IFACE=eth0 в /etc/default/traffic-noise" >&2
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
  for pidfile in "$WORKER_DIR"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    kill "$(<"$pidfile")" 2>/dev/null || true
  done
  rm -rf "$WORKER_DIR"
  exit 0
}
trap cleanup SIGINT SIGTERM EXIT

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

kill_one_worker() {
  for pidfile in "$WORKER_DIR"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    local pid=$(<"$pidfile")
    kill "$pid" 2>/dev/null || true
    pkill -P "$pid" 2>/dev/null || true
    rm -f "$pidfile"
    return 0
  done
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

echo "Старт. iface=$IFACE ratio=$RATIO smooth=${SMOOTH_WINDOW}s base=${BASE_MBIT}Mbit/s max_noise=${MAX_NOISE_MBIT}Mbit/s jitter=$JITTER"

NEXT_ID=0
for ((i=0; i<MIN_WORKERS; i++)); do
  spawn_worker "$NEXT_ID"; NEXT_ID=$((NEXT_ID+1))
done

DEBT=0
BASE_BPS=$(awk -v m="$BASE_MBIT" 'BEGIN{printf "%.0f", m*1000000/8}')
MAX_NOISE_BPS=$(awk -v m="$MAX_NOISE_MBIT" 'BEGIN{printf "%.0f", m*1000000/8}')
TARGET_RATE_BPS=$BASE_BPS
EMA_ALPHA="0.05"

TX_PREV=$(<"$TX_FILE")
RX_PREV=$(<"$RX_FILE")
T_PREV=$(date +%s.%N)

SUM_TX=0; SUM_RX=0; SUM_TGT=0; SUM_N=0; SUM_DEBT=0; TICKS=0
LAST_SUMMARY=$(date +%s)

while true; do
  sleep 2

  TX_NOW=$(<"$TX_FILE")
  RX_NOW=$(<"$RX_FILE")
  T_NOW=$(date +%s.%N)

  read DT TX_DELTA RX_DELTA < <(awk \
    -v ta="$TX_PREV" -v tb="$TX_NOW" \
    -v ra="$RX_PREV" -v rb="$RX_NOW" \
    -v t1="$T_PREV"  -v t2="$T_NOW"  \
    'BEGIN{
       dt=t2-t1; if(dt<=0) dt=1;
       dtx=tb-ta; if(dtx<0) dtx=0;
       drx=rb-ra; if(drx<0) drx=0;
       printf "%.3f %.0f %.0f", dt, dtx, drx;
     }')

  TX_PREV="$TX_NOW"; RX_PREV="$RX_NOW"; T_PREV="$T_NOW"

  TX_RATE=$(awk -v d="$TX_DELTA" -v t="$DT" 'BEGIN{printf "%.0f", d/t}')
  RX_RATE=$(awk -v d="$RX_DELTA" -v t="$DT" 'BEGIN{printf "%.0f", d/t}')

  RAW_ADD=$(awk -v tx="$TX_DELTA" -v r="$RATIO" 'BEGIN{printf "%.0f", tx*r}')
  CAP_ADD=$(awk -v tx="$TX_DELTA" -v cap="$MAX_NOISE_BPS" -v dt="$DT" \
    'BEGIN{printf "%.0f", tx + cap*dt}')
  if (( RAW_ADD > CAP_ADD )); then
    ADD_DEBT=$CAP_ADD
  else
    ADD_DEBT=$RAW_ADD
  fi
  DEBT=$(( DEBT + ADD_DEBT - RX_DELTA ))
  (( DEBT < 0 )) && DEBT=0

  WANT_BPS=$(awk -v d="$DEBT" -v w="$SMOOTH_WINDOW" -v b="$BASE_BPS" \
    'BEGIN{printf "%.0f", d/w + b}')
  HARD_CAP=$(( TX_RATE + MAX_NOISE_BPS ))
  (( WANT_BPS > HARD_CAP )) && WANT_BPS=$HARD_CAP

  TARGET_RATE_BPS=$(awk -v cur="$TARGET_RATE_BPS" -v want="$WANT_BPS" -v a="$EMA_ALPHA" \
    'BEGIN{printf "%.0f", cur + a*(want-cur)}')

  JITTER_RATE=$(awk -v r="$TARGET_RATE_BPS" -v j="$JITTER" -v rnd="$RANDOM" \
    'BEGIN{
       srand(rnd);
       k = 1 + j*(2*rand()-1);
       printf "%.0f", r*k;
     }')

  N=$(count_workers)
  LOW=$(awk  -v t="$JITTER_RATE" 'BEGIN{printf "%.0f", t*0.85}')
  HIGH=$(awk -v t="$JITTER_RATE" 'BEGIN{printf "%.0f", t*1.15}')

  ACTION=""
  if (( RX_RATE < LOW )) && (( N < MAX_WORKERS )); then
    spawn_worker "$NEXT_ID"; NEXT_ID=$((NEXT_ID+1))
    ACTION="+1"
  elif (( RX_RATE > HIGH )) && (( N > MIN_WORKERS )); then
    kill_one_worker
    ACTION="-1"
  fi

  if [[ "$VERBOSE" == "1" ]]; then
    TX_M=$(awk -v r="$TX_RATE" 'BEGIN{printf "%.1f", r*8/1000000}')
    RX_M=$(awk -v r="$RX_RATE" 'BEGIN{printf "%.1f", r*8/1000000}')
    TGT_M=$(awk -v r="$JITTER_RATE" 'BEGIN{printf "%.1f", r*8/1000000}')
    DEBT_MB=$(awk -v d="$DEBT" 'BEGIN{printf "%.1f", d/1048576}')
    echo "[$(date '+%H:%M:%S')] TX=${TX_M} RX=${RX_M} target=${TGT_M} Mbit/s debt=${DEBT_MB}MB workers=$N $ACTION"
  else
    SUM_TX=$(( SUM_TX + TX_RATE ))
    SUM_RX=$(( SUM_RX + RX_RATE ))
    SUM_TGT=$(( SUM_TGT + JITTER_RATE ))
    SUM_N=$(( SUM_N + N ))
    SUM_DEBT=$(( SUM_DEBT + DEBT ))
    TICKS=$(( TICKS + 1 ))

    NOW=$(date +%s)
    if (( NOW - LAST_SUMMARY >= 60 )); then
      AVG_TX=$(( SUM_TX / TICKS ))
      AVG_RX=$(( SUM_RX / TICKS ))
      AVG_TGT=$(( SUM_TGT / TICKS ))
      AVG_DEBT=$(( SUM_DEBT / TICKS ))
      AVG_N=$(awk -v s="$SUM_N" -v t="$TICKS" 'BEGIN{printf "%.1f", s/t}')

      TX_M=$(awk -v r="$AVG_TX"  'BEGIN{printf "%.1f", r*8/1000000}')
      RX_M=$(awk -v r="$AVG_RX"  'BEGIN{printf "%.1f", r*8/1000000}')
      TGT_M=$(awk -v r="$AVG_TGT" 'BEGIN{printf "%.1f", r*8/1000000}')
      DEBT_MB=$(awk -v d="$AVG_DEBT" 'BEGIN{printf "%.1f", d/1048576}')
      RATIO_NOW=$(awk -v t="$AVG_TX" -v r="$AVG_RX" 'BEGIN{if(t<1) t=1; printf "%.2f", r/t}')

      echo "[$(date '+%F %H:%M:%S')] avg/min: TX=${TX_M} RX=${RX_M} target=${TGT_M} Mbit/s | ratio=${RATIO_NOW} | debt=${DEBT_MB}MB workers~${AVG_N}"

      SUM_TX=0; SUM_RX=0; SUM_TGT=0; SUM_N=0; SUM_DEBT=0; TICKS=0
      LAST_SUMMARY=$NOW
    fi
  fi
done
NOISE_EOF
chmod +x "$SCRIPT_PATH"

echo "[3/6] Создаю systemd unit $SERVICE_PATH..."
cat > "$SERVICE_PATH" <<UNIT_EOF
[Unit]
Description=Adaptive Traffic Noise (smoothed, decoupled from TX shape)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-$ENV_PATH
ExecStart=$SCRIPT_PATH
Restart=always
RestartSec=10
User=root
LimitNOFILE=65536
StandardOutput=append:$LOG_PATH
StandardError=append:$LOG_PATH

[Install]
WantedBy=multi-user.target
UNIT_EOF

if [[ ! -f "$ENV_PATH" ]]; then
  cat > "$ENV_PATH" <<ENV_EOF
# Конфигурация traffic-noise (опционально). После правки: systemctl restart $SERVICE_NAME
#IFACE=eth0
#RATIO=2.5
#MIN_WORKERS=1
#MAX_WORKERS=32
#CHUNK_MB=200
#SMOOTH_WINDOW=300       # окно сглаживания, сек (300 = долг гасится за 5 минут)
#BASE_MBIT=10            # базовый шум при idle, Mbit/s
#MAX_NOISE_MBIT=400      # потолок прибавки RX над TX (RX <= TX + MAX_NOISE_MBIT)
#JITTER=0.30             # рандом-разброс ±30%
#VERBOSE=0
ENV_EOF
fi

echo "[4/6] Создаю logrotate-конфиг $LOGROTATE_PATH..."
cat > "$LOGROTATE_PATH" <<LR_EOF
$LOG_PATH {
    daily
    rotate 7
    maxsize 50M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
LR_EOF
chmod 644 "$LOGROTATE_PATH"

touch "$LOG_PATH"
chmod 644 "$LOG_PATH"

echo "[5/6] Перезагружаю systemd, включаю автозапуск..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1

echo "[6/6] Запускаю сервис..."
systemctl restart "$SERVICE_NAME"

sleep 1
systemctl status "$SERVICE_NAME" --no-pager -l || true

echo
echo "Готово."
echo "Логи:     tail -f $LOG_PATH                  (тихий режим: 1 строка/мин)"
echo "Подробно: VERBOSE=1 в $ENV_PATH              (1 строка/2 сек)"
echo "Журнал:   journalctl -u $SERVICE_NAME -f"
echo "Трафик:   vnstat -h                          (по часам, проверить RX:TX)"
echo "Стоп:     systemctl stop $SERVICE_NAME"
