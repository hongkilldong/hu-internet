#requires -Version 5.1
<#
.SYNOPSIS
    Roll back the HU X9 internet recipe from the snapshot taken before applying it.

.DESCRIPTION
    The snapshot is created by Enable-HuInternet.ps1 before any change:
      artifacts\enable-<timestamp>\snapshot\state.json
      artifacts\enable-<timestamp>\snapshot\ethernet-dump.txt
      ip-addr/ip-route/ip-neigh/dumpsys files

    Rollback restores the real network configuration from state.json:
      - persist.eth.priority (value or empty);
      - vlan11/vlan21 IpAssignment and static config (DHCP/STATIC/UNASSIGNED).

    It does not rely on ipconfig.txt. The snapshot stores the real
    IEthernetManager assignment/static config plus runtime evidence.

    The su password is read from su-password.txt next to this script.

.PARAMETER Snapshot
    Snapshot directory or path to state.json. Default: latest
    artifacts\enable-*\snapshot under this folder.

.PARAMETER VerifyOnly
    Do not change anything; compare current state with the snapshot.

.PARAMETER Force
    Allow restoring a snapshot whose device serial/model does not match the current HU.

.EXAMPLE
    .\Rollback-HuInternet.ps1 -Serial 192.168.137.232:5555

.EXAMPLE
    .\Rollback-HuInternet.ps1 -Serial 192.168.137.232:5555 -Snapshot .\artifacts\enable-20261116-211837\snapshot

.EXAMPLE
    .\Rollback-HuInternet.ps1 -Serial 192.168.137.232:5555 -VerifyOnly
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [string]$Adb = "",
    [string]$Serial = "",
    [string]$Snapshot = "",
    [switch]$VerifyOnly,
    [switch]$Force,
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

function Write-ShellFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text
    )
    $lf = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $lf, $utf8)
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

if (-not $Snapshot) {
    $artifacts = Join-Path $PSScriptRoot "artifacts"
    $latest = Get-ChildItem -LiteralPath $artifacts -Directory -Filter "enable-*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "snapshot\state.json") } |
        Select-Object -First 1
    if (-not $latest) {
        throw "No snapshot found under $artifacts. Apply Enable-HuInternet.ps1 -Apply first or pass -Snapshot."
    }
    $Snapshot = Join-Path $latest.FullName "snapshot"
}
$Snapshot = (Resolve-Path -LiteralPath $Snapshot).Path
$statePath = if ((Get-Item -LiteralPath $Snapshot).PSIsContainer) {
    Join-Path $Snapshot "state.json"
} else {
    $Snapshot
}
if (-not (Test-Path -LiteralPath $statePath)) {
    throw "Snapshot state.json not found: $statePath"
}
$snapshotDir = Split-Path -Parent $statePath
$snap = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json

$RunId = Get-Date -Format "yyyyMMdd-HHmmss"
if (-not $OutDir) {
    $OutDir = Join-Path $PSScriptRoot ("artifacts\rollback-" + $RunId)
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$RunLog = Join-Path $OutDir "run.log"

function Write-Log {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    Write-Host $Text
    Add-Content -LiteralPath $RunLog -Value $Text -Encoding utf8
}

function Invoke-AdbShell {
    param([Parameter(Mandatory)][string]$Command)
    $out = & $Adb @AdbArgs shell $Command 2>&1 | Out-String
    return $out.TrimEnd()
}

$script:RootMode = ""
$script:SuPasswordPlain = ""
$script:RemoteDex = ""

function Get-SuPassword {
    $file = Join-Path $PSScriptRoot "su-password.txt"
    if (-not (Test-Path -LiteralPath $file)) {
        throw "Missing $file. Create it with the HU su password (one line)."
    }
    $password = (Get-Content -LiteralPath $file -Raw -Encoding UTF8).Trim()
    if (-not $password) {
        throw "su-password.txt is empty."
    }
    if ($password -match '[\r\n]') {
        throw "su-password.txt must contain a single line."
    }
    return $password
}

function Invoke-RootScript {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$Name
    )
    $local = Join-Path $OutDir ("root-{0}-{1}.sh" -f $RunId, $Name)
    $remote = "/data/local/tmp/hu-internet-rollback-{0}-{1}.sh" -f $RunId, $Name
    $body = "set -e`n" + $Script + "`necho __OK__`n"
    Write-ShellFile -Path $local -Text $body

    & $Adb @AdbArgs push $local $remote 2>&1 | Out-Null
    & $Adb @AdbArgs shell "chmod 755 $remote" 2>&1 | Out-Null

    if ($script:RootMode -eq "adb") {
        $out = & $Adb @AdbArgs shell "sh $remote" 2>&1 | Out-String
    } else {
        $escaped = $script:SuPasswordPlain.Replace("'", "'\''")
        $out = & $Adb @AdbArgs shell "echo '$escaped' | su 0 sh $remote" 2>&1 | Out-String
    }

    & $Adb @AdbArgs shell "rm -f $remote" 2>&1 | Out-Null
    $out | Out-File -LiteralPath (Join-Path $OutDir ("root-{0}.log" -f $Name)) -Encoding utf8

    if ($out -notmatch "__OK__") {
        throw "Root command failed ($Name):`n$out"
    }
    return ($out -replace "__OK__", "").Trim()
}

