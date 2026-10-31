# macos/ — app macOS

Lire aussi le `CLAUDE.md` à la racine (règles transverses).

## Stack

- **macOS 15 minimum**, Apple Silicon, distribution Mac App Store.
- **Swift 6** avec la vérification stricte de la concurrence, **SwiftUI** (AppKit seulement si une vue l'exige, par exemple pour la performance de la grille).
- **SwiftData** pour le catalogue local.
- Frameworks Apple : Vision, ImageIO, Core Image, AVFoundation, Accelerate, CryptoKit, StoreKit 2.
- Dépendances tierces : le moins possible. Demander avant d'en ajouter une.

## Chris débute en Swift

- Quand tu introduis un concept Swift ou SwiftUI nouveau (optionnels, `actor`, `@MainActor`, `@Observable`, `ModelActor`, `struct` contre `class`…), explique-le en deux ou trois phrases, avec si possible l'équivalent en TypeScript / React.
- Préfère le code simple et lisible au code astucieux.
- En cas de doute sur une API Apple récente (macOS 15), le dire plutôt que d'inventer une signature, et vérifier en compilant.

## Organisation du code

```
macos/LinkLens/
  App/            point d'entrée, navigation
  Features/
    Import/       F1 carte SD, F2 dossier existant
    Library/      galeries, catalogue, F9 disque débranché
    Culling/      F3 tri IA, F4 rafales
    Duplicates/   F5 doublons
    Export/       F6 export et conversion
    Publish/      F7 publication (phase 2)
  Core/
    Vision/       analyse (score, visages, yeux, similarité, flou)
    Imaging/      lecture RAW, miniatures, conversion
    Storage/      modèles SwiftData, accès fichiers, bookmarks
    Networking/   client API généré depuis api/openapi.yaml (phase 2)
  Resources/      Localizable.xcstrings (français d'abord)
macos/LinkLensTests/
  Fixtures/       jeu de photos de test versionné
```

## Règles par domaine

### Import (F1, F2)
- **F1, carte SD** : copier vers l'emplacement choisi pour la galerie, ranger par `AAAA/AAAA-MM-JJ Nom de séance/`, comparer l'empreinte SHA-256 de chaque fichier copié à l'original. N'afficher « Vous pouvez formater la carte » que si tous les fichiers sont identiques.
- **F2, dossier existant** : indexer sur place, **ne jamais copier ni déplacer** les fichiers.
- Ne jamais modifier ni supprimer un fichier sur la carte SD.

### Sandbox et fichiers
- Tout accès à un dossier passe par un choix de l'utilisateur (`NSOpenPanel`) puis un **security-scoped bookmark** persisté.
- Toujours encadrer l'accès par `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`.
- Ne jamais supposer qu'un chemin est accessible : un disque externe peut être débranché (F9). Dans ce cas, afficher la galerie depuis les miniatures en cache et désactiver export et publication.

### SwiftData
- Les écritures en masse (import, résultats d'analyse) se font dans un `ModelActor` en tâche de fond, par lots, jamais sur le `MainActor` dans une boucle.
- L'interface lit les données via `@Query` ou des modèles `@Observable`.
- Garder un test de volume à 10 000 photos ; si les performances ne suffisent pas, le signaler (GRDB est la solution de repli prévue).
- Limite connue (acceptée pour la phase 1) : rattacher une photo à sa galerie coûte plus cher à mesure que la galerie grossit (SwiftData met à jour `Gallery.photos`), donc l'insertion croît comme le carré du nombre de photos : environ 3 s pour 5 000, 11 à 14 s pour 10 000. Le test exige moins de 5 s à 5 000 et moins de 20 s à 10 000. À revoir avant d'accepter des galeries de plus de 20 000 photos.

### IA (F3, F4)
- Similarité : `VNGenerateImageFeaturePrintRequest`. Visages : `VNDetectFaceCaptureQualityRequest` + points du visage (yeux fermés). Score : `VNCalculateImageAestheticsScoresRequest`. Flou : largeur des contours zone par zone (dérivées via Accelerate), jugée aussi par rapport au reste de la galerie.
- Chaque classement (Garder / À revoir / Rejeter) stocke **la raison** affichée à l'utilisateur.
- Analyse en parallèle, avec progression visible et annulable.

### UX
- Aucun réglage technique visible par défaut.
- L'IA propose, elle ne supprime jamais rien seule. Suppression vers la corbeille uniquement. Tout est annulable.
- Raccourcis clavier pour le tri, VoiceOver sur les écrans principaux.

### Ne pas toucher sans demander
- Signature, entitlements, identifiant de bundle, réglages de l'App Store.

## Commandes

À ajuster une fois le projet Xcode créé :

```sh
xcodebuild -project macos/LinkLens.xcodeproj -scheme LinkLens -destination 'platform=macOS' build
xcodebuild -project macos/LinkLens.xcodeproj -scheme LinkLens -destination 'platform=macOS' test
```

Tests avec **Swift Testing** pour la logique (scores, doublons, empreintes, conversion). Lancer build et tests avant chaque commit.

### Rendus PNG de l'interface (sans accès à l'écran)

```sh
TEST_RUNNER_LINKLENS_RENDERS=1 xcodebuild -project macos/LinkLens.xcodeproj -scheme LinkLens -destination 'platform=macOS' test -only-testing:LinkLensTests/InterfaceRenderTests
```

- Un seul écran : ajouter `TEST_RUNNER_LINKLENS_RENDERS_ONLY=accueil,import-carte` (préfixes des noms ; `-only-testing` ne sélectionne pas les tests à arguments).
- PNG clair et sombre dans `~/Library/Containers/fr.chriscrepin.linklens/Data/tmp/LinkLensRenders/`.
- Données d'exemple en mémoire (`LinkLensTests/Renders/RenderLibrary.swift`) : le vrai catalogue et le vrai cache de miniatures ne sont pas touchés.
- Ajouter un écran : un `@Test` de plus dans `InterfaceRenderTests.swift`. Détails et limites en tête de `WindowRenderer.swift` (les fenêtres s'affichent quelques secondes pendant les rendus).
- La galerie « Séance du 20 sept. » reprend la vraie séance (52 photos, 12 rafales) avec 14 vraies miniatures (`LinkLensTests/Fixtures/Thumbnails/`). `WindowRenderer.render(…) { window in … }` permet d'envoyer des touches avant la capture.
- Le verre (Liquid Glass, matériau) n'est pas rendu fidèlement par la capture : vérifier à l'écran.
- Ignorés dans la suite normale.

### Piège des tests avec annulation

Avec `UndoManager.groupsByEvent = false`, tout appel qui enregistre une annulation (P/U/X, B…) doit être entre `beginUndoGrouping()` et `endUndoGrouping()`. Sinon AppKit lève une exception : dans l'app hôte des tests, cela donne un plantage dans un `@Query` de la vraie fenêtre, puis des lancements de tests qui restent bloqués sans aucune sortie.
