# Stack serveur V Rising auto-hébergée — design

**Date** : 2026-08-21
**Statut** : validé, prêt pour le plan d'implémentation
**Périmètre** : spec 1 sur 2. Les sauvegardes automatiques font l'objet d'une spec distincte.

## Objectif

Remplacer un `compose.yaml` récupéré sur internet, qui dépend d'une image
communautaire tierce, par une stack maîtrisée de bout en bout : image construite
localement depuis un `Dockerfile`, configuration externalisée dans un `.env`,
arrêt propre du serveur. Cible de déploiement : un serveur Debian distinct,
administré via un compte sudoer.

## Ce que le spike a établi

Un spike a été mené le 2026-08-21 sur l'image communautaire
`sknnr/vrising-dedicated-server:latest`. Il a servi de base factuelle à ce
design ; les conclusions ci-dessous sont mesurées, pas supposées.

### Verdict

Le serveur démarre et fonctionne sur Debian. La chaîne technique est saine :
steamcmd télécharge le build Windows (AppID 1829350, buildid 24686592, 2,02 Go)
et l'exécute sous Wine avec Xvfb. Le log atteint `Server Setup Complete`, les
ports UDP sont bindés, le monde est créé.

### Défauts du compose d'origine

1. **Guillemets inclus dans les valeurs.** La syntaxe `- SERVER_NAME="X"` en
   liste YAML produit la valeur `"X"`, guillemets compris. Config effective
   observée : `"Name": "\"VRising Containerized\""` et
   `"Password": "\"PleaseChangeMe\""`. Les joueurs devraient taper les
   guillemets pour se connecter.
2. **Collision de ports.** `QUERY_PORT` était forcé à 27015, égal à
   `GAME_PORT`. Observé : `"Port": 27015, "QueryPort": 27015`. Le port 27016
   était publié sans que rien n'écoute dessus.
3. **Aucune politique `restart`.** Le premier appel steamcmd a réellement
   échoué (`Failed to install app '1829350' (Missing configuration)`),
   l'entrypoint a fait `exit 1` et le conteneur est resté mort jusqu'à une
   relance manuelle.
4. **Arrêt brutal.** `docker compose stop` a rendu **exit 137** : le serveur a
   été tué par SIGKILL après les 10 s de grâce par défaut, sans arrêt ordonné.
   L'entrypoint de l'image faisait `exec wine`, donc aucun trap de SIGTERM.

### Faits établis expérimentalement

- **Socle prouvé** : Debian 12 bookworm, dépôt WineHQ
  (`dl.winehq.org/wine-builds/debian`), `winehq-stable` version
  `10.0.0.0~bookworm-1`, Xvfb, multiarch i386.
- **Le serveur lit nativement ~37 variables `VR_*`.** Aucun entrypoint
  construisant des arguments CLI n'est nécessaire.
- **`+login anonymous` est la méthode officielle.** Le script
  `examples/download-default.bat` de Stunlock l'utilise. Aucun compte Steam
  n'est requis pour télécharger l'AppID 1829350.
- **Les overrides de réglages peuvent être partiels** : « you can populate it
  with just the settings/values that differ from the default file ».
- **RCON expose une commande `shutdown`** ainsi que `announce` et
  `announcerestart`. RCON est `Enabled: false` par défaut.
- **L'API Prometheus est `Enabled: false`** par défaut (port 9090) : aucune
  exposition involontaire.
- **Comportement des guillemets dans un `.env`**, vérifié en lisant les valeurs
  côté conteneur :

  | Écriture dans `.env` | Valeur réelle | Verdict |
  |---|---|---|
  | `P='Mot$DePasse'` | `Mot$DePasse` | correct — guillemets simples = littéral |
  | `P=Mot$$DePasse` | `Mot$DePasse` | correct — `$$` échappe |
  | `P="Mot$DePasse"` | `Mot` | **piège** — les guillemets doubles interpolent |
  | `P=Mot123 #x` | `Mot123` | **piège** — ` #` démarre un commentaire |
  | `P=Mot123#456` | `Mot123#456` | correct — `#` sans espace est littéral |

  Règle retenue : **tout secret s'écrit entre guillemets simples.**

## Périmètre

### Inclus

- `Dockerfile` multi-étages, image construite localement.
- Configuration externalisée : `.env` + `.env.example` versionné.
- Règles de jeu versionnées via un `ServerGameSettings.json` partiel.
- `adminlist.txt` et `banlist.txt` pilotés depuis le `.env`.
- Arrêt propre du serveur via RCON.
- Exécution en utilisateur non-root, UID/GID configurables.
- Correction des quatre défauts identifiés ci-dessus.

### Exclus

- **Sauvegardes automatiques** : spec 2, conçue après mise en production de
  cette stack.
