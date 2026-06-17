# Install-EdgeVps.ps1
# Starten mit:
# powershell -ExecutionPolicy Bypass -File .\Install-EdgeVps.ps1
#
# Dieses Script laeuft lokal auf Windows und installiert per SSH den Edge-VPS.
# Es nutzt die Dateien homeedge.sh und remote-bootstrap.template.sh aus demselben Ordner.
#
# Neu: Eingaben werden lokal in Install-EdgeVps.config.json gespeichert.
# Beim naechsten Start fragt das Script, ob diese Werte wiederverwendet werden sollen.

param(
    [string]$ConfigPath = ""
)

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

function Ask-SecretPlain($Prompt) {
    $sec = Read-Host $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Ask-YesNo($Prompt, $Default = "n") {
    $v = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($v)) { $v = $Default }
    return ($v -match '^(y|j|yes|ja)$')
}

function To-B64($Text) {
    if ($null -eq $Text) { $Text = "" }
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$Text))
}

function Get-CfgValue($Config, $Name, $Default = "") {
    if ($null -ne $Config -and $Config.PSObject.Properties.Name -contains $Name -and $null -ne $Config.$Name) {
        return [string]$Config.$Name
    }
    return $Default
}

function Get-CfgBool($Config, $Name, $Default = $false) {
    if ($null -ne $Config -and $Config.PSObject.Properties.Name -contains $Name -and $null -ne $Config.$Name) {
        return [bool]$Config.$Name
    }
    return [bool]$Default
}


function Build-SshArgs($HostName, $UserName, $Port, $KeyPath) {
    $args = @()
    if (-not [string]::IsNullOrWhiteSpace($KeyPath)) {
        $args += @("-i", $KeyPath)
    }
    $args += @("-p", $Port, "$UserName@$HostName")
    return $args
}

function Invoke-RemoteBashScript($HostName, $UserName, $Port, $KeyPath, $ScriptText) {
    $args = Build-SshArgs -HostName $HostName -UserName $UserName -Port $Port -KeyPath $KeyPath
    return $ScriptText | & ssh @args "bash -s" 2>&1
}

