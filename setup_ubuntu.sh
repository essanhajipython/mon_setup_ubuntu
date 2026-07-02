#!/usr/bin/env bash
###############################################################################
# setup_ubuntu.sh
# Script d'installation "tout-en-un" pour retrouver rapidement ton
# environnement de travail sur Ubuntu (dual-boot avec Windows).
#
# Usage :
#   chmod +x setup_ubuntu.sh
#   ./setup_ubuntu.sh            -> menu interactif
#   ./setup_ubuntu.sh --all      -> installe TOUT sans poser de questions
#   ./setup_ubuntu.sh --ai --latex --python   -> installe seulement ces modules
#
# Modules disponibles (utilisables aussi en argument) :
#   --prereqs   --ai   --browser-pdf   --office   --latex
#   --python    --web-mobile   --vscode   --utils   --local-ai
#
# Le script est idempotent : tu peux le relancer plusieurs fois sans risque,
# il saute ce qui est déjà installé.
###############################################################################

set -uo pipefail

# ----------------------------- Couleurs / logs ------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[FAIL]${NC} $*"; }

LOGFILE="$HOME/setup_ubuntu_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1
log "Journal complet de cette exécution : $LOGFILE"

# ----------------------------- Vérifications ---------------------------------
if [[ "$EUID" -eq 0 ]]; then
    err "Ne lance pas ce script avec sudo/root directement. Lance-le en utilisateur normal ;"
    err "il demandera sudo lui-même quand nécessaire."
    exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
    err "Ce script est conçu pour Ubuntu/Debian (apt introuvable). Abandon."
    exit 1
fi

# On garde le sudo "chaud" pendant toute l'exécution
sudo -v
( while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null & )

APT_UPDATED=0
apt_update_once() {
    if [[ "$APT_UPDATED" -eq 0 ]]; then
        log "Mise à jour des dépôts apt..."
        sudo apt update -y
        APT_UPDATED=1
    fi
}

apt_install() {
    apt_update_once
    sudo DEBIAN_FRONTEND=noninteractive apt install -y "$@"
}

###############################################################################
# 0. PRÉREQUIS DE BASE
###############################################################################
install_prereqs() {
    log "=== Prérequis système ==="
    apt_install curl wget git git-lfs ca-certificates gnupg lsb-release \
        software-properties-common apt-transport-https build-essential \
        unzip zip p7zip-full
    ok "Prérequis installés."
}

###############################################################################
# 1. OUTILS IA EN LIGNE DE COMMANDE : Claude Code, OpenCode, Antigravity CLI
###############################################################################
install_ai_clis() {
    log "=== Claude Code, OpenCode, Antigravity CLI ==="

    # --- Claude Code (installeur natif officiel, pas besoin de Node) ---
    if command -v claude >/dev/null 2>&1; then
        ok "Claude Code déjà installé ($(claude --version 2>/dev/null))."
    else
        log "Installation de Claude Code..."
        if curl -fsSL https://claude.ai/install.sh | bash; then
            ok "Claude Code installé."
        else
            warn "Échec install Claude Code. Réessaie plus tard avec : curl -fsSL https://claude.ai/install.sh | bash"
        fi
    fi

    # --- OpenCode ---
    if command -v opencode >/dev/null 2>&1; then
        ok "OpenCode déjà installé ($(opencode --version 2>/dev/null))."
    else
        log "Installation d'OpenCode..."
        if curl -fsSL https://opencode.ai/install | bash; then
            ok "OpenCode installé."
        else
            warn "Échec install OpenCode. Réessaie avec : curl -fsSL https://opencode.ai/install | bash"
        fi
    fi

    # --- Antigravity CLI (agy) ---
    if command -v agy >/dev/null 2>&1; then
        ok "Antigravity CLI déjà installé ($(agy --version 2>/dev/null))."
    else
        log "Installation d'Antigravity CLI (agy)..."
        if curl -fsSL https://antigravity.google/cli/install.sh | bash; then
            ok "Antigravity CLI installé."
        else
            warn "Échec install Antigravity CLI. Réessaie avec : curl -fsSL https://antigravity.google/cli/install.sh | bash"
        fi
    fi

    # S'assurer que ~/.local/bin est dans le PATH (tous ces installeurs y placent leur binaire)
    if ! grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
        log "PATH mis à jour dans ~/.bashrc (~/.local/bin ajouté)."
    fi
    export PATH="$HOME/.local/bin:$PATH"

    warn "Pense à lancer 'claude', 'opencode' et 'agy' une première fois pour t'authentifier (navigateur)."
}

