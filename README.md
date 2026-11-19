# HU X9: интернет через Wi-Fi

Обратимая инструкция для Honda CR-V 2026 (SemiDrive X9, `honda_3ya`, `20251205`).

## Дисклеймер

Проверено только на Honda CR-V 2026 / SemiDrive X9 (`honda_3ya`), прошивка `01.603.002` (`20251205`), Android 12.

На других моделях и прошивках поведение не гарантируется. Все действия выполняются на ваш риск: автор не несёт ответственности за поломку ГУ, потерю данных, проблемы с OTA, гарантией или иные последствия. Скрипты предоставляются «как есть», без гарантий.

## Что делает

- Ставит `persist.eth.priority=50`, чтобы default-сеть ушла на Wi-Fi.
- Прописывает статические IP на `vlan11` (`172.29.11.3/24`) и `vlan21` (`172.29.21.3/24`) без gateway/DNS.
- Проверяет доступность TSU `172.29.11.5`.

Изменения только в `/data` и `persist.*`; `/system`, `/vendor`, `boot` и dm-verity не трогаются.

## Требования

- Windows PowerShell 5.1+.
- ADB в `PATH` или `-Adb`.
- Root на ГУ через `su`.
- ГУ подключён по ADB.
- Прошивка `honda_3ya` / `20251205`.

Пароль `su` читается автоматически из `su-password.txt` рядом со скриптом.

## Как пользоваться

### 1. Клонировать репозиторий

```powershell
git clone https://github.com/hongkilldong/hu-internet.git
cd hu-internet
```

### 2. Подключить ГУ

```powershell
adb connect 192.168.137.232:5555
adb devices -l
```

### 3. Проверить текущее состояние

```powershell
.\Enable-HuInternet.ps1 -Serial 192.168.137.232:5555
```

Ничего не меняет и не требует root.

### 4. Применить

```powershell
.\Enable-HuInternet.ps1 -Serial 192.168.137.232:5555 -Apply
```

### 5. Перезагрузить ГУ

Reboot обязателен для `persist.eth.priority`.

### 6. Проверить после reboot

```powershell
.\Verify-HuInternet.ps1 -Serial 192.168.137.232:5555
```

Ожидаемо: default-сеть — Wi-Fi, `vlan11`/`vlan21` с указанными IP, `ping 172.29.11.5` без потерь, интернет в приложениях работает.

### 7. Откатить

```powershell
.\Rollback-HuInternet.ps1 -Serial 192.168.137.232:5555
```

После rollback нужен reboot. Проверка без изменений:

```powershell
.\Rollback-HuInternet.ps1 -Serial 192.168.137.232:5555 -VerifyOnly
```

## Параметры

- `-Serial` — ADB serial ГУ.
- `-Adb` — путь к `adb.exe`, если его нет в `PATH`.
- `-Force` — пропустить проверку модели/прошивки.
- `-SkipLinkBounce` — не дёргать VLAN после записи static config.
- `-VerifyOnly` — только сравнить с snapshot, ничего не менять.

## Если что-то не так

- `adb root` не даёт uid 0 — это нормально; используется `su`.
- Нет `vlan11` — проверьте Ethernet-кабель ГУ↔TSU.
- После reboot default всё ещё Ethernet — проверьте `getprop persist.eth.priority`; должно быть `50`, затем reboot.
- Нет интернета в приложениях — проверьте Wi-Fi/DNS и `ping -I wlan0 8.8.8.8`.
