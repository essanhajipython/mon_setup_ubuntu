# Environnement d'Abdelhak sur un Windows neuf, en une commande (PowerShell, sans droits administrateur) :
#
#   irm https://raw.githubusercontent.com/essanhajipython/mon_setup_ubuntu/main/windows/installer.ps1 | iex
#
# 1. Git, Python et GitHub CLI par winget ; 2. connexion a GitHub (code a saisir dans le navigateur) ;
# 3. depot prive abdelhak-workspace ; 4. scripts/poste.py : autres programmes (winget), reglages des
# outils, projets (Mizan), connexions, verification. Relancable sans risque : ce qui est fait est saute.
# Texte sans accents : Windows PowerShell 5.1 lit un fichier sans BOM en cp1252. Pas de
# ErrorActionPreference = Stop : en 5.1, la moindre ligne d'un programme sur stderr deviendrait une erreur
# fatale ; les codes de retour sont testes un a un.

function Etape($texte) { Write-Host "`n== $texte" -ForegroundColor Cyan }

function Relire-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
}

function Installer($id) {
    winget list -e --id $id --accept-source-agreements *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  $id deja installe"
        return
    }
    winget install -e --id $id --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "installation de $id echouee : relancez ce script" }
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget est introuvable : installez 'App Installer' depuis le Microsoft Store, puis relancez."
}

Etape "Programmes de base : Git, Python, GitHub CLI"
Installer "Git.Git"
Installer "Python.Python.3.14"
Installer "GitHub.cli"
Relire-Path

Etape "Connexion a GitHub"
gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    gh auth login --web --git-protocol https
    if ($LASTEXITCODE -ne 0) { throw "connexion GitHub echouee : relancez ce script" }
}
gh auth setup-git

Etape "Depot abdelhak-workspace"
$espace = Join-Path $HOME "abdelhak-workspace"
if (Test-Path (Join-Path $espace ".git")) {
    git -C $espace pull --ff-only
} else {
    gh repo clone essanhajipython/abdelhak-workspace $espace
    if ($LASTEXITCODE -ne 0) { throw "clonage d'abdelhak-workspace echoue" }
}
$poste = Join-Path $espace "scripts\poste.py"

$python = (Get-Command py -ErrorAction SilentlyContinue).Source
$arguments = @("-3")
if (-not $python) {
    $python = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe" `
              -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1 -ExpandProperty FullName
    $arguments = @()
}
if (-not $python) { throw "Python introuvable apres son installation : ouvrez un nouveau PowerShell et relancez." }

Etape "Programmes, reglages et projets"
& $python @arguments $poste appliquer
Relire-Path

Etape "Connexions (navigateur), puis verification"
& $python @arguments $poste connexions
Write-Host "`nPour verifier plus tard : $python $($arguments -join ' ') $poste" -ForegroundColor Cyan