###############################################################################
# 2. CHROME + LECTEURS PDF (rapide + puissant/annotation)
###############################################################################
install_browser_pdf() {
    log "=== Google Chrome + lecteurs PDF ==="

    # --- Google Chrome ---
    if command -v google-chrome >/dev/null 2>&1; then
        ok "Google Chrome déjà installé."
    else
        log "Installation de Google Chrome..."
        TMP_DEB=$(mktemp --suffix=.deb)
        if wget -q -O "$TMP_DEB" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb; then
            sudo apt install -y "$TMP_DEB"
            rm -f "$TMP_DEB"
            ok "Google Chrome installé."
        else
            warn "Téléchargement de Chrome échoué."
        fi
    fi

    # --- Lecteur PDF rapide et léger : Evince (par défaut GNOME, très rapide) ---
    apt_install evince
    ok "Evince (lecture rapide) installé."

    # --- Lecteur PDF puissant avec annotation : Xournal++ (annotation/manuscrit)
    #     + Okular (KDE, très complet : formulaires, surlignage, signatures)
    apt_install xournalpp okular
    ok "Xournal++ et Okular (annotation avancée) installés."

    log "Astuce : Xournal++ = annoter/écrire à la main sur un PDF (idéal cours/corrections)."
    log "         Okular    = le plus complet (formulaires, surlignage, révisions, synctex LaTeX)."
}

###############################################################################
# 3. LECTEURS WORD / EXCEL / PPT
###############################################################################
install_office_readers() {
    log "=== Suite bureautique (Word / Excel / PowerPoint) ==="
    apt_install libreoffice libreoffice-l10n-fr

    # OnlyOffice : bien meilleure fidélité de mise en forme avec les fichiers
    # .docx / .xlsx / .pptx que LibreOffice (utile si tu échanges avec Word/Office).
    if command -v onlyoffice-desktopeditors >/dev/null 2>&1; then
        ok "OnlyOffice déjà installé."
    else
        log "Installation d'OnlyOffice Desktop Editors (compatibilité Word/Excel/PPT)..."
        TMP_DEB=$(mktemp --suffix=.deb)
        if wget -q -O "$TMP_DEB" "https://download.onlyoffice.com/install/desktop/editors/linux/onlyoffice-desktopeditors_amd64.deb"; then
            sudo apt install -y "$TMP_DEB" || sudo apt --fix-broken install -y
            rm -f "$TMP_DEB"
            ok "OnlyOffice installé."
        else
            warn "Téléchargement OnlyOffice échoué (pas bloquant, LibreOffice suffit)."
        fi
    fi
}