function Select-RemoteInterface($DefaultInterface, $HostName, $UserName, $Port, $KeyPath) {
    Write-Host ""
    Write-Host "Netzwerkadapter werden vom VPS ausgelesen..."
    Write-Host "Falls du Passwort-Login nutzt, fragt SSH jetzt ggf. nach dem Passwort."
    Write-Host ""

    $remoteScript = @'
def=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')
src=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')
echo "__DEFAULT__|${def}|${src}"
for n in $(ls /sys/class/net | sort); do
  state=$(cat /sys/class/net/$n/operstate 2>/dev/null || echo unknown)
  ipv4=$(ip -o -4 addr show dev "$n" scope global 2>/dev/null | awk '{print $4}' | paste -sd ',' -)
  ipv6=$(ip -o -6 addr show dev "$n" scope global 2>/dev/null | awk '{print $4}' | paste -sd ',' -)
  [ -z "$ipv4" ] && ipv4="-"
  [ -z "$ipv6" ] && ipv6="-"
  echo "__IF__|${n}|${state}|${ipv4}|${ipv6}"
done
'@

    try {
        $out = Invoke-RemoteBashScript -HostName $HostName -UserName $UserName -Port $Port -KeyPath $KeyPath -ScriptText $remoteScript
    } catch {
        Write-Host "Adapter konnten nicht automatisch ausgelesen werden: $($_.Exception.Message)" -ForegroundColor Yellow
        return (Ask "Externes Interface auf dem VPS" $DefaultInterface)
    }

    $defaultIf = ""
    $defaultSrc = ""
    $interfaces = @()

    foreach ($line in $out) {
        $text = [string]$line
        if ($text.StartsWith("__DEFAULT__|")) {
            $parts = $text.Split('|')
            if ($parts.Count -ge 3) {
                $defaultIf = $parts[1]
                $defaultSrc = $parts[2]
            }
        } elseif ($text.StartsWith("__IF__|")) {
            $parts = $text.Split('|')
            if ($parts.Count -ge 5) {
                $interfaces += [pscustomobject]@{
                    Name = $parts[1]
                    State = $parts[2]
                    IPv4 = $parts[3]
                    IPv6 = $parts[4]
                }
            }
        }
    }

    if ($interfaces.Count -eq 0) {
        Write-Host "Keine Adapterdaten erhalten. Roh-Ausgabe:" -ForegroundColor Yellow
        $out | ForEach-Object { Write-Host $_ }
        return (Ask "Externes Interface auf dem VPS" $DefaultInterface)
    }

    Write-Host "Gefundene Netzwerkadapter:" -ForegroundColor Cyan
    Write-Host ""
    $i = 1
    $defaultIndex = 0
    foreach ($iface in $interfaces) {
        $hint = ""
        if ($iface.Name -eq $defaultIf) {
            $hint = " <= Default-Route / Internet"
            $defaultIndex = $i
        }
        if ($iface.Name -eq $DefaultInterface) {
            $hint = "$hint <= Config-Vorschlag"
        }
        Write-Host ("{0,2}) {1,-14} Status: {2,-8} IPv4: {3,-22} IPv6: {4}{5}" -f $i, $iface.Name, $iface.State, $iface.IPv4, $iface.IPv6, $hint)
        $i++
    }

    Write-Host ""
    if (-not [string]::IsNullOrWhiteSpace($defaultIf)) {
        Write-Host "Empfehlung: $defaultIf" -ForegroundColor Green
        if (-not [string]::IsNullOrWhiteSpace($defaultSrc)) {
            Write-Host "Source-IP Richtung Internet: $defaultSrc"
        }
    }
    Write-Host ""

    $defaultAnswer = if ($defaultIndex -gt 0) { [string]$defaultIndex } elseif (-not [string]::IsNullOrWhiteSpace($DefaultInterface)) { $DefaultInterface } else { "1" }
    $choice = Ask "Netzwerkadapter waehlen: Nummer oder Interface-Name" $defaultAnswer

    if ($choice -match '^[0-9]+$') {
        $idx = [int]$choice
        if ($idx -ge 1 -and $idx -le $interfaces.Count) {
            return $interfaces[$idx - 1].Name
        }
        Write-Host "Ungueltige Nummer, nutze Vorschlag: $DefaultInterface" -ForegroundColor Yellow
        return $DefaultInterface
    }

    return $choice
}

function Protect-PlainText($Text) {
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    $sec = ConvertTo-SecureString $Text -AsPlainText -Force
    return ConvertFrom-SecureString $sec
}

