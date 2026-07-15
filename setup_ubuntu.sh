#!/usr/bin/env bash
###############################################################################
# setup_ubuntu.sh — v2 (robuste, reprise sur échec, préflight réseau/DNS/dpkg)
#
# Installe l'environnement de travail complet : outils IA (Claude Code,
# OpenCode, Antigravity CLI), Chrome + lecteurs PDF, bureautique, LaTeX
# complet, Python scientifique, dev Web/Mobile, VS Code, utilitaires.
#
# Usage :
#   chmod +x setup_ubuntu.sh
#   ./setup_ubuntu.sh                -> menu interactif
#   ./setup_ubuntu.sh --all          -> installe TOUT
#   ./setup_ubuntu.sh --ai --latex   -> modules choisis
#   ./setup_ubuntu.sh --retry-failed -> relance UNIQUEMENT ce qui a échoué
#                                        la dernière fois
#   ./setup_ubuntu.sh --force --all  -> réinstalle tout même les modules déjà
#                                        marqués comme réussis
#
# Modules : --prereqs --ai --browser-pdf --office --latex --python
#           --web-mobile --vscode --utils --local-ai --dash-to-panel --gdrive
#
# Le script est idempotent et reprend là où il s'est arrêté : il garde une
# trace des modules réussis/échoués dans ~/.setup_ubuntu_state
###############################################################################

set -uo pipefail

# ------------------------------- Mode non interactif global -----------------
# Empêche apt/dpkg de poser des questions bloquantes pendant une install longue
# (needrestart, conflits de fichiers de conf, redémarrage de services...).
# C'est LA clé pour qu'une exécution --all aille jusqu'au bout sans surveillance.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a          # applique les redémarrages de services sans demander
export NEEDRESTART_SUSPEND=1       # ne suspend jamais l'exécution pour needrestart
export APT_LISTCHANGES_FRONTEND=none
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
          -o Dpkg::Use-Pty=0)

# ASSUME_YES=1 => aucune question interactive (impliqué par --all et --yes).
# Détecté aussi automatiquement si on tourne sans terminal (stdin non tty).
ASSUME_YES=0
[[ -t 0 ]] || ASSUME_YES=1

# ------------------------------- Couleurs / logs ----------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[FAIL]${NC} $*"; }

LOGFILE="$HOME/setup_ubuntu_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1
log "Journal complet de cette exécution : $LOGFILE"

# ------------------------------- État (reprise) ------------------------------
STATE_FILE="$HOME/.setup_ubuntu_state"
touch "$STATE_FILE"
FORCE=0
HEADLESS=0

module_done()   { grep -qxF "$1" "$STATE_FILE" 2>/dev/null; }
mark_done()     { grep -qxF "$1" "$STATE_FILE" 2>/dev/null || echo "$1" >> "$STATE_FILE"; }
mark_undone()   { sed -i "/^$1\$/d" "$STATE_FILE" 2>/dev/null || true; }

# Compteur d'échecs de paquets apt individuels (rempli par apt_install)
declare -a FAILED_PACKAGES=()
declare -a FAILED_MODULES=()

# ------------------------------- Vérifications de base -----------------------
if [[ "$EUID" -eq 0 ]]; then
    err "Ne lance pas ce script avec sudo/root directement. Lance-le en utilisateur normal ;"
    err "il demandera sudo lui-même quand nécessaire."
    exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
    err "Ce script est conçu pour Ubuntu/Debian (apt introuvable). Abandon."
    exit 1
fi

log "Ce script a besoin des droits administrateur. Tape ton mot de passe UNE SEULE"
log "fois maintenant : il sera gardé actif automatiquement, tu peux ensuite partir."
sudo -v || { err "Impossible d'obtenir les droits sudo. Abandon."; exit 1; }
# Garde la session sudo active tant que le script tourne (installs longues).
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null & )

###############################################################################
# PRÉFLIGHT : réseau, DNS, dpkg cassé — évite 90% des galères déjà vécues
###############################################################################
# repair_dns : (re)bascule sur des DNS publics fiables. Réutilisable — appelée
# en préflight ET automatiquement pendant les téléchargements si la résolution
# de noms retombe en panne (cause n°1 des échecs de CLI IA la dernière fois).
repair_dns() {
    local iface
    iface=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
    if [[ -n "${iface:-}" ]] && command -v resolvectl >/dev/null 2>&1; then
        sudo resolvectl dns "$iface" 8.8.8.8 1.1.1.1 >/dev/null 2>&1 || true
        sudo resolvectl flush-caches >/dev/null 2>&1 || true
    fi
    # Filet de sécurité : /etc/resolv.conf direct si resolvectl n'a pas suffi
    if ! getent hosts github.com >/dev/null 2>&1; then
        if [[ -w /etc/resolv.conf ]] || sudo test -w /etc/resolv.conf 2>/dev/null; then
            printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' | sudo tee /etc/resolv.conf >/dev/null 2>&1 || true
        fi
    fi
}

# dns_ok : test rapide de résolution (plusieurs domaines, tolérant).
dns_ok() {
    getent hosts github.com >/dev/null 2>&1 || getent hosts claude.ai >/dev/null 2>&1
}

preflight() {
    log "=== Vérifications préalables (réseau / DNS / dpkg) ==="

    # 1) Réparer un dpkg interrompu AVANT de commencer quoi que ce soit
    sudo dpkg --configure -a >/dev/null 2>&1 || true
    sudo apt --fix-broken install -y -qq >/dev/null 2>&1 || true

    # 2) Connectivité IP brute
    if ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; then
        ok "Connectivité réseau OK."
    else
        warn "Pas de réponse à 8.8.8.8. Vérifie ton câble/WiFi avant de continuer."
        if [[ "$ASSUME_YES" -eq 1 ]]; then
            warn "Mode non interactif : on continue quand même (certaines étapes échoueront peut-être)."
        else
            read -rp "Continuer quand même ? (o/N) : " REPLY
            [[ "$REPLY" =~ ^[Oo]$ ]] || exit 1
        fi
    fi

    # 3) Résolution DNS — la panne qu'on a eue la dernière fois
    if dns_ok; then
        ok "Résolution DNS OK."
    else
        warn "Le DNS ne répond pas. Tentative de correction automatique..."
        repair_dns
        sleep 2
        if dns_ok; then
            ok "DNS réparé (bascule sur 8.8.8.8 / 1.1.1.1)."
        else
            warn "DNS toujours en échec. Le script continuera et re-tentera de le réparer à chaque téléchargement."
        fi
    fi

    ok "Préflight terminé."
}

# ------------------------------- Téléchargement avec retry -------------------
# download_retry <url> <destination> [tentatives=3]
download_retry() {
    local url="$1" dest="$2" tries="${3:-3}" attempt=1
    while (( attempt <= tries )); do
        if wget -q --timeout=30 --tries=1 -O "$dest" "$url"; then
            # Vérifie que le fichier n'est pas vide/corrompu (taille > 1 Ko)
            if [[ -s "$dest" ]] && [[ $(stat -c%s "$dest" 2>/dev/null || echo 0) -gt 1024 ]]; then
                return 0
            fi
        fi
        warn "  Tentative $attempt/$tries échouée pour $url, nouvel essai..."
        rm -f "$dest"
        # Si c'est un problème de DNS, on tente de le réparer avant de réessayer.
        dns_ok || { warn "  DNS en panne — réparation..."; repair_dns; }
        sleep $(( attempt * 2 ))   # backoff progressif
        ((attempt++))
    done
    return 1
}

