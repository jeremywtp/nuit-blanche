# Nuit Blanche

App de barre des menus macOS (Liquid Glass, style Centre de contrôle) qui garde le Mac éveillé, **même écran rabattu**, pendant que Claude Code, Codex ou une commande travaillent, puis rend la main à la veille.

## Pourquoi pas juste `caffeinate -dimsu` ?

- `caffeinate` crée des *assertions* qui bloquent la veille **par inactivité**. Rabattre l'écran déclenche une veille forcée que ces assertions n'empêchent pas (sur batterie, c'est certain ; sur secteur, `-s` est au mieux un « dark wake » non garanti).
- `sudo pmset -a disablesleep 1` bloque **toute** veille, y compris écran rabattu. Mais c'est un réglage **permanent** : il survit aux redémarrages et laisse un Mac fermé, sur batterie, dans un sac, chauffer jusqu'à 0 %.
- Nuit Blanche combine les deux : assertions IOKit (comme `caffeinate`) pendant un maintien, et `disablesleep` **seulement pendant ce maintien**, avec garde-fous et watchdog.

## Installation

Dans le Terminal, sur n'importe quel Mac sous macOS 26 ou plus récent (Apple Silicon ou Intel) :

```bash
curl -fsSL https://raw.githubusercontent.com/jeremywtp/nuit-blanche/main/install.sh | bash
```

La commande télécharge la dernière [version publiée](https://github.com/jeremywtp/nuit-blanche/releases), vérifie sa somme SHA-256 et sa signature, l'installe dans `~/Applications` (pas de mot de passe), puis la lance et ouvre le panneau. Elle s'ouvre ensuite à chaque démarrage du Mac.

| Pour… | Commande |
|---|---|
| Mettre à jour | relancer la même commande (la caféine et les maintiens en cours sont conservés) |
| Connecter aussi Claude Code et Codex | `… \| bash -s -- --hooks` |
| Revenir à une version précise | `… \| bash -s -- --version 1.0` |
| Tout désinstaller | `… \| bash -s -- --uninstall` |

Puis, dans le panneau : **Capot fermé** → mot de passe administrateur une seule fois (installe une règle sudoers limitée à `pmset -a disablesleep 0|1`).

Pourquoi pas un `.dmg` ? L'app n'est pas notarisée par Apple (il faut un compte développeur payant). Téléchargée par un navigateur, macOS la bloquerait (« impossible de vérifier le développeur »). Téléchargée par `curl`, elle ne reçoit pas l'attribut de quarantaine et s'ouvre normalement, comme ce que fait Homebrew. Si vous récupérez quand même le `.zip` des releases avec Safari : `xattr -dr com.apple.quarantine "/chemin/Nuit Blanche.app"`.

Depuis les sources (Xcode 26 ou plus récent requis, pour `actool` et le SDK Liquid Glass) :

```bash
git clone https://github.com/jeremywtp/nuit-blanche.git && cd nuit-blanche && ./build.sh --install
```

Hooks Claude Code / Codex : bouton **Connecter** dans *Agents IA* (rien n'est installé automatiquement), ou :

```bash
python3 ~/Library/Application\ Support/NuitBlanche/bin/install-hooks.py install all
```

Codex demandera de valider les nouveaux hooks au prochain lancement (« Hooks need review »).

## Panneau

| Module | Rôle |
|---|---|
| **Caféine** | Maintien manuel (= `caffeinate`), même écran rabattu : 30 min → 8 h ou « jusqu’à ce que je l’arrête ». ⌥ + clic sur la lune ou ⌃⌥⌘N |
| **Capot fermé** | Autorise le travail écran rabattu (`disablesleep` pendant les maintiens uniquement) ; secteur uniquement et protection thermique dans le détail |
| **État** (carré) | Éveillé ou non, pourquoi, et en toutes lettres : « Écran rabattable », « Veille si rabattu », « Mac chaud », « Batterie faible » |
| **Agents IA** | Maintien automatique tant que Claude Code / Codex travaillent (ou tant qu’une session est ouverte, pour Remote Control), avec délai avant la veille |
| **Écran allumé** | Garder l’écran allumé pendant les maintiens ou le laisser s’éteindre ; « Éteindre l’écran maintenant » dans le détail |
| **Durée** | Durée de la caféine |
| **Batterie minimum** | Sur batterie, sous ce seuil, tout maintien s’arrête et le Mac peut dormir |
| **Réglages…** | Ouverture au démarrage, temps restant dans la barre des menus, notifications, raccourci, historique |

Règle de clarté : aucun bouton du panneau principal n’est une icône seule ; chaque tuile écrit son état, et chaque élément s’explique au survol.

**Sur l’icône de la lune** : clic = panneau ; ⌥ + clic = caféine marche / arrêt ; clic droit (ou ⌃ + clic) = menu rapide (caféine 30 min → illimitée, arrêter, capot fermé, agents, réglages, quitter). Raccourci global ⌃⌥⌘N (les réglages signalent s’il est déjà pris par une autre app, et si macOS bloque les notifications).

Garde-fous : seuil de batterie, protection thermique (`thermalState` sérieux → capot fermé suspendu), option secteur uniquement, minuteur, watchdog LaunchAgent (relance l'app après un plantage ou un gel ; rétablit la veille s'il n'y arrive pas), arrêt propre sur `SIGTERM` (la caféine en cours reprend à la relance, pas après « Quitter » ni un redémarrage du Mac).

## Commande Terminal

```bash
nuitblanche run -- make build     # éveillé le temps de la commande
nuitblanche hold 2h               # 30m, 2h, 1h30, 90… ; sans durée : jusqu'à release
nuitblanche release
nuitblanche status [--json]
nuitblanche open [main|awake|lid|agents|settings]
```

URL : `nuitblanche://panel/agents`, `nuitblanche://hold?minutes=30`, `nuitblanche://release`, `nuitblanche://toggle`.

## Fonctionnement

```
hooks Claude Code / Codex ──► nuitblanche hook … ──► ~/Library/Application Support/NuitBlanche/sessions/*.json
nuitblanche run / hold   ──────────────────────────┘                │
                                                                     ▼
                           Nuit Blanche (toutes les 2 s) : sessions + batterie + écran rabattu + température
                                     │
                     ┌───────────────┴────────────────┐
             assertions IOKit                 sudo -n pmset -a disablesleep 0|1
        (libérées si l'app meurt)       (règle /etc/sudoers.d/nuitblanche ; marqueur
                                          sleep-disabled-by-app pour le watchdog)
```

- Une session d'agent sans processus vivant (PID mort) est retirée automatiquement.
- Une fois l'assistant installé, **l'app pilote seule `disablesleep`** : un ancien `pmset disablesleep 1` permanent est retiré quand rien ne maintient le Mac éveillé (c'est voulu : plus de Mac qui ne dort jamais).
- **Démarrage du Mac** : l'app est un élément d'ouverture (Réglages → *Ouvrir au démarrage*, activé par défaut), lancée à chaque ouverture de session.
- **Plantage** : le watchdog (`~/Library/LaunchAgents/com.jeremywtp.NuitBlanche.watchdog.plist`, toutes les 60 s et à l'ouverture de session) relance l'app si macOS a écrit un rapport de plantage depuis son dernier battement, ou si elle est figée (battement de plus de 3 min constaté deux fois de suite, jamais dans les 4 min qui suivent un réveil). « Forcer à quitter » (pas de rapport) est respecté. La caféine en cours est mémorisée en continu et reprend après une coupure de moins de 10 min ; « Quitter » et un redémarrage du Mac l'effacent.
- **Capot fermé** : une fois la veille rétablie écran rabattu (fin de maintien, chaleur, batterie), elle n'est pas rebloquée tant que l'écran reste rabattu sans écran externe (réveil Power Nap dans un sac) ; ouvrir l'écran réarme.
- Après 3 relances en 5 minutes (boucle de plantage), le watchdog abandonne et retire le `disablesleep` posé par l'app (jamais un réglage qu'elle n'a pas posé), puis rendort le Mac s'il est fermé sans écran externe.
- Sessions d'agents : `Stop`/`StopFailure` et la notification « Claude attend votre saisie » les remettent au repos. Une interruption (Échap) n'envoie pas de `Stop` : une session « au travail » muette depuis 15 min (Claude) ou 30 min (Codex) est considérée comme inactive, sauf si l'agent exécute une commande shell (2 h au plus). Après la fin d'un tour, une commande lancée en arrière-plan garde le Mac éveillé 30 min au plus (un `tail -f` ou un serveur oublié ne tient pas toute la nuit).
- Batterie : sous le seuil (sur batterie, ou sur secteur sans charge), tout maintien est suspendu ; la caféine reprend au-dessus du seuil.

## Désinstallation

```bash
curl -fsSL https://raw.githubusercontent.com/jeremywtp/nuit-blanche/main/install.sh | bash -s -- --uninstall
```

La commande retire l'élément d'ouverture au démarrage, les hooks, le watchdog, la règle sudoers (mot de passe demandé), rétablit la veille si l'app l'avait désactivée, puis supprime l'app, la commande `nuitblanche`, ses données et ses préférences. Les sauvegardes `.avant-nuitblanche` des réglages Claude Code / Codex sont conservées.

À la main :

1. Panneau → Capot fermé → **Désinstaller l'assistant…** (retire la règle sudoers, le watchdog et remet `disablesleep 0`).
2. `python3 ~/Library/Application\ Support/NuitBlanche/bin/install-hooks.py uninstall all`
3. Réglages → décocher *Ouvrir au démarrage*, quitter, supprimer `~/Applications/Nuit Blanche.app`, `~/.local/bin/nuitblanche` et `~/Library/Application Support/NuitBlanche`.
4. Facultatif : `defaults delete com.jeremywtp.NuitBlanche` (préférences) et les sauvegardes `~/.claude*/settings.json.avant-nuitblanche`, `~/.codex/hooks.json.avant-nuitblanche`.

## Design Liquid Glass

Sources : documentation Apple embarquée dans Xcode 27 (`IDEIntelligenceChat.framework/…/AdditionalDocumentation/SwiftUI-` et `AppKit-Implementing-Liquid-Glass-Design.md`) et mesures sur une capture du Centre de contrôle.

- **Panneau** : `NSGlassEffectView` en verre *regular* (il floute ce qu'il y a derrière : un terminal reste illisible à travers), voile de 12 % noir en sombre / blanc en clair, dans un conteneur arrondi masqué pour que l'ombre suive les coins. Calibré par captures sur un terminal et sur un fond d'écran coloré.
- **Grille** : modules de 64 pt, espacement 12 pt, comme le Centre de contrôle. Coins concentriques : modules 26 pt, panneau 26 + 12 = 38 pt.
- **Modules** : `glassEffect(.clear)` (verre liquide à liseré spéculaire, comme le Centre de contrôle de macOS 27), `.interactive()` seulement sur ce qui est cliquable. Un `GlassEffectContainer` par écran (rendu groupé recommandé par Apple, `spacing` 0 : pas de fusion entre modules).
- **États** : rond blanc + pictogramme accentué en sombre, rond accentué + pictogramme blanc en clair. Curseurs fins sans poignée qui s'épaississent au survol.
- **Mouvement** : effets de symboles SF ponctuels (rebond à la bascule, quand le Mac s’éveille ou qu’un agent se met au travail), jamais en boucle : une animation continue redessinait tout le panneau à chaque image (~18 % de CPU). Désactivés avec « Réduire les animations ». Retour haptique sur le trackpad.
- **Bulles d’explication** : chaque élément explique ce qu’il fait au survol (`.tip(…)`, Views/Tips.swift). Le survol est détecté par le panneau lui-même (position du curseur 30 fois par seconde, panneau ouvert seulement) car `.help` et `onHover` dépendent de l’app active, ce que n’est jamais un panneau de barre des menus.
- **Accessibilité** : libellés VoiceOver sur tous les boutons-icônes, curseurs ajustables au clavier VoiceOver.
- **Icône** : document Icon Composer `Resources/AppIcon.icon` (lune et étoiles dessinées en Bézier : la licence SF Symbols interdit leur usage dans une icône d'app), compilé par `actool` en `Assets.car`. macOS rend lui-même les variantes sombre, teintée et transparente.

### Bug SwiftUI contourné (macOS 27.0.1)

Un `GlassEffectContainer` qui englobe un changement d'écran (ou des `glassEffectID` partagés entre deux écrans) fait boucler SwiftUI à l'infini dans `FocusBridge` → `nextResponder` quand le panneau est la fenêtre active (app figée à 100 % CPU). D'où un conteneur par écran et `M.glassMorphing = false`. Ne pas réactiver sans retester.

## Développement

```bash
swift build -c release
swift test                      # 23 tests, dont 24 000 événements aléatoires (invariants de sécurité) (mode dryRun : rien n'est touché sur le système)
NB_SNAPSHOT=1 "$(swift build -c release --show-bin-path)/NuitBlanche" --snapshot /tmp/apercus dark   # ou light
```

Publier une version (celle qu'installe `install.sh`) : `./release.sh 1.1`. Le script vérifie que tout est commité, passe la version dans `Info.plist`, lance les tests, compile l'app universelle, crée `NuitBlanche.zip` et sa somme SHA-256, contrôle l'archive comme le fera l'installeur, puis pousse le tag et crée la release GitHub.

Le mode aperçu rend chaque écran du panneau en PNG sans toucher au système (modèle en `dryRun`, verre remplacé par un fond translucide car le Liquid Glass ne se rend pas hors écran).

Réglage du verre en direct (calibrage par captures) : `open -g "nuitblanche://debug/glass?dim=0.35&radius=38&clear=0&appearance=light|dark|system"`. Fermer le panneau : `nuitblanche://close`. Dernière ouverture du panneau (position, écran) : `~/Library/Application Support/NuitBlanche/panel-diagnostic.txt`.

`Shell.run` utilise `posix_spawn` + `waitpid` et jamais `Process.waitUntilExit()`, qui fait tourner la boucle d'événements pendant l'attente (réentrance constatée).
