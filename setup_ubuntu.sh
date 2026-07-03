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
#           --web-mobile --vscode --utils --local-ai --gdrive
#
# Le script est idempotent et reprend là où il s'est arrêté : il garde une
# trace des modules réussis/échoués dans ~/.setup_ubuntu_state
###############################################################################

set -uo pipefail

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

sudo -v || { err "Impossible d'obtenir les droits sudo. Abandon."; exit 1; }
( while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null & )

###############################################################################
# PRÉFLIGHT : réseau, DNS, dpkg cassé — évite 90% des galères déjà vécues
###############################################################################
preflight() {
    log "=== Vérifications préalables (réseau / DNS / dpkg) ==="

    # 1) Réparer un dpkg interrompu AVANT de commencer quoi que ce soit
    if sudo dpkg --configure -a >/dev/null 2>&1; then
        :
    fi
    sudo apt --fix-broken install -y -qq >/dev/null 2>&1 || true

    # 2) Connectivité IP brute
    if ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; then
        ok "Connectivité réseau OK."
    else
        warn "Pas de réponse à 8.8.8.8. Vérifie ton câble/WiFi avant de continuer."
        read -rp "Continuer quand même ? (o/N) : " REPLY
        [[ "$REPLY" =~ ^[Oo]$ ]] || exit 1
    fi

    # 3) Résolution DNS — la panne qu'on a eue la dernière fois
    if getent hosts github.com >/dev/null 2>&1; then
        ok "Résolution DNS OK."
    else
        warn "Le DNS ne répond pas (github.com introuvable). Tentative de correction automatique..."
        IFACE=$(ip route | awk '/default/ {print $5; exit}')
        if [[ -n "${IFACE:-}" ]] && command -v resolvectl >/dev/null 2>&1; then
            sudo resolvectl dns "$IFACE" 8.8.8.8 1.1.1.1 >/dev/null 2>&1 || true
            sudo resolvectl flush-caches >/dev/null 2>&1 || true
        fi
        sleep 2
        if getent hosts github.com >/dev/null 2>&1; then
            ok "DNS réparé (bascule sur 8.8.8.8 / 1.1.1.1)."
        else
            warn "DNS toujours en échec. Le script va continuer mais certaines étapes vont probablement échouer."
            warn "Essaie de changer de réseau ou de régler le DNS manuellement, puis relance avec --retry-failed."
        fi
    fi

    ok "Préflight terminé."
}

# ------------------------------- Téléchargement avec retry -------------------
# download_retry <url> <destination> [tentatives=3]
download_retry() {
    local url="$1" dest="$2" tries="${3:-3}" attempt=1
    while (( attempt <= tries )); do
        if wget -q --timeout=20 -O "$dest" "$url"; then
            # Vérifie que le fichier n'est pas vide/corrompu (taille > 1 Ko)
            if [[ -s "$dest" ]] && [[ $(stat -c%s "$dest" 2>/dev/null || echo 0) -gt 1024 ]]; then
                return 0
            fi
        fi
        warn "  Tentative $attempt/$tries échouée pour $url, nouvel essai..."
        rm -f "$dest"
        sleep 2
        ((attempt++))
    done
    return 1
}

curl_retry() {
    local url="$1" tries="${2:-3}" attempt=1
    while (( attempt <= tries )); do
        if curl -fsSL --connect-timeout 15 "$url"; then
            return 0
        fi
        warn "  Tentative $attempt/$tries échouée pour $url..."
        sleep 2
        ((attempt++))
    done
    return 1
}

APT_UPDATED=0
apt_update_once() {
    if [[ "$APT_UPDATED" -eq 0 ]]; then
        log "Mise à jour des dépôts apt..."
        sudo apt update -y -qq || warn "apt update a rencontré des erreurs (certains dépôts sont peut-être injoignables)."
        APT_UPDATED=1
    fi
}

# apt_install <paquet1> <paquet2> ... — installe ET vérifie réellement chaque paquet
apt_install() {
    apt_update_once
    sudo DEBIAN_FRONTEND=noninteractive apt install -y -qq "$@" >/dev/null 2>&1

    local pkg missing=()
    for pkg in "$@"; do
        # certains paquets n'ont pas d'entrée dpkg avec exactement ce nom (ex: métapaquets) -> on vérifie large
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        warn "Paquets non confirmés installés : ${missing[*]}"
        FAILED_PACKAGES+=("${missing[@]}")
        return 1
    fi
    return 0
}

###############################################################################
# 0. PRÉREQUIS DE BASE
###############################################################################
install_prereqs() {
    log "=== Prérequis système ==="
    if apt_install curl wget git git-lfs ca-certificates gnupg lsb-release \
        software-properties-common apt-transport-https build-essential \
        unzip zip p7zip-full; then
        ok "Prérequis installés."
        mark_done "prereqs"
    else
        warn "Certains prérequis ont échoué (voir ci-dessus)."
        FAILED_MODULES+=("prereqs")
    fi
}

