# AGENTS.md — Contexte pour un agent IA (Claude Code, OpenCode, agy...)

Ce fichier sert à donner rapidement le contexte à un agent IA lancé dans ce
dépôt (`claude`, `opencode`, `agy`) pour diagnostiquer ou corriger une panne
du script `setup_ubuntu.sh`, sans avoir à tout réexpliquer à chaque fois.

## Ce que fait ce projet

Un unique script bash (`setup_ubuntu.sh`) qui installe l'environnement de
travail complet du propriétaire sur une machine Ubuntu fraîchement
installée (souvent en dual-boot avec Windows) : outils IA en CLI (Claude
Code, OpenCode, Antigravity CLI), LaTeX complet (XeLaTeX/LuaLaTeX/minted),
Python scientifique, dev Web/Mobile (Node, Flutter), bureautique, VS Code,
utilitaires système.

Public visé : un seul utilisateur (le propriétaire du dépôt), pas un outil
distribué à des tiers. Pas de secrets, pas de clé API dans ce dépôt.

## Structure

- `setup_ubuntu.sh` — le script complet, un seul fichier.
- `README.md` — usage et historique des pannes déjà corrigées.
- `AGENTS.md` — ce fichier.

Pas de sous-dossiers, pas de dépendances externes autres que celles que le
script installe lui-même via `apt`, `curl`/`wget`, `pip`, `npm`, `snap`.

## Architecture interne du script (important avant de modifier)

- `set -uo pipefail` (pas `-e` volontairement) : les erreurs sont gérées
  manuellement pour pouvoir continuer sur les autres modules même si un
  module échoue.
- **Logging** : toute la sortie est dupliquée dans
  `~/setup_ubuntu_AAAAMMJJ_HHMMSS.log` via `tee`.
- **État persistant** :
  - `~/.setup_ubuntu_state` : liste des modules marqués réussis (un par
    ligne). Un module déjà présent est sauté sauf avec `--force`.
  - `~/.setup_ubuntu_last_failures` : modules en échec de la dernière
    exécution, utilisé par `--retry-failed`.
- **Fonctions utilitaires clés** :
  - `apt_install()` : installe puis vérifie RÉELLEMENT chaque paquet avec
    `dpkg -s`. Alimente le tableau `FAILED_PACKAGES`. Ne jamais faire
    confiance au seul code de sortie d'`apt` — c'est la cause de la
    principale panne historique (voir README.md).
  - `download_retry()` : wrapper `wget` avec 3 tentatives + vérification de
    taille de fichier (>1 Ko) pour détecter un téléchargement corrompu ou
    tronqué.
  - `curl_retry()` : équivalent pour les installeurs `curl | bash`.
  - `preflight()` : lancé systématiquement en tout début d'exécution —
    répare `dpkg --configure -a`, teste la connectivité (`ping 8.8.8.8`),
    teste et corrige le DNS (`getent hosts github.com`, sinon bascule sur
    8.8.8.8 / 1.1.1.1 via `resolvectl`).
- **Dispatch modulaire** : chaque module est une fonction `install_xxx()`
  appelée par `run_module()` via un `case`. Chaque fonction marque elle-même
  son succès (`mark_done "nom_module"`) ou son échec
  (`FAILED_MODULES+=("nom_module")`) — ne jamais supposer qu'un module a
  réussi juste parce qu'il s'est terminé sans crash.

## Conventions à respecter si tu modifies le script

- **Flags CLI en tirets** (`--browser-pdf`, pas `--browser_pdf`) — norme
  POSIX, décision assumée par le propriétaire malgré sa préférence
  personnelle pour les underscores ailleurs (noms de dossiers/dépôts).
- **Modules GUI** définis dans `GUI_MODULES=(browser-pdf office dash-to-panel)` :
  tout module ajouté qui nécessite un environnement graphique doit y être listé
  pour que le flag `--headless` puisse le filtrer.
- **Variables et fonctions internes en snake_case** (`VENV_DIR`,
  `install_latex()`).
- **Commentaires et messages utilisateur en français.**
- **Jamais de `sudo npm install -g` ni `sudo pip install`** — toujours passer
  par un venv (`~/venvs/sci`) ou npm avec `~/.npm-global` / nvm. C'est une
  règle explicite du propriétaire, ne pas la casser même pour "simplifier".
- **Idempotence obligatoire** : toute nouvelle installation doit d'abord
  vérifier si elle est déjà en place (`command -v`, `dpkg -s`,
  `[[ -d ... ]]`) avant d'agir.
- Avant de livrer une modification : `bash -n setup_ubuntu.sh` au minimum
  (vérification syntaxique). Idéalement `shellcheck` si disponible.

## Pannes déjà rencontrées et corrigées (ne pas régresser dessus)

1. **`dpkg` interrompu** faussait le code de sortie d'`apt install`, le
   script v1 affichait `[ OK ]` alors que rien n'était réellement installé.
   → Corrigé par la vérification post-install réelle dans `apt_install()`
   et la réparation systématique en `preflight()`.
2. **`curl` absent** au tout premier lancement sur une install Ubuntu
   fraîche → tout ce qui dépendait de `curl | bash` (Claude Code, OpenCode,
   Antigravity CLI, nvm, VS Code) échouait silencieusement.
   → `curl` fait partie des tout premiers paquets installés et vérifiés.
3. **Panne DNS temporaire** (résolution de noms KO alors que le ping IP brut
   fonctionnait) → bloquait `packages.microsoft.com`, `snapcraft.io`, etc.
   → Détectée et corrigée automatiquement en `preflight()`.