function Get-Root {
    $uid = Invoke-AdbShell "id -u"
    if ($uid -eq "0") {
        $script:RootMode = "adb"
        Write-Log "Root: adb"
        return
    }
    $script:RootMode = "su"
    $script:SuPasswordPlain = Get-SuPassword
    $probe = Invoke-RootScript -Script "id -u" -Name "root-probe"
    if ($probe -notmatch '(?m)^\s*0\s*$') {
        throw "su root check failed. Wrong su password or su is unavailable."
    }
    Write-Log "Root: su"
}

function Save-Text {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $Text | Set-Content -LiteralPath (Join-Path $OutDir $Name) -Encoding utf8 -ErrorAction Stop
}

function Push-EthernetConfig {
    $dex = Join-Path $PSScriptRoot "tools\ethernet-config\classes.dex"
    if (-not (Test-Path -LiteralPath $dex)) {
        throw "Missing dependency: $dex"
    }
    $script:RemoteDex = "/data/local/tmp/hu-internet-rollback-$RunId-ethconfig.dex"
    & $Adb @AdbArgs push $dex $script:RemoteDex 2>&1 | Out-Null
}

function Get-CurrentDump {
    $script = "CLASSPATH=$script:RemoteDex app_process /system/bin EthernetConfig dump vlan11 vlan21"
    return Invoke-RootScript -Script $script -Name "current-dump"
}

function Parse-Dump {
    param([Parameter(Mandatory)][string]$Dump)
    $result = [ordered]@{}
    foreach ($line in ($Dump -split "`r?`n")) {
        if ($line -notmatch '^[A-Za-z0-9_.-]+\|') { continue }
        $parts = $line -split '\|'
        $iface = $parts[0]
        $assignment = $parts[1]
        if ($assignment -eq "MISSING") { continue }
        $dns = @()
        if ($parts.Count -gt 4 -and $parts[4]) { $dns = @($parts[4] -split ',') }
        $domains = @()
        if ($parts.Count -gt 5 -and $parts[5]) { $domains = @($parts[5] -split ',') }
        $result[$iface] = [ordered]@{
            assignment = $assignment
            cidr       = if ($parts.Count -gt 2) { $parts[2] } else { "" }
            gateway    = if ($parts.Count -gt 3) { $parts[3] } else { "" }
            dns        = $dns
            domains    = $domains
        }
    }
    return $result
}

function Compare-Snapshot {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Priority
    )
    $fail = @()
    $expectedPriority = if ($Expected.priority.present) { $Expected.priority.value } else { "" }
    if ($Priority -ne $expectedPriority) {
        $fail += "persist.eth.priority: expected '$expectedPriority', got '$Priority'"
    }
    foreach ($name in @("vlan11", "vlan21")) {
        $e = $Expected.interfaces.$name
        $a = $Actual[$name]
        if (-not $a) { $fail += "${name}: missing"; continue }
        if ($e.assignment -ne $a.assignment) {
            $fail += "$name assignment: expected $($e.assignment), got $($a.assignment)"
        }
        if ($e.assignment -eq "STATIC") {
            if ($e.cidr -ne $a.cidr) { $fail += "$name cidr: expected $($e.cidr), got $($a.cidr)" }
            if ($e.gateway -ne $a.gateway) { $fail += "$name gateway: expected $($e.gateway), got $($a.gateway)" }
            if (($e.dns -join ',') -ne ($a.dns -join ',')) { $fail += "$name dns mismatch" }
            if (($e.domains -join ',') -ne ($a.domains -join ',')) { $fail += "$name domains mismatch" }
        }
    }
    return $fail
}

$currentModel = Invoke-AdbShell "getprop ro.product.device"
$currentDeviceSerial = Invoke-AdbShell "getprop ro.serialno"
if (-not $currentDeviceSerial) { $currentDeviceSerial = Invoke-AdbShell "getprop ro.boot.serialno" }
if ($snap.device_serial -and $currentDeviceSerial) {
    if ($snap.device_serial -ne $currentDeviceSerial -and -not $Force) {
        throw "Snapshot device serial '$($snap.device_serial)' does not match current '$currentDeviceSerial'. Use -Force only if you are sure."
    }
} elseif ($snap.serial -and $snap.serial -ne $Serial -and -not $Force) {
    throw "Snapshot ADB serial '$($snap.serial)' does not match current '$Serial'. Use -Force only if you are sure."
}
if ($snap.model -and $snap.model -ne $currentModel -and -not $Force) {
    throw "Snapshot model '$($snap.model)' does not match current '$currentModel'. Use -Force only if you are sure."
}

