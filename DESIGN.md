---
name: Appothèque — Natif
description: Un lanceur macOS 26+ en Liquid Glass, avec une signature légère : titre sérif, teinte verte, états en pastilles.
colors:
  tint-green: "#2F7A4E"
  tint-green-dark: "#3F9E68"
  tint-pine: "#1F6F6B"
  tint-blue: "#0A6CD6"
  tint-purple: "#7D4FC4"
  tint-pink: "#C2306A"
  tint-brick: "#B5481A"
  tint-graphite: "#5B6470"
typography:
  panel-title:
    fontFamily: "New York (system serif)"
    fontSize: "21px"
    fontWeight: 600
  body:
    fontFamily: "SF Pro (system)"
    fontSize: "13px"
  label:
    fontFamily: "SF Pro (system)"
    fontSize: "11px"
    fontWeight: 500
  mono:
    fontFamily: "SF Mono (system)"
    fontSize: "11px"
spacing:
  panel-width: "384px"
  row-height: "40px"
  row-radius: "12px"
  card-radius: "18px"
---

# Design System: Appothèque — Natif

## Overview

**North Star : « une app d’Apple, avec une signature ».** Direction retenue le 6 octobre 2026, en remplacement de la passe Atelier (papier, Georgia, thèmes). Les surfaces, textes, contrôles et matériaux sont ceux de macOS 26+ ; l’identité tient en trois touches légères : le titre « Appothèque » en sérif New York, une teinte (vert par défaut) réservée aux actions et à la sélection, et des états en pastilles. Les maquettes de référence sont sur la toile « Appothèque — maquettes natives ».

Mode d’usage : Operate. Une action principale par app.

## Surfaces

1. **Lanceur** (`LauncherPanel`) : le même contenu dans la fenêtre du `MenuBarExtra` et dans le panneau flottant du raccourci global (`LauncherFloatingPanel`, verre `glassEffect`, coins de 26 pt, fermeture à la perte du focus ou avec Échap). Le panneau de la barre de menus garde le matériau du système : on ne peint pas son fond.
2. **Fenêtre unique** (`MainWindowView`) : `NavigationSplitView` (barre latérale avec recherche, Favoris, Apps, Masquées, Propositions), détail en `Form` groupé, inspecteur pour le journal. La modification d’une recette remplace le détail ; le choix de destination iOS est une feuille (avant un lancement) ou un popover (depuis le détail).
3. **Réglages** : scène `Settings` native, onglets Général, Apparence, Icône.

Aucune autre fenêtre. Toute action qui demande de la place ouvre la fenêtre unique à la bonne section.

## Couleur

- La **teinte** (`AppTint`) est la seule couleur choisie par l’utilisateur. Chaque teinte a une valeur claire (≥ 4,5:1 sur blanc) et sombre (≥ 4,5:1 sur fond sombre, ≥ 3:1 sous un libellé blanc) ; un test le vérifie. « Accent du système » suit les Réglages Système.
- Elle sert au bouton principal (libellé teinté sur un fond teinté à 15 %, plus discret qu’un bouton plein), à la sélection (fond teinté à 16 %), à l’état **Ouverte**, au focus de la recherche et aux liens d’action. Les boutons ronds secondaires restent neutres.
- États : **Modifiée** en orange, **Échec** en rouge avec symbole, **Prête** en gris, **À compiler** et **Destination** avec une pastille vide. La couleur ne porte jamais seule l’état : le texte reste affiché.
- Mode **Automatique / Clair / Sombre** appliqué aux fenêtres AppKit par leur `appearance`.

## Typographie

Police du système partout. Seul le titre du lanceur utilise la sérif du système (New York, `design: .serif`). SF Mono pour la branche, la date et le journal.

## Composants

- **Ligne du lanceur** : 40 pt, icône 26 pt, nom, symbole iPhone/iPad pour iOS, état à droite. Sélection en fond teinté arrondi (12 pt). `…` au survol. Pendant une compilation : indicateur et étape courte à la place de l’état.
- **Fiche du lanceur** : carte `fill.quaternary` arrondie (18 pt), hauteur fixe pour que le panneau ne change pas de taille. Icône 40 pt, nom, branche et date en mono, destination iOS, état (ou progression avec durée et dernière ligne du journal, ou erreur avec actions), boutons ronds Journal et Dossier, bouton principal dont le libellé dit ce qu’un clic fera.
- **Détail de la fenêtre** : en-tête (icône 64 pt, nom, pastille d’état), puis sections Source, Destination, Compilations. Barre d’outils : favori, dossier, modifier, journal, puis le bouton principal séparé.
- **Réglages → Apparence** : trois miniatures de mode, huit pastilles de teinte, aperçu d’une ligne sélectionnée.

## À faire / à éviter

- **À faire** : utiliser les matériaux, `Form(.grouped)`, `List(.sidebar)`, `.inspector`, `ContentUnavailableView` et les styles `glass` du système avant toute forme maison.
- **À faire** : garder le clavier complet (raccourci global, flèches, Entrée, ⌘0, ⌘E, ⌘L, ⌘↩, ⌘,) et le menu contextuel pour chaque action d’une ligne.
- **À éviter** : empiler du verre sur du verre (pas de `glassEffect` sur le fond du panneau de la barre de menus), peindre des fonds opaques, réintroduire des couleurs de texte ou des polices personnalisables.
- **À éviter** : cacher une erreur ou une progression derrière un menu ; ouvrir une nouvelle fenêtre pour une tâche qui tient dans la fenêtre unique.
