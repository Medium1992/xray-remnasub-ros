# RemnaSub Xray RoS

Подписочный контейнер Xray-core для MikroTik RouterOS. Он принимает Remnawave/Happ-подписку в виде массива полных Xray JSON-конфигураций, позволяет выбрать один элемент и запускает его с минимальными локальными фрагментами для перехвата трафика RouterOS.

## Возможности

- несколько профилей подписок;
- сохранение исходного ответа без изменений;
- выбор полного JSON-конфига с сохранением выбора по SHA-256 fingerprint;
- проверка итогового `confdir` командой `xray run -test` до активации;
- откат к последнему рабочему source/runtime при ошибке транспорта, JSON, Xray или установки;
- ручное и периодическое обновление подписок;
- REDIR + TPROXY, чистый TPROXY и REDIR + TUN;
- HTTP-проверка конфигурации через её реальные Xray outbound;
- bootstrap недостающих файлов geodata до запуска ядра, обновления оставлены самому Xray;
- встроенная веб-панель без Clash API и внешнего dashboard;
- семь тем оформления и свой акцентный цвет, хранятся в контейнере;
- `amd64`, `arm64`, `arm/v7` и `arm/v5`.

По умолчанию веб-панель использует `admin` / `admin`. Смените пароль перед постоянной эксплуатацией.

## Перезапуски ядра

Обновление подписки само по себе Xray не перезапускает. Скачанный ответ сравнивается с работающей конфигурацией — четыре фрагмента `confdir`, режим перехвата, отпечаток исходника, выбранная позиция и набор ассетов geodata, — и при полном совпадении контейнер оставляет ядро работать, а в журнале появляется `configuration unchanged`. Неизменившаяся подписка, которую опрашивают раз в час, больше не рвёт соединения клиентов.

Сравнение идёт по всему ответу целиком, а не только по выбранной конфигурации. Поэтому если провайдер поменял сервер, который вы не используете, перезапуск всё равно произойдёт: список конфигураций в панели обязан остаться актуальным, а он хранится рядом с рабочим `confdir`.

Содержимое самих файлов geodata в сравнение не входит намеренно — см. раздел «Geodata»: их обновляет сам Xray, без перезапуска.

## Формат подписки

Корень ответа должен быть JSON-массивом:

```json
[
  {
    "remarks": "Server A",
    "dns": {},
    "routing": {},
    "outbounds": []
  },
  {
    "remarks": "Server B",
    "outbounds": []
  }
]
```

Каждый элемент массива является отдельным полным Xray-конфигом, как в Happ. Контейнер не извлекает первый proxy outbound и не собирает общий balancer. У выбранного элемента сохраняются `dns`, `routing`, все `outbounds`, цепочки `proxySettings`/`dialerProxy`, `observatory`, `burstObservatory`, `policy`, `reverse` и остальные штатные поля.

Поздними файлами `confdir` добавляются только:

- каталог assets и при необходимости стандартная секция geodata;
- локальный уровень логирования;
- mixed inbound `1080` и inbounds текущего режима перехвата.

Исходные inbounds не удаляются. Конфликт их портов с `80`, `1080`, REDIR или TPROXY необходимо исправить в шаблоне подписки.

Теги управляемых контейнером inbounds стабильны и зарезервированы:

| Тег | Где используется |
|---|---|
| `xray-remnasub-mixed` | mixed inbound во всех режимах |
| `xray-remnasub-tproxy` | общий TCP/UDP inbound в режиме `tproxy` |
| `xray-remnasub-tcp` | TCP REDIR в режимах `redir-tproxy` и `redir-tun` |
| `xray-remnasub-udp` | UDP TPROXY в режиме `redir-tproxy` |
| `xray-remnasub-tun` | TUN в режиме `redir-tun` |

Контейнер не переписывает `routing.rules[].inboundTag`. Правила без `inboundTag` продолжают применяться ко всем входам. Правило с тегом исходного inbound остаётся привязанным только к нему; для трафика RouterOS укажите нужные теги из таблицы в шаблоне подписки. Исходный inbound с зарезервированным тегом отклоняется, чтобы поздний `confdir`-файл не заменил его молча.

