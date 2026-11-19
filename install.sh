#!/bin/bash
# Nuit Blanche : installation, mise à jour et désinstallation en une commande.
#
#   curl -fsSL https://raw.githubusercontent.com/jeremywtp/nuit-blanche/main/install.sh | bash
#
# Options (après « | bash -s -- ») :
#   --hooks            connecte aussi Claude Code et Codex (sinon : bouton « Connecter » dans le panneau)
#   --version 1.0      installe une version précise (retour en arrière)
#   --reinstall        réinstalle même si la version installée est déjà la dernière
#   --uninstall        retire tout : app, hooks, règle sudoers, watchdog, préférences
#
# Relancer la commande met l'app à jour ; la caféine et les maintiens en cours sont conservés.
# Tout le script est dans des fonctions appelées à la dernière ligne : un téléchargement coupé
# en plein milieu n'exécute rien.

set -euo pipefail

REPO="jeremywtp/nuit-blanche"
APP_NAME="Nuit Blanche.app"
BUNDLE_ID="com.jeremywtp.NuitBlanche"
ASSET="NuitBlanche.zip"
SUPPORT="$HOME/Library/Application Support/NuitBlanche"
CLI="$HOME/.local/bin/nuitblanche"
WATCHDOG_LABEL="com.jeremywtp.NuitBlanche.watchdog"
SUDOERS="/etc/sudoers.d/nuitblanche"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
TMP=""
STAGED=""