Write-Log "HU: $Serial"
Write-Log "Snapshot: $snapshotDir"
Write-Log "Artifacts: $OutDir"
Write-Log "Mode: $(if ($VerifyOnly) { 'verify-only' } else { 'rollback' })"

if ($VerifyOnly) {
    Get-Root
    Push-EthernetConfig
    $dump = Get-CurrentDump
    $actual = Parse-Dump -Dump $dump
    $priority = Invoke-AdbShell "getprop persist.eth.priority"
    $fail = Compare-Snapshot -Expected $snap -Actual $actual -Priority $priority
    $dump | Set-Content -LiteralPath (Join-Path $OutDir "current-ethernet-dump.txt") -Encoding utf8
    if ($fail.Count) {
        Write-Host ""
        Write-Host "Rollback verification: FAIL"
        $fail | ForEach-Object { Write-Host "  $_" }
        exit 1
    }
    Write-Host ""
    Write-Host "Rollback verification: OK"
    Write-Host "Artifacts: $OutDir"
    return
}

if (-not $Force) {
    $target = "HU $Serial"
    if (-not $PSCmdlet.ShouldProcess($target, "Restore network snapshot from $snapshotDir and reboot required")) {
        return
    }
}

Get-Root
Push-EthernetConfig

# Save current state before rollback.
$dump = Get-CurrentDump
$dump | Set-Content -LiteralPath (Join-Path $OutDir "ethernet-dump-before-rollback.txt") -Encoding utf8
(Invoke-AdbShell "getprop persist.eth.priority") | Set-Content -LiteralPath (Join-Path $OutDir "getprop-before-rollback.txt") -Encoding utf8
(Invoke-AdbShell "ip -4 addr") | Set-Content -LiteralPath (Join-Path $OutDir "ip-addr-before-rollback.txt") -Encoding utf8
(Invoke-AdbShell "ip route show table all") | Set-Content -LiteralPath (Join-Path $OutDir "ip-route-before-rollback.txt") -Encoding utf8

# Restore persist.eth.priority exactly as it was.
if ($snap.priority.present) {
    $value = [string]$snap.priority.value
    $script = "setprop persist.eth.priority '$value'"
} else {
    $script = "setprop persist.eth.priority ''"
}
$out = Invoke-RootScript -Script $script -Name "restore-priority"
Write-Log $out

# Restore vlan11/vlan21 assignment and static config.
$commands = @()
foreach ($prop in $snap.interfaces.PSObject.Properties) {
    $iface = $prop.Name
    $cfg = $prop.Value
    $assignment = [string]$cfg.assignment
    if ($assignment -eq "STATIC") {
        $cidr = [string]$cfg.cidr
        $gateway = if ($cfg.gateway) { [string]$cfg.gateway } else { "none" }
        $dns = (@($cfg.dns) -join ',')
        $domains = (@($cfg.domains) -join ',')
        $commands += "CLASSPATH=$script:RemoteDex app_process /system/bin EthernetConfig set $iface STATIC $cidr $gateway '$dns' '$domains'"
    } elseif ($assignment -eq "DHCP" -or $assignment -eq "UNASSIGNED") {
        $commands += "CLASSPATH=$script:RemoteDex app_process /system/bin EthernetConfig set $iface $assignment"
    } else {
        throw "Unsupported assignment '$assignment' for $iface in snapshot."
    }
}
if ($commands.Count -eq 0) {
    throw "Snapshot contains no vlan11/vlan21 interface configuration to restore."
}
$script = $commands -join "`n"
$out = Invoke-RootScript -Script $script -Name "restore-interfaces"
Write-Log $out
if ($out -match '(?m)^ERROR:') {
    throw "EthernetConfig restore failed:`n$out"
}

# Apply at runtime.
$script = @'
ip link set vlan11 down || true
ip link set vlan21 down || true
sleep 1
ip link set vlan11 up || true
ip link set vlan21 up || true
sleep 2
'@
Invoke-RootScript -Script $script -Name "bounce-vlans" | Out-Null

$priority = Invoke-AdbShell "getprop persist.eth.priority"
$addr = Invoke-AdbShell "ip -4 addr show vlan11; ip -4 addr show vlan21"
$route = Invoke-AdbShell "ip route show table all"
$addr | Set-Content -LiteralPath (Join-Path $OutDir "ip-addr-after-rollback.txt") -Encoding utf8
$route | Set-Content -LiteralPath (Join-Path $OutDir "ip-route-after-rollback.txt") -Encoding utf8

& $Adb @AdbArgs shell "rm -f $script:RemoteDex" 2>&1 | Out-Null

Write-Host ""
Write-Host "Rollback applied."
Write-Host "  persist.eth.priority : '$priority'"
Write-Host "  vlan11/vlan21        : $addr"
Write-Host "  snapshot             : $snapshotDir"
Write-Host ""
Write-Host "Reboot is required. After reboot run:"
Write-Host "  .\Rollback-HuInternet.ps1 -Serial $Serial -Snapshot $snapshotDir -VerifyOnly"
Write-Host "Artifacts: $OutDir"
