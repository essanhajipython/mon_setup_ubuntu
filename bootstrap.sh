#!/usr/bin/env bash
# Environnement d'Abdelhak sur un Ubuntu neuf, en une commande, une fois connecté à Internet :
#
#   curl -fsSL https://raw.githubusercontent.com/essanhajipython/mon_setup_ubuntu/main/bootstrap.sh | bash
#
# Installe git, récupère ce dépôt dans ~/mon_setup_ubuntu, puis lance ./setup_ubuntu.sh --all : tous les
# programmes, et en dernier le module poste (GitHub, workspace et skills, réglages, projets, Bureau restauré
# depuis Drive, connexions guidées dans le navigateur). Relançable sans risque : ce qui est fait est sauté.
set -euo pipefail
echo "== Environnement d'Abdelhak : git, puis mon_setup_ubuntu"
sudo apt-get update -qq
sudo apt-get install -y -qq git curl
if [[ -d "$HOME/mon_setup_ubuntu/.git" ]]; then
    git -C "$HOME/mon_setup_ubuntu" pull --ff-only
else
    git clone -q https://github.com/essanhajipython/mon_setup_ubuntu.git "$HOME/mon_setup_ubuntu"
fi
cd "$HOME/mon_setup_ubuntu"
# stdin vient de curl : on rend le clavier au script, qui pose des questions (connexions, mot de passe sudo)
exec ./setup_ubuntu.sh --all < /dev/tty
