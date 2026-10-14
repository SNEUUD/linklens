# web/ — pages publiques et API

Lire aussi le `CLAUDE.md` à la racine (règles transverses).

## Stack

- **Next.js** (App Router) + **TypeScript** strict.
- **Prisma** + **PostgreSQL**.
- **Better Auth** : cookies pour le web, jeton Bearer pour l'app Mac.
- **Zod** pour valider chaque entrée d'API, schémas générés depuis `api/openapi.yaml`.
- **S3 OVH** pour les fichiers, via URL présignées.
- Hébergement : VPS Coolify (Traefik), comme Staylow.

## Le web reste minimal : 4 pages, pas de tableau de bord

| Page | URL | Phase |
| --- | --- | --- |
| Présentation | `/` | 2 |
| Connexion / inscription | `/login` (réutilisée par l'app Mac) | 2 |
| Livraison client | `/[pseudo]/[deliveryId]` | 2 |
| Portfolio | `/[pseudo]` | 3 |

- L'abonnement et la gestion des livraisons se font **dans l'app Mac**, via l'API. Ne pas créer d'autre page sans demande explicite.
- Le client final n'a jamais de compte.
- Pages `/[pseudo]...` uniquement pour un photographe abonné.

## API

- Route handlers sous `app/api/...` (pas de préfixe de version).
- **Tout passe par l'API** : les pages appellent les mêmes routes que l'app Mac. Prisma n'est importé que dans la couche serveur de l'API (`lib/server/`), jamais dans un composant de page.
- Chaque route valide son entrée avec Zod et répond `400` avec `{ error }` si elle est invalide.
- **Additive uniquement** : voir les règles du `CLAUDE.md` racine.
- Un middleware lit l'en-tête `X-App-Version` des requêtes de l'app Mac et répond `426 Upgrade Required` s'il est inférieur à `MIN_APP_VERSION`.

## Fichiers (S3 OVH)

- Bucket **privé**, aucun objet public.
- Arborescence : `users/{userId}/deliveries/{deliveryId}/{original|web|thumb}/`.
- Les fichiers **ne transitent jamais par le serveur** : URL présignées pour l'upload (multipart) depuis le Mac et pour la lecture côté client, à durée limitée.
- Les versions web et miniatures sont générées par le Mac, pas par le serveur.
- Seul traitement lourd côté serveur : le ZIP « tout télécharger » (worker BullMQ + Redis, ou streaming).

## Abonnement

- Statut synchronisé via **App Store Server Notifications V2** + App Store Server API.
- Quota de stockage vérifié à chaque demande d'upload.
- **Fin de la période payée** (et non au clic sur « Annuler ») : suppression des pages **et** des fichiers S3 du photographe.

## URL et identifiants

- `pseudo` : unique, minuscules, chiffres et tirets. Refuser les mots réservés du site (`login`, `api`, `admin`, `aide`, et tout futur segment de route).
- `deliveryId` : nanoid d'une dizaine de caractères, non devinable.

## Commandes

À ajuster une fois le projet initialisé :

```sh
npm run dev                 # serveur local
npm run lint
npm test                    # Vitest (API)
npm run test:e2e            # Playwright (page de livraison)
npx prisma migrate dev      # migration locale
```

Lancer lint et tests avant chaque commit. Ne jamais lancer de migration sur la base de production.
