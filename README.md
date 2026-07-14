# mon_setup_ubuntu

Script d'installation automatique de mon environnement de travail complet sur
Ubuntu : outils IA en CLI, LaTeX poussé, Python scientifique, dev Web/Mobile,
bureautique, utilitaires.

## Utilisation rapide (sur un PC neuf, Ubuntu fraîchement installé)

Ce dépôt est **public** et ne contient aucun secret : sur une machine vierge, le
clone se fait **sans aucune authentification** (ni mot de passe, ni token, ni clé
SSH). C'est voulu — c'est le tout premier truc qu'on installe.

```bash
sudo apt update && sudo apt install -y git      # git n'est pas là par défaut
git clone https://github.com/essanhajipython/mon_setup_ubuntu.git
cd mon_setup_ubuntu
chmod +x setup_ubuntu.sh
./setup_ubuntu.sh --all
```

Ouvre un **nouveau terminal** une fois terminé pour que tout soit dans le PATH.

> **Note (auth) :** en HTTPS, GitHub ne demande d'identifiants que pour *pousser*
> ou pour un dépôt privé — et le « mot de passe » attendu n'est PAS celui du site
> mais un *token (PAT)* depuis 2021. Comme ce dépôt est public, le clone n'en a
> pas besoin. Pour **pousser** tes modifs depuis une de tes machines, configure
> SSH une fois :
>
> ```bash
> ssh-keygen -t ed25519 -C "abdelhakessanhaji@gmail.com"   # Entrée à toutes les questions
> cat ~/.ssh/id_ed25519.pub    # -> à coller dans GitHub > Settings > SSH and GPG keys
> git remote set-url origin git@github.com:essanhajipython/mon_setup_ubuntu.git
> ```

## Modules disponibles

| Flag | Contenu |
|---|---|
| `--prereqs` | curl, wget, git, build-essential... |
| `--ai` | CLI IA : Claude Code, OpenCode, Antigravity (agy), **Codex (OpenAI)**, **Grok Build (xAI)**. Le CLI GLM de Z.ai (`chelper`) est installé avec `--web-mobile` (besoin de npm). |
| `--desktop-ai` | **Claude Desktop** (app officielle Anthropic pour Linux, via apt) + **OpenCode Desktop** (beta, .deb officiel opencode.ai) |
| `--browser-pdf` | Chrome, Evince (rapide), Xournal++ / Okular (annotation) |
| `--office` | LibreOffice + OnlyOffice (Word/Excel/PPT) |
| `--latex` | texlive-full, XeLaTeX, LuaLaTeX, minted, polices Amiri/Cairo/TeX Gyre |
| `--python` | venv scientifique `~/venvs/sci` (NumPy, Pandas, Jupyter, ReportLab, edge-tts...) |
| `--web-mobile` | Node.js (nvm), pnpm/yarn, **Z.ai `chelper`** (CLI GLM), Flutter, Android Studio |
| `--vscode` | VS Code + extensions Python/LaTeX/Markdown |
| `--utils` | htop, tmux, ripgrep, fzf, Timeshift, Flameshot, GIMP, VLC |
| `--local-ai` | Ollama |
| `--gdrive` | Google Drive via `rclone` (montage local automatique avec cache systemd) |
| `--docker` | Docker + Docker Compose (via get.docker.com, utilisateur dans le groupe `docker`) |

```bash
./setup_ubuntu.sh                       # menu interactif
./setup_ubuntu.sh --all                 # tout installer
./setup_ubuntu.sh --ai --latex          # modules choisis
./setup_ubuntu.sh --retry-failed        # relance uniquement ce qui a échoué
./setup_ubuntu.sh --force --all         # réinstalle tout, même déjà marqué OK
./setup_ubuntu.sh --headless --all      # tout sauf les modules GUI (Chrome, Office, Dash to Panel)
./setup_ubuntu.sh --update              # met à jour tout l'existant (pipx, npm, pip, apt, TeX Live)
./setup_ubuntu.sh --yes --all           # 100% non interactif (aucune question), idéal "lance et pars"
```

