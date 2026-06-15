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
Write-Host "Lade homeedge auf den VPS und ersetze /usr/local/bin/homeedge ..."
Write-Host ""

$Content = Get-Content $EdgectlPath -Raw
$Content | & ssh @sshArgs "cat >/tmp/homeedge && sed -i 's/\r$//' /tmp/homeedge && chmod +x /tmp/homeedge && sudo mv /tmp/homeedge /usr/local/bin/homeedge && sudo chown root:root /usr/local/bin/homeedge && sudo chmod +x /usr/local/bin/homeedge && sudo ln -sf /usr/local/bin/homeedge /usr/local/bin/edgectl && sudo homeedge values"

Write-Host ""
Write-Host "Fertig. Menü starten mit:"
Write-Host "  sudo homeedge menu"
Write-Host ""