function Unprotect-Text($ProtectedText) {
    if ([string]::IsNullOrWhiteSpace($ProtectedText)) { return "" }
    try {
        $sec = ConvertTo-SecureString $ProtectedText
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try {
            return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } catch {
        return ""
    }
}

function Save-InstallerConfig($Path, $Data) {
    $json = $Data | ConvertTo-Json -Depth 12
    Set-Content -Path $Path -Value $json -Encoding UTF8
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $ScriptDir "Install-EdgeVps.config.json"
}

$HomeEdgePath = Join-Path $ScriptDir "homeedge.sh"
$BootstrapPath = Join-Path $ScriptDir "remote-bootstrap.template.sh"

if (!(Test-Path $HomeEdgePath)) { throw "homeedge.sh nicht gefunden im Ordner: $ScriptDir" }
if (!(Test-Path $BootstrapPath)) { throw "remote-bootstrap.template.sh nicht gefunden im Ordner: $ScriptDir" }

$LoadedConfig = $null
$UseLoadedConfig = $false

if (Test-Path $ConfigPath) {
    Write-Host ""
    Write-Host "Vorhandene Config gefunden: $ConfigPath"
    if (Ask-YesNo "Diese Werte als Vorschlag verwenden?" "y") {
        $LoadedConfig = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        $UseLoadedConfig = $true
        Write-Host "Config geladen. Alle Werte koennen trotzdem ueberschrieben werden."
    }
}

Write-Host ""
Write-Host "============================================================"
Write-Host " HomeEdge Installer fuer PIKO/Nano"
Write-Host "============================================================"
Write-Host ""

$SshHost = Ask "VPS IP oder Hostname fuer SSH" (Get-CfgValue $LoadedConfig "SshHost" "")
$SshUser = Ask "SSH Benutzer fuer initialen Login" (Get-CfgValue $LoadedConfig "SshUser" "root")
$SshPortConnect = Ask "SSH Port fuer initialen Login" (Get-CfgValue $LoadedConfig "SshPortConnect" "22")
$SshKeyPath = Ask "SSH Key Pfad optional, leer lassen falls Passwortlogin" (Get-CfgValue $LoadedConfig "SshKeyPath" "")

$VpsPublicHost = Ask "Oeffentliche VPS-IP oder DNS-Name fuer WireGuard Endpoint" (Get-CfgValue $LoadedConfig "VpsPublicHost" $SshHost)
$ExtIfDefault = Get-CfgValue $LoadedConfig "ExtIf" "eth0"
if (Ask-YesNo "Netzwerkadapter vom VPS anzeigen und auswaehlen?" "y") {
    $ExtIf = Select-RemoteInterface -DefaultInterface $ExtIfDefault -HostName $SshHost -UserName $SshUser -Port $SshPortConnect -KeyPath $SshKeyPath
} else {
    $ExtIf = Ask "Externes Interface auf dem VPS" $ExtIfDefault
}
$SshPortFinal = Ask "SSH Port auf dem VPS" (Get-CfgValue $LoadedConfig "SshPortFinal" $SshPortConnect)

$WgIf = Ask "WireGuard Interface Name" (Get-CfgValue $LoadedConfig "WgIf" "unifi")
$WgPort = Ask "WireGuard UDP Port" (Get-CfgValue $LoadedConfig "WgPort" "51821")
# Leer = automatisch (keine MTU-Zeile, WireGuard-Default, empfohlen).
$WgMtu = Ask "WireGuard MTU (leer = automatisch/WireGuard-Default, empfohlen)" (Get-CfgValue $LoadedConfig "WgMtu" "")
if ($WgMtu -ne "") {
    if (($WgMtu -notmatch '^[0-9]+$') -or ([int]$WgMtu -lt 1200) -or ([int]$WgMtu -gt 1420)) {
        Write-Host "Ungueltige MTU '$WgMtu' - nutze automatisch (leer)."
        $WgMtu = ""
    }
}
$VpsWgAddr = Ask "VPS WireGuard Adresse mit CIDR" (Get-CfgValue $LoadedConfig "VpsWgAddr" "10.0.1.1/24")
$ClientWgAddr = Ask "UniFi/Client WireGuard Adresse mit CIDR" (Get-CfgValue $LoadedConfig "ClientWgAddr" "10.0.1.2/32")
$HomeSubnet = Ask "Heimnetz/Subnetz hinter UniFi" (Get-CfgValue $LoadedConfig "HomeSubnet" "192.168.10.0/24")

$AcmeEmail = Ask "E-Mail fuer Let's Encrypt" (Get-CfgValue $LoadedConfig "AcmeEmail" "")

$SavedCfToken = ""
if ($null -ne $LoadedConfig) {
    if ($LoadedConfig.PSObject.Properties.Name -contains "CloudflareApiTokenProtected") {
        $SavedCfToken = Unprotect-Text ([string]$LoadedConfig.CloudflareApiTokenProtected)
    } elseif ($LoadedConfig.PSObject.Properties.Name -contains "CloudflareApiToken") {
        $SavedCfToken = [string]$LoadedConfig.CloudflareApiToken
    }
}

if (-not [string]::IsNullOrWhiteSpace($SavedCfToken)) {
    if (Ask-YesNo "Gespeicherten Cloudflare API Token verwenden?" "y") {
        $CfToken = $SavedCfToken
    } else {
        $CfToken = Ask-SecretPlain "Cloudflare API Token"
    }
} else {
    $CfToken = Ask-SecretPlain "Cloudflare API Token"
}

$DefaultUsePsk = if (Get-CfgBool $LoadedConfig "UsePsk" $true) { "y" } else { "n" }
$UsePsk = if (Ask-YesNo "WireGuard PresharedKey verwenden?" $DefaultUsePsk) { "1" } else { "0" }

Write-Host ""
Write-Host "Empfohlen: Ja."
Write-Host "Schuetzt gegen viele fehlerhafte Login-/Auth-Versuche (401/403)."
Write-Host "Gebannte IPs koennen spaeter im HomeEdge-Menue wieder entbannt werden."
$DefaultCaddyF2b = if (Get-CfgBool $LoadedConfig "EnableCaddyFail2ban" $true) { "y" } else { "n" }
$EnableCaddyFail2ban = if (Ask-YesNo "Fail2ban fuer Caddy/Jellyfin 401/403 aktivieren?" $DefaultCaddyF2b) { "1" } else { "0" }

Write-Host ""
Write-Host "HTTP/3 / QUIC nutzt zusaetzlich UDP 443. Fuer Jellyfin erstmal AUS empfohlen."
Write-Host "Kann spaeter im Menue aktiviert werden."
$DefaultHttp3 = if (Get-CfgBool $LoadedConfig "EnableHttp3" $false) { "y" } else { "n" }
$EnableHttp3 = if (Ask-YesNo "HTTP/3 / QUIC aktivieren?" $DefaultHttp3) { "1" } else { "0" }

$ClientPublicKey = Ask "UniFi/Client WireGuard PublicKey optional, leer lassen falls noch nicht vorhanden" (Get-CfgValue $LoadedConfig "ClientPublicKey" "")
$SwapMb = Ask "Swap Groesse in MB" (Get-CfgValue $LoadedConfig "SwapMb" "2048")

Write-Host ""
Write-Host "Externe Dienste erfassen."
Write-Host "Beispiel: jellyfin.smatitec.de | http | 192.168.10.20 | 8096"
Write-Host ""

$ServiceLines = @()
$UseSavedServices = $false

if ($null -ne $LoadedConfig -and $LoadedConfig.PSObject.Properties.Name -contains "Services" -and $null -ne $LoadedConfig.Services -and $LoadedConfig.Services.Count -gt 0) {
    Write-Host "Gespeicherte Dienste:"
    $n = 1
    foreach ($svc in $LoadedConfig.Services) {
        Write-Host "  $n) $($svc.Domain) | $($svc.Scheme) | $($svc.BackendIp) | $($svc.BackendPort)"
        $n++
    }
    if (Ask-YesNo "Gespeicherte Dienste verwenden?" "y") {
        $UseSavedServices = $true
        foreach ($svc in $LoadedConfig.Services) {
            $prof = if ($svc.PSObject.Properties.Name -contains "Profile" -and $svc.Profile) { $svc.Profile } else { "standard" }
            $ServiceLines += "$($svc.Domain)`t$($svc.Scheme)`t$($svc.BackendIp)`t$($svc.BackendPort)`t$prof"
        }
    }
}

if (-not $UseSavedServices) {
    $ServiceCountDefault = Get-CfgValue $LoadedConfig "ServiceCount" "2"
    $ServiceCount = [int](Ask "Anzahl externe Dienste" $ServiceCountDefault)

    for ($i = 1; $i -le $ServiceCount; $i++) {
        Write-Host ""
        Write-Host "Dienst $i"
        $d = Ask "Domain"
        $s = Ask "Backend Scheme http/https" "http"
        $ip = Ask "Backend IP im Heimnetz"
        $p = Ask "Backend Port"
        Write-Host "Backend-Profil: 1) Standard  2) Jellyfin  3) Jellyseerr"
        $prc = Ask "Profil" "1"
        $prof = switch ($prc) { "2" { "jellyfin" } "3" { "jellyseerr" } default { "standard" } }
        $ServiceLines += "$d`t$s`t$ip`t$p`t$prof"
    }
}

$ServicesTsv = ($ServiceLines -join "`n") + "`n"
$ServiceCount = $ServiceLines.Count

$DefaultCreateAdmin = if (Get-CfgBool $LoadedConfig "CreateAdmin" $false) { "y" } else { "n" }
$CreateAdmin = Ask-YesNo "Optional: neuen Admin-User mit SSH-Key erstellen und Root/Password-SSH deaktivieren?" $DefaultCreateAdmin
$AdminUser = ""
$AdminPubKey = ""
$AdminPubKeyPath = Get-CfgValue $LoadedConfig "AdminPubKeyPath" ""

if ($CreateAdmin) {
    $AdminUser = Ask "Neuer Admin-User" (Get-CfgValue $LoadedConfig "AdminUser" "admin")
    $PubKeyPath = Ask "Pfad zu deiner Public-Key-Datei, z.B. C:\Users\du\.ssh\id_ed25519.pub" $AdminPubKeyPath
    if (!(Test-Path $PubKeyPath)) { throw "Public-Key-Datei nicht gefunden: $PubKeyPath" }
    $AdminPubKey = Get-Content $PubKeyPath -Raw
    if ([string]::IsNullOrWhiteSpace($AdminPubKey)) { throw "Public-Key-Datei ist leer." }
    $AdminPubKeyPath = $PubKeyPath
}

$F2bCaddyState = if ($EnableCaddyFail2ban -eq "1") { "aktiv" } else { "inaktiv" }
$TokenState = if (-not [string]::IsNullOrWhiteSpace($CfToken)) { "gesetzt" } else { "nicht gesetzt" }
$HardeningState = if ($CreateAdmin) { "ja (neuer User: $AdminUser)" } else { "nein" }

Write-Host ""
Write-Host "============================================================"
Write-Host "HomeEdge Installationszusammenfassung"
Write-Host "============================================================"
Write-Host ""
Write-Host "SSH-Ziel:         $SshUser@${SshHost}:$SshPortConnect"
Write-Host ""
Write-Host "VPS:"
Write-Host "  Host/IP:        $VpsPublicHost"
Write-Host "  Interface:      $ExtIf"
Write-Host "  SSH-Port:       $SshPortFinal"
Write-Host ""
Write-Host "WireGuard:"
Write-Host "  Interface:      $WgIf"
Write-Host "  UDP-Port:       $WgPort"
Write-Host "  VPS WG-IP:      $VpsWgAddr"
Write-Host "  Client WG-IP:   $ClientWgAddr"
Write-Host "  Backend-Netze:  $HomeSubnet"
Write-Host ""
Write-Host "Dienste:"
if ($ServiceLines.Count -eq 0) {
    Write-Host "  (keine Dienste erfasst)"
} else {
    $n = 1
    foreach ($line in $ServiceLines) {
        $p = $line -split "`t"
        if ($p.Count -ge 4) {
            Write-Host ("  {0}) {1,-22} -> {2}://{3}:{4}" -f $n, $p[0], $p[1], $p[2], $p[3])
            $n++
        }
    }
}
Write-Host ""
Write-Host "Security:"
Write-Host "  UFW:              wird aktiviert"
Write-Host "  Fail2ban SSH:     wird aktiviert"
Write-Host "  Fail2ban Caddy:   $F2bCaddyState"
Write-Host "  Cloudflare Token: $TokenState"
Write-Host "  SSH Hardening:    $HardeningState"
Write-Host "  Config-Datei:     $ConfigPath"
Write-Host "============================================================"
Write-Host ""

if (Ask-YesNo "Eingaben lokal als Config fuer naechstes Mal speichern/aktualisieren?" "y") {
    $ServiceObjects = @()
    foreach ($line in $ServiceLines) {
        $parts = $line -split "`t"
        if ($parts.Count -ge 4) {
            $ServiceObjects += [pscustomobject]@{
                Domain = $parts[0]
                Scheme = $parts[1]
                BackendIp = $parts[2]
                BackendPort = $parts[3]
                Profile = if ($parts.Count -ge 5) { $parts[4] } else { "standard" }
            }
        }
    }

    $ConfigToSave = [pscustomobject]@{
        Version = 2
        LastSavedUtc = (Get-Date).ToUniversalTime().ToString("o")
        SshHost = $SshHost
        SshUser = $SshUser
        SshPortConnect = $SshPortConnect
        SshKeyPath = $SshKeyPath
        VpsPublicHost = $VpsPublicHost
        ExtIf = $ExtIf
        SshPortFinal = $SshPortFinal
        WgIf = $WgIf
        WgPort = $WgPort
        WgMtu = $WgMtu
        VpsWgAddr = $VpsWgAddr
        ClientWgAddr = $ClientWgAddr
        HomeSubnet = $HomeSubnet
        AcmeEmail = $AcmeEmail
        CloudflareApiTokenProtected = Protect-PlainText $CfToken
        UsePsk = ($UsePsk -eq "1")
        EnableCaddyFail2ban = ($EnableCaddyFail2ban -eq "1")
        EnableHttp3 = ($EnableHttp3 -eq "1")
        ClientPublicKey = $ClientPublicKey
        SwapMb = $SwapMb
        ServiceCount = $ServiceCount
        Services = $ServiceObjects
        CreateAdmin = $CreateAdmin
        AdminUser = $AdminUser
        AdminPubKeyPath = $AdminPubKeyPath
    }

    Save-InstallerConfig -Path $ConfigPath -Data $ConfigToSave
    Write-Host "Config gespeichert: $ConfigPath"
    Write-Host "Hinweis: Der Cloudflare Token wird Windows-benutzergebunden verschluesselt gespeichert."
    Write-Host ""
}

Write-Host ""
Write-Host "Achtung:"
Write-Host "Auf dem VPS werden jetzt Pakete installiert und konfiguriert:"
Write-Host "Docker/Caddy, WireGuard, UFW, Fail2ban, automatische Updates, Swap, HomeEdge-Menue."
Write-Host ""
if (!(Ask-YesNo "Konfiguration uebernehmen und Installation jetzt starten?" "n")) {
    Write-Host "Installation abgebrochen. Die Konfiguration kann beim naechsten Start wiederverwendet werden."
    exit 0
}

$HomeEdgeContent = Get-Content $HomeEdgePath -Raw
$RemoteScript = Get-Content $BootstrapPath -Raw

$Replacements = @{
    "__EXT_IF_B64__" = To-B64 $ExtIf
    "__VPS_PUBLIC_HOST_B64__" = To-B64 $VpsPublicHost
    "__SSH_PORT_B64__" = To-B64 $SshPortFinal
    "__WG_IF_B64__" = To-B64 $WgIf
    "__WG_PORT_B64__" = To-B64 $WgPort
    "__WG_MTU_B64__" = To-B64 $WgMtu
    "__VPS_WG_ADDR_B64__" = To-B64 $VpsWgAddr
    "__CLIENT_WG_ADDR_B64__" = To-B64 $ClientWgAddr
    "__HOME_SUBNET_B64__" = To-B64 $HomeSubnet
    "__ACME_EMAIL_B64__" = To-B64 $AcmeEmail
    "__CF_TOKEN_B64__" = To-B64 $CfToken
    "__USE_PSK_B64__" = To-B64 $UsePsk
    "__CADDY_FAIL2BAN_B64__" = To-B64 $EnableCaddyFail2ban
    "__ENABLE_HTTP3_B64__" = To-B64 $EnableHttp3
    "__CLIENT_PUBLIC_KEY_B64__" = To-B64 $ClientPublicKey
    "__SERVICES_TSV_B64__" = To-B64 $ServicesTsv
    "__SWAP_MB_B64__" = To-B64 $SwapMb
    "__CREATE_ADMIN_B64__" = To-B64 ($(if ($CreateAdmin) { "1" } else { "0" }))
    "__ADMIN_USER_B64__" = To-B64 $AdminUser
    "__ADMIN_PUBKEY_B64__" = To-B64 $AdminPubKey
    "__HOMEEDGE_B64__" = To-B64 $HomeEdgeContent
}

foreach ($k in $Replacements.Keys) {
    $RemoteScript = $RemoteScript.Replace($k, $Replacements[$k])
}

$sshArgs = @()
if ($SshKeyPath -ne "") {
    $sshArgs += @("-i", $SshKeyPath)
}
$sshArgs += @("-p", $SshPortConnect, "$SshUser@$SshHost")

Write-Host ""
Write-Host "Verbinde per SSH und starte Installation..."
Write-Host "Die Ausgabe wird hier angezeigt und zusaetzlich auf dem VPS nach /root/edge-install.log geschrieben."
Write-Host ""

$RemoteScript | & ssh @sshArgs "cat >/tmp/edge-bootstrap.sh && chmod +x /tmp/edge-bootstrap.sh && bash -lc 'set -o pipefail; /tmp/edge-bootstrap.sh 2>&1 | tee /root/edge-install.log'"

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "SETUP NICHT VOLLSTAENDIG"
    Write-Host "============================================================"
    Write-Host "Die Remote-Installation ist fehlgeschlagen (Exitcode $LASTEXITCODE)."
    Write-Host "Log auf dem VPS: /root/edge-install.log"
    Write-Host "Pruefen/Reparieren: sudo homeedge health ; sudo homeedge apply-all"
    throw "Remote-Installation fehlgeschlagen. Siehe /root/edge-install.log"
}

