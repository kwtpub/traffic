# traffic-noise

Адаптивный генератор шумового трафика для маскировки proxy/VPN-сервера.

Раз в `WINDOW` секунд читает счетчики `/sys/class/net/<iface>/statistics/tx_bytes`,
вычисляет дельту исходящего трафика и скачивает с публичных файловых зеркал
в `RATIO` раз больше байт. В результате соотношение RX:TX становится
характерным для обычного клиента (~2.5:1), а не для proxy-сервера (где TX > RX).

## Содержимое

- `traffic_noise.sh` — сам сервисный скрипт (бесконечный цикл замер → скачивание).
- `install.sh` — установщик: ставит зависимости, кладет скрипт в `/usr/local/bin/`,
  создает systemd unit и `EnvironmentFile`, запускает сервис.
- `README.md` — этот файл.

> `install.sh` встраивает копию `traffic_noise.sh` в свое тело между метками
> `NOISE_EOF`. При правке логики синхронизируй оба файла.

## Установка

**Один раз на сервере (Debian/Ubuntu, нужен root):**

```bash
curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/main/install.sh | sudo bash
```

После установки сервис уже запущен и добавлен в автозагрузку.

## Конфигурация

Все параметры — в `/etc/default/traffic-noise`. После правки:

```bash
sudo systemctl restart traffic-noise
```

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `IFACE` | автоопределение | Сетевой интерфейс (например, `eth0`, `ens3`) |
| `RATIO` | `2.5` | Во сколько раз RX должен превышать TX |
| `WINDOW` | `60` | Окно замера в секундах |
| `MAX_DOWNLOAD_MB` | `500` | Потолок скачивания за одно окно (страховка от лимитов VPS) |
| `MIN_TX_BYTES` | `1048576` | Если за окно отдано меньше — считаем idle, не качаем |
| `LIMIT_RATE` | `0` | `0` = без лимита; иначе передается в `curl --limit-rate` (например, `5M`) |

## Управление

```bash
sudo systemctl status traffic-noise           # состояние
sudo systemctl restart traffic-noise          # перезапустить
sudo systemctl stop traffic-noise             # остановить
sudo systemctl disable traffic-noise          # убрать из автозапуска

tail -f /var/log/traffic_noise.log            # логи скрипта
sudo journalctl -u traffic-noise -f           # systemd-журнал

vnstat -l                                      # live-скорость
vnstat -h                                      # трафик по часам
vnstat -d                                      # трафик по дням (проверить RX:TX)
```

Главная метрика — колонки `rx` / `tx` в `vnstat -d`. После суток работы
`rx` должен быть примерно в `RATIO` раз больше `tx`.

## Удаление

```bash
sudo systemctl disable --now traffic-noise
sudo rm /etc/systemd/system/traffic-noise.service
sudo rm /usr/local/bin/traffic_noise.sh
sudo rm /etc/default/traffic-noise
sudo rm /var/log/traffic_noise.log
sudo systemctl daemon-reload
```

## Требования

- Debian/Ubuntu с systemd
- Root-доступ для установки
- Исходящий доступ в интернет (HTTP/HTTPS)
- Зависимости (ставятся автоматически): `curl`, `ca-certificates`, `gawk`, `iproute2`, `vnstat`

## Источники файлов для скачивания

Список зеркал в `traffic_noise.sh` → массив `FILES`. Сейчас используются
публичные speedtest-серверы (Hetzner, Tele2, OVH) и зеркала ISO-образов
(Ubuntu, Debian). При необходимости замени на свои — главное, чтобы
поддерживался HTTP Range (`-r 0-N`), иначе скрипт не сможет качать
дозированными порциями.