###############################################################################
# 4. LATEX POUSSÉ (XeLaTeX, LuaLaTeX, minted, polices avancées, arabe)
###############################################################################
install_latex() {
    log "=== LaTeX complet (XeLaTeX / LuaLaTeX / minted / polices) ==="
    warn "texlive-full pèse plusieurs Go, ça peut prendre du temps..."

    apt_install texlive-full latexmk biber python3-pygments \
        fonts-noto fonts-noto-color-emoji fonts-noto-cjk \
        fonts-texgyre fonts-freefont-ttf

    # Polices arabes de qualité (Amiri, utilisées dans tes docs pédagogie/habitudes)
    apt_install fonts-amiri texlive-lang-arabic texlive-lang-french

    # Police Cairo (Google Fonts) — pas toujours dans les dépôts, on la récupère si besoin
    if ! fc-list | grep -qi "Cairo"; then
        log "Installation de la police Cairo (Google Fonts)..."
        FONT_DIR="$HOME/.local/share/fonts/cairo"
        mkdir -p "$FONT_DIR"
        TMP_ZIP=$(mktemp --suffix=.zip)
        if wget -q -O "$TMP_ZIP" "https://github.com/google/fonts/raw/main/ofl/cairo/Cairo%5Bslnt%2Cwght%5D.ttf" 2>/dev/null; then
            mv "$TMP_ZIP" "$FONT_DIR/Cairo.ttf" 2>/dev/null
        fi
        # Libertinus (souvent utilisée dans ton style LaTeX)
        apt_install fonts-libertinus 2>/dev/null || warn "fonts-libertinus indisponible dans les dépôts, à installer manuellement si besoin."
        fc-cache -f "$FONT_DIR" >/dev/null 2>&1
    fi

    # Activer -shell-escape (nécessaire pour minted) de façon pratique via un alias
    if ! grep -q "alias xelatex-se=" "$HOME/.bashrc" 2>/dev/null; then
        cat >> "$HOME/.bashrc" <<'EOF'

# --- Alias LaTeX avec shell-escape (nécessaire pour le package minted) ---
alias xelatex-se='xelatex -shell-escape -interaction=nonstopmode'
alias lualatex-se='lualatex -shell-escape -interaction=nonstopmode'
alias latexmk-se='latexmk -pdf -xelatex -shell-escape'
EOF
        log "Alias xelatex-se / lualatex-se / latexmk-se ajoutés à ~/.bashrc (pour minted)."
    fi

    ok "LaTeX complet installé (XeLaTeX, LuaLaTeX, minted, polices Amiri/Cairo/TeX Gyre/Libertinus)."
}

###############################################################################
# 5. PYTHON SCIENTIFIQUE
###############################################################################
install_python_sci() {
    log "=== Python scientifique ==="
    apt_install python3 python3-pip python3-venv python3-full pipx

    pipx ensurepath >/dev/null 2>&1 || true

    VENV_DIR="$HOME/venvs/sci"
    if [[ -d "$VENV_DIR" ]]; then
        ok "Environnement virtuel scientifique déjà présent : $VENV_DIR"
    else
        log "Création de l'environnement virtuel Python scientifique : $VENV_DIR"
        python3 -m venv "$VENV_DIR"
    fi

    log "Installation des paquets scientifiques dans $VENV_DIR..."
    "$VENV_DIR/bin/pip" install --upgrade pip wheel setuptools
    "$VENV_DIR/bin/pip" install \
        numpy scipy pandas matplotlib seaborn plotly sympy \
        scikit-learn statsmodels numba \
        jupyter jupyterlab notebook ipykernel \
        reportlab edge-tts pydub openpyxl xlsxwriter \
        requests beautifulsoup4 lxml tqdm

    "$VENV_DIR/bin/python" -m ipykernel install --user --name=sci --display-name "Python (sci)" >/dev/null 2>&1

    if ! grep -q "alias sci-activate=" "$HOME/.bashrc" 2>/dev/null; then
        echo "alias sci-activate='source $VENV_DIR/bin/activate'" >> "$HOME/.bashrc"
        log "Alias 'sci-activate' ajouté à ~/.bashrc pour activer rapidement ton venv scientifique."
    fi

    ok "Python scientifique prêt. Active-le avec : source ~/.bashrc && sci-activate"
}