Пустой авторитетный ответ, HTTP `401/403/404/410/451` и явное ограничение HWID отключают активный runtime. Старые credentials в этом случае не продолжают работать. Ошибка сети, timeout, `5xx`, повреждённый JSON или невалидный Xray-конфиг сохраняют последнюю рабочую версию.

## Geodata

Если выбранный JSON уже содержит `geodata`, его `cron`, `assets` и `outbound` сохраняются. Если секции нет, контейнер добавляет:

```json
{
  "geodata": {
    "cron": "0 4 * * *",
    "assets": [
      {
        "url": "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat",
        "file": "geoip.dat"
      },
      {
        "url": "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat",
        "file": "geosite.dat"
      }
    ],
    "outbound": "direct"
  }
}
```

Если тег `direct` уже занят не-`freedom` outbound или отсутствует, контейнер безопасно использует существующий tagged `freedom` либо добавляет отдельный служебный `freedom` в конец списка. Исходные outbounds и их порядок не меняются.

### Кто и когда скачивает файлы

Расписание принадлежит Xray, bootstrap — контейнеру, и граница между ними проходит ровно в одном месте.

Xray обновляет geodata сам: `app/geodata` заводит планировщик по вашему `cron`, скачивает файлы **через собственный outbound** (то есть через прокси), атомарно подменяет их и перечитывает геобазы в памяти. Перезапуск ядра для этого не нужен и не делается.

Но при старте ядро не скачивает ничего. Хуже того, `infra/conf/geodata.go` вызывает `StatAsset` на каждый объявленный файл при разборе конфигурации, поэтому отсутствующий ассет не просто не скачивается — он роняет разбор, и Xray не проходит даже `xray run -test`. Это и есть единственная причина, по которой контейнер вообще трогает эти файлы: он скачивает **только недостающие** и только перед стартом. Если обязательный файл получить нельзя, новая конфигурация не активируется.

Уже лежащий файл контейнер не перекачивает и не трогает его `mtime`: соревноваться с ядром за один и тот же файл незачем, а лишняя запись в хранилище противоречит всему остальному устройству контейнера.

По той же причине содержимое файлов geodata не участвует в сравнении «изменилась ли конфигурация»: первое же обновление, сделанное самим Xray, выглядело бы как изменение и вызывало бы перезапуск. Значение имеет только состав набора ассетов.

### Куда именно пишутся обновления

`common/platform.GetAssetLocation` ищет файл сначала в `xray.location.asset`, а затем в `/usr/local/share/xray`, `/usr/share/xray` и `/opt/share/xray`. Загрузчик ядра пишет обновление туда, куда разрешился путь. Контейнер задаёт `xray.location.asset` в оверлее и в переменной окружения и гарантирует наличие файлов в выбранном каталоге, поэтому выигрывает всегда он. Если в системном пути обнаружится посторонняя копия — например, смонтированная снаружи, — панель покажет предупреждение: иначе обновления молча ушли бы мимо выбранного хранилища.

Для точных URL Loyalsoldier проверяются соседние `.sha256sum`. Пользовательские assets должны использовать HTTPS, безопасный относительный путь и размер не более 128 MiB на файл.

Доступны два режима хранения:

| Режим | Каталог | Поведение |
|---|---|---|
| `memory` | `/dev/shm/xray-remnasub/geodata/<hash>` | По умолчанию. Не пишет большие файлы на накопитель; после перезапуска контейнера файлы исчезают и скачиваются заново. |
| `persistent` | `/etc/xray/remnasub/geodata/<hash>` | Файлы остаются на подключённом накопителе и переживают перезапуск контейнера. |

Умолчание намеренно такое. Флешка на роутере — это обычно 128 МБ, а при установке на внутреннюю память запас ещё меньше, поэтому регулярно перезаписываемые двадцать мегабайт по умолчанию живут в оперативной памяти. Переключение на накопитель остаётся вашим осознанным выбором, а не решением контейнера.

Пока набор используется работающим Xray или HTTP-проверкой, задания контейнера его не изменяют: единственным писателем активного набора остаётся сам Xray.