curl_retry() {
    local url="$1" tries="${2:-3}" attempt=1
    while (( attempt <= tries )); do
        # --max-time borne la durée TOTALE : un serveur qui traîne ne bloque
        # jamais indéfiniment le script (contrairement à un simple connect-timeout).
        if curl -fsSL --connect-timeout 15 --max-time 120 "$url"; then
            return 0
        fi
        warn "  Tentative $attempt/$tries échouée pour $url..."
        dns_ok || { warn "  DNS en panne — réparation..."; repair_dns; }
        sleep $(( attempt * 2 ))
        ((attempt++))
    done
    return 1
}

# run_installer <nom> <url> <interpréteur: bash|sh> — exécute un installeur
# "curl | bash" de façon robuste : téléchargement borné dans le temps + exécution
# bornée dans le temps (timeout dur) pour qu'un installeur qui "hang" n'immobilise
# jamais tout le script. Retourne 0 si succès.
run_installer() {
    local name="$1" url="$2" shell_bin="${3:-bash}" script
    script=$(mktemp --suffix=.sh)
    if curl_retry "$url" > "$script" && [[ -s "$script" ]]; then
        # 8 min max pour un installeur : largement assez, jamais infini.
        if timeout 480 "$shell_bin" "$script" >/dev/null 2>&1; then
            rm -f "$script"; return 0
        fi
        warn "  Installeur $name : exécution échouée ou expirée (timeout)."
    else
        warn "  Installeur $name : téléchargement impossible."
    fi
    rm -f "$script"; return 1
}

APT_UPDATED=0
apt_update_once() {
    if [[ "$APT_UPDATED" -eq 0 ]]; then
        log "Mise à jour des dépôts apt..."
        dns_ok || repair_dns
        sudo apt "${APT_OPTS[@]}" update -y -qq || warn "apt update a rencontré des erreurs (certains dépôts sont peut-être injoignables)."
        APT_UPDATED=1
    fi
}

# pkg_present <paquet> — vrai si le paquet est réellement installé. Tolérant aux
# paquets transitoires/virtuels : on accepte aussi bien l'entrée dpkg installée
# que l'état "installed" rapporté par apt-cache policy.
pkg_present() {
    dpkg -s "$1" >/dev/null 2>&1 && return 0
    LANG=C apt-cache policy "$1" 2>/dev/null | grep -q 'Installed: [^(]' && return 0
    return 1
}

# with_heartbeat <message> <commande...> — exécute une commande longue en
# affichant un point toutes les 20 s pour prouver que ça avance (évite de croire
# que le script est figé sur texlive-full ou un gros téléchargement).
with_heartbeat() {
    local msg="$1"; shift
    log "$msg (peut être long — un point toutes les 20 s tant que ça travaille)"
    # Le battement de cœur tourne en arrière-plan ; la commande reste au PREMIER
    # plan pour que ses effets (FAILED_PACKAGES, APT_UPDATED...) restent visibles.
    ( while true; do sleep 20; printf '.'; done ) &
    local hb=$!
    "$@"
    local rc=$?
    kill "$hb" 2>/dev/null; wait "$hb" 2>/dev/null
    printf '\n'
    return $rc
}

