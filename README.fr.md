# HandyKopie – Sauvegarde de téléphone Android pour Windows (MTP + adb)

**Langue / Language :** [English](README.md) · [Deutsch](README.de.md) ·
[Français](README.fr.md) · [Русский](README.ru.md) · [中文](README.zh.md)

HandyKopie est un outil Windows gratuit et portable qui copie les fichiers
d'un téléphone Android (connecté en USB/MTP, p. ex. Xiaomi/Redmi) vers votre
PC – avec sélection de dossiers, recherche par type de fichier,
téléchargement de fichiers uniques, sauvegarde incrémentale, mode « Turbo »
rapide via adb, nettoyage du téléphone (caches/restes de mises à jour) et un
désinstallateur d'applications propre. Sans installation, sans cloud, sans
publicité – tout reste sur votre PC.

> Version prête à l'emploi : [`release/HandyKopie_UI.zip`](release/HandyKopie_UI.zip)
> (`adb` inclus ; SHA256 voir [`release/SHA256SUMS.txt`](release/SHA256SUMS.txt))

## Fonctionnalités

- **Arbre de sélection** (à gauche) avec cases à cocher, y compris sélection
  partielle (les sous-dossiers décochés sont exclus).
- Bascule **mémoire interne / carte SD**.
- **Navigateur à droite** : cliquez sur un dossier à gauche pour voir
  immédiatement ses fichiers ; navigation par double-clic et « Haut ».
- **Filtre par type de fichier avec recherche complète** : cochez p. ex.
  *Images*, *Vidéos*, *Audio*, *APK*, *Documents* (ou ajoutez vos propres
  extensions) puis « Rechercher sur le téléphone » – tous les dossiers
  contenant des résultats sont listés ; ouvrez un dossier, téléchargez **un
  seul fichier** par double-clic ou copiez tout le dossier.
- **Vue miniatures** (grandes icônes avec aperçu, comme l'Explorateur Windows).
- **Dossiers système masqués par défaut** (Android, MIUI, caches …) –
  activables par case à cocher.
- **Mode Turbo (adb pull)** – beaucoup plus rapide que MTP pour de gros
  volumes (mémoire interne ; repli automatique sur MTP sinon).
- **Sauvegarde incrémentale** – lors d'une répétition, seuls les fichiers
  nouveaux/modifiés sont transférés ; les doublons (même nom + taille) sont
  ignorés sans question.
- **Détection des doublons** avec question oui/non claire (écraser ou ignorer).
- **Dossier du téléphone à la destination** : tout est rangé sous
  `<destination>\<nom du téléphone>\…` – plusieurs appareils restent séparés.
- **Tolérant aux erreurs** : un fichier défectueux n'interrompt jamais
  l'opération – les erreurs sont écrites immédiatement dans un journal
  temporaire (`%TEMP%\HandyKopie_Fehler_*.txt`, ouvert automatiquement à la
  fin) et la copie continue avec le fichier suivant.
- **Nettoyage** contre un téléphone lent : miniatures, caches d'applications
  (via adb `pm trim-caches` quand Android les masque en MTP), dossiers
  temporaires et restes de mises à jour Android obsolètes – chacun avec
  taille **et nombre de fichiers**.
- **Gestion des applications** : liste les applications tierces installées et
  les désinstalle *proprement* (application + dossiers résiduels
  `Android/data` / `Android/obb`).
- **Progression en direct** (pourcentage, compteurs, fichier en cours) et
  bouton Annuler fonctionnel.

## Prérequis

- Windows 10/11 avec PowerShell 5.1 (inclus dans Windows).
- Câble USB ; téléphone déverrouillé ; mode USB « Transfert de fichiers / MTP ».
- Recommandé : activer le **débogage USB** (Paramètres → À propos du
  téléphone → touchez 7× le numéro de build → Options pour les
  développeurs → Débogage USB) et faire confiance à ce PC – nécessaire pour
  le mode Turbo, le nettoyage profond et la gestion des applications.
- `adb` est fourni (`platform-tools/`) ; si supprimé,
  `tools/get_platform_tools.ps1` télécharge le paquet officiel de Google.

## Démarrage rapide (3 étapes)

1. Téléchargez [`release/HandyKopie_UI.zip`](release/HandyKopie_UI.zip) et
   extrayez-le dans **un seul** dossier (gardez `platform-tools` dedans).
2. Branchez le téléphone (déverrouillé, MTP), double-cliquez sur
   `Start_HandyKopie_UI.bat`.
3. Cochez les dossiers à gauche, choisissez la destination, cliquez sur
   **Copier**. (Première utilisation d'adb : confirmez « faire confiance à
   cet ordinateur » sur le téléphone.)

## Documentation

- Manuel complet : [`docs/`](docs/) – `MANUAL.fr.txt` etc.
- Code source : [`app/HandyKopieUI.ps1`](app/HandyKopieUI.ps1) (application
  PowerShell WinForms en un seul fichier), lanceur :
  [`app/Start_HandyKopie_UI.bat`](app/Start_HandyKopie_UI.bat)

## Sécurité et confidentialité

- Vos fichiers ne quittent jamais le PC : copie USB directe, pas de cloud,
  pas de télémétrie.
- Le nettoyage et la désinstallation ne touchent ni aux applications système
  ni à vos fichiers personnels ; chaque action destructive demande
  confirmation et est journalisée.
- Le programme ne s'interrompt jamais silencieusement : chaque erreur est
  journalisée avec horodatage.

## Licence et composants tiers

- Code propre : **MIT** (voir [`LICENSE`](LICENSE)).
- Android SDK Platform-Tools (adb) fournis : **Apache-2.0**,
  Copyright (C) Google LLC, distribués sans modification (voir
  [`NOTICE`](NOTICE)).

## Vérifier l'intégrité

```powershell
Get-FileHash release\HandyKopie_UI.zip -Algorithm SHA256
# comparer avec release\SHA256SUMS.txt
```

## Journal des modifications

Voir [`CHANGELOG.md`](CHANGELOG.md).
