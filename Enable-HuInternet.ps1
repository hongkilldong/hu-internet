#requires -Version 5.1
<#
.SYNOPSIS
    Enable internet on the HU X9 by preferring Wi-Fi over Ethernet while keeping
    the TCU/eCall link on vlan11/vlan21.

.DESCRIPTION
    Reversible /data-only recipe. It does not touch /system, /vendor, boot,
    dm-verity or eCall coding.

    It does two things:
      1. Sets persist.eth.priority=50, so after reboot Ethernet scores below
         Wi-Fi and the default network becomes Wi-Fi.
      2. Restores static IPv4 on vlan11/vlan21 (172.29.11.3/24 and
         172.29.21.3/24, no gateway/DNS), so the TCU/eCall link keeps working.

    Before changing anything it snapshots the real network configuration:
    IEthernetManager assignment/static config for vlan11/vlan21,
    persist.eth.priority, ip addr/route/neigh, dumpsys connectivity/ethernet.
    The rollback script restores that snapshot; it does not rely on ipconfig.txt.

    The su password is read from su-password.txt next to this script. There is
    no prompt and no -SuPassword parameter.

    A reboot is required for persist.eth.priority to take effect. The script
    does not reboot automatically.

.PARAMETER Serial
    ADB serial, e.g. 192.168.137.232:5555. If omitted, exactly one device must
    be connected.

.PARAMETER Apply
    Actually change the HU. Without -Apply the script only shows the current
    state and exits.

.PARAMETER Force
    Skip the confirmation prompt and the model check.

.PARAMETER SkipLinkBounce
    Do not bounce vlan11/vlan21 after writing the static config. The config is
    still persisted; a reboot will apply it.

.EXAMPLE
    .\Enable-HuInternet.ps1 -Serial 192.168.137.232:5555 -Apply
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [string]$Adb = "",
    [string]$Serial = "",
    [switch]$Apply,
    [switch]$Force,
    [switch]$SkipLinkBounce,
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

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object
    )
    $json = $Object | ConvertTo-Json -Depth 8
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8)
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
    $OutDir = Join-Path $PSScriptRoot ("artifacts\enable-" + $RunId)
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
    $remote = "/data/local/tmp/hu-internet-{0}-{1}.sh" -f $RunId, $Name
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
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$Directory = $OutDir
    )
    $Text | Set-Content -LiteralPath (Join-Path $Directory $Name) -Encoding utf8 -ErrorAction Stop
}

function Show-Current {
    Write-Host ""
    Write-Host "Current state:"
    $priority = Invoke-AdbShell "getprop persist.eth.priority"
    if (-not $priority) { $priority = "(default 70)" }
    Write-Host "  persist.eth.priority : $priority"
    $default = Invoke-AdbShell "dumpsys connectivity | grep 'Active default network' | head -n 1"
    Write-Host "  $default"
    $addr = Invoke-AdbShell "ip -4 addr show vlan11; ip -4 addr show vlan21"
    if ($addr) { Write-Host $addr } else { Write-Host "  vlan11/vlan21: no IPv4" }
    Write-Host ""
}

function New-Snapshot {
    $snapDir = Join-Path $OutDir "snapshot"
    New-Item -ItemType Directory -Force -Path $snapDir | Out-Null

    $dumpScript = "CLASSPATH=$script:RemoteDex app_process /system/bin EthernetConfig dump vlan11 vlan21"
    $dump = Invoke-RootScript -Script $dumpScript -Name "ethernet-dump"
    $dump | Set-Content -LiteralPath (Join-Path $snapDir "ethernet-dump.txt") -Encoding utf8 -ErrorAction Stop

    $interfaces = [ordered]@{}
    foreach ($line in ($dump -split "`r?`n")) {
        if ($line -notmatch '^[A-Za-z0-9_.-]+\|') { continue }
        $parts = $line -split '\|'
        $iface = $parts[0]
        $assignment = $parts[1]
        if ($assignment -eq "MISSING") {
            throw "EthernetConfig dump: $iface is missing."
        }
        $cidr = if ($parts.Count -gt 2) { $parts[2] } else { "" }
        $gateway = if ($parts.Count -gt 3) { $parts[3] } else { "" }
        $dns = @()
        if ($parts.Count -gt 4 -and $parts[4]) { $dns = @($parts[4] -split ',') }
        $domains = @()
        if ($parts.Count -gt 5 -and $parts[5]) { $domains = @($parts[5] -split ',') }
        $interfaces[$iface] = [ordered]@{
            assignment = $assignment
            cidr       = $cidr
            gateway    = $gateway
            dns        = $dns
            domains    = $domains
        }
    }
    if (-not $interfaces.Keys -contains "vlan11" -or -not $interfaces.Keys -contains "vlan21") {
        throw "Snapshot did not contain vlan11 and vlan21."
    }

    $priority = Invoke-AdbShell "getprop persist.eth.priority"
    $deviceSerial = Invoke-AdbShell "getprop ro.serialno"
    if (-not $deviceSerial) { $deviceSerial = Invoke-AdbShell "getprop ro.boot.serialno" }
    $ipAddr = Invoke-AdbShell "ip -4 addr"
    $ipRoute = Invoke-AdbShell "ip route show table all"
    $ipNeigh = Invoke-AdbShell "ip neigh"
    $conn = Invoke-AdbShell "dumpsys connectivity"
    $eth = Invoke-AdbShell "dumpsys ethernet"

    Save-Text "ip-addr-before.txt" $ipAddr $snapDir
    Save-Text "ip-route-before.txt" $ipRoute $snapDir
    Save-Text "ip-neigh-before.txt" $ipNeigh $snapDir
    Save-Text "dumpsys-connectivity-before.txt" $conn $snapDir
    Save-Text "dumpsys-ethernet-before.txt" $eth $snapDir
    Save-Text "getprop-before.txt" $priority $snapDir

    $state = [ordered]@{
        serial        = $Serial
        device_serial = $deviceSerial
        model         = $model
        build         = $build
        timestamp     = (Get-Date).ToString("o")
        priority  = [ordered]@{
            present = [bool]$priority
            value   = $priority
        }
        interfaces = $interfaces
        runtime    = [ordered]@{
            ip_addr  = $ipAddr
            ip_route = $ipRoute
            ip_neigh = $ipNeigh
        }
    }
    Write-JsonFile -Path (Join-Path $snapDir "state.json") -Object $state
    Write-Log "Snapshot: $snapDir"
    return $snapDir
}

