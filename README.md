# HU X9: интернет через Wi-Fi + сохранение TCU/eCall линка

Отдельный **обратимый recipe** для ГУ Honda CR-V 2026 (SemiDrive X9, `honda_3ya`, build `20251205`).

Это не патч `/system`. Все изменения — в `/data` и `persist.*`; dm-verity, `/system`, `/vendor` и `boot` не трогаются.

## Дисклеймер

Эта инструкция проверена только на:

- Honda CR-V 2026;
- ГУ SemiDrive X9 (`honda_3ya`);
- прошивка `01.603.002`, идентификатор сборки `01.603.002_CXIC_20251205_D` (`20251205`);
- Android 12 / API 31.

На других моделях, прошивках, ревизиях ГУ или при других настройках ADB/root поведение не гарантируется. Скрипты могут изменить сетевую конфигурацию, `persist.eth.priority`, статические IP на `vlan11`/`vlan21`, выполнить команды через `su` и перезагрузить ГУ. Это может повлиять на TCU, OTA, CarPlay/CarLife, гарантию и работу автомобиля.

**Все действия выполняются на ваш риск.** Пользуясь инструкцией, вы подтверждаете, что действуете на свой риск и несёте всю ответственность за действия и возможные проблемы с ГУ. Автор репозитория не несёт ответственности за:

- поломку, циклическую перезагрузку, потерю данных или невозможность восстановить ГУ;
- проблемы с TCU, OTA, гарантией или дилерским обслуживанием;
- ДТП, травмы, ущерб имуществу или иные последствия;
- последствия нарушения местных законов и требований безопасности.

Перед применением:

- прочитайте README и скрипты;
- сделайте резервную копию/снимок состояния;
- убедитесь, что понимаете команды;
- не выполняйте на движущемся автомобиле.

Скрипты предоставляются «как есть», без гарантий.

Проект не связан с Honda, Hangsheng, SemiDrive или их дилерами.

## Что делает

1. Ставит `persist.eth.priority=50`, чтобы после reboot Ethernet-сети (`vlan11`/`vlan21`/`usb0`) получили score ниже Wi-Fi (60), и default-сеть ушла на `wlan0`.
2. Ставит статические IPv4 на `vlan11`/`vlan21`:
   - `vlan11` → `172.29.11.3/24`
   - `vlan21` → `172.29.21.3/24`
   - gateway/DNS не задаются, чтобы Ethernet не забирал default.
3. Проверяет, что TSU `172.29.11.5` доступен.

После этого приложения ГУ получают интернет через Wi-Fi/хотспот, а TCU/eCall-линк остаётся живым.

**16.11 вечером:** после cold boot вернулся eCall-рецидив (`Ecall system problem` + красная лампа SOS). Recipe сохраняет VLAN-линк, но не гарантирует прохождение eCall self-test; проверяйте eCall отдельно.

## Snapshot перед изменениями

`Enable-HuInternet.ps1 -Apply` сначала опрашивает **реальную** конфигурацию и только потом что-то меняет. Snapshot сохраняется в:

```text
artifacts\enable-<timestamp>\snapshot\
  state.json
  ethernet-dump.txt
  ip-addr-before.txt
  ip-route-before.txt
  ip-neigh-before.txt
  getprop-before.txt
  dumpsys-connectivity-before.txt
  dumpsys-ethernet-before.txt
```

`state.json` содержит:

- `serial`/`device_serial`, `model`, `build`, timestamp;
- `persist.eth.priority`: было ли свойство пустым или какое значение;
- `vlan11`/`vlan21`: `ipAssignment` (`DHCP`/`STATIC`/`UNASSIGNED`), CIDR, gateway, DNS, domains;
- runtime `ip addr` / `ip route` / `ip neigh` — как evidence для проверки.

`ipconfig.txt` не является основой snapshot и для rollback не используется. Если snapshot не удалось снять, скрипт останавливается до изменений.

## Требования

- Windows PowerShell 5.1+.
- ADB в `PATH` (или `-Adb`).
- Root на ГУ через `su`.
- ГУ подключён по ADB: `adb connect 192.168.137.232:5555` или USB Device mode.
- Прошивка `honda_3ya` / `20251205`. На другой модели скрипт откажется работать без `-Force`.

### su-password.txt

Пароль `su` читается автоматически из `su-password.txt` рядом со скриптом — без prompt и без параметра `-SuPassword`.

- Файл содержит одну строку с текущим паролем.
- Файл **не включён** в `manifest.json` и `SHA256SUMS.txt`.
- По решению владельца файл включён в этот public-репозиторий.
- Если файла нет или он пустой, `Enable -Apply`/`Rollback` падают с понятной ошибкой и ничего не меняют.

## Состав

```text
Enable-HuInternet.ps1    — snapshot + применить recipe
Verify-HuInternet.ps1    — read-only проверка после reboot
Rollback-HuInternet.ps1  — восстановить snapshot
manifest.json            — версия, target, зависимости, SHA-256 файлов
su-password.txt          — пароль su; в public-репозитории, не входит в manifest/SHA
tools/ethernet-config/   — dump/restore Ethernet через IEthernetManager
```

## Как пользоваться

### 0. Клонировать репозиторий

```powershell
git clone https://github.com/hongkilldong/hu-internet.git
cd hu-internet
```

### 1. Подключить ГУ