# apt_install <paquet1> <paquet2> ... — installe ET vérifie réellement chaque
# paquet (échec = module en échec). Réessaie une fois avec réparation DNS.
apt_install() {
    apt_update_once
    sudo apt "${APT_OPTS[@]}" install -y -qq "$@" >/dev/null 2>&1 || {
        dns_ok || repair_dns
        sudo apt "${APT_OPTS[@]}" install -y -qq "$@" >/dev/null 2>&1 || true
    }

    local pkg missing=()
    for pkg in "$@"; do
        pkg_present "$pkg" || missing+=("$pkg")
    done

    if (( ${#missing[@]} > 0 )); then
        warn "Paquets non confirmés installés : ${missing[*]}"
        FAILED_PACKAGES+=("${missing[@]}")
        return 1
    fi
    return 0
}

# apt_install_optional <paquet1> <paquet2> ... — comme apt_install mais NE FAIT
# PAS échouer le module : sert aux paquets secondaires (polices, extras) dont
# l'absence ne doit pas marquer tout un module comme raté.
apt_install_optional() {
    apt_update_once
    sudo apt "${APT_OPTS[@]}" install -y -qq "$@" >/dev/null 2>&1 || true
    local pkg
    for pkg in "$@"; do
        pkg_present "$pkg" || warn "  Paquet optionnel non installé : $pkg (pas bloquant)."
    done
    return 0
}

# apt_install_firstof <cmd_de_test> <candidat1> <candidat2> ... — installe le
# PREMIER candidat disponible dans les dépôts. Utile quand un paquet a changé de
# nom selon la version d'Ubuntu (ex: p7zip-full -> 7zip sur 26.04).
apt_install_firstof() {
    local test_cmd="$1"; shift
    if [[ -n "$test_cmd" ]] && command -v "$test_cmd" >/dev/null 2>&1; then
        return 0   # déjà présent (vérif par commande)
    fi
    apt_update_once
    local cand
    for cand in "$@"; do
        if LANG=C apt-cache show "$cand" >/dev/null 2>&1; then
            apt_install "$cand" && return 0
        fi
    done
    warn "  Aucun des candidats installable : $*"
    return 1
}

###############################################################################
# 0. PRÉREQUIS DE BASE
###############################################################################
install_prereqs() {
    log "=== Prérequis système ==="
    # Paquets CRITIQUES : sans eux le reste du script casse (curl, git...).
    local critical_ok=1
    apt_install curl wget git git-lfs ca-certificates gnupg lsb-release \
        software-properties-common apt-transport-https build-essential \
        unzip zip || critical_ok=0

    # 7-Zip : le nom a changé selon la version d'Ubuntu
    # (p7zip-full sur ≤24.04, 7zip sur 26.04). On teste par la commande `7z`/`7za`.
    if ! command -v 7z >/dev/null 2>&1 && ! command -v 7za >/dev/null 2>&1; then
        apt_install_firstof "" 7zip p7zip-full || warn "7-Zip non installé (pas bloquant)."
    fi

    if [[ "$critical_ok" -eq 1 ]]; then
        ok "Prérequis installés."
        mark_done "prereqs"
    else
        err "Des prérequis CRITIQUES ont échoué (curl/git/...) — le reste risque d'échouer."
        FAILED_MODULES+=("prereqs")
    fi
}

###############################################################################
# 1. OUTILS IA : Claude Code, OpenCode, Antigravity CLI
###############################################################################
install_ai_clis() {
    log "=== Claude Code, OpenCode, Antigravity CLI ==="
    local module_ok=1

    # Le PATH doit inclure ~/.local/bin AVANT de vérifier les binaires, sinon un
    # outil déjà installé (mais pas dans le PATH courant) serait réinstallé pour rien.
    export PATH="$HOME/.local/bin:$PATH"
    if ! grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
    fi

    if command -v claude >/dev/null 2>&1; then
        ok "Claude Code déjà installé ($(claude --version 2>/dev/null))."
    else
        log "Installation de Claude Code..."
        if run_installer "Claude Code" "https://claude.ai/install.sh" bash; then
            export PATH="$HOME/.local/bin:$PATH"
            command -v claude >/dev/null 2>&1 && ok "Claude Code installé." || { warn "Claude Code : script exécuté mais binaire introuvable."; module_ok=0; }
        else
            warn "Échec install Claude Code après plusieurs tentatives."
            module_ok=0
        fi
    fi

    if command -v opencode >/dev/null 2>&1; then
        ok "OpenCode déjà installé ($(opencode --version 2>/dev/null))."
    else
        log "Installation d'OpenCode..."
        if run_installer "OpenCode" "https://opencode.ai/install" bash; then
            # OpenCode s'installe dans ~/.opencode/bin (PAS ~/.local/bin) et ajoute
            # lui-même son PATH à ~/.bashrc : on l'ajoute au PATH courant pour
            # vérifier correctement sans faux négatif.
            export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$PATH"
            command -v opencode >/dev/null 2>&1 && ok "OpenCode installé." || { warn "OpenCode : script exécuté mais binaire introuvable."; module_ok=0; }
        else
            warn "Échec install OpenCode après plusieurs tentatives."
            module_ok=0
        fi
    fi

    if command -v agy >/dev/null 2>&1; then
        ok "Antigravity CLI déjà installé ($(agy --version 2>/dev/null))."
    else
        log "Installation d'Antigravity CLI (agy)..."
        if run_installer "Antigravity CLI" "https://antigravity.google/cli/install.sh" bash; then
            export PATH="$HOME/.local/bin:$PATH"
            command -v agy >/dev/null 2>&1 && ok "Antigravity CLI installé." || { warn "Antigravity CLI : script exécuté mais binaire introuvable."; module_ok=0; }
        else
            warn "Échec install Antigravity CLI (serveur Google parfois indisponible temporairement)."
            module_ok=0
        fi
    fi

    # --- Codex CLI (OpenAI) : installeur officiel, ne dépend PAS de Node ---
    if command -v codex >/dev/null 2>&1; then
        ok "Codex CLI déjà installé ($(codex --version 2>/dev/null))."
    else
        log "Installation de Codex CLI (OpenAI)..."
        # CODEX_NON_INTERACTIVE : l'installeur officiel demande "Start Codex now?"
        # en lisant /dev/tty directement (contourne la redirection stdout de
        # run_installer), ce qui bloquait le script en silence. On saute le prompt.
        export CODEX_NON_INTERACTIVE=1
        if run_installer "Codex CLI" "https://chatgpt.com/codex/install.sh" sh; then
            export PATH="$HOME/.local/bin:$PATH"
            command -v codex >/dev/null 2>&1 && ok "Codex CLI installé." \
                || warn "Codex CLI : script exécuté mais binaire introuvable (relance un terminal)."
        else
            warn "Échec install Codex CLI (pas bloquant pour le module ai)."
        fi
    fi

    # --- Grok Build CLI (xAI) : installeur officiel, ne dépend PAS de Node ---
    # (l'utilisation nécessite un abonnement SuperGrok / X Premium+.)
    if command -v grok >/dev/null 2>&1; then
        ok "Grok Build CLI déjà installé."
    else
        log "Installation de Grok Build CLI (xAI)..."
        # Le binaire installé s'appelle "grok" (pas "grok-build"), dans ~/.grok/bin.
        if run_installer "Grok Build CLI" "https://x.ai/cli/install.sh" bash; then
            export PATH="$HOME/.grok/bin:$HOME/.local/bin:$PATH"
            command -v grok >/dev/null 2>&1 && ok "Grok Build CLI installé (grok login pour t'authentifier)." \
                || warn "Grok Build CLI : script exécuté mais binaire introuvable (relance un terminal)."
        else
            warn "Échec install Grok Build CLI (pas bloquant pour le module ai)."
        fi
    fi
    # NB : le CLI GLM de Z.ai (@z_ai/coding-helper, alias 'chelper') a besoin de
    # npm ; il est installé dans le module web-mobile, après Node.

    if [[ "$module_ok" -eq 1 ]]; then
        mark_done "ai"
        warn "Pense à lancer 'claude', 'opencode', 'agy', 'codex', 'grok' une première fois pour t'authentifier."
    else
        FAILED_MODULES+=("ai")
    fi
}

###############################################################################
# 2. CHROME + LECTEURS PDF
###############################################################################
install_browser_pdf() {
    log "=== Google Chrome + lecteurs PDF ==="
    local module_ok=1

    if command -v google-chrome >/dev/null 2>&1; then
        ok "Google Chrome déjà installé."
    else
        log "Installation de Google Chrome..."
        TMP_DEB=$(mktemp --suffix=.deb)
        if download_retry "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" "$TMP_DEB"; then
            if sudo apt install -y -qq "$TMP_DEB" >/dev/null 2>&1 && command -v google-chrome >/dev/null 2>&1; then
                ok "Google Chrome installé."
            else
                warn "Échec installation du .deb Chrome."
                module_ok=0
            fi
        else
            warn "Téléchargement de Chrome échoué après plusieurs tentatives."
            module_ok=0
        fi
        rm -f "$TMP_DEB"
    fi

    apt_install evince xournalpp okular || module_ok=0

    if [[ "$module_ok" -eq 1 ]]; then
        mark_done "browser-pdf"
        ok "Chrome + lecteurs PDF installés (Evince rapide, Xournal++/Okular pour l'annotation)."
    else
        FAILED_MODULES+=("browser-pdf")
    fi
}

###############################################################################
# 3. LECTEURS WORD / EXCEL / PPT
###############################################################################
install_office_readers() {
    log "=== Suite bureautique (Word / Excel / PowerPoint) ==="
    local module_ok=1

    apt_install libreoffice libreoffice-l10n-fr || module_ok=0

    if command -v onlyoffice-desktopeditors >/dev/null 2>&1; then
        ok "OnlyOffice déjà installé."
    else
        log "Installation d'OnlyOffice Desktop Editors..."
        TMP_DEB=$(mktemp --suffix=.deb)
        if download_retry "https://download.onlyoffice.com/install/desktop/editors/linux/onlyoffice-desktopeditors_amd64.deb" "$TMP_DEB"; then
            sudo apt install -y -qq "$TMP_DEB" >/dev/null 2>&1 || sudo apt --fix-broken install -y -qq >/dev/null 2>&1
            if command -v onlyoffice-desktopeditors >/dev/null 2>&1; then
                ok "OnlyOffice installé."
            else
                warn "OnlyOffice non confirmé après install (pas bloquant, LibreOffice suffit)."
            fi
        else
            warn "Téléchargement OnlyOffice échoué (pas bloquant, LibreOffice suffit)."
        fi
        rm -f "$TMP_DEB"
    fi

    if [[ "$module_ok" -eq 1 ]]; then
        mark_done "office"
    else
        FAILED_MODULES+=("office")
    fi
}

###############################################################################
# 4. LATEX POUSSÉ (XeLaTeX, LuaLaTeX, minted, polices avancées)
###############################################################################
install_latex() {
    log "=== LaTeX complet (XeLaTeX / LuaLaTeX / minted / polices) ==="
    warn "texlive-full pèse plusieurs Go, ça peut prendre du temps..."
    local module_ok=1

    with_heartbeat "Installation de texlive-full + paquets LaTeX" \
        apt_install texlive-full latexmk biber python3-pygments pipx \
        fonts-noto fonts-noto-color-emoji fonts-noto-cjk \
        fonts-texgyre fonts-freefont-ttf texlive-lang-arabic texlive-lang-french \
        || module_ok=0

    # Patch latexminted pour compatibilité Python 3.14
    # Le wheel 0.6.0 fourni par TeX Live 2025 plante sur Python ≥3.14 :
    #   TypeError: ArgParser.__init__() got an unexpected keyword argument 'color'
    # Cause : argparse a changé dans Python 3.14 (passe de nouveaux kwargs).
    # Solution : patcher le wheel localement et l'installer via pipx (sans sudo).
    if python3 -c "import sys; exit(0 if sys.version_info >= (3,14) else 1)" 2>/dev/null; then
        WHL_SRC="/usr/share/texlive/texmf-dist/scripts/minted/latexminted-0.6.0-py3-none-any.whl"
        if [[ -f "$WHL_SRC" ]] && ! latexminted config --help >/dev/null 2>&1; then
            log "Python ≥3.14 détecté — patch de latexminted..."
            TMP_DIR=$(mktemp -d)
            WHL_PATCHED="$TMP_DIR/latexminted-0.6.0-py3-none-any.whl"
            cp "$WHL_SRC" "$WHL_PATCHED"
            cat > "$TMP_DIR/patch_wheel.py" << 'PYEOF'
import zipfile, sys, re
whl = sys.argv[1]
with zipfile.ZipFile(whl, 'r') as z:
    files = {f: z.read(f) for f in z.namelist()}
content = files['latexminted/cmdline.py'].decode('utf-8')
# Remplace le constructeur pour accepter **kwargs (Python 3.14+)
content = re.sub(
    r'def __init__\(self, \*, prog: str\):',
    'def __init__(self, *, prog: str, **kwargs):',
    content,
)
# Ajoute **kwargs dans l'appel super().__init__()
content = re.sub(
    r'(formatter_class=argparse\.RawTextHelpFormatter)\s*\)',
    r'\1, **kwargs)',
    content,
)
files['latexminted/cmdline.py'] = content.encode('utf-8')
with zipfile.ZipFile(whl, 'w', zipfile.ZIP_DEFLATED) as z:
    for fname, data in files.items():
        z.writestr(fname, data)
PYEOF
            python3 "$TMP_DIR/patch_wheel.py" "$WHL_PATCHED" && \
            pipx install --force "$WHL_PATCHED" >/dev/null 2>&1 && \
            latexminted config --help >/dev/null 2>&1 && \
            ok "latexminted patché et installé via pipx." || \
            warn "Échec du patch latexminted (les couleurs minted seront absentes)."
            rm -rf "$TMP_DIR"
        fi
    fi

    # Amiri : nom de paquet variable selon la version d'Ubuntu -> on essaie
    # plusieurs candidats sans faire échouer tout le module si aucun ne matche.
    if ! fc-list | grep -qi "Amiri"; then
        for candidate in fonts-amiri fonts-hosny-amiri; do
            if apt-cache show "$candidate" >/dev/null 2>&1; then
                apt_install "$candidate" && break
            fi
        done
        if ! fc-list | grep -qi "Amiri"; then
            warn "Police Amiri indisponible via apt sur cette version d'Ubuntu."
            log "Récupération directe depuis Google Fonts..."
            FONT_DIR="$HOME/.local/share/fonts/amiri"
            mkdir -p "$FONT_DIR"
            download_retry "https://github.com/google/fonts/raw/main/ofl/amiri/Amiri-Regular.ttf" "$FONT_DIR/Amiri-Regular.ttf" \
                && fc-cache -f "$FONT_DIR" >/dev/null 2>&1 \
                && ok "Police Amiri installée manuellement." \
                || warn "Amiri non installée (à faire manuellement plus tard si besoin)."
        fi
    fi

    # Police Cairo (Google Fonts)
    if ! fc-list | grep -qi "Cairo"; then
        log "Installation de la police Cairo (Google Fonts)..."
        FONT_DIR="$HOME/.local/share/fonts/cairo"
        mkdir -p "$FONT_DIR"
        download_retry "https://github.com/google/fonts/raw/main/ofl/cairo/Cairo%5Bslnt%2Cwght%5D.ttf" "$FONT_DIR/Cairo.ttf" \
            && fc-cache -f "$FONT_DIR" >/dev/null 2>&1 \
            || warn "Police Cairo non récupérée (pas bloquant)."
    fi
    apt_install fonts-libertinus 2>/dev/null || true

    if ! grep -q "alias xelatex-se=" "$HOME/.bashrc" 2>/dev/null; then
        cat >> "$HOME/.bashrc" <<'EOF'

# --- Alias LaTeX avec shell-escape (nécessaire pour le package minted) ---
alias xelatex-se='xelatex -shell-escape -interaction=nonstopmode'
alias lualatex-se='lualatex -shell-escape -interaction=nonstopmode'
alias latexmk-se='latexmk -pdf -xelatex -shell-escape'
EOF
        log "Alias xelatex-se / lualatex-se / latexmk-se ajoutés à ~/.bashrc."
    fi

    # Test réel : compilation LaTeX avec minted pour vérifier que tout fonctionne
    if command -v lualatex >/dev/null 2>&1; then
        log "Test de compilation LaTeX avec minted..."
        TEST_DIR=$(mktemp -d)
        cat > "$TEST_DIR/test_minted.tex" <<'TMEOF'
\documentclass{article}
\usepackage[highlightmode=immediate]{minted}
\begin{document}
\begin{minted}{python}
def hello():
    print("Hello, minted!")
\end{minted}
\end{document}
TMEOF
        PATH="$HOME/.local/bin:$PATH" lualatex -shell-escape -interaction=nonstopmode -jobname="test_minted" "$TEST_DIR/test_minted.tex" >/dev/null 2>&1
        if grep -q "Cannot highlight code\|minted.*Error" "$TEST_DIR/test_minted.log" 2>/dev/null; then
            warn "minted ne fonctionne pas correctement — la coloration syntaxique sera absente."
            warn "Consulte le log : $TEST_DIR/test_minted.log"
            module_ok=0
            FAILED_MODULES+=("latex")
        else
            ok "Compilation LaTeX + minted réussie (coloration OK)."
        fi
        rm -rf "$TEST_DIR"
    fi

    # Vérification finale réelle (pas juste le code retour d'apt)
    if command -v xelatex >/dev/null 2>&1 && command -v lualatex >/dev/null 2>&1; then
        ok "LaTeX complet installé et vérifié (XeLaTeX + LuaLaTeX fonctionnels)."
        mark_done "latex"
    else
        err "xelatex/lualatex introuvables après installation — module en échec réel."
        module_ok=0
        FAILED_MODULES+=("latex")
    fi
}

###############################################################################
# 5. PYTHON SCIENTIFIQUE
###############################################################################
install_python_sci() {
    log "=== Python scientifique ==="
    local module_ok=1
    local PYVER
    PYVER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')

    apt_install python3 python3-pip "python3-venv" "python3-full" pipx \
        "python${PYVER}-venv" 2>/dev/null || true
    # python3-venv générique suffit dans la plupart des cas ; le paquet versionné
    # (ex: python3.14-venv) est tenté en plus car certaines versions d'Ubuntu
    # récentes le séparent du paquet générique.

    pipx ensurepath >/dev/null 2>&1 || true

    VENV_DIR="$HOME/venvs/sci"
    if [[ -x "$VENV_DIR/bin/python" ]]; then
        ok "Environnement virtuel scientifique déjà présent : $VENV_DIR"
    else
        log "Création de l'environnement virtuel Python scientifique : $VENV_DIR"
        rm -rf "$VENV_DIR"
        if ! python3 -m venv "$VENV_DIR" || [[ ! -x "$VENV_DIR/bin/python" ]]; then
            err "Création du venv échouée — python3-venv manque probablement pour ta version de Python (${PYVER})."
            log "Essaie manuellement : sudo apt install python${PYVER}-venv"
            module_ok=0
        fi
    fi

    if [[ -x "$VENV_DIR/bin/pip" ]]; then
        log "Installation des paquets scientifiques dans $VENV_DIR..."
        "$VENV_DIR/bin/pip" install -q --upgrade pip wheel setuptools
        if "$VENV_DIR/bin/pip" install -q \
            numpy scipy pandas matplotlib seaborn plotly sympy \
            scikit-learn statsmodels numba \
            jupyter jupyterlab notebook ipykernel \
            reportlab edge-tts pydub openpyxl xlsxwriter \
            requests beautifulsoup4 lxml tqdm; then
            "$VENV_DIR/bin/python" -m ipykernel install --user --name=sci --display-name "Python (sci)" >/dev/null 2>&1
            ok "Paquets scientifiques installés."
        else
            warn "Certains paquets Python ont échoué à l'installation."
            module_ok=0
        fi
    fi

    if ! grep -q "alias sci-activate=" "$HOME/.bashrc" 2>/dev/null; then
        echo "alias sci-activate='source $VENV_DIR/bin/activate'" >> "$HOME/.bashrc"
    fi

    if [[ "$module_ok" -eq 1 ]]; then
        ok "Python scientifique prêt. Active-le avec : sci-activate"
        mark_done "python"
    else
        FAILED_MODULES+=("python")
    fi
}

###############################################################################
# 6. DÉVELOPPEMENT WEB + MOBILE
###############################################################################
install_web_mobile() {
    log "=== Développement Web & Mobile ==="
    local module_ok=1

    if [[ -d "$HOME/.nvm" ]] && [[ -s "$HOME/.nvm/nvm.sh" ]]; then
        ok "nvm déjà installé."
    else
        log "Installation de nvm..."
        run_installer "nvm" "https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh" bash || warn "Échec install nvm."
    fi
    export NVM_DIR="$HOME/.nvm"
    # IMPORTANT : nvm.sh n'est PAS compatible avec `set -u` (il référence des
    # variables non définies). Sous nounset, le sourcer tue le script SILENCIEUSEMENT
    # (sortie immédiate juste après "nvm déjà installé"). On désactive donc nounset
    # le temps de charger et d'utiliser nvm, puis on le réactive.
    set +u
    # shellcheck disable=SC1091
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    if command -v nvm >/dev/null 2>&1; then
        nvm install --lts >/dev/null 2>&1
        nvm use --lts >/dev/null 2>&1
        npm install -g pnpm yarn >/dev/null 2>&1
        # CLI GLM de Z.ai (@z_ai/coding-helper, commande 'chelper') : charge le
        # plan GLM Coding dans Claude Code / OpenCode. Installé ici car il a besoin
        # de npm. JAMAIS de 'sudo npm -g' (règle du repo) -> npm de nvm sans sudo.
        npm install -g @z_ai/coding-helper >/dev/null 2>&1 \
            && ok "Z.ai coding-helper installé (lance 'chelper')." \
            || warn "Z.ai coding-helper non installé (pas bloquant)."
        if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
            ok "Node.js LTS + npm/pnpm/yarn installés."
        else
            warn "nvm installé mais node/npm non confirmés."
            module_ok=0
        fi
    else
        warn "nvm non chargé — relance un nouveau terminal puis 'nvm install --lts'."
        module_ok=0
    fi
    set -u   # réactive nounset pour la suite du script

    # Mobile : Flutter (snap peut échouer si problème réseau IPv6 -> pas fatal)
    if command -v flutter >/dev/null 2>&1 || snap list 2>/dev/null | grep -q flutter; then
        ok "Flutter déjà installé."
    else
        log "Installation de Flutter (snap, ça peut prendre plusieurs minutes)..."
        timeout 900 sudo snap install flutter --classic >/dev/null 2>&1 || warn "Échec/timeout install Flutter via snap (réessaie plus tard : sudo snap install flutter --classic)."
    fi

    if snap list 2>/dev/null | grep -q android-studio; then
        ok "Android Studio déjà installé."
    else
        log "Installation d'Android Studio (snap, gros téléchargement)..."
        timeout 1200 sudo snap install android-studio --classic >/dev/null 2>&1 || warn "Échec/timeout install Android Studio via snap."
    fi

    apt_install openjdk-17-jdk || true

    log "Pour React Native/Expo (alternative légère à Flutter) : npm install -g expo-cli"

    if [[ "$module_ok" -eq 1 ]]; then
        mark_done "web-mobile"
    else
        FAILED_MODULES+=("web-mobile")
    fi
}

###############################################################################
# 7. VSCODE + EXTENSIONS
###############################################################################
install_vscode() {
    log "=== Visual Studio Code ==="
    local module_ok=1

    if command -v code >/dev/null 2>&1; then
        ok "VS Code déjà installé."
    else
        log "Installation de VS Code (dépôt officiel Microsoft)..."
        sudo install -d -m 0755 /etc/apt/keyrings
        if curl_retry "https://packages.microsoft.com/keys/microsoft.asc" | sudo gpg --dearmor -o /etc/apt/keyrings/packages.microsoft.gpg 2>/dev/null; then
            echo "deb [arch=amd64,arm64 signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | \
                sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
            apt_update_once
            apt_install code
        fi

        # Fallback 1 : .deb officiel direct si le dépôt apt a échoué
        if ! command -v code >/dev/null 2>&1; then
            warn "Dépôt apt VS Code indisponible, tentative via le .deb officiel..."
            TMP_DEB=$(mktemp --suffix=.deb)
            if download_retry "https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64" "$TMP_DEB"; then
                sudo apt install -y -qq "$TMP_DEB" >/dev/null 2>&1
            fi
            rm -f "$TMP_DEB"
        fi

        # Fallback 2 : snap
        if ! command -v code >/dev/null 2>&1; then
            warn "Tentative via snap..."
            sudo snap install code --classic >/dev/null 2>&1 || true
        fi

        if command -v code >/dev/null 2>&1; then
            ok "VS Code installé."
        else
            err "VS Code non installé après 3 méthodes différentes (dépôt apt, .deb, snap)."
            module_ok=0
        fi
    fi

    if command -v code >/dev/null 2>&1; then
        log "Installation des extensions VS Code..."
        EXTENSIONS=(
            ms-python.python ms-python.vscode-pylance ms-toolsai.jupyter
            James-Yu.latex-workshop yzhang.markdown-all-in-one
            DavidAnson.vscode-markdownlint esbenp.prettier-vscode
            dbaeumer.vscode-eslint eamodio.gitlens redhat.vscode-yaml
            tamasfe.even-better-toml ms-azuretools.vscode-docker
            christian-kohler.path-intellisense mechatroner.rainbow-csv
        )
        for ext in "${EXTENSIONS[@]}"; do
            code --install-extension "$ext" --force >/dev/null 2>&1 && ok "  - $ext" || warn "  - $ext (échec)"
        done
    fi

    if [[ "$module_ok" -eq 1 ]]; then
        mark_done "vscode"
    else
        FAILED_MODULES+=("vscode")
    fi
}

###############################################################################
# 8. UTILITAIRES DIVERS
###############################################################################
install_utils() {
    log "=== Utilitaires divers ==="
    local module_ok=1
    apt_install htop tmux ripgrep fzf jq tree gparted timeshift \
        flameshot gimp vlc synaptic ufw bat || module_ok=0

    if ! command -v eza >/dev/null 2>&1; then
        apt_install eza 2>/dev/null || warn "eza indisponible (pas bloquant)."
    fi

    if [[ "$module_ok" -eq 1 ]]; then
        ok "Utilitaires installés."
        mark_done "utils"
    else
        FAILED_MODULES+=("utils")
    fi
    warn "Pense à configurer Timeshift dès maintenant (utile en dual-boot) : sudo timeshift-launcher"
}

###############################################################################
# 9. IA LOCALE (Ollama)
###############################################################################
install_local_ai() {
    log "=== IA locale (Ollama) ==="
    if command -v ollama >/dev/null 2>&1; then
        ok "Ollama déjà installé."
        mark_done "local-ai"
    else
        log "Installation d'Ollama..."
        if run_installer "Ollama" "https://ollama.com/install.sh" sh && command -v ollama >/dev/null 2>&1; then
            ok "Ollama installé."
            mark_done "local-ai"
        else
            warn "Échec install Ollama."
            FAILED_MODULES+=("local-ai")
        fi
    fi
}

###############################################################################
# 10. DASH TO PANEL (extension GNOME)
###############################################################################
install_dash_to_panel() {
    log "=== Dash to Panel (extension GNOME) ==="
    local module_ok=1
    local ext_dir="$HOME/.local/share/gnome-shell/extensions/dash-to-panel@jderose9.github.com"

    if [[ -d "$ext_dir" ]] && [[ -f "$ext_dir/extension.js" ]]; then
        ok "Dash to Panel déjà installé et fonctionnel."
        mark_done "dash-to-panel"
        return
    fi

    # Détection / nettoyage d'une installation corrompue (ex: clonage Git sans compilation)
    if [[ -d "$ext_dir" ]] && [[ ! -f "$ext_dir/extension.js" ]]; then
        warn "Installation corrompue détectée (extension.js manquant) — nettoyage..."
        rm -rf "$ext_dir"
    fi

    log "Installation de Dash to Panel v73..."
    mkdir -p "$(dirname "$ext_dir")"
    local tmp_zip
    tmp_zip=$(mktemp --suffix=.zip)
    if download_retry "https://extensions.gnome.org/extension-data/dash-to-paneljderose9.github.com.v73.shell-extension.zip" \
        "$tmp_zip"; then
        if unzip -q -o "$tmp_zip" -d "$ext_dir"; then
            # Activer l'extension
            busctl --user call org.gnome.Shell.Extensions \
                /org/gnome/Shell/Extensions \
                org.gnome.Shell.Extensions InstallRemoteExtension \
                s "dash-to-panel@jderose9.github.com" >/dev/null 2>&1 || true
            gnome-extensions enable dash-to-panel@jderose9.github.com >/dev/null 2>&1 || true
            # Désactiver ubuntu-dock qui est incompatible
            gnome-extensions disable ubuntu-dock@ubuntu.com >/dev/null 2>&1 || true
            # Vider le cache
            rm -rf "$HOME/.cache/gnome-shell/" "$HOME/.local/share/gnome-shell/gnome-shell-extensions-cache/" 2>/dev/null || true
            ok "Dash to Panel installé."
        else
            warn "Extraction du zip échouée."
            module_ok=0
        fi
        rm -f "$tmp_zip"
    else
        warn "Téléchargement de Dash to Panel échoué après plusieurs tentatives."
        module_ok=0
    fi

    if [[ "$module_ok" -eq 1 ]]; then
        mark_done "dash-to-panel"
        warn "Déconnexion/reconnexion nécessaire (surtout sous Wayland) pour voir l'extension."
    else
        FAILED_MODULES+=("dash-to-panel")
    fi
}

###############################################################################
# 10bis. RACCOURCIS CLAVIER GNOME (Super+E -> gestionnaire de fichiers)
###############################################################################
install_gnome_shortcuts() {
    log "=== Raccourcis clavier GNOME (Super+E -> Fichiers) ==="
    local module_ok=1
    local base="org.gnome.settings-daemon.plugins.media-keys"
    local key_path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/super-e-files/"

    if ! command -v gsettings >/dev/null 2>&1; then
        warn "gsettings introuvable (pas un environnement GNOME ?) — raccourci non configuré."
        FAILED_MODULES+=("gnome-shortcuts")
        return
    fi

    # Ajoute notre chemin à la liste existante sans écraser d'éventuels autres
    # raccourcis personnalisés déjà configurés par l'utilisateur.
    local current new_list
    current=$(gsettings get "$base" custom-keybindings 2>/dev/null)
    if [[ "$current" != *"$key_path"* ]]; then
        if [[ -z "$current" || "$current" == "@as []" || "$current" == "[]" ]]; then
            new_list="['$key_path']"
        else
            new_list="${current%]}, '$key_path']"
        fi
        gsettings set "$base" custom-keybindings "$new_list"
    fi

    gsettings set "$base.custom-keybinding:$key_path" name 'Open Files'
    gsettings set "$base.custom-keybinding:$key_path" command 'nautilus'
    gsettings set "$base.custom-keybinding:$key_path" binding '<Super>e'

    if gsettings get "$base.custom-keybinding:$key_path" binding 2>/dev/null | grep -q "Super>e"; then
        ok "Raccourci Super+E -> Fichiers (nautilus) configuré, comme sous Windows."
        mark_done "gnome-shortcuts"
    else
        err "Le raccourci Super+E n'a pas pu être vérifié après configuration."
        module_ok=0
    fi

    if [[ "$module_ok" -ne 1 ]]; then
        FAILED_MODULES+=("gnome-shortcuts")
    fi
}

###############################################################################
# 11. GOOGLE DRIVE (rclone + systemd mount)
###############################################################################
install_gdrive() {
    log "=== Google Drive (rclone) ==="
    local module_ok=1

    apt_install rclone || module_ok=0

    # Dossier de montage
    mkdir -p "$HOME/Google_Drive"

    # Fichier service systemd
    local service_dir="$HOME/.config/systemd/user"
    mkdir -p "$service_dir"
    cat > "$service_dir/rclone-gdrive.service" <<EOF
[Unit]
Description=Rclone Google Drive Mount Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/rclone mount gdrive: %h/Google_Drive --vfs-cache-mode full --vfs-cache-max-age 24h --vfs-cache-max-size 10G --vfs-read-chunk-size 32M --vfs-read-chunk-size-limit off --buffer-size 32M
ExecStop=/usr/bin/fusermount3 -u %h/Google_Drive
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

    # Recharger systemd et activer le service
    if systemctl --user daemon-reload \
       && systemctl --user enable rclone-gdrive.service; then
        ok "Service systemd rclone-gdrive installé et activé."
    else
        warn "Impossible d'activer le service systemd rclone-gdrive."
        module_ok=0
    fi

    # Ajoute le dossier à la barre latérale du gestionnaire de fichiers (Nautilus/
    # Nemo/Thunar lisent tous ce même fichier de favoris GTK). Idempotent.
    local bookmarks="$HOME/.config/gtk-3.0/bookmarks"
    mkdir -p "$(dirname "$bookmarks")"
    touch "$bookmarks"
    if ! grep -qF "file://$HOME/Google_Drive" "$bookmarks" 2>/dev/null; then
        echo "file://$HOME/Google_Drive Google Drive" >> "$bookmarks"
        ok "Raccourci « Google Drive » ajouté à la barre latérale du gestionnaire de fichiers."
    fi

    # L'AUTHENTIFICATION GOOGLE NE PEUT PAS ÊTRE AUTOMATISÉE : elle exige une
    # connexion OAuth interactive dans un navigateur (fenêtre de login Google).
    # On détecte juste si c'est déjà fait, et sinon on donne la marche à suivre.
    if rclone listremotes 2>/dev/null | grep -qx "gdrive:"; then
        ok "Compte Google Drive déjà configuré (remote 'gdrive' trouvé)."
        systemctl --user start rclone-gdrive.service 2>/dev/null || true
        sleep 2
        if mountpoint -q "$HOME/Google_Drive" 2>/dev/null; then
            ok "Google Drive monté sur ~/Google_Drive."
        else
            warn "Remote configuré mais montage non confirmé — relance : systemctl --user restart rclone-gdrive.service"
        fi
    else
        warn "Compte Google pas encore connecté — étape MANUELLE obligatoire (connexion OAuth) :"
        warn "  1) rclone config"
        warn "     -> n (New remote) -> name: gdrive -> Storage: drive -> Entrée/Entrée/Entrée"
        warn "     -> scope: 1 -> Entrée/Entrée -> Use web browser? y (le navigateur s'ouvre,"
        warn "        connecte-toi à Google et clique Autoriser) -> n -> y -> q"
        warn "  2) systemctl --user start rclone-gdrive.service"
        warn "  3) ls ~/Google_Drive   (tes fichiers doivent apparaître)"
        warn "Une fois fait, le montage redémarrera automatiquement à chaque session."
    fi

    if [[ "$module_ok" -eq 1 ]]; then
        mark_done "gdrive"
    else
        FAILED_MODULES+=("gdrive")
    fi
}

###############################################################################
# 12. DOCKER
###############################################################################
install_docker() {
    log "=== Docker ==="
    local module_ok=1

    if command -v docker >/dev/null 2>&1; then
        ok "Docker déjà installé ($(docker --version 2>/dev/null))."
    else
        log "Installation de Docker (dépôt officiel)..."
        if run_installer "Docker" "https://get.docker.com" sh; then
            sudo usermod -aG docker "$USER" >/dev/null 2>&1 || true
            if command -v docker >/dev/null 2>&1; then
                ok "Docker installé."
            else
                warn "Docker : script exécuté mais binaire introuvable."
                module_ok=0
            fi
        else
            warn "Échec install Docker."
            module_ok=0
        fi
    fi

    if command -v docker-compose >/dev/null 2>&1 || docker compose version >/dev/null 2>&1; then
        ok "Docker Compose déjà disponible."
    else
        log "Installation de Docker Compose plugin..."
        apt_install docker-compose-plugin 2>/dev/null || warn "Docker Compose plugin non installé."
    fi

    if [[ "$module_ok" -eq 1 ]]; then
        mark_done "docker"
        warn "Déconnexion/reconnexion nécessaire pour utiliser docker sans sudo (ou exécute 'newgrp docker')."
    else
        FAILED_MODULES+=("docker")
    fi
}

###############################################################################
# 13. APPS IA DESKTOP (Claude Desktop, OpenCode Desktop — apps officielles pour Linux)
###############################################################################
install_desktop_ai() {
    log "=== Apps IA desktop (Claude Desktop, OpenCode Desktop) ==="
    local module_ok=1

    if dpkg -s claude-desktop >/dev/null 2>&1 || command -v claude-desktop >/dev/null 2>&1; then
        ok "Claude Desktop déjà installé."
    else
        log "Installation de Claude Desktop (dépôt apt officiel Anthropic)..."
        # Clé de signature + dépôt officiels (downloads.claude.ai) : install et
        # surtout mises à jour via apt upgrade ensuite.
        sudo curl -fsSLo /usr/share/keyrings/claude-desktop-archive-keyring.asc \
            https://downloads.claude.ai/claude-desktop/key.asc 2>/dev/null || \
            warn "Téléchargement de la clé Claude Desktop échoué."
        echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main" \
            | sudo tee /etc/apt/sources.list.d/claude-desktop.list >/dev/null
        APT_UPDATED=0   # forcer un apt update pour prendre en compte le nouveau dépôt
        if apt_install claude-desktop; then
            ok "Claude Desktop installé (lance 'claude-desktop' ou depuis le menu d'applis)."
        else
            warn "Échec install Claude Desktop (nécessite Ubuntu 22.04+ / Debian 12+, x86_64 ou arm64)."
            module_ok=0
        fi
    fi

    if [[ -d /opt/OpenCode ]] || dpkg -s opencode >/dev/null 2>&1; then
        ok "OpenCode Desktop déjà installé."
    else
        log "Installation d'OpenCode Desktop (beta, .deb officiel opencode.ai)..."
        # Pas de dépôt apt : opencode.ai/download ne fournit qu'un .deb en
        # téléchargement direct, donc install ponctuelle (pas de maj via apt upgrade).
        # Le paquet .deb s'appelle "opencode" (pas "opencode-desktop") et installe
        # dans /opt/OpenCode ; le lanceur enregistré est "ai.opencode.desktop".
        local oc_deb; oc_deb="$(mktemp --suffix=.deb)"
        if curl -fsSL "https://opencode.ai/download/stable/linux-x64-deb" -o "$oc_deb"; then
            if sudo apt-get install -y "$oc_deb"; then
                ok "OpenCode Desktop installé (lance-le depuis le menu d'applis, ou 'ai.opencode.desktop')."
            else
                warn "Échec install OpenCode Desktop (dépendances .deb)."
                module_ok=0
            fi
        else
            warn "Téléchargement d'OpenCode Desktop échoué."
            module_ok=0
        fi
        rm -f "$oc_deb"
    fi

    if [[ "$module_ok" -eq 1 ]]; then
        mark_done "desktop-ai"
    else
        FAILED_MODULES+=("desktop-ai")
    fi
}

# --- skill:setup-ubuntu id=jupyter-notebook ---
###############################################################################
# MODULE (skill:setup-ubuntu) — Jupyter Notebook (pipx)
###############################################################################
install_jupyter_notebook() {
    if command -v jupyter-notebook >/dev/null 2>&1; then
        ok "Jupyter Notebook déjà installé ($(jupyter-notebook --version 2>/dev/null || echo 'version inconnue'))."
    else
        log "Installation de Jupyter Notebook via pipx..."
        if command -v pipx >/dev/null 2>&1; then
            if pipx install jupyter --include-deps; then
                ok "Jupyter Notebook installé via pipx."
            else
                err "Échec de l'installation de Jupyter Notebook via pipx."
                FAILED_MODULES+=("jupyter-notebook")
                return
            fi
        else
            err "pipx introuvable. Installe pipx d'abord (apt install pipx)."
            FAILED_MODULES+=("jupyter-notebook")
            return
        fi
    fi
    mark_done "jupyter-notebook"
}
# --- skill:setup-ubuntu end:jupyter-notebook ---

###############################################################################
# MENU / DISPATCH
###############################################################################
# Ordre optimisé : d'abord les modules importants ET rapides (on veut les outils
# IA/dev utilisables au plus vite), ensuite les gros téléchargements (office,
# mobile, et surtout texlive-full de plusieurs Go) qui tournent en fin de course
# sans surveillance.
ALL_MODULES=(prereqs ai python utils vscode browser-pdf desktop-ai gdrive docker local-ai dash-to-panel gnome-shortcuts office web-mobile latex jupyter-notebook)

# Libellés affichés dans le menu interactif, tenus à jour en parallèle de
# ALL_MODULES. Le menu est généré à partir de ces deux tableaux (voir
# show_menu) : ajouter un module ne demande jamais de renuméroter le menu à
# la main, ce qui est la source d'erreur historique de cette section.
declare -A MODULE_LABELS=(
    [prereqs]="Prérequis système"
    [ai]="IA CLI (Claude/OpenCode/Antigravity/Codex/Grok/Z.ai)"
    [browser-pdf]="Chrome + lecteurs PDF"
    [office]="Suite bureautique (Word/Excel/PPT)"
    [latex]="LaTeX complet"
    [python]="Python scientifique"
    [web-mobile]="Dev Web + Mobile"
    [vscode]="VS Code + extensions"
    [utils]="Utilitaires"
    [local-ai]="IA locale (Ollama)"
    [dash-to-panel]="Dash to Panel (GNOME)"
    [gnome-shortcuts]="Raccourci Super+E -> Fichiers (GNOME)"
    [gdrive]="Google Drive (rclone)"
    [docker]="Docker"
    [desktop-ai]="Apps IA desktop (Claude Desktop, OpenCode Desktop)"
    [jupyter-notebook]="Jupyter Notebook (pipx)"
)

run_module() {
    local m="$1"
    if [[ "$FORCE" -eq 0 ]] && module_done "$m"; then
        ok "Module '$m' déjà marqué réussi précédemment — ignoré (utilise --force pour forcer)."
        return
    fi
    case "$m" in
        prereqs)      install_prereqs ;;
        ai)           install_ai_clis ;;
        browser-pdf)  install_browser_pdf ;;
        office)       install_office_readers ;;
        latex)        install_latex ;;
        python)       install_python_sci ;;
        web-mobile)   install_web_mobile ;;
        vscode)       install_vscode ;;
        utils)        install_utils ;;
        local-ai)     install_local_ai ;;
        dash-to-panel) install_dash_to_panel ;;
        gnome-shortcuts) install_gnome_shortcuts ;;
        gdrive)       install_gdrive ;;
        docker)       install_docker ;;
        desktop-ai)   install_desktop_ai ;;
        jupyter-notebook) install_jupyter_notebook ;;
        *) warn "Module inconnu : $m" ;;
    esac
}

