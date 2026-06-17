# Update-HomeEdgeOnly.ps1
# Aktualisiert nur /usr/local/bin/homeedge auf einem bestehenden VPS.
# Starten mit:
# powershell -ExecutionPolicy Bypass -File .\Update-HomeEdgeOnly.ps1

$ErrorActionPreference = "Stop"

function Ask($Prompt, $Default = "") {
    if ($Default -ne "") {
        $v = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
        return $v
    } else {
        return (Read-Host $Prompt)
    }
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EdgectlPath = Join-Path $ScriptDir "homeedge.sh"
$ConfigPath = Join-Path $ScriptDir "Install-EdgeVps.config.json"

if (!(Test-Path $EdgectlPath)) { throw "homeedge.sh nicht gefunden im Ordner: $ScriptDir" }

$LoadedConfig = $null
if (Test-Path $ConfigPath) {
    try { $LoadedConfig = Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch { $LoadedConfig = $null }
}

function Get-CfgValue($Config, $Name, $Default = "") {
    if ($null -ne $Config -and $Config.PSObject.Properties.Name -contains $Name -and $null -ne $Config.$Name) {
        return [string]$Config.$Name
    }
    return $Default
}

$SshHost = Ask "VPS IP oder Hostname fuer SSH" (Get-CfgValue $LoadedConfig "SshHost" "")
$SshUser = Ask "SSH Benutzer" (Get-CfgValue $LoadedConfig "SshUser" "root")
$SshPort = Ask "SSH Port" (Get-CfgValue $LoadedConfig "SshPortConnect" "22")
$SshKeyPath = Ask "SSH Key Pfad optional, leer lassen falls Passwortlogin" (Get-CfgValue $LoadedConfig "SshKeyPath" "")

$sshArgs = @()
if ($SshKeyPath -ne "") { $sshArgs += @("-i", $SshKeyPath) }
$sshArgs += @("-p", $SshPort, "$SshUser@$SshHost")

Write-Host ""
Write-Host "Lade homeedge auf den VPS, ersetze /usr/local/bin/homeedge und fuehre Migration/Healthcheck aus ..."
Write-Host ""

# Remote-Ablauf: Binary ersetzen, Pre-Update-Backup, Migration, Validierung,
# Healthcheck. Bei Fehler Rollback-Hinweis. (Hier-String ist literal.)
$remote = @'
sed -i 's/\r$//' /tmp/homeedge
sudo bash -c '
set -u
TS=$(date +%Y%m%d-%H%M%S)
FAIL=0
[ -f /usr/local/bin/homeedge ] && cp -a /usr/local/bin/homeedge /usr/local/bin/homeedge.preupdate.$TS || true
chmod +x /tmp/homeedge
mv /tmp/homeedge /usr/local/bin/homeedge
chown root:root /usr/local/bin/homeedge
ln -sf /usr/local/bin/homeedge /usr/local/bin/edgectl
echo "[OK] homeedge ersetzt: $(/usr/local/bin/homeedge --version 2>/dev/null)"
/usr/local/bin/homeedge backup-create </dev/null >/dev/null 2>&1 && echo "[OK] Pre-Update-Backup erstellt" || echo "[WARN] Pre-Update-Backup uebersprungen"
/usr/local/bin/homeedge migrate --no-backup || FAIL=1
/usr/local/bin/homeedge validate-services || FAIL=1
/usr/local/bin/homeedge health || true
if [ $FAIL -ne 0 ]; then echo "[ERR] Update mit Fehlern. Rollback: cp /usr/local/bin/homeedge.preupdate.$TS /usr/local/bin/homeedge ; sudo homeedge restore-config"; exit 1; fi
echo "[OK] Update abgeschlossen."
'
'@

$Content = Get-Content $EdgectlPath -Raw
$Content | & ssh @sshArgs ("cat >/tmp/homeedge && " + $remote)

Write-Host ""
Write-Host "Fertig. Menue starten mit:"
Write-Host "  sudo homeedge menu"
Write-Host ""
