#Requires -Version 5.1
<#
.SYNOPSIS
   /dockerlogin
    Legt die Docker-Registrierungsdaten (Docker Hub) einmalig sicher im
    Docker-Anmeldespeicher ab, damit deploy-all.sh die Images pushen kann.

.DESCRIPTION
    Das Skript fragt Benutzername und Zugangs-Token ab (der Token wird nicht
    angezeigt und nicht in einer Datei gespeichert). Mit dem Token wird
    "docker login --password-stdin" ausgefuehrt. Docker merkt sich die Daten
    im Credential-Store. Danach kann deploy-all.sh die Images bauen und pushen.

    Empfohlen wird ein Docker-Hub-Access-Token (nicht das Konto-Passwort):
    Docker Hub -> Account Settings -> Security -> New Access Token.

.PARAMETER Registry
    Registry-Adresse. Standard: docker.io

.PARAMETER Username
    Docker-Hub-Benutzername. Wird interaktiv abgefragt, wenn nicht angegeben.

.PARAMETER Deploy
    Nach erfolgreichem Login deploy-all.sh sofort mit PUSH_IMAGES=1 ausfuehren.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\docker-login.ps1

.EXAMPLE
    .\scripts\docker-login.ps1 -Username dennitzo -Deploy
#>
[CmdletBinding()]
param(
    [string]$Registry = "docker.io",
    [string]$Username,
    [switch]$Deploy
)

$ErrorActionPreference = "Stop"

function Test-Docker {
    try {
        $null = docker version --format "{{.Server.Version}}" 2>$null
        if ($LASTEXITCODE -ne 0) { throw }
    }
    catch {
        Write-Host "Docker ist nicht erreichbar. Bitte Docker Desktop starten und erneut ausfuehren." -ForegroundColor Red
        exit 1
    }
}

function Find-GitBash {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $candidates = @(
            (Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) "bin\bash.exe")
            (Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) "usr\bin\bash.exe")
        )
        foreach ($c in $candidates) { if (Test-Path $c) { return (Resolve-Path $c).Path } }
    }
    $fallbacks = @(
        "C:\Program Files\Git\bin\bash.exe"
        "C:\Program Files\Git\usr\bin\bash.exe"
    )
    foreach ($f in $fallbacks) { if (Test-Path $f) { return (Resolve-Path $f).Path } }
    return $null
}

Write-Host "=== Docker-Anmeldung fuer deploy-all.sh ===" -ForegroundColor Cyan
Test-Docker

if ([string]::IsNullOrWhiteSpace($Username)) {
    $Username = Read-Host -Prompt "Docker-Hub Benutzername"
}

Write-Host "Hinweis: Bitte einen Access-Token verwenden, nicht das Konto-Passwort." -ForegroundColor Yellow
$secureToken = Read-Host -Prompt "Zugangs-Token (Eingabe wird nicht angezeigt)" -AsSecureString

# Klartext nur kurz im Prozess, danach geloescht.
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
$plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

try {
    # Fuehrt docker login ohne interaktiven Prompt aus; Token laeuft ueber stdin.
    $plainToken | docker login --username $Username --password-stdin $Registry
    $loginExit = $LASTEXITCODE
}
finally {
    $plainToken = $null
    $secureToken = $null
    [GC]::Collect()
}

if ($loginExit -ne 0) {
    Write-Host "Anmeldung fehlgeschlagen (Code $loginExit). Benutzername und Token bitte pruefen." -ForegroundColor Red
    exit $loginExit
}

Write-Host "Anmeldung erfolgreich. Die Zugangsdaten liegen im Docker-Anmeldespeicher." -ForegroundColor Green

if ($Deploy) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $bash = Find-GitBash
    if (-not $bash) {
        Write-Host "Git Bash nicht gefunden. deploy-all.sh bitte manuell mit PUSH_IMAGES=1 ausfuehren." -ForegroundColor Red
        exit 2
    }
    Write-Host "Starte deploy-all.sh mit PUSH_IMAGES=1..." -ForegroundColor Cyan
    & $bash -c "cd '$($repoRoot -replace '\\','/')' && PUSH_IMAGES=1 KASPA_DOCKER_USER='$Username' bash deploy-all.sh"
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "Naechster Schritt (Build mit Push):" -ForegroundColor Cyan
Write-Host "  PUSH_IMAGES=1 bash deploy-all.sh"
Write-Host "Oder direkt: .\scripts\docker-login.ps1 -Deploy"