- **Authentification steamcmd par compte Steam** : écartée. `+login anonymous`
  est la méthode officielle et fonctionne ; un compte n'apporterait rien tout
  en introduisant un secret sensible et la 2FA Steam Guard à gérer.
- **RCON joignable depuis l'extérieur** : le protocole est en clair. RCON reste
  interne au conteneur, au seul service de l'arrêt propre.
- **Redémarrage quotidien** recommandé par Stunlock : trivial à ajouter par
  timer systemd une fois la stack en place, hors périmètre ici.
- **Mods** (BepInEx) et **monitoring** (API Prometheus).

## Architecture

### Arborescence

```
vrising/
├── compose.yaml
├── Dockerfile
├── .dockerignore
├── .gitignore
├── .env                      # valeurs réelles, NON versionné
├── .env.example              # modèle documenté, versionné
├── config/
│   └── ServerGameSettings.json   # écarts de règles, versionné
├── docker/
│   └── entrypoint.sh
└── vrising-persistent-data/  # volume : Saves/ + Settings/, NON versionné
```

`.gitignore` couvre `.env` et `vrising-persistent-data/`.

### Étage `builder`

Base `debian:12-slim`. Active le multiarch i386, installe les dépendances de
steamcmd, puis télécharge le jeu avec la commande officielle :

```
steamcmd +@sSteamCmdForcePlatformType windows \
         +force_install_dir /game +login anonymous \
         +app_update 1829350 validate +quit
```

Compile également **mcrcon** (client RCON en C, quelques Ko, sans dépendance
au-delà de la libc), utilisé pour l'arrêt propre.

Cet étage est jetable : ni steamcmd ni les ~240 paquets i386 n'atteignent
l'image finale.

### Étage `runtime`

Base `debian:12-slim`. Ajoute le dépôt WineHQ et installe `winehq-stable`
**épinglé à `10.0.0.0~bookworm-1`** — la version dont le fonctionnement est
prouvé — ainsi que Xvfb. Récupère le jeu et le binaire mcrcon par
`COPY --from=builder`. Crée l'utilisateur non-root et **initialise le préfixe
Wine au build** (`wineboot`), afin qu'aucun premier démarrage ne paie cette
latence.

### Décisions structurantes

**Signaux.** L'entrypoint reste PID 1 et lance Wine en arrière-plan au lieu de
`exec`. C'est la condition nécessaire pour intercepter SIGTERM et déclencher
l'arrêt RCON. C'est précisément ce que l'image communautaire ne faisait pas,
d'où son `exit 137`.

**Non-root.** Utilisateur dédié, UID/GID paramétrés par `PUID`/`PGID`. Corrige
les fichiers en `root:root` observés dans le volume : les sauvegardes
appartiendront au compte sudoer, sans `sudo` requis pour les futurs backups.

**Reproductibilité, limite assumée.** `app_update` récupère la version courante
au moment du build. L'image est immuable et sa version connue une fois
construite, mais deux builds espacés dans le temps ne produisent pas le même
jeu. Épingler réellement une version exigerait d'archiver le dépôt Steam ;
jugé disproportionné ici.

## Couche de configuration

### Précédence

Du plus faible au plus fort :