###############################################################################
# 1. OUTILS IA : Claude Code, OpenCode, Antigravity CLI
###############################################################################
install_ai_clis() {
    log "=== Claude Code, OpenCode, Antigravity CLI ==="
    local module_ok=1

    if command -v claude >/dev/null 2>&1; then
        ok "Claude Code déjà installé ($(claude --version 2>/dev/null))."
    else
        log "Installation de Claude Code..."
        if curl_retry "https://claude.ai/install.sh" | bash >/dev/null 2>&1; then
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
        if curl_retry "https://opencode.ai/install" | bash >/dev/null 2>&1; then
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
        if curl_retry "https://antigravity.google/cli/install.sh" | bash >/dev/null 2>&1; then
            command -v agy >/dev/null 2>&1 && ok "Antigravity CLI installé." || { warn "Antigravity CLI : script exécuté mais binaire introuvable."; module_ok=0; }
        else
            warn "Échec install Antigravity CLI (serveur Google parfois indisponible temporairement)."
            module_ok=0
        fi
    fi

    if ! grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
    fi
    export PATH="$HOME/.local/bin:$PATH"

    if [[ "$module_ok" -eq 1 ]]; then
        mark_done "ai"
        warn "Pense à lancer 'claude', 'opencode' et 'agy' une première fois pour t'authentifier."
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

    apt_install texlive-full latexmk biber python3-pygments \
        fonts-noto fonts-noto-color-emoji fonts-noto-cjk \
        fonts-texgyre fonts-freefont-ttf texlive-lang-arabic texlive-lang-french \
        || module_ok=0

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
        curl_retry "https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh" | bash >/dev/null 2>&1
    fi
    export NVM_DIR="$HOME/.nvm"
    # shellcheck disable=SC1091
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    if command -v nvm >/dev/null 2>&1; then
        nvm install --lts >/dev/null 2>&1
        nvm use --lts >/dev/null 2>&1
        npm install -g pnpm yarn >/dev/null 2>&1
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

    # Mobile : Flutter (snap peut échouer si problème réseau IPv6 -> pas fatal)
    if command -v flutter >/dev/null 2>&1 || snap list 2>/dev/null | grep -q flutter; then
        ok "Flutter déjà installé."
    else
        log "Installation de Flutter (snap)..."
        sudo snap install flutter --classic >/dev/null 2>&1 || warn "Échec install Flutter via snap (réessaie plus tard : sudo snap install flutter --classic)."
    fi

    if snap list 2>/dev/null | grep -q android-studio; then
        ok "Android Studio déjà installé."
    else
        log "Installation d'Android Studio (snap)..."
        sudo snap install android-studio --classic >/dev/null 2>&1 || warn "Échec install Android Studio via snap."
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
        if curl_retry "https://ollama.com/install.sh" | sh >/dev/null 2>&1 && command -v ollama >/dev/null 2>&1; then
            ok "Ollama installé."
            mark_done "local-ai"
        else
            warn "Échec install Ollama."
            FAILED_MODULES+=("local-ai")
        fi
    fi
}

###############################################################################
# 10. GOOGLE DRIVE (rclone + systemd mount)
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

    if [[ "$module_ok" -eq 1 ]]; then
        mark_done "gdrive"
        warn "Pense à lancer 'rclone config' si ce n'est pas déjà fait pour authentifier le compte 'gdrive'."
    else
        FAILED_MODULES+=("gdrive")
    fi
}

###############################################################################
# MENU / DISPATCH
###############################################################################
ALL_MODULES=(prereqs ai browser-pdf office latex python web-mobile vscode utils local-ai gdrive)

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
        gdrive)       install_gdrive ;;
        *) warn "Module inconnu : $m" ;;
    esac
}

show_menu() {
    echo ""
    echo "======================================================================"
    echo "   Configuration de ton environnement Ubuntu — choisis les modules"
    echo "======================================================================"
    echo "  1) Prérequis système       6) Python scientifique"
    echo "  2) IA CLI (Claude/OC/agy)  7) Dev Web + Mobile"
    echo "  3) Chrome + lecteurs PDF   8) VS Code + extensions"
    echo "  4) Suite bureautique       9) Utilitaires"
    echo "  5) LaTeX complet          10) IA locale (Ollama)"
    echo "                            11) Google Drive (rclone)"
    echo "  A) TOUT installer          R) Relancer seulement les échecs précédents"
    echo "  Q) Quitter"
    echo "======================================================================"
    read -rp "Ton choix (ex: 1 3 5 ou A) : " -a CHOICES

    for c in "${CHOICES[@]}"; do
        case "$c" in
            1) run_module prereqs ;;      2) run_module ai ;;
            3) run_module browser-pdf ;;  4) run_module office ;;
            5) run_module latex ;;        6) run_module python ;;
            7) run_module web-mobile ;;   8) run_module vscode ;;
            9) run_module utils ;;        10) run_module local-ai ;;
            11) run_module gdrive ;;
            [Aa]) for m in "${ALL_MODULES[@]}"; do run_module "$m"; done ;;
            [Rr]) retry_failed ;;
            [Qq]) log "À bientôt !"; exit 0 ;;
            *) warn "Choix ignoré : $c" ;;
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
# POINT D'ENTRÉE
###############################################################################
main() {
    local args=("$@")
    local do_retry=0

    for a in "${args[@]}"; do
        [[ "$a" == "--force" ]] && FORCE=1
        [[ "$a" == "--retry-failed" ]] && do_retry=1
    done

    preflight

    if [[ "$do_retry" -eq 1 ]]; then
        retry_failed
    elif [[ ${#args[@]} -eq 0 ]]; then
        show_menu
    elif [[ " ${args[*]} " == *" --all "* ]]; then
        for m in "${ALL_MODULES[@]}"; do run_module "$m"; done
    else
        for arg in "${args[@]}"; do
            [[ "$arg" == "--force" ]] && continue
            module="${arg#--}"
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