## Проверка конфигураций

Кнопка проверки выполняет реальный HTTP-запрос через outbound выбранного полного JSON, а не TCP connect к адресу сервера.

Приоритет параметров:

1. подходящий `burstObservatory.pingConfig`;
2. подходящий `observatory`;
3. URL, timeout и метод из настроек контейнера.

Для проверки запускается короткоживущий изолированный Xray с полным массивом outbounds, поэтому сохраняются `sockopt.dialerProxy`, `proxySettings.tag` и другие зависимости. Проверка всех строк выполняется последовательно, чтобы не создавать пиковую нагрузку на роутер.

## Сетевые режимы

| Режим | TCP | UDP | Backend |
|---|---|---|---|
| `auto` | REDIR | TPROXY при поддержке, иначе TUN | определяется проверкой возможностей ядра |
| `redir-tproxy` | REDIR `12345` | TPROXY `12346` | nftables |
| `tproxy` | TPROXY `12346` | TPROXY `12346` | nftables |
| `redir-tun` | REDIR `12345` | TUN `Xray` | nftables либо iptables-legacy |

Если nftables доступен, но ядро не поддерживает TPROXY, на `amd64` и `arm64` используется nftables с REDIR + TUN. На ядре без nftables, а также на `arm/v7` и `arm/v5`, используется iptables-legacy. Контейнер удаляет только собственные таблицы/цепочки и не выполняет `nft flush ruleset` или очистку базовых iptables chains.

При старте Alpine нормализует стандартные policy rules:

```text
0:      from all lookup local
32766:  from all lookup main
32767:  from all lookup default
```

TPROXY добавляет `fwmark 1` в таблицу `100` с priority `100`. TUN использует таблицу `110` и rules `10000..10005`. При остановке Xray эти правила и собственные firewall objects удаляются.

## RouterOS

Пример ниже использует синтаксис `mountlists` и `envlists` из RouterOS 7.21+. На новом роутере сначала включите контейнеры в device mode:

```routeros
/system/device-mode/print
/system/device-mode/update mode=advanced container=yes
```

Пример адресации:

```routeros
/interface/veth/add name=XrayRemnaSub address=192.168.255.14/30 gateway=192.168.255.13
/ip/address/add address=192.168.255.13/30 interface=XrayRemnaSub
/container/mounts/add list=xray-remnasub-ros src=usb1/xray-remnasub dst=/etc/xray
/container/envs/add list=xray-remnasub-ros key=BASIC_AUTH_USER value=admin
/container/envs/add list=xray-remnasub-ros key=BASIC_AUTH_HASH value="\$1\$salt\$replace-with-your-digest"
```

Контейнер из registry:

```routeros
/container/config/set registry-url=https://ghcr.io tmpdir=usb1/pull
/container/add remote-image=ghcr.io/medium1992/xray-remnasub-ros:latest interface=XrayRemnaSub root-dir=usb1/xray-remnasub-root mountlists=xray-remnasub-ros envlists=xray-remnasub-ros logging=yes start-on-boot=yes comment=XrayRemnaSub
```

Маршрут с проверкой готовности контейнера:

```routeros
/routing/table/add name=XrayRemnaSub fib
/ip/route/add dst-address=0.0.0.0/0 gateway=192.168.255.14 routing-table=XrayRemnaSub check-gateway=ping comment=XrayRemnaSub
/routing/rule/add src-address=192.168.88.100/32 action=lookup-only-in-table table=XrayRemnaSub comment="XrayRemnaSub client"
```

Контейнер блокирует ICMP echo к своему gateway до успешного запуска Xray и установки правил. Поэтому `check-gateway=ping` отключает маршрут в состоянии fail-closed.

Веб-панель доступна по `http://192.168.255.14/`.

## Docker

```bash
docker run -d \
  --name xray-remnasub-ros \
  --restart unless-stopped \
  --cap-add NET_ADMIN \
  --device /dev/net/tun \
  -p 8080:80 \
  -v ./xray-remnasub:/etc/xray \
  -e BASIC_AUTH_USER=admin \
  -e BASIC_AUTH_HASH='$1$replace$the-generated-hash' \
  ghcr.io/medium1992/xray-remnasub-ros:latest
```