Write-Host ""
Write-Host "Fertig. Auf dem VPS sind jetzt diese Befehle verfuegbar:"
Write-Host "  sudo homeedge menu"
Write-Host "  sudo homeedge status"
Write-Host "  sudo homeedge wg-values"
Write-Host ""

if (Ask-YesNo "Direkt jetzt eine SSH-Sitzung zum VPS oeffnen?" "y") {
    $SessionUser = $SshUser
    $SessionPort = $SshPortConnect
    $SessionKeyPath = $SshKeyPath

    if ($CreateAdmin -and -not [string]::IsNullOrWhiteSpace($AdminUser)) {
        $SessionUser = $AdminUser
        $SessionPort = $SshPortFinal

        if (-not [string]::IsNullOrWhiteSpace($AdminPubKeyPath) -and $AdminPubKeyPath.EndsWith(".pub")) {
            $PossiblePrivateKey = $AdminPubKeyPath.Substring(0, $AdminPubKeyPath.Length - 4)
            if (Test-Path $PossiblePrivateKey) {
                $SessionKeyPath = $PossiblePrivateKey
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($SessionKeyPath)) {
        $SessionKeyPath = Ask "SSH-Key fuer die neue Sitzung optional, leer lassen fuer Passwort/Agent" ""
    }

    $sessionArgs = @()
    if ($SessionKeyPath -ne "") {
        $sessionArgs += @("-i", $SessionKeyPath)
    }
    $sessionArgs += @("-p", $SessionPort, "$SessionUser@$SshHost")

    Write-Host ""
    Write-Host "Oeffne SSH-Sitzung: $SessionUser@$SshHost Port $SessionPort"
    Write-Host ""

    if (Ask-YesNo "Direkt das homeedge-Menue starten?" "y") {
        & ssh -t @sessionArgs "sudo homeedge menu"
    } else {
        & ssh @sessionArgs
    }
}