1. **Défauts du jeu** — `VRisingServer_Data/StreamingAssets/Settings/`, jamais
   modifiés (Stunlock indique qu'ils sont écrasés aux mises à jour).
2. **`config/ServerGameSettings.json`** — règles de jeu, monté en lecture seule
   dans le conteneur, copié par l'entrypoint vers `Settings/`. Override
   partiel : ne contient que les écarts.
3. **`.env` → `VR_*`** — réglages d'hébergement, priorité maximale.

`compose.yaml` n'utilise que de l'interpolation `${VAR}`, sans aucun guillemet.
Le défaut n°1 du compose d'origine devient structurellement impossible.

### Variables du `.env`

Noms canoniques vérifiés dans la documentation officielle. `VR_NAME` et
`VR_HIDEIPADDRESS` existent comme alias respectifs de `VR_SERVER_NAME` et
`VR_HIDE_IP_ADDRESS` ; les formes longues sont retenues.

| Variable | Rôle | Valeur retenue |
|---|---|---|
| `VR_SERVER_NAME` | nom affiché | à définir, guillemets simples |
| `VR_DESCRIPTION` | description | à définir, guillemets simples |
| `VR_PASSWORD` | mot de passe joueurs | **à changer**, guillemets simples |
| `VR_GAME_PORT` | port de jeu UDP | `27015` |
| `VR_QUERY_PORT` | port de requête UDP | `27016` |
| `VR_BIND_ADDRESS` | interface d'écoute | `0.0.0.0` |
| `VR_LIST_ON_EOS` | listé sur EOS | `true` |
| `VR_LIST_ON_STEAM` | listé sur Steam | `false` |
| `VR_HIDE_IP_ADDRESS` | masque l'IP | `true` |
| `VR_SECURE` | anti-triche | `true` |
| `VR_MAX_USERS` | joueurs simultanés | `40` |
| `VR_MAX_ADMINS` | admins simultanés | défaut du jeu |
| `VR_LOWER_FPS_WHEN_EMPTY` | économie CPU à vide | `true` |
| `VR_SAVE_NAME` | nom du monde | `vrising_world` |
| `VR_SAVE_COUNT` | autosaves conservées | `20` |
| `VR_SAVE_INTERVAL` | intervalle autosave (s) | `120` |
| `VR_PRESET` | preset de règles | **vide** — voir ci-dessous |
| `VR_DIFFICULTY_PRESET` | preset de difficulté | vide |
| `PUID` / `PGID` | propriétaire des fichiers | `1000` / `1000` |
| `VRISING_ADMINS` | SteamID64, séparés par virgule | à définir |
| `VRISING_BANS` | SteamID64 d'amorçage | vide |
| `RCON_PASSWORD` | RCON interne | à définir, guillemets simples |
| `TZ` | fuseau horaire | `Europe/Paris` |

**Interaction à respecter** : `VR_PRESET` doit rester vide dès lors que
`config/ServerGameSettings.json` est utilisé. La documentation officielle est
explicite : un preset non vide charge ses propres règles *à la place* des
règles fournies. `.env.example` le signalera en commentaire.

### adminlist et banlist : source de vérité

Les deux fichiers vivent dans `Settings/`, à l'intérieur du volume, mais sont
traités différemment :

- **`adminlist.txt` — déclaratif.** Réécrit depuis `VRISING_ADMINS` à chaque
  démarrage. Les admins relèvent de la configuration d'infrastructure et
  appartiennent au `.env` versionné. Le fichier est modifiable à chaud sans
  redémarrage, conformément à la documentation.
- **`banlist.txt` — propriété du serveur.** Le serveur l'écrit lui-même lors
  d'un bannissement en jeu. `VRISING_BANS` ne fait que l'**amorcer si le
  fichier est absent**. L'écraser à chaque démarrage détruirait des données
  opérationnelles.

Une troisième voie a été envisagée et écartée : l'union des deux sources rend
le débannissement en jeu silencieusement inopérant au redémarrage suivant.
Séparer configuration et données runtime est plus prévisible.

## Cycle de vie du conteneur

### Séquence de l'entrypoint

1. **En root** : création des dossiers du volume, `chown` vers `PUID:PGID`.
2. **Rendu de la configuration** : écriture de `adminlist.txt` depuis
   `VRISING_ADMINS` ; amorçage de `banlist.txt` s'il est absent ; copie de
   `/config/ServerGameSettings.json` vers `Settings/` s'il est fourni.
   Cette copie **écrase** la cible à chaque démarrage : les règles de jeu
   sont déclaratives et le fichier versionné est seul maître. Le serveur
   n'écrit jamais dans ce fichier, contrairement à `banlist.txt`.
3. **Activation de RCON en interne** : `VR_RCON_ENABLED=true`,
   `VR_RCON_BIND_ADDRESS=127.0.0.1`, mot de passe issu du `.env`. Le port
   n'est pas publié dans `compose.yaml`.
4. **Démarrage de Xvfb** sur `:1`.
5. **Lancement de Wine en arrière-plan** sous l'utilisateur non-root, PID
   conservé.
6. **Trap SIGTERM/SIGINT** : voir ci-dessous.

### Arrêt propre

Sur réception de SIGTERM ou SIGINT, l'entrypoint enchaîne : `announce` aux
joueurs connectés, puis la commande RCON `shutdown`, puis attente de la sortie
effective du processus serveur (90 s maximum), et `SIGKILL` en dernier recours.

`stop_grace_period` est fixé à `120s` dans `compose.yaml`, délibérément
supérieur aux 90 s de l'entrypoint, pour que Docker ne tue jamais le conteneur
avant la fin de l'arrêt ordonné.

### Risque principal

**Validé le 2026-08-21 (Tâche 1 du plan).** RCON s'active bien par variable
`VR_*` et le serveur répond à la commande `shutdown`, qui déclenche un arrêt
ordonné. Syntaxe retenue : `shutdown <message times> <message>` (relevée via
`help shutdown` sur le serveur lui-même — la doc officielle est ambiguë sur ce
point ; exemple testé et fonctionnel : `shutdown 1 Test`). La Tâche 7 du plan
implémente le trap SIGTERM sur cette base.

Preuve mesurée : le dump de configuration du serveur montre `"Rcon": {
"Enabled": true, "BindAddress": "0.0.0.0", "Port": 25575, ... }` (les
variables `VR_*` sont donc bien lues nativement), mcrcon s'authentifie et
obtient une réponse à `version`, et la commande `shutdown` fait sortir le
processus serveur de lui-même avec **exit 0** — mesuré directement sur le
conteneur, sans passer par `docker compose stop` (ce chemin complet, avec
trap SIGTERM, reste à câbler par la Tâche 7).

**Écart mesuré à signaler à la Tâche 7 :** le délai entre l'envoi de la
commande `shutdown 1 Test` et la sortie effective du processus a été
d'environ **3 min 40 s** (serveur sans joueur connecté), pas les ~120 s
supposées par le script de sonde. C'est nettement supérieur aux 90 s
d'attente prévues pour l'entrypoint et au `stop_grace_period` de 120 s déjà
fixé dans `compose.yaml` (voir « Arrêt propre » ci-dessus) : tels quels, ces
délais couperaient l'arrêt ordonné avant son terme. La Tâche 7 doit revoir
ces deux valeurs à la hausse (une marge confortable au-delà de 3 min 40 s,
par exemple 240 s pour l'attente et `stop_grace_period`) avant de s'appuyer
sur ce mécanisme.

*(Repli documenté mais non retenu, RCON s'étant avéré fiable : conserver un
`stop_grace_period` long en s'appuyant sur les autosaves. Dégradé, mais sans
perte massive puisque le serveur sauvegarde toutes les 120 s.)*

## Réseau et déploiement

**Ports** : `27015/udp` pour le jeu, `27016/udp` pour les requêtes. La
collision du compose d'origine est corrigée.

**Pare-feu Debian** : la documentation officielle précise que **les deux**
ports doivent être ouverts et redirigés pour que le serveur apparaisse dans la
liste ; le port de jeu seul suffit pour une connexion par IP directe.

**Compose** : `restart: unless-stopped` — correctif direct du défaut n°3, dont
la survenue a été constatée — et `stop_grace_period: 120s`.

**Procédure de déploiement** sur le serveur Debian cible :

Le projet n'a pas encore de dépôt distant. Deux transferts possibles vers
la machine cible : `rsync -a` du répertoire (en excluant `.env` et
`vrising-persistent-data/`), ou publication sur un dépôt distant puis
`git clone`. Dans les deux cas :

```
cd vrising
cp .env.example .env
# éditer .env : mot de passe, nom, PUID/PGID, VRISING_ADMINS, RCON_PASSWORD
docker compose build      # long : 2 Go à télécharger
docker compose up -d
```

Le build s'exécute sur la machine cible : aucun registre d'images à gérer.

## Critères de vérification

| Critère | Preuve attendue |
|---|---|
| Le serveur démarre | `Server Setup Complete` dans les logs |
| Configuration effective correcte | dump du log : `"Name"` et `"Password"` sans guillemets parasites |
| Ports distincts | `"Port": 27015, "QueryPort": 27016` |
| Non-root effectif | `ls -l` du volume montre `PUID:PGID`, plus aucun `root:root` |
| Règles de jeu appliquées | valeurs de `ServerGameSettings.json` visibles dans le dump |
| Admin reconnu | le SteamID64 figure dans `Settings/adminlist.txt` |
| banlist préservée | un ban en jeu survit à un `docker compose restart` |
| **Arrêt propre** | `docker compose stop` rend **exit 0** |
| Connexion réelle | un client rejoint le serveur avec le mot de passe du `.env`, sans guillemets |

## Risques et limites connus

1. **Arrêt propre RCON non prouvé** — première tâche d'implémentation, repli
   documenté ci-dessus.
2. **Version du jeu non épinglable** — l'image fige la version au build ;
   un patch Stunlock impose un `docker compose build` pour que les joueurs
   puissent se reconnecter.
3. **Mot de passe en clair dans les logs** — le serveur dumpe sa configuration
   effective au démarrage, mot de passe compris. Comportement du jeu, non
   corrigeable côté image. À prendre en compte avant de partager des logs.
4. **`$` et ` #` dans le `.env`** — pièges d'interpolation mesurés ; la règle
   « secrets en guillemets simples » les neutralise et sera documentée dans
   `.env.example`.
5. **Wine épinglé** — `10.0.0.0~bookworm-1` est prouvé mais ne recevra pas les
   correctifs ultérieurs sans montée de version délibérée et re-test.

## Références

- Instructions officielles Stunlock, version 1.1.x PC :
  `StunlockStudios/vrising-dedicated-server-instructions`, fichier
  `1.1.x-pc/INSTRUCTIONS.md`
- Script de téléchargement officiel : `1.1.x-pc/examples/download-default.bat`
- AppID du serveur dédié : `1829350`
- Client RCON : `Tiiffi/mcrcon`
