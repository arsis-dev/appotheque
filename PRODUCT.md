# Appothèque

<!-- impeccable:product-schema 1 -->

## Platform
macOS natif, barre de menus.

## Stack
SwiftUI et AppKit, Swift Package sans dépendance externe. 

## Users
Développeurs qui construisent plusieurs applications Mac, iPhone et iPad (Swift/Xcode, XcodeGen, Swift Package, Tauri, Electron) et veulent lancer la version correspondant à leur code local sans ouvrir Xcode ni un terminal.

## Product Purpose
Cliquer sur un projet pour lancer la version correspondant au code local, sans ouvrir Xcode ou un terminal. Réutiliser la dernière compilation réussie lorsque ses entrées sont inchangées, y compris les fichiers non commités.

## Capabilities and Constraints
Procédure de compilation configurable par projet ; états de progression et erreurs lisibles ; journal accessible ; recompilation forcée ; activation de l'app déjà ouverte ; fermeture normale avant de lancer une nouvelle version. Une erreur ne doit pas faire passer une ancienne version pour la nouvelle.

Apps masquables, favoris persistants et ordre manuel. Recherche au clavier et raccourci global configurable. État des sources et branche Git visibles avant le lancement. Découverte de projets avec configuration proposée, sans ajout automatique. Ouverture explicite d'une compilation précédente conservée, sans modifier la référence du lancement normal.

Deux surfaces et les Réglages : le lanceur (barre de menus, ou panneau flottant pour le raccourci global) et une fenêtre unique qui regroupe détail, journal, modification, découverte et destination iOS. Icône dans le Dock en option ; barre de menus désactivable si le Dock est actif. Interface native macOS 26+ (Liquid Glass) : seuls le mode clair/sombre/automatique et une teinte parmi huit sont réglables. Quatre icônes au choix, appliquées sans redémarrage, et pictogramme de barre de menus système ou assorti. Ces réglages ne modifient pas les recettes de compilation.

Détection des cibles iOS/iPadOS et choix d’un simulateur ou d’un appareil jumelé. Destination mémorisée par projet ; compilations séparées par destination et version du système. Installation et lancement après compilation, ou réutilisation du cache. Signature Apple, jumelage et mode développeur restent configurés par l’utilisateur ; aucune autre destination n’est choisie à la place d’un appareil absent. Xcode 27 ouvre le simulateur dans Device Hub ; les Xcode antérieurs utilisent Simulator.

## Product Principles
Une action principale par app. Interface française native. Aucun changement de branche ou téléchargement Git automatique. Aucun arrêt forcé d'une application. L'ouverture au démarrage reste un choix dans les réglages.
