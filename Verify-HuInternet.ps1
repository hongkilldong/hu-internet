#requires -Version 5.1
<#
.SYNOPSIS
    Verify the HU X9 internet/TCU recipe after reboot.

.DESCRIPTION
    Read-only checks:
      - persist.eth.priority = 50
      - default network is Wi-Fi (wlan0)
      - vlan11/vlan21 have static IPv4
      - TSU 172.29.11.5 is reachable
      - internet works through wlan0

    No root and no changes.

    For rollback verification against the pre-recipe snapshot use:
      .\Rollback-HuInternet.ps1 -Serial <serial> -VerifyOnly

.EXAMPLE
    .\Verify-HuInternet.ps1 -Serial 192.168.137.232:5555
#>
[CmdletBinding()]
param(
    [string]$Adb = "",
    [string]$Serial = "",
    [string]$OutDir = ""
)

$ErrorActionPreference = "Continue"

function Resolve-Adb {
    param([string]$Explicit)
    if ($Explicit) { return $Explicit }
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($candidate in @(
            "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
            "C:\platform-tools\adb.exe")) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw "adb not found. Pass -Adb 'C:\path\to\adb.exe'."
}

$Adb = Resolve-Adb -Explicit $Adb
if (-not $Serial) {
    $devices = @(& $Adb devices -l 2>&1 | Where-Object { $_ -match '\sdevice(\s|$)' })
    if ($devices.Count -eq 1) {
        $Serial = ($devices[0] -split '\s+')[0]
    } elseif ($devices.Count -eq 0) {
        throw "No ADB device. Connect the HU or run: adb connect <HU_IP>:5555"
    } else {
        throw ("More than one ADB device; pass -Serial. Devices:`n" + ($devices -join "`n"))
    }
}
if ($Serial -match '^\d{1,3}(\.\d{1,3}){3}:\d+$') {
    & $Adb connect $Serial 2>&1 | Out-Null
    Start-Sleep -Milliseconds 700
}

$AdbArgs = @("-s", $Serial)
$state = (& $Adb @AdbArgs get-state 2>$null | Out-String).Trim()
if ($state -ne "device") {
    throw "ADB device '$Serial' is not available. Connect the HU and retry."
}
$RunId = Get-Date -Format "yyyyMMdd-HHmmss"
if (-not $OutDir) {
    $OutDir = Join-Path $PSScriptRoot ("artifacts\verify-" + $RunId)
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

function Invoke-AdbShell {
    param([Parameter(Mandatory)][string]$Command)
    $out = & $Adb @AdbArgs shell $Command 2>&1 | Out-String
    return $out.TrimEnd()
}

$priority = Invoke-AdbShell "getprop persist.eth.priority"
$conn = Invoke-AdbShell "dumpsys connectivity"
$addr = Invoke-AdbShell "ip -4 addr"
$route = Invoke-AdbShell "ip route show table all"
$tsu = Invoke-AdbShell "ping -c 2 -W 1 172.29.11.5"
$net = Invoke-AdbShell "ping -I wlan0 -c 2 -W 2 8.8.8.8"

$conn | Set-Content -LiteralPath (Join-Path $OutDir "dumpsys-connectivity.txt") -Encoding utf8
$addr | Set-Content -LiteralPath (Join-Path $OutDir "ip-addr.txt") -Encoding utf8
$route | Set-Content -LiteralPath (Join-Path $OutDir "ip-route.txt") -Encoding utf8
$tsu | Set-Content -LiteralPath (Join-Path $OutDir "ping-tsu.txt") -Encoding utf8
$net | Set-Content -LiteralPath (Join-Path $OutDir "ping-internet.txt") -Encoding utf8

$activeId = ""
$m = [regex]::Match($conn, 'Active default network:\s*(\d+)')
if ($m.Success) { $activeId = $m.Groups[1].Value }

$activeIface = ""
if ($activeId) {
    $m = [regex]::Match($conn, "NetworkAgentInfo\{network\{$activeId\}[^\r\n]*InterfaceName:\s*([A-Za-z0-9_.-]+)")
    if ($m.Success) { $activeIface = $m.Groups[1].Value }
}

$vlan11 = $addr -match '(?m)^\s*inet\s+172\.29\.11\.3/24'
$vlan21 = $addr -match '(?m)^\s*inet\s+172\.29\.21\.3/24'
$tsuOk = $tsu -match '(?m)(?<!\d)0% packet loss'
$netOk = $net -match '(?m)(?<!\d)0% packet loss'
$priorityOk = $priority -eq "50"
$wifiOk = $activeIface -eq "wlan0"

Write-Host ""
Write-Host "HU internet/TCU verification"
Write-Host "  persist.eth.priority : $priority  $(if ($priorityOk) { '[OK]' } else { '[FAIL, expected 50]' })"
Write-Host "  active default       : $activeId / $activeIface  $(if ($wifiOk) { '[OK]' } else { '[FAIL, expected wlan0]' })"
Write-Host "  vlan11 172.29.11.3   : $(if ($vlan11) { '[OK]' } else { '[FAIL]' })"
Write-Host "  vlan21 172.29.21.3   : $(if ($vlan21) { '[OK]' } else { '[FAIL]' })"
Write-Host "  TSU 172.29.11.5      : $(if ($tsuOk) { '[OK]' } else { '[FAIL]' })"
Write-Host "  internet via wlan0   : $(if ($netOk) { '[OK]' } else { '[FAIL]' })"
Write-Host ""
Write-Host "Artifacts: $OutDir"
Write-Host "Rollback check: .\Rollback-HuInternet.ps1 -Serial $Serial -VerifyOnly"

if (-not ($priorityOk -and $wifiOk -and $vlan11 -and $vlan21 -and $tsuOk -and $netOk)) {
    Write-Host "Some checks failed. See artifacts and README.md."
}
