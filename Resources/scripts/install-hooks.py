#!/usr/bin/env python3
"""Nuit Blanche : ajoute ou retire les hooks Claude Code et Codex.

Usage : install-hooks.py install|uninstall claude|codex|all

Claude Code : chaque profil ~/.claude*/ qui contient settings.json et projects/.
Codex : ~/.codex/hooks.json.
Les autres hooks sont conservés tels quels ; une sauvegarde *.avant-nuitblanche est faite une fois.
"""
import glob
import json
import os
import shutil
import sys
import tempfile

CLI = "~/.local/bin/nuitblanche"
MARK = "nuitblanche hook"
# StopFailure : fin de tour sur erreur d’API (Stop n’est pas envoyé) ; PostToolUseFailure : outil en échec
# (PostToolUse n’est pas envoyé) ; PermissionRequest : attente d’une validation. Vérifiés dans Claude Code 2.1.327.
CLAUDE_EVENTS = ["SessionStart", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
                 "Notification", "Stop", "StopFailure", "SessionEnd"]
# Codex : événements présents dans le schéma JSON des hooks du binaire Codex (entrée : session_id, cwd,
# hook_event_name, comme Claude Code).
# PostToolUse rafraîchit l’activité pendant un long tour (sinon la session expire au bout de 30 min sans signal).
CODEX_EVENTS = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"]


def entry(agent, event):
    return {"hooks": [{"type": "command", "command": f"{CLI} hook {agent} {event}", "timeout": 5}]}


def strip(hooks):
    """Retire toutes les entrées Nuit Blanche, et les groupes / événements devenus vides."""
    for event in list(hooks.keys()):
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue
        kept = []
        for group in groups:
            if isinstance(group, dict) and isinstance(group.get("hooks"), list):
                group["hooks"] = [h for h in group["hooks"] if MARK not in str(h.get("command", ""))]
                if not group["hooks"]:
                    continue
            kept.append(group)
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]


def update(path, agent, events, install):
    # Un settings.json lien symbolique est mis à jour à sa cible (os.replace remplacerait le lien par un fichier).
    path = os.path.realpath(path)
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
        data = json.loads(raw) if raw.strip() else {}
        backup = path + ".avant-nuitblanche"
        if not os.path.exists(backup):
            shutil.copy2(path, backup)
    else:
        if not install:
            return
        raw, data = "", {}
        # Fichier absent avant Nuit Blanche : la sauvegarde le dit (« {} »), elle n'est pas refaite plus tard
        # à partir d'un fichier qui contiendrait déjà nos hooks.
        backup = path + ".avant-nuitblanche"
        if not os.path.exists(backup):
            with open(backup, "w", encoding="utf-8") as fh:
                fh.write("{}\n")
    if not isinstance(data, dict):
        raise ValueError("le fichier ne contient pas un objet JSON")
    if data.get("hooks") is None and "hooks" in data:
        del data["hooks"]  # "hooks": null
    if not install and "hooks" not in data:
        return
    hooks = data.setdefault("hooks", {})
    strip(hooks)
    if install:
        for event in events:
            hooks.setdefault(event, []).append(entry(agent, event))
    elif not hooks:
        del data["hooks"]
    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    if text == raw:
        return
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".nuitblanche.")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    if os.path.exists(path):
        shutil.copymode(path, tmp)
    os.replace(tmp, path)
    print(("Hooks ajoutés : " if install else "Hooks retirés : ") + path)


def claude_profiles(home):
    """Profils Claude Code : dossiers ~/.claude* qui contiennent projects/ (exclut ~/.claude-mem, etc.).
    Un profil sans settings.json (installation fraîche) reçoit le sien."""
    for directory in sorted(glob.glob(os.path.join(home, ".claude*"))):
        if os.path.isdir(directory) and os.path.isdir(os.path.join(directory, "projects")):
            yield os.path.join(directory, "settings.json")


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("install", "uninstall") or sys.argv[2] not in ("claude", "codex", "all"):
        print(__doc__)
        return 2
    install = sys.argv[1] == "install"
    target = sys.argv[2]
    home = os.path.expanduser("~")
    failures = 0
    jobs = []
    if target in ("claude", "all"):
        profiles = list(claude_profiles(home))
        if not profiles and target == "claude":
            print("Aucun profil Claude Code trouvé (~/.claude/projects) : lancez Claude Code une première fois.", file=sys.stderr)
            return 1
        jobs += [(settings, "claude", CLAUDE_EVENTS) for settings in profiles]
    if target in ("codex", "all") and os.path.isdir(os.path.join(home, ".codex")):
        jobs.append((os.path.join(home, ".codex", "hooks.json"), "codex", CODEX_EVENTS))
    for path, agent, events in jobs:
        try:
            update(path, agent, events, install)
        except Exception as error:  # un profil illisible ne doit pas empêcher les autres
            failures += 1
            print(f"Échec pour {path} : {error}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