```powershell
adb connect 192.168.137.232:5555
adb devices -l
```

### 2. Посмотреть текущее состояние (ничего не меняет)

```powershell
.\Enable-HuInternet.ps1 -Serial 192.168.137.232:5555
```

Read-only режим не создаёт snapshot и не требует root.

### 3. Применить

```powershell
.\Enable-HuInternet.ps1 -Serial 192.168.137.232:5555 -Apply
```

Скрипт:

- проверит модель/загрузку/наличие `vlan11`;
- проверит root (при необходимости — через `su` с паролем из `su-password.txt`);
- снимет snapshot реальной конфигурации в `artifacts\enable-<timestamp>\snapshot\`;
- поставит статические IP на `vlan11`/`vlan21` через `EthernetConfig`;
- сделает link bounce VLAN (если не указан `-SkipLinkBounce`);
- выставит `persist.eth.priority=50`;
- проверит ping TSU.

**Reboot обязателен** для `persist.eth.priority`. Скрипт сам не перезагружает.

### 4. Перезагрузить ГУ вручную

После reboot:

```powershell
.\Verify-HuInternet.ps1 -Serial 192.168.137.232:5555
```

Ожидаемо:

- `persist.eth.priority = 50`;
- default network = `wlan0` (Wi-Fi);
- `vlan11` = `172.29.11.3/24`, `vlan21` = `172.29.21.3/24`;
- `ping 172.29.11.5` — 0% потерь;
- `ping -I wlan0 8.8.8.8` — 0% потерь;
- eCall-лампа зелёная на момент проверки; после cold boot возможен рецидив;
- CarLife провод/WLAN работает.

## Rollback

По умолчанию берётся **последний** snapshot с `state.json`:

```powershell
.\Rollback-HuInternet.ps1 -Serial 192.168.137.232:5555
```

Можно указать конкретный snapshot:

```powershell
.\Rollback-HuInternet.ps1 -Serial 192.168.137.232:5555 `
  -Snapshot .\artifacts\enable-20261116-211837\snapshot
```

Скрипт:

- проверяет, что `device_serial`/`model` snapshot совпадают с текущим ГУ;
- сохраняет текущее состояние в `artifacts\rollback-<timestamp>\`;
- возвращает `persist.eth.priority` ровно как было: значение или пустое;
- через `EthernetConfig` возвращает `vlan11`/`vlan21` их `ipAssignment` и static config;
- делает link bounce VLAN;
- пишет `ip addr`/`ip route` до и после.

После rollback нужен reboot. Проверка после reboot:

```powershell
.\Rollback-HuInternet.ps1 -Serial 192.168.137.232:5555 -VerifyOnly
```

`-VerifyOnly` ничего не меняет: сравнивает текущие `persist.eth.priority` и assignment/static config с snapshot и завершается с кодом `1`, если есть расхождения.

### Ограничения rollback

- Если исходно был `DHCP`, вернётся режим DHCP, а не гарантированно тот же lease/IP.
- Если IP/маршрут назначались вручную вне `IEthernetManager`, snapshot сохранит их в `runtime`, но rollback восстановит только assignment/static config. Ручные runtime-адреса при необходимости возвращаются вручную по `snapshot\ip-addr-before.txt`/`ip-route-before.txt`.
- Snapshot от другой машины/прошивки не применяется без `-Force`.

## Если что-то не так

- **`adb root` не даёт uid 0** — это нормально на этом ГУ; скрипт использует `su`.
- **`vlan11` отсутствует** — проверь Ethernet-кабель ГУ↔TSU; без него TCU-линк не поднять.
- **default всё ещё Ethernet после reboot** — проверь `getprop persist.eth.priority`; если не 50, property не сохранилось. Повтори `setprop` и reboot.
- **нет интернета в приложениях** — проверь Wi-Fi/DNS и `ping -I wlan0 8.8.8.8`; default должен быть `wlan0`.
- **TSU не пингуется** — проверь кабель/ARP; не меняй eCall-кодирование.
- **CarPlay/CarLife** — `persist.eth.priority` влияет на все Ethernet, включая `usb0`; проверь после reboot.
- **`su-password.txt` missing/empty** — создай файл с одной строкой пароля; скрипт не запрашивает пароль интерактивно.

## Ограничения

- Не трогать `/system`, `/vendor`, `boot`, dm-verity.
- Не отключать/не кодировать eCall.
- Recipe меняет конфигурацию Ethernet через системный сервис, а не файл `/system`; пользовательский конфиг остаётся в `/data`.
- На другой прошивке расположение/поведение может отличаться.

## Проверено

2026-11-16 на живом ГУ:

- `persist.eth.priority=50` + reboot;
- default ушёл на Wi-Fi, приложения получили интернет;
- `vlan11/21` сохранили статические IP;
- eCall-ошибка не вернулась на момент проверки; позже — рецидив после cold boot;
- CarLife проверен по проводу и WLAN.

Ручные шаги (`setprop`, статические IP, reboot) проверены 16.11. PowerShell-обёртки проверены синтаксически и на mock-ADB (DHCP и STATIC snapshot, rollback, `-VerifyOnly`); end-to-end на живом ГУ ещё не запускались — первый запуск делать без `-Apply`, затем `-Apply`.

Подробности: комментарии в скриптах и `manifest.json`.
