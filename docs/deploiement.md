# Déployer le serveur

Procédure de mise en service sur une machine neuve, du clone du dépôt à la
connexion d'un premier joueur.

## Prérequis

Debian avec Docker et le plugin Compose. Prévoir :

- **~7,5 Go** pour l'image finale
- **~10 Go supplémentaires** de cache de build, qui restent sur le disque après
  la construction — `docker builder prune` les récupère
- **~2 Go de téléchargement** au premier build (les fichiers du jeu)

Soit une vingtaine de gigaoctets disponibles pour construire confortablement.

## Installation

```bash
cp .env.example .env
```

Éditer `.env`. Au minimum :

- `VR_PASSWORD` — mot de passe des joueurs, **entre guillemets simples**
- `RCON_PASSWORD` — sert à l'arrêt propre, **entre guillemets simples**
- `PUID` / `PGID` — résultat de `id -u` et `id -g`, pour que les sauvegardes
  appartiennent à ton compte
- `VRISING_ADMINS` — ton SteamID64, pour être administrateur en jeu (voir
  « Administration en jeu » plus bas — laisser la valeur par défaut ne
  donne **aucun** administrateur, sans avertissement)

Puis :

```bash
docker compose build    # long : 2 Go a telecharger
docker compose up -d
docker compose logs -f  # attendre "Server Setup Complete"
```

## Règle sur les guillemets dans le `.env`

Mesurée, pas supposée :

| Écriture | Valeur réelle | |
|---|---|---|
| `VR_PASSWORD='Mot$X'` | `Mot$X` | correct |
| `VR_PASSWORD=Mot$$X` | `Mot$X` | correct |
| `VR_PASSWORD="Mot$X"` | `Mot` | faux, interpolation |
| `VR_PASSWORD=Mot #x` | `Mot` | faux, commentaire |

**Tout secret s'écrit entre guillemets simples.**

## Pare-feu et redirection de ports

`27015/udp` (jeu) et `27016/udp` (requêtes). Les **deux** doivent être ouverts
et redirigés pour que le serveur apparaisse dans la liste publique. Le port de
jeu seul suffit pour une connexion par IP directe.

```bash
sudo ufw allow 27015/udp
sudo ufw allow 27016/udp
```

## Administration en jeu

`VRISING_ADMINS` accepte plusieurs SteamID64 séparés par des virgules. Le
premier doit être le tien pour que tu sois administrateur : `.env.example`
laisse la variable vide, et une valeur vide écrite telle quelle ne donne
**aucun** administrateur en jeu — rien ne le signale, ni au démarrage ni en
jeu. C'est à l'opérateur d'y mettre son propre SteamID64.

La liste est réécrite dans
`vrising-persistent-data/Settings/adminlist.txt` à chaque démarrage. En jeu :
activer la console dans les options, l'ouvrir avec `~`, taper `adminauth`.
Commandes disponibles ensuite : `kick`, `banuser`, `bancharacter`, `unban`.

## Règles de jeu

`config/ServerGameSettings.json` est un override **partiel** : il ne contient
que les écarts par rapport aux défauts du jeu. `VR_PRESET` doit rester **vide**,
sinon le preset charge ses propres règles à la place des tiennes.

## Mise à jour du jeu

Les fichiers du jeu sont figés dans l'image. Après un patch Stunlock, les
joueurs ne peuvent se reconnecter qu'après :

```bash
docker compose build --no-cache
docker compose up -d
```

## Arrêt

```bash
docker compose stop
```

L'arrêt est ordonné : les joueurs sont prévenus, le serveur sauvegarde, puis
s'arrête de lui-même.

Le **code de sortie discrimine**, et c'est la seule trace qui survive aux
journaux du conteneur :

| Code | Signification |
|---|---|
| `0` | La commande d'arrêt est passée par RCON et le serveur est sorti de lui-même : **le monde est sauvegardé**. |
| `1` | Soit RCON était injoignable et le repli SIGTERM a tué Wine, soit le délai de grâce a expiré et le serveur a reçu SIGKILL. Dans les deux cas la **sauvegarde n'est pas garantie** : le dernier autosave est le dernier état sûr. Les journaux nomment le cas. |

```bash
docker inspect -f '{{.State.ExitCode}}' "$(docker compose ps -aq vrising)"
```

Un `1` n'est pas anodin : Wine ne traduit pas SIGTERM en arrêt applicatif, donc
le serveur n'a eu aucune occasion d'écrire son monde.

## Vérification

```bash
docker build --target builder -t vrising-builder:test .
./tests/verify.sh
```

`docker compose build` ne pose pas de tag sur l'étage `builder` : sans la
première commande, les deux assertions qui l'inspectent échouent faute d'image,
et non faute de défaut. Cette image ne sert qu'au harnais.

Le harnais **arrête le serveur** : ses deux dernières sections vérifient l'arrêt
ordonné puis l'arrêt dégradé, et le laissent arrêté. Relance-le avec
`docker compose start`.

## Limites connues

- La version du jeu n'est pas épinglable : elle est celle du moment du build.
- Wine est épinglé en `10.0.0.0~bookworm-1` et ne recevra pas les correctifs
  ultérieurs sans montée de version délibérée et re-test.
- Les sauvegardes automatiques ne sont pas incluses : voir la spec 2.
- **Le masquage des secrets ne porte que sur la sortie du conteneur**
  (`docker compose logs`). Le serveur écrit lui-même son mot de passe et celui
  de RCON en clair dans le **fichier** de journal Unity, à l'intérieur du
  conteneur (`/opt/vrising/logs/VRisingServer.log`) : c'est lui qui produit ce
  fichier, pas l'entrypoint, et rien ne filtre son contenu. Y accéder demande
  un accès Docker au conteneur, qui vaut déjà un accès root sur la machine —
  ce n'est donc pas une élévation de privilège, mais garder ce fichier en tête
  avant de le partager ou de le sauvegarder.
- **Les mots de passe déjà divulgués avant le masquage le restent.** Les
  journaux de démarrages antérieurs à l'ajout du masquage, et l'historique
  git du `.env` versionné dans ce dépôt, contiennent les valeurs en clair.
  Aucun filtrage rétroactif ne les efface. Seul un changement de
  `VR_PASSWORD` et de `RCON_PASSWORD` neutralise ce qui a déjà fuité.