Хеш создаётся командой:

```bash
openssl passwd -1 'replace-with-a-long-password'
```

Либо во вкладке «Доступ» самой панели — она сгенерирует sha512crypt, который
надёжнее md5crypt из `openssl passwd -1`.

Если `BASIC_AUTH_HASH` не задан, контейнер не поднимает панель с общим для всех
паролем: он генерирует случайный пароль на каждый старт и печатает его в
журнал контейнера (`/log/print` в RouterOS, `docker logs` локально). Пароль
меняется при каждом перезапуске, поэтому для постоянной установки задайте
`BASIC_AUTH_HASH`.

Для локальной проверки mixed inbound можно дополнительно опубликовать `1080/tcp`.

## Сборка и TAR для RouterOS

```bash
docker buildx build \
  --platform linux/arm64 \
  --build-arg XRAY_VERSION=v26.7.28 \
  --provenance=false \
  --sbom=false \
  -t xray-remnasub-ros:v26.7.28-arm64 \
  --load .
```

Новые версии Docker с containerd image store могут экспортировать OCI layout, который старые RouterOS не распознают. Для самого совместимого ручного импорта нужен legacy `docker-archive`, например через Skopeo:

```bash
skopeo copy --format v2s2 \
  docker-daemon:xray-remnasub-ros:v26.7.28-arm64 \
  docker-archive:xray-remnasub-ros-v26.7.28-arm64.tar:xray-remnasub-ros:v26.7.28
gzip -9 xray-remnasub-ros-v26.7.28-arm64.tar
```

Корректный архив содержит `manifest.json`, `repositories` и `*/layer.tar`, а не `oci-layout` и `blobs/sha256/*`.

## Хранение и безопасность

В `/etc/xray/remnasub` хранятся профили, исходные подписки, response metadata и persistent geodata. Рабочие confdir, статусы, логи и memory geodata находятся в `/dev/shm/xray-remnasub`.

### Память

`/dev/shm` в контейнере — это половина оперативной памяти роутера. При хранилище geodata в памяти туда ложатся `geoip.dat` и `geosite.dat` (около 20 МБ вместе), а сам Xray с загруженными геобазами занимает ещё 40–80 МБ. На устройствах с 256 МБ (`hEX refresh`, `hAP ac²`) запас получается тонким: если к контейнеру примонтирован накопитель, переключите geodata на постоянное хранилище. Кнопка «Проверить все» в списке конфигураций поднимает второй экземпляр Xray рядом с работающим — на таких устройствах проверяйте конфигурации по одной.

### Время

Расписание обновления geodata (`geodata.cron`, по умолчанию `0 4 * * *`) считается по локальному времени контейнера. Переменная `TZ` не выставляется, поэтому без неё это 04:00 UTC. Добавьте `TZ` в `envlist`, если хотите привязать обновление к своему часовому поясу.

### Пароль

Генератор хеша во вкладке «Доступ» отдаёт `sha512crypt`, когда busybox в образе его поддерживает, и `md5crypt` в противном случае; какой алгоритм использован, написано рядом с полем. Проверяет хеш тот же busybox, который его сгенерировал, поэтому несовместимости быть не может.

Подписки содержат ключи доступа. Не публикуйте `/etc/xray`, не отключайте Basic Auth на доступном извне интерфейсе и используйте отдельный длинный пароль. Контейнер сам не добавляет и не публикует Xray API; при этом пользовательские API/inbounds из полного JSON сохраняются, поэтому контролируйте шаблон подписки.

## Диагностика

Веб-панель показывает HTTP status, размер ответа, этап задания, вывод `xray run -test`, last-good состояние, ограничения HWID, geodata и последние события.

Внутри контейнера полезны:

```sh
cat /dev/shm/xray-remnasub/events.log
cat /dev/shm/xray-remnasub/network.log
ip rule show
ip route show table 100
ip route show table 110
nft list tables
```

Если отсутствующий geodata asset не скачался, Xray не запускается. При memory storage это также означает, что после каждого перезапуска контейнеру нужен доступ к URL assets.