4. **Dépôt apt VS Code parfois indisponible** ("Aucun paquet apt code") →
   chaîne de secours à 3 niveaux dans `install_vscode()` : dépôt apt → `.deb`
   officiel (`code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64`)
   → snap (`--classic`).
5. **`fonts-amiri` absent** des dépôts sur Ubuntu 26.04 "Resolute" → plusieurs
   noms de paquets candidats testés, sinon récupération directe du `.ttf`
   depuis le dépôt Google Fonts sur GitHub.
6. **`python3.14-venv` requis en plus de `python3-venv`** sur les versions
   Python très récentes (le paquet générique ne suffit pas toujours) →
   les deux sont tentés dans `install_python_sci()`.
7. **Snap injoignable en IPv6** (`network is unreachable`) sur certaines
   connexions → pas de correction automatique dans le script (dépend du
   réseau), mais `install_vscode()` a un fallback `.deb` qui contourne le
   problème dans la majorité des cas.
8. **`latexminted` 0.6.0 incompatible avec Python ≥3.14** (Ubuntu 26.04) : le
   wheel fourni par TeX Live 2025 plante avec
   `TypeError: ArgParser.__init__() got an unexpected keyword argument 'color'`
   à cause d'un changement dans l'API `argparse` de Python 3.14. Le symptôme
   est que `minted` ne colore pas le code (pas d'erreur fatale, juste
   `Cannot highlight code` silencieux). → **Corrigé** dans `install_latex()`
   par : (a) tentative d'install via `pipx install latexminted` (version 0.7.1
   compatible), (b) si échec, patch direct du wheel système avec `**kwargs`.
   Vérifier avec `latexminted config --help` après installation.

9. **Panne DNS PENDANT les téléchargements** (le préflight passe, puis la
   résolution retombe en panne en plein `curl | bash`) → a fait échouer les 3
   CLI IA (`curl: (28) Resolving timed out`). → **Corrigé** : `curl_retry()` et
   `download_retry()` appellent `repair_dns()` (bascule 8.8.8.8/1.1.1.1 via
   `resolvectl`, sinon écriture directe de `/etc/resolv.conf`) entre chaque
   tentative, avec backoff progressif.
10. **`p7zip-full` renommé `7zip` sur Ubuntu 26.04** → `dpkg -s p7zip-full`
    échouait et marquait tout le module *prereqs* en échec. → **Corrigé** :
    `apt_install_firstof "7z" 7zip p7zip-full` (essaie le 1er candidat dispo,
    vérifie par la commande `7z`). Distinction paquets critiques/optionnels.
11. **OpenCode s'installe dans `~/.opencode/bin`, pas `~/.local/bin`** → le
    `command -v opencode` juste après install échouait (faux négatif). →
    **Corrigé** : on ajoute `~/.opencode/bin` au PATH avant de vérifier.
12. **Installeurs `curl | bash` qui traînent/pendent** (serveur lent, réseau) →
    pouvaient bloquer le script longtemps. → **Corrigé** : helper `run_installer()`
    avec `timeout 480` (dur) + `curl --max-time 120`. Snap Flutter/Android Studio
    bornés par `timeout` aussi.
13. **texlive-full paraît figé** (plusieurs Go, sortie masquée) → **Corrigé** :
    `with_heartbeat()` affiche un point toutes les 20 s pendant les commandes
    longues.
14. **Questions apt bloquantes** (needrestart, conflits de conf) en exécution non
    surveillée → **Corrigé** : env global `DEBIAN_FRONTEND=noninteractive`,
    `NEEDRESTART_MODE=a`, options dpkg `--force-confdef --force-confold`, flag
    `--yes`/`-y` (impliqué par `--all`) et auto-détection stdin non-tty.

## Ordre des modules (volontaire)

`ALL_MODULES` est ordonné pour installer d'abord les outils importants ET rapides
(prereqs, ai, python, utils, vscode) puis les gros téléchargements (office,
web-mobile avec Android Studio, et enfin texlive-full qui est le plus lourd).
Ne pas remettre `latex`/`office` en tête sans raison.

## Comment diagnostiquer une nouvelle panne

1. Lire le dernier log : `ls -t ~/setup_ubuntu_*.log | head -1`
2. Vérifier l'état : `cat ~/.setup_ubuntu_state` et
   `cat ~/.setup_ubuntu_last_failures`
3. Isoler le module en cause et le relancer seul en verbeux, par exemple :
   `bash -x setup_ubuntu.sh --latex 2>&1 | tee /tmp/debug.log`
4. Vérifier si c'est un problème réseau/DNS avant tout (cause la plus
   fréquente historiquement) :
   `ping -c1 8.8.8.8` puis `getent hosts github.com`
5. Chercher si le nom d'un paquet a changé selon la version d'Ubuntu :
   `apt-cache search <mot-clé>` ou `apt list --all-versions <paquet> 2>/dev/null`

## Ce qu'il NE FAUT PAS faire

- Ne pas ajouter `set -e` global (casserait la logique de continuation
  multi-modules volontaire).
- Ne pas supprimer les vérifications post-install pour "simplifier" — c'est
  la correction du bug principal historique.
- Ne pas committer de clé API, token, ou identifiant personnel dans ce
  dépôt, même temporairement.
- Ne pas changer les flags CLI en underscore (voir Conventions ci-dessus).