if [ -t 1 ]; then
  BOLD=$'\033[1m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RED=$'\033[31m' DIM=$'\033[2m' RESET=$'\033[0m'
else
  BOLD="" GREEN="" YELLOW="" RED="" DIM="" RESET=""
fi
step() { printf '%s›%s %s\n' "$BOLD" "$RESET" "$*"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%s✗ %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }
note() { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }

cleanup() {
  if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
  if [ -n "$STAGED" ]; then rm -rf "$STAGED"; fi
}

usage() {
  cat <<EOF
Nuit Blanche : installation, mise à jour et désinstallation.

  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash -s -- [option]

Options :
  --hooks          connecte aussi Claude Code et Codex
  --version 1.0    installe une version précise
  --reinstall      réinstalle même si la dernière version est déjà là
  --uninstall      retire tout (app, hooks, règle sudoers, watchdog, préférences)

https://github.com/$REPO
EOF
}

preflight() {
  [ "$(uname -s)" = Darwin ] || die "Nuit Blanche est une app macOS."
  [ "$(id -u)" -ne 0 ] || die "À lancer sans sudo : l'app s'installe pour votre compte (le mot de passe est demandé seulement si besoin)."
  local version major
  version=$(sw_vers -productVersion)
  major=${version%%.*}
  [ "$major" -ge 26 ] 2>/dev/null || die "macOS 26 (Tahoe) ou plus récent requis ; ce Mac a macOS $version."
}

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }

# App déjà installée (première trouvée), sinon rien.
installed_app() {
  local path
  for path in "$HOME/Applications/$APP_NAME" "/Applications/$APP_NAME"; do
    if [ -d "$path" ]; then echo "$path"; return 0; fi
  done
  return 1
}

running() { pgrep -xq -U "$(id -u)" NuitBlanche; }

# SIGTERM : l'app mémorise son état (caféine, réglage de veille) et le reprend au lancement suivant.
stop_app() {
  running || return 0
  pkill -TERM -x -U "$(id -u)" NuitBlanche 2>/dev/null || true
  local _
  for _ in $(seq 1 50); do
    running || return 0
    sleep 0.2
  done
  warn "Nuit Blanche ne s'est pas arrêtée d'elle-même : arrêt forcé."
  pkill -KILL -x -U "$(id -u)" NuitBlanche 2>/dev/null || true
  sleep 1
}

fetch() { # url fichier
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 --connect-timeout 15 -o "$2" "$1"
}

# Dernière version publiée, d'après la redirection de /releases/latest (pas d'API GitHub : pas de quota).
# N'affiche rien si aucune version n'est publiée ; échoue si GitHub est injoignable.
latest_tag() {
  local url
  url=$(curl -fsSLI --proto '=https' --retry 3 --connect-timeout 15 -o /dev/null -w '%{url_effective}' \
    "https://github.com/$REPO/releases/latest") || return 1
  case "$url" in
    */releases/tag/*) echo "${url##*/}" ;;
  esac
}

# Profils Claude Code (dossiers ~/.claude* avec projects/) ou Codex présents sur ce Mac.
agents_present() {
  local dir
  for dir in "$HOME"/.claude*; do
    if [ -d "$dir/projects" ]; then return 0; fi
  done
  [ -d "$HOME/.codex" ]
}

connect_hooks() {
  local script="$SUPPORT/bin/install-hooks.py"
  if ! agents_present; then
    warn "Ni Claude Code ni Codex trouvés : hooks non installés (lancez un agent une première fois, puis « Connecter » dans le panneau)."
    return 0
  fi
  if ! xcode-select -p >/dev/null 2>&1; then
    warn "Les outils de ligne de commande d'Apple sont requis pour les hooks : xcode-select --install, puis relancez avec --hooks."
    return 0
  fi
  [ -f "$script" ] || { warn "Installeur de hooks introuvable ($script)."; return 0; }
  step "Connexion de Claude Code et Codex…"
  if /usr/bin/python3 -I "$script" install all | sed 's/^/  /'; then
    ok "Hooks installés. Codex demandera de les valider à son prochain lancement (« Hooks need review »)."
  else
    warn "Certains hooks n'ont pas pu être installés (voir ci-dessus)."
  fi
}

install_app() { # tag forcer hooks
  local tag=$1 force=$2 hooks=$3
  local current="" dest base expected actual new_app version fresh=1

  if current=$(installed_app); then
    dest=$current
    fresh=0
  else
    current=""
    dest="$HOME/Applications/$APP_NAME"
  fi

  if [ -z "$tag" ]; then
    step "Recherche de la dernière version…"
    tag=$(latest_tag) || die "Impossible de joindre GitHub (github.com/$REPO). Vérifiez la connexion."
    [ -n "$tag" ] || die "Aucune version publiée sur github.com/$REPO/releases."
  fi
  case "$tag" in v*) ;; *) tag="v$tag" ;; esac
  version=${tag#v}

  if [ -n "$current" ] && [ "$force" = 0 ] && [ "$(plist_value "$current" CFBundleShortVersionString)" = "$version" ]; then
    ok "Nuit Blanche $version est déjà installée ($current)."
    if ! running; then open -g "$current" && ok "Nuit Blanche est relancée."; fi
    if [ "$hooks" = 1 ]; then connect_hooks; fi
    note "Pour réinstaller quand même : … | bash -s -- --reinstall"
    return 0
  fi

  TMP=$(mktemp -d "${TMPDIR:-/tmp}/nuitblanche.XXXXXX")
  trap cleanup EXIT
  base="https://github.com/$REPO/releases/download/$tag"

  step "Téléchargement de Nuit Blanche $version…"
  fetch "$base/$ASSET" "$TMP/$ASSET" || die "Version $version introuvable ($base/$ASSET)."
  fetch "$base/$ASSET.sha256" "$TMP/$ASSET.sha256" || die "Somme de contrôle introuvable pour la version $version."

  expected=$(awk 'NR == 1 { print $1 }' "$TMP/$ASSET.sha256")
  actual=$(shasum -a 256 "$TMP/$ASSET" | awk '{ print $1 }')
  [ -n "$expected" ] && [ "$expected" = "$actual" ] \
    || die "Somme de contrôle incorrecte : téléchargement corrompu. Rien n'a été modifié."

  ditto -x -k "$TMP/$ASSET" "$TMP/app" || die "Archive illisible. Rien n'a été modifié."
  new_app="$TMP/app/$APP_NAME"
  [ -d "$new_app" ] && [ "$(plist_value "$new_app" CFBundleIdentifier)" = "$BUNDLE_ID" ] \
    || die "Archive inattendue. Rien n'a été modifié."
  codesign --verify --deep --strict "$new_app" 2>/dev/null \
    || die "Signature de l'app invalide. Rien n'a été modifié."
  ok "Archive vérifiée (SHA-256 et signature)."

  # Copie à côté de la destination, puis échange : l'ancienne version reste en place jusqu'au dernier moment.
  if [ -e "$dest" ] && [ ! -w "$dest" ]; then die "$dest n'est pas modifiable par ce compte. Rien n'a été modifié."; fi
  mkdir -p "$(dirname "$dest")" || die "Dossier $(dirname "$dest") impossible à créer."
  STAGED="$(dirname "$dest")/.nuitblanche-update-$$"
  rm -rf "$STAGED"
  ditto "$new_app" "$STAGED" || die "Copie impossible vers $(dirname "$dest"). Rien n'a été modifié."
  # Téléchargée par curl, l'app n'a pas d'attribut de quarantaine ; on s'en assure (Gatekeeper refuserait
  # une app signée sans compte développeur Apple).
  xattr -dr com.apple.quarantine "$STAGED" 2>/dev/null || true

  if [ -n "$current" ]; then step "Mise à jour de $(plist_value "$current" CFBundleShortVersionString) vers $version…"; fi
  stop_app
  rm -rf "$dest" || die "Ancienne version impossible à retirer ($dest). Relancez la commande."
  mv "$STAGED" "$dest" || die "Installation impossible dans $dest. Relancez la commande."
  STAGED=""
  "$LSREGISTER" -f "$dest" >/dev/null 2>&1 || true

  if [ "$fresh" = 1 ]; then
    open "$dest" --args --open main   # premier lancement : le panneau s'ouvre
  else
    open -g "$dest"
  fi
  local _
  for _ in $(seq 1 50); do
    running && [ -x "$CLI" ] && break
    sleep 0.2
  done
  running || die "Nuit Blanche est installée ($dest) mais ne démarre pas. Ouvrez-la depuis le Finder."
  ok "Nuit Blanche $version installée : $dest"

  if [ "$hooks" = 1 ]; then connect_hooks; fi

  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *)
      warn "La commande nuitblanche est dans ~/.local/bin, absent de votre PATH. Pour l'ajouter :"
      note "echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zprofile && exec zsh -l"
      ;;
  esac

  if [ "$fresh" = 1 ]; then
    echo
    echo "${BOLD}Dernières étapes, dans le panneau (lune de la barre des menus) :${RESET}"
    echo "  1. ${BOLD}Capot fermé${RESET} : mot de passe administrateur une fois, pour travailler écran rabattu."
    [ "$hooks" = 1 ] || echo "  2. ${BOLD}Agents IA → Connecter${RESET} : maintien automatique pendant que Claude Code ou Codex travaillent."
    echo
    note "Mise à jour : relancez la même commande. Désinstallation : … | bash -s -- --uninstall"
  fi
}