###############################################################################
# 6. DÉVELOPPEMENT WEB + MOBILE
###############################################################################
install_web_mobile() {
    log "=== Développement Web & Mobile ==="

    # --- Node.js via nvm (gestion propre des versions) ---
    if [[ -d "$HOME/.nvm" ]]; then
        ok "nvm déjà installé."
    else
        log "Installation de nvm (Node Version Manager)..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    fi
    export NVM_DIR="$HOME/.nvm"
    # shellcheck disable=SC1091
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    if command -v nvm >/dev/null 2>&1; then
        nvm install --lts
        nvm use --lts
        npm install -g pnpm yarn
        ok "Node.js LTS + npm/pnpm/yarn installés."
    else
        warn "nvm non chargé dans cette session ; relance un nouveau terminal puis 'nvm install --lts'."
    fi

    # --- Outils web utiles ---
    apt_install nginx-light --no-install-recommends || true
    sudo systemctl disable nginx-light >/dev/null 2>&1 || true  # installé pour test local, pas lancé par défaut

    # --- Mobile : Flutter (le plus simple pour démarrer en multiplateforme) ---
    if command -v flutter >/dev/null 2>&1 || snap list 2>/dev/null | grep -q flutter; then
        ok "Flutter déjà installé."
    else
        log "Installation de Flutter (snap)..."
        sudo snap install flutter --classic || warn "Échec install Flutter via snap."
    fi

    # --- Android Studio (nécessaire pour l'émulateur / build Android) ---
    if snap list 2>/dev/null | grep -q android-studio; then
        ok "Android Studio déjà installé."
    else
        log "Installation d'Android Studio (snap)..."
        sudo snap install android-studio --classic || warn "Échec install Android Studio via snap."
    fi

    apt_install openjdk-17-jdk

    log "Pour React Native/Expo (alternative plus légère à Flutter) : npm install -g expo-cli"
    ok "Environnement web + mobile prêt (Flutter/Android Studio pour commencer le mobile)."
}

###############################################################################
# 7. VSCODE + EXTENSIONS UTILES (LaTeX, Python, Markdown)
###############################################################################
install_vscode() {
    log "=== Visual Studio Code ==="

    if command -v code >/dev/null 2>&1; then
        ok "VS Code déjà installé."
    else
        log "Installation de VS Code (dépôt officiel Microsoft)..."
        sudo install -d -m 0755 /etc/apt/keyrings
        curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
            sudo gpg --dearmor -o /etc/apt/keyrings/packages.microsoft.gpg
        echo "deb [arch=amd64,arm64 signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | \
            sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
        apt_update_once
        apt_install code
        ok "VS Code installé."
    fi

    if command -v code >/dev/null 2>&1; then
        log "Installation des extensions VS Code (Python, LaTeX, Markdown, Git...)..."
        EXTENSIONS=(
            ms-python.python
            ms-python.vscode-pylance
            ms-toolsai.jupyter
            James-Yu.latex-workshop
            yzhang.markdown-all-in-one
            DavidAnson.vscode-markdownlint
            esbenp.prettier-vscode
            dbaeumer.vscode-eslint
            eamodio.gitlens
            redhat.vscode-yaml
            tamasfe.even-better-toml
            ms-azuretools.vscode-docker
            christian-kohler.path-intellisense
            mechatroner.rainbow-csv
        )
        for ext in "${EXTENSIONS[@]}"; do
            code --install-extension "$ext" --force >/dev/null 2>&1 && ok "  - $ext" || warn "  - $ext (échec)"
        done
    fi

    ok "VS Code prêt avec les extensions Python / LaTeX / Markdown."
}

