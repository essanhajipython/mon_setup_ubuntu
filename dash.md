# 📋 État Dash to Panel - 06/07/2026

## ✅ Ce qui a été fait

1. **Problème initial** : Dash to Panel était installé mais **cassé** (fichier `extension.js` manquant)
   - L'extension avait été clonée depuis Git (version brute non compilée)
   - GNOME Shell affichait : `Error: Missing extension.js`

2. **Suppression** de l'ancienne installation corrompue :
   - Dossier supprimé : `~/.local/share/gnome-shell/extensions/dash-to-panel@jderose9.github.com/`

3. **Réinstallation propre** depuis extensions.gnome.org :
   - Version installée : **73** (compatible GNOME Shell 50.1)
   - Téléchargé via : `https://extensions.gnome.org/download-extension/dash-to-panel@jderose9.github.com.shell-extension.zip?version_tag=69173`
   - `extension.js` bien présent ✅

4. **Activation** de l'extension :
   - `gnome-extensions enable dash-to-panel@jderose9.github.com` ✅
   - `ubuntu-dock@ubuntu.com` désactivé (incompatible avec Dash to Panel) ✅
   - dconf mis à jour ✅
   - Cache GNOME Shell vidé ✅

---

## 🔄 Étape en cours

**→ Se déconnecter et se reconnecter** pour que GNOME Shell charge la nouvelle extension (obligatoire sous Wayland).

---

## ❌ Si ça ne marche toujours pas après reconnexion

Lancer dans un terminal :
```bash
journalctl /usr/bin/gnome-shell -n 50 --no-pager | grep -i "dash"
```
Et partager le résultat.

---

## 📁 Emplacement de l'extension
```
~/.local/share/gnome-shell/extensions/dash-to-panel@jderose9.github.com/
```

## 🔧 Commandes utiles
```bash
# Vérifier l'état
gnome-extensions info dash-to-panel@jderose9.github.com

# Activer manuellement
gnome-extensions enable dash-to-panel@jderose9.github.com

# Désactiver ubuntu-dock (incompatible)
gnome-extensions disable ubuntu-dock@ubuntu.com

# Vider le cache
rm -rf ~/.cache/gnome-shell/extensions/

# Fermer la session
gnome-session-quit --logout
```