uninstall() {
  local app="" hooks_script path
  app=$(installed_app) || app=""
  step "Désinstallation de Nuit Blanche…"

  # Le watchdog d'abord : il ne doit pas relancer l'app pendant qu'on la retire.
  launchctl bootout "gui/$(id -u)/$WATCHDOG_LABEL" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$WATCHDOG_LABEL.plist"

  # Hooks Claude Code / Codex (le script de l'app sait retirer exactement ce qu'il a ajouté).
  hooks_script="$SUPPORT/bin/install-hooks.py"
  if [ ! -f "$hooks_script" ] && [ -n "$app" ]; then hooks_script="$app/Contents/Resources/install-hooks.py"; fi
  if grep -qs "nuitblanche hook" "$HOME"/.claude*/settings.json "$HOME/.codex/hooks.json"; then
    if [ -f "$hooks_script" ] && xcode-select -p >/dev/null 2>&1 \
      && /usr/bin/python3 -I "$hooks_script" uninstall all | sed 's/^/  /'; then
      ok "Hooks retirés."
    else
      warn "Hooks non retirés : supprimez les entrées « nuitblanche hook » de ~/.claude*/settings.json et ~/.codex/hooks.json."
    fi
  fi

  if [ -n "$app" ]; then "$app/Contents/MacOS/NuitBlanche" --unregister-login-item </dev/null >/dev/null 2>&1 || true; fi
  stop_app

  # La veille : rétablie seulement si c'est l'app qui l'avait désactivée.
  if [ -f "$SUPPORT/sleep-disabled-by-app" ] && /usr/bin/pmset -g | grep -Eq '^[[:space:]]*SleepDisabled[[:space:]]+1'; then
    if /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null; then
      ok "Veille rétablie."
    else
      warn "Veille encore désactivée : sudo pmset -a disablesleep 0"
    fi
  fi

  if [ -e "$SUDOERS" ]; then
    step "Mot de passe administrateur demandé pour retirer la règle $SUDOERS…"
    if /usr/bin/sudo /bin/rm -f "$SUDOERS"; then ok "Règle sudoers retirée."; else warn "À retirer à la main : sudo rm $SUDOERS"; fi
  fi

  for path in "$HOME/Applications/$APP_NAME" "/Applications/$APP_NAME"; do
    if [ -d "$path" ]; then
      "$LSREGISTER" -u "$path" >/dev/null 2>&1 || true
      rm -rf "$path" || warn "Impossible de supprimer $path."
    fi
  done
  if [ -f "$CLI" ] && grep -q "Nuit Blanche" "$CLI"; then rm -f "$CLI"; fi
  # Tout le dossier de l'app, sauf d'éventuelles sauvegardes de réglages.
  if [ -d "$SUPPORT" ]; then
    find "$SUPPORT" -mindepth 1 -maxdepth 1 ! -name backups -exec rm -rf {} + 2>/dev/null || true
    rmdir "$SUPPORT" 2>/dev/null || true
  fi
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true

  ok "Nuit Blanche est désinstallée."
  note "Sauvegardes conservées : ~/.claude*/settings.json.avant-nuitblanche, ~/.codex/hooks.json.avant-nuitblanche"
  if [ -d "$SUPPORT/backups" ]; then note "ainsi que $SUPPORT/backups"; fi
}

main() {
  local tag="" force=0 hooks=0 action=install
  while [ $# -gt 0 ]; do
    case "$1" in
      --hooks) hooks=1 ;;
      --reinstall|--force) force=1 ;;
      --uninstall) action=uninstall ;;
      --version)
        [ -n "${2:-}" ] || die "--version attend un numéro (exemple : --version 1.0)."
        tag=$2
        force=1
        shift
        ;;
      -h|--help) usage; return 0 ;;
      *) die "Option inconnue : $1 (voir --help)." ;;
    esac
    shift
  done

  preflight
  if [ "$action" = uninstall ]; then uninstall; else install_app "$tag" "$force" "$hooks"; fi
}

main "$@"
