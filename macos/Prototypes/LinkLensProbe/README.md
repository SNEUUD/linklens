# LinkLensProbe

Prototype en ligne de commande pour valider, avant de construire l'interface :

1. la qualité du tri IA (Vision, flou, exposition, rafales, doublons) ;
2. les performances de SwiftData à 10 000 photos.

Le dossier de photos est **en lecture seule** : rien n'y est jamais écrit. Tout ce qui est produit va dans `probe-output/` (ignoré par Git), et l'outil refuse un dossier de sortie situé dans le dossier de photos.

## Commandes

Depuis `macos/Prototypes/LinkLensProbe/` (toujours en `-c release` pour mesurer : le mode debug est 5 à 10 fois plus lent) :

```sh
swift test                                                         # tests (Swift Testing)
swift run -c release linklens-probe analyze ~/Downloads/photos     # analyse → probe-output/report.json + report.csv + thumbs/
swift run -c release linklens-probe contact-sheet probe-output/report.json
open probe-output/contact-sheet.html                               # planche-contact
swift run -c release linklens-probe volume-test                    # 10 000 photos fictives dans SwiftData
```

Options utiles :

- `analyze --print-thresholds` : affiche les seuils actuels en JSON.
- `analyze --thresholds mes-seuils.json` : surcharge tout ou partie des seuils, sans recompiler.
- `analyze --concurrency 4` : nombre de photos analysées en parallèle (par défaut : nombre de cœurs).
- `volume-test --count 50000 --galleries 100 --batch-size 1000`.

## Comment juger les résultats

- **Planche-contact** : les faux rejets (une bonne photo en rouge) sont l'erreur la plus grave. Vérifier aussi les rafales et la meilleure de chacune (★).
- **report.csv** : trier par `sharpness` pour placer les seuils de flou ; `report.json` → `neighborDistances` pour le seuil de rafale.
- **Vitesse** : regarder les photos/s et le temps par étape du résumé.
- **volume-test** : alerte si insertion > 10 s, requête > 50 ms ou mémoire > 300 Mo (→ GRDB).

## Organisation

```
Sources/linklens-probe/   commandes (ArgumentParser)
Sources/ProbeCore/
  Imaging/    liste des fichiers, aperçu embarqué + EXIF (ImageIO), miniatures
  Analysis/   Vision, yeux, netteté (Laplacien, Accelerate), exposition, SHA-256, pipeline parallèle
  Culling/    seuils, rafales, classement Garder / À revoir / Rejeter
  Report/     structures du rapport, JSON / CSV / résumé, planche-contact HTML
  Storage/    modèles SwiftData, ModelActor, test de volume
  Support/    erreurs, progression (actor), mémoire, chronométrage
Tests/ProbeCoreTests/
```