show_menu() {
    echo ""
    echo "======================================================================"
    echo "   Configuration de ton environnement Ubuntu — choisis les modules"
    echo "======================================================================"
    local i=1 m
    for m in "${ALL_MODULES[@]}"; do
        printf "  %2d) %s\n" "$i" "${MODULE_LABELS[$m]:-$m}"
        ((i++))
    done
    echo "  A) TOUT installer          R) Relancer seulement les échecs précédents"
    echo "  Q) Quitter"
    echo "======================================================================"
    read -rp "Ton choix (ex: 1 3 5 ou A) : " -a CHOICES

    for c in "${CHOICES[@]}"; do
        case "$c" in
            [Aa]) for m in "${ALL_MODULES[@]}"; do run_module "$m"; done ;;
            [Rr]) retry_failed ;;
            [Qq]) log "À bientôt !"; exit 0 ;;
            ''|*[!0-9]*) warn "Choix ignoré : $c" ;;
            *)
                if (( c >= 1 && c <= ${#ALL_MODULES[@]} )); then
                    run_module "${ALL_MODULES[$((c - 1))]}"
                else
                    warn "Choix ignoré : $c"
                fi
                ;;
        esac
    done
}

retry_failed() {
    if [[ ! -f "$HOME/.setup_ubuntu_last_failures" ]]; then
        warn "Aucun échec enregistré lors de la dernière exécution."
        return
    fi
    log "Relance des modules en échec la dernière fois..."
    while IFS= read -r m; do
        [[ -n "$m" ]] && { mark_undone "$m"; run_module "$m"; }
    done < "$HOME/.setup_ubuntu_last_failures"
}

###############################################################################
# 13. MISE À JOUR (pipx, npm, pip)
###############################################################################
run_update() {
    log "=== Mise à jour de tout l'existant ==="

    # pipx
    if command -v pipx >/dev/null 2>&1; then
        log "Mise à jour des paquets pipx..."
        pipx upgrade-all 2>/dev/null || true
        ok "pipx à jour."
    fi

    # npm global
    if command -v npm >/dev/null 2>&1; then
        log "Mise à jour des paquets npm globaux..."
        npm update -g 2>/dev/null || true
        ok "npm à jour."
    fi

    # pip venv scientifique
    if [[ -x "$HOME/venvs/sci/bin/pip" ]]; then
        log "Mise à jour du venv scientifique..."
        "$HOME/venvs/sci/bin/pip" install -q --upgrade \
            numpy scipy pandas matplotlib seaborn plotly sympy \
            scikit-learn statsmodels numba \
            jupyter jupyterlab notebook ipykernel \
            reportlab edge-tts pydub openpyxl xlsxwriter \
            requests beautifulsoup4 lxml tqdm 2>/dev/null || true
        ok "Venv scientifique à jour."
    fi

    # apt
    log "Mise à jour des paquets système (apt upgrade)..."
    sudo apt update -y -qq >/dev/null 2>&1 || true
    sudo apt upgrade -y -qq >/dev/null 2>&1 || true
    ok "Système à jour."

    # tlmgr (TeX Live)
    if command -v tlmgr >/dev/null 2>&1; then
        log "Mise à jour TeX Live..."
        sudo tlmgr update --self --all >/dev/null 2>&1 || warn "Échec mise à jour TeX Live (pas bloquant)."
        ok "TeX Live à jour."
    fi

    mark_done "update"
    ok "Mise à jour terminée."
}

###############################################################################
# POINT D'ENTRÉE
###############################################################################
GUI_MODULES=(browser-pdf office dash-to-panel desktop-ai gnome-shortcuts)

main() {
    local args=("$@")
    local do_retry=0

    for a in "${args[@]}"; do
        [[ "$a" == "--force" ]] && FORCE=1
        [[ "$a" == "--retry-failed" ]] && do_retry=1
        [[ "$a" == "--headless" ]] && HEADLESS=1
        [[ "$a" == "--yes" || "$a" == "-y" ]] && ASSUME_YES=1
        # --all est par nature non surveillé : on force le mode non interactif.
        [[ "$a" == "--all" ]] && ASSUME_YES=1
    done

    preflight

    if [[ "$do_retry" -eq 1 ]]; then
        retry_failed
    elif [[ ${#args[@]} -eq 0 ]]; then
        show_menu
    elif [[ " ${args[*]} " == *" --all "* ]]; then
        for m in "${ALL_MODULES[@]}"; do
            if [[ "$HEADLESS" -eq 1 ]] && [[ " ${GUI_MODULES[*]} " == *" $m "* ]]; then
                log "Mode headless — module '$m' ignoré (GUI)."
                continue
            fi
            run_module "$m"
        done
    elif [[ " ${args[*]} " == *" --update "* ]]; then
        run_update
    else
        for arg in "${args[@]}"; do
            [[ "$arg" == "--force" ]] && continue
            [[ "$arg" == "--headless" ]] && continue
            [[ "$arg" == "--yes" || "$arg" == "-y" ]] && continue
            module="${arg#--}"
            if [[ "$HEADLESS" -eq 1 ]] && [[ " ${GUI_MODULES[*]} " == *" $module "* ]]; then
                log "Mode headless — module '$module' ignoré (GUI)."
                continue
            fi
            run_module "$module"
        done
    fi

    # Sauvegarde des échecs pour un --retry-failed ultérieur
    printf "%s\n" "${FAILED_MODULES[@]}" > "$HOME/.setup_ubuntu_last_failures" 2>/dev/null || true

    echo ""
    if [[ ${#FAILED_MODULES[@]} -eq 0 ]]; then
        ok "Tous les modules lancés se sont terminés avec succès."
    else
        err "Modules en échec : ${FAILED_MODULES[*]}"
        log "Relance uniquement ceux-là avec : ./setup_ubuntu.sh --retry-failed"
    fi
    if [[ ${#FAILED_PACKAGES[@]} -gt 0 ]]; then
        warn "Paquets apt individuels non confirmés : ${FAILED_PACKAGES[*]}"
    fi

    ok "Ouvre un NOUVEAU terminal (ou fais 'source ~/.bashrc') pour que tout soit dans le PATH."
    log "Journal complet : $LOGFILE"
}

main "$@"