###############################################################################
# 8. UTILITAIRES DIVERS (confort quotidien)
###############################################################################
install_utils() {
    log "=== Utilitaires divers ==="
    apt_install htop neofetch tmux ripgrep fzf jq tree gparted timeshift \
        flameshot gimp vlc synaptic ufw curl wget

    # eza (remplaçant moderne de ls / exa est déprécié)
    if ! command -v eza >/dev/null 2>&1; then
        apt_install eza 2>/dev/null || warn "eza indisponible dans les dépôts par défaut (pas bloquant)."
    fi

    # bat (cat amélioré avec coloration syntaxique)
    apt_install bat 2>/dev/null || true

    ok "Utilitaires installés (htop, tmux, ripgrep, fzf, flameshot, timeshift, gparted, vlc, gimp...)."
    warn "Pense à configurer Timeshift dès maintenant pour sauvegarder ton système (utile en dual-boot)."
}

###############################################################################
# 9. IA LOCALE (Ollama) — mentionné dans tes explorations précédentes
###############################################################################
install_local_ai() {
    log "=== IA locale (Ollama) ==="
    if command -v ollama >/dev/null 2>&1; then
        ok "Ollama déjà installé."
    else
        log "Installation d'Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh
        ok "Ollama installé."
    fi
    log "Exemples : ollama pull qwen2.5vl   |   ollama pull llama3.1"
}

###############################################################################
# MENU / DISPATCH
###############################################################################
ALL_MODULES=(prereqs ai browser-pdf office latex python web-mobile vscode utils local-ai)

run_module() {
    case "$1" in
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
        *) warn "Module inconnu : $1" ;;
    esac
}

show_menu() {
    echo ""
    echo "======================================================================"
    echo "   Configuration de ton environnement Ubuntu — choisis les modules"
    echo "======================================================================"
    echo "  1) Prérequis système (curl, git, build-essential...)"
    echo "  2) IA en CLI : Claude Code, OpenCode, Antigravity CLI"
    echo "  3) Chrome + lecteurs PDF (Evince rapide, Xournal++/Okular annotation)"
    echo "  4) Suite bureautique (LibreOffice + OnlyOffice pour Word/Excel/PPT)"
    echo "  5) LaTeX complet (XeLaTeX, LuaLaTeX, minted, polices Amiri/Cairo...)"
    echo "  6) Python scientifique (NumPy, Pandas, Jupyter, ReportLab, edge-tts...)"
    echo "  7) Dev Web + Mobile (Node.js, pnpm, Flutter, Android Studio)"
    echo "  8) VS Code + extensions (Python, LaTeX Workshop, Markdown)"
    echo "  9) Utilitaires (htop, tmux, fzf, Timeshift, Flameshot, VLC, GIMP...)"
    echo " 10) IA locale (Ollama)"
    echo "  A) TOUT installer"
    echo "  Q) Quitter"
    echo "======================================================================"
    read -rp "Ton choix (ex: 1 3 5 ou A) : " -a CHOICES

    for c in "${CHOICES[@]}"; do
        case "$c" in
            1) run_module prereqs ;;
            2) run_module ai ;;
            3) run_module browser-pdf ;;
            4) run_module office ;;
            5) run_module latex ;;
            6) run_module python ;;
            7) run_module web-mobile ;;
            8) run_module vscode ;;
            9) run_module utils ;;
            10) run_module local-ai ;;
            [Aa]) for m in "${ALL_MODULES[@]}"; do run_module "$m"; done ;;
            [Qq]) log "À bientôt !"; exit 0 ;;
            *) warn "Choix ignoré : $c" ;;
        esac
    done
}

###############################################################################
# POINT D'ENTRÉE
###############################################################################
main() {
    if [[ $# -eq 0 ]]; then
        show_menu
    elif [[ "$1" == "--all" ]]; then
        install_prereqs
        for m in "${ALL_MODULES[@]}"; do
            [[ "$m" == "prereqs" ]] && continue
            run_module "$m"
        done
    else
        install_prereqs
        for arg in "$@"; do
            module="${arg#--}"
            run_module "$module"
        done
    fi

    echo ""
    ok "Terminé. Ouvre un NOUVEAU terminal (ou fais 'source ~/.bashrc') pour que tout soit disponible dans le PATH."
    log "Journal complet : $LOGFILE"
}

main "$@"