Write-Log "HU: $Serial"
Write-Log "Artifacts: $OutDir"
Write-Log "Mode: $(if ($Apply) { 'apply' } else { 'read-only' })"

$model = Invoke-AdbShell "getprop ro.product.device"
$build = Invoke-AdbShell "getprop ro.build.display.id"
$boot = Invoke-AdbShell "getprop sys.boot_completed"
if ($boot -ne "1") {
    throw "HU is not fully booted (sys.boot_completed=$boot)."
}
if ($model -ne "honda_3ya" -and -not $Force) {
    throw "Unexpected device '$model'. This recipe is for honda_3ya. Use -Force only if you are sure."
}
$hasVlan = Invoke-AdbShell "ip link show vlan11 >/dev/null 2>&1 && echo yes || echo no"
if ($hasVlan -notmatch "yes") {
    throw "vlan11 is missing. Check the HU-TSU Ethernet cable and network setup."
}

Show-Current

if (-not $Apply) {
    Write-Host "Read-only mode. Nothing changed."
    Write-Host "To apply: .\Enable-HuInternet.ps1 -Serial $Serial -Apply"
    return
}

if (-not $Force) {
    $target = "HU $Serial"
    if (-not $PSCmdlet.ShouldProcess($target, "Set persist.eth.priority=50 and static IP on vlan11/vlan21")) {
        return
    }
}

Get-Root

$dex = Join-Path $PSScriptRoot "tools\ethernet-config\classes.dex"
if (-not (Test-Path -LiteralPath $dex)) {
    throw "Missing dependency: $dex"
}
$script:RemoteDex = "/data/local/tmp/hu-internet-$RunId-ethconfig.dex"
& $Adb @AdbArgs push $dex $script:RemoteDex 2>&1 | Out-Null

$snapshot = New-Snapshot

# 1. Static IP on vlan11/vlan21, no gateway/DNS.
$script = @"
CLASSPATH=$script:RemoteDex app_process /system/bin EthernetConfig static vlan11 172.29.11.3/24 none
CLASSPATH=$script:RemoteDex app_process /system/bin EthernetConfig static vlan21 172.29.21.3/24 none
"@
$out = Invoke-RootScript -Script $script -Name "ethconfig-static"
Write-Log $out
if ($out -match '(?m)^ERROR:') {
    throw "EthernetConfig static failed:`n$out"
}

if (-not $SkipLinkBounce) {
    $script = @'
ip link set vlan11 down || true
ip link set vlan21 down || true
sleep 1
ip link set vlan11 up || true
ip link set vlan21 up || true
sleep 2
'@
    Invoke-RootScript -Script $script -Name "bounce-vlans" | Out-Null
    Write-Log "vlan11/vlan21 link bounced."
}

# 2. Prefer Wi-Fi over Ethernet after reboot.
$script = @'
setprop persist.eth.priority 50
echo "persist.eth.priority=$(getprop persist.eth.priority)"
'@
$out = Invoke-RootScript -Script $script -Name "set-priority"
Write-Log $out

# 3. Verify what can be verified before reboot.
Save-Text "ip-addr-after.txt" (Invoke-AdbShell "ip -4 addr")
Save-Text "ip-route-after.txt" (Invoke-AdbShell "ip route show table all")
Save-Text "dumpsys-connectivity-after.txt" (Invoke-AdbShell "dumpsys connectivity")
$tsu = Invoke-AdbShell "ping -c 2 -W 1 172.29.11.5"
Write-Log $tsu
$afterPriority = Invoke-AdbShell "getprop persist.eth.priority"
$vlanOk = (Invoke-AdbShell "ip -4 addr show vlan11") -match '172\.29\.11\.3'
$tsuOk = $tsu -match '(?m)(?<!\d)0% packet loss'

& $Adb @AdbArgs shell "rm -f $script:RemoteDex" 2>&1 | Out-Null

Write-Host ""
Write-Host "Applied."
Write-Host "  persist.eth.priority : $afterPriority"
Write-Host "  vlan11 static IP     : $(if ($vlanOk) { 'OK' } else { 'NOT APPLIED YET' })"
Write-Host "  TSU ping             : $(if ($tsuOk) { 'OK' } else { 'FAILED - check cable/TCU' })"
Write-Host "  snapshot             : $snapshot"
Write-Host ""
Write-Host "Reboot is required for persist.eth.priority to take effect."
Write-Host "After reboot run: .\Verify-HuInternet.ps1 -Serial $Serial"
Write-Host "Rollback: .\Rollback-HuInternet.ps1 -Serial $Serial"
Write-Host "Artifacts: $OutDir"
