#!/bin/bash
# install.sh — автоматическая установка traffic_noise (адаптивная версия)
# как systemd-сервиса. Скачивает в RATIO раз больше байт, чем сервер
# отдает наружу (TX), чтобы соотношение RX:TX выглядело как у обычного
# клиента, а не как у proxy/VPN сервера.
#
# Установщик встраивает актуальную версию traffic_noise.sh в свое тело.
# Если правишь логику — синхронизируй блок между NOISE_EOF метками
# с traffic_noise.sh из этого же репозитория.
#
# Использование на сервере (Debian/Ubuntu, от root):
#   curl -fsSL https://<твой-raw-url> | sudo bash

set -euo pipefail

SCRIPT_PATH="/usr/local/bin/traffic_noise.sh"
SERVICE_PATH="/etc/systemd/system/traffic-noise.service"
ENV_PATH="/etc/default/traffic-noise"
LOG_PATH="/var/log/traffic_noise.log"
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
apt-get install -y -qq curl ca-certificates gawk iproute2 vnstat >/dev/null
systemctl enable --now vnstat >/dev/null 2>&1 || true

echo "[2/6] Записываю traffic_noise.sh в $SCRIPT_PATH..."
cat > "$SCRIPT_PATH" <<'NOISE_EOF'
#!/bin/bash
# Адаптивный шум: RX = RATIO * TX за окно WINDOW секунд.

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
  echo "Не удалось определить интерфейс. Задай IFACE=eth0 в /etc/default/traffic-noise" >&2
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
NOISE_EOF
chmod +x "$SCRIPT_PATH"

echo "[3/6] Создаю файл настроек $ENV_PATH..."
if [[ ! -f "$ENV_PATH" ]]; then
  cat > "$ENV_PATH" <<ENV_EOF
# Конфигурация traffic-noise. После правки: systemctl restart $SERVICE_NAME
#IFACE=eth0
RATIO=2.5
WINDOW=60
MAX_DOWNLOAD_MB=500
MIN_TX_BYTES=1048576
LIMIT_RATE=0
ENV_EOF
fi

echo "[4/6] Создаю systemd unit $SERVICE_PATH..."
cat > "$SERVICE_PATH" <<UNIT_EOF
[Unit]
Description=Adaptive Traffic Noise (RX = RATIO * TX)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-$ENV_PATH
ExecStart=$SCRIPT_PATH
Restart=always
RestartSec=10
User=root
StandardOutput=append:$LOG_PATH
StandardError=append:$LOG_PATH

[Install]
WantedBy=multi-user.target
UNIT_EOF

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
echo "Готово. Конфиг: $ENV_PATH"
echo "Логи:     tail -f $LOG_PATH"
echo "Журнал:   journalctl -u $SERVICE_NAME -f"
echo "Трафик:   vnstat -l    (live)   |   vnstat -h    (по часам)"
echo "Стоп:     systemctl stop $SERVICE_NAME"