### Installation « lance et pars »

```bash
./setup_ubuntu.sh --all
```

Tu tapes ton mot de passe **une seule fois au tout début**, puis tu peux
laisser la machine finir seule : plus aucune question ne t'est posée
(`--all` active automatiquement le mode non interactif). Les outils IA et de
dev sont installés en premier (rapides), les gros paquets — bureautique,
mobile, puis `texlive-full` (plusieurs Go) — passent en dernier avec un
indicateur de progression pour ne pas paraître figés.

## Comportement

- **Idempotent** : relançable sans risque, saute ce qui est déjà installé.
- **Préflight automatique** : répare `dpkg` cassé, teste la connectivité, corrige
  un DNS en panne (bascule sur 8.8.8.8 / 1.1.1.1) avant de commencer quoi que ce soit.
- **Vérification réelle** : chaque paquet est contrôlé après installation
  (`dpkg -s`, `command -v`), pas de faux "OK".
- **Retry automatique** : chaque téléchargement réessaie 3 fois.
- **État sauvegardé** dans `~/.setup_ubuntu_state` (modules réussis) et
  `~/.setup_ubuntu_last_failures` (modules à relancer).
- **Log complet** à chaque exécution : `~/setup_ubuntu_AAAAMMJJ_HHMMSS.log`.

## Historique / pourquoi ce script existe

Première install (juillet 2026, Ubuntu 26.04 "Resolute Raccoon", ThinkPad X1
Yoga) : plusieurs galères rencontrées et maintenant corrigées dans le script :

- `dpkg` interrompu en plein milieu d'une exécution précédente → faussait le
  code de sortie d'`apt`, le script v1 affichait "OK" alors que rien n'était
  installé. **Corrigé** : vérification réelle post-install + réparation dpkg
  systématique en préflight.
- `curl` absent au tout premier lancement → tout ce qui en dépendait (Claude
  Code, OpenCode, Antigravity CLI, nvm, VS Code) a échoué en silence.
  **Corrigé** : `curl` fait partie des tout premiers prérequis vérifiés.
- Panne DNS temporaire (`Erreur de résolution de nom`) qui a bloqué
  `packages.microsoft.com`, `snapcraft.io`, etc. **Corrigé** : test DNS +
  bascule automatique sur des DNS publics en préflight.
- Dépôt apt VS Code parfois indisponible → **corrigé** avec une chaîne de
  secours à 3 niveaux : dépôt apt → `.deb` officiel → snap.
- `fonts-amiri` absent des dépôts sur Ubuntu 26.04 → **corrigé** avec
  plusieurs noms de paquets candidats + fallback téléchargement direct
  (Google Fonts).
- `python3.14-venv` nécessaire en plus de `python3-venv` sur les versions
  Python très récentes → **corrigé**, les deux sont tentés.
- `latexminted` 0.6.0 (TeX Live 2025) incompatible avec Python ≥3.14 : l'API
  `argparse` a changé, le kwarg `color` n'est plus accepté par `ArgumentParser`,
  ce qui fait échouer silencieusement `minted` (code Python sans couleurs).
  → **Corrigé** : patch du wheel `latexminted` + installation via `pipx` de la
  version 0.7.1 (compatible) dans la fonction `install_latex()`.

Voir `AGENTS.md` dans ce dépôt pour le contexte technique complet destiné à
un agent IA (Claude Code, OpenCode...) en cas de nouvelle panne à corriger.

## Notes personnelles

- Environnement Python scientifique activable avec l'alias `sci-activate`.
- Alias LaTeX avec `-shell-escape` (pour `minted`) : `xelatex-se`,
  `lualatex-se`, `latexmk-se`.
- Après install, penser à configurer Timeshift : `sudo timeshift-launcher`.
