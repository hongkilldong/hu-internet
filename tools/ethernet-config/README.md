# EthernetConfig

Небольшой `app_process`-хелпер для чтения и восстановления конфигурации Ethernet через `IEthernetManager`.

## Зачем

Recipe `hu-internet` меняет:

- `persist.eth.priority`;
- `IpAssignment` и статический IPv4 на `vlan11`/`vlan21`.

`EthernetConfig` позволяет перед изменением снять реальную конфигурацию (`dump`), а при rollback вернуть её обратно (`set`/`static`/`dhcp`/`unassigned`). Он не читает и не парсит `ipconfig.txt`.

## Использование

```sh
# Реальная конфигурация: assignment, CIDR, gateway, DNS, domains
CLASSPATH=/data/local/tmp/ethconfig/classes.dex \
  app_process /system/bin EthernetConfig dump vlan11 vlan21

# Вернуть DHCP / UNASSIGNED
CLASSPATH=/data/local/tmp/ethconfig/classes.dex \
  app_process /system/bin EthernetConfig dhcp vlan11
CLASSPATH=/data/local/tmp/ethconfig/classes.dex \
  app_process /system/bin EthernetConfig unassigned vlan21

# Вернуть STATIC (gateway/DNS/domains можно не указывать)
CLASSPATH=/data/local/tmp/ethconfig/classes.dex \
  app_process /system/bin EthernetConfig static vlan11 172.29.11.3/24 none
CLASSPATH=/data/local/tmp/ethconfig/classes.dex \
  app_process /system/bin EthernetConfig set vlan21 STATIC 172.29.21.3/24 none "" ""
```

`dump` печатает одну строку на интерфейс:

```text
iface|ASSIGNMENT|cidr|gateway|dns1,dns2|domain1,domain2
```

Для `DHCP`/`UNASSIGNED` печатается только `iface|ASSIGNMENT`.

## Сборка

```powershell
javac --release 8 -d out EthernetConfig.java
d8 --min-api 26 --output dexout out\EthernetConfig.class
```

`classes.dex` уже собран и лежит рядом.

## Ограничения

- Нужен root (`su 0`) или system UID: `IEthernetManager` защищён permission.
- Не трогает `/system`; меняет только конфигурацию Ethernet через системный сервис.
- `setConfiguration` меняет assignment/static config, но proxy-настройки сохраняются: хелпер берёт существующий `IpConfiguration` и меняет только нужные поля.
- После изменения assignment может потребоваться link bounce (`ip link set vlan11 down/up`) или reboot.
- `DHCP` восстанавливает режим, а не гарантированно тот же lease/IP.
