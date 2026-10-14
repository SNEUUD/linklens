# LinkLens (nom provisoire) — monorepo

App macOS simple pour photographes débutants : tri des photos par IA locale, import et export, puis livraison aux clients via des pages web payantes.
Cahier des charges validé : https://claude.ai/code/artifact/ea3b110c-8fe2-4cdd-9de8-6b4656d22c04

## Structure

```
macos/            App macOS (Xcode, Swift 6, SwiftUI)        → voir macos/CLAUDE.md
web/              Next.js : pages publiques + API            → voir web/CLAUDE.md
api/openapi.yaml  Contrat d'API, source unique de vérité
```

## Phases

1. **App Mac locale** : import, tri IA expliqué, rafales, doublons, export. Sans compte, hors ligne.
2. **Livraison** : compte, abonnement StoreKit 2, publication, page de livraison client.
3. **Portfolio** : page portfolio publique, paliers, option Pro.

Ne jamais coder une fonctionnalité d'une phase suivante sans demande explicite.

## Règles transverses

### Contrat d'API d'abord
- Toute modification d'API commence par `api/openapi.yaml`.
- Ensuite, régénérer les schémas Zod / types côté `web/` et le client Swift côté `macos/`.
- Ne jamais écrire à la main un modèle qui peut être généré depuis le contrat.

### API additive uniquement (pas de versionnage)
- Autorisé : ajouter un endpoint, ajouter un champ **facultatif**.
- Interdit : renommer ou supprimer un champ, changer son type, rendre obligatoire un champ existant.
- Toute liste de valeurs fermée (statut, type de média) doit prévoir un cas « inconnu » côté Swift.
- Si un changement incompatible semble nécessaire : s'arrêter et demander. La procédure est : nouveau champ à côté de l'ancien → publication de l'app → relever la version minimale (`MIN_APP_VERSION`) → suppression de l'ancien champ.

### Tout passe par l'API
- Les pages web et l'app Mac utilisent les mêmes routes.
- Seule la couche API accède à la base (Prisma).

### Confidentialité
- Aucune photo ne quitte le Mac sans l'action explicite « Publier ».
- Données et fichiers hébergés en France (VPS + S3 OVH).

## Façon de travailler

- **Plan avant code** : pour chaque tâche, proposer un plan court et attendre la validation de Chris avant de modifier des fichiers.
- **Une fonctionnalité par session** (identifiants F1–F10 côté Mac, pages et routes côté web, voir le cahier des charges).
- **Vérifier avant de terminer** : build et tests qui passent avant chaque commit. Ne jamais déclarer une tâche finie sans les avoir lancés.
- **Petits commits** en français, au présent : `Ajoute la vérification d'empreinte à l'import`.
- **Branches** : `development` pour le travail, `main` pour la production. Pas de push direct sur `main`.
- **Secrets** : jamais dans le code ni dans les commits ; uniquement en variables d'environnement.
- Code, noms de variables et commentaires en **anglais** ; interface et textes utilisateur en **français** (localisés).

## Vocabulaire

| Terme | Sens |
| --- | --- |
| Galerie | Ensemble de photos d'une séance dans l'app Mac (importée d'une carte SD ou d'un dossier) |
| Livraison | Page web privée envoyée à un client final : `/[pseudo]/[deliveryId]` |
| Portfolio | Page publique d'un photographe abonné : `/[pseudo]` |
| Pseudo | Identifiant public du photographe, unique, minuscules et tirets |
| deliveryId | Identifiant aléatoire non devinable (nanoid) |
