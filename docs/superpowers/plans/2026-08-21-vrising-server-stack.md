# Plan d'implémentation — Stack serveur V Rising auto-hébergée

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remplacer un `compose.yaml` dépendant d'une image communautaire tierce par une stack maîtrisée de bout en bout : image construite localement, configuration en `.env`, exécution non-root, arrêt propre du serveur.

**Architecture:** `Dockerfile` multi-étages. Un étage `builder` jetable contient steamcmd et ses ~240 paquets i386, télécharge le jeu anonymement et compile mcrcon. Un étage `runtime` minimal ne contient que Wine épinglé et Xvfb, et récupère les artefacts par `COPY --from`. La configuration passe par les variables `VR_*` que le serveur lit nativement, alimentées depuis un `.env`. Un entrypoint PID 1 rend la configuration déclarative, lance le serveur en arrière-plan sous un utilisateur non-root, et intercepte SIGTERM pour déclencher un arrêt ordonné via RCON interne.

**Tech Stack:** Docker multi-stage, Debian 12 bookworm, WineHQ `winehq-stable` 10.0.0.0~bookworm-1, Xvfb, steamcmd (AppID 1829350), mcrcon v0.7.2, bash, `setpriv` (util-linux).

**Spec:** `docs/superpowers/specs/2026-08-21-vrising-server-stack-design.md`

## Global Constraints

Ces contraintes s'appliquent implicitement à **toutes** les tâches.

- **Base d'image** : `debian:12-slim` pour les deux étages. Pas d'autre base.
- **Version de Wine épinglée** : `10.0.0.0~bookworm-1`, exactement. C'est la version dont le fonctionnement est prouvé. `11.0.0.0~bookworm-1` existe dans le dépôt mais n'est pas testée : ne pas l'utiliser.
- **Incantation apt obligatoire pour Wine** : la forme naïve `apt-get install winehq-stable=10.0.0.0~bookworm-1` **échoue** avec `unmet dependencies`, car `wine-stable` (amd64) dépend de `wine-stable-i386` qui n'existe qu'en architecture i386. Les quatre paquets doivent être nommés explicitement :
  ```
  winehq-stable=$V wine-stable=$V wine-stable-amd64=$V wine-stable-i386:i386=$V
  ```
  avec `dpkg --add-architecture i386` exécuté **avant** le premier `apt-get update`.
- **AppID Steam** : `1829350`. Téléchargement en `+login anonymous` uniquement — c'est la méthode officielle Stunlock. **Ne jamais** implémenter d'authentification par compte Steam : explicitement hors périmètre.
- **Ports** : `27015/udp` pour le jeu, `27016/udp` pour les requêtes. Ils doivent être **distincts** (la collision est le défaut n°2 de la spec).
- **RCON** : `VR_RCON_BIND_ADDRESS=127.0.0.1` toujours. Le port RCON ne doit **jamais** apparaître dans la section `ports:` de `compose.yaml` — sauf dans le fichier d'override jetable de la Tâche 1.
- **Secrets dans le `.env`** : toujours entre **guillemets simples**. Mesuré : les guillemets doubles interpolent (`"Mot$X"` → `Mot`), et ` #` démarre un commentaire.
- **`stop_grace_period`** : `330s`, strictement supérieur au délai d'arrêt de
  l'entrypoint (`300s`). **Ces valeurs sont issues d'une mesure, pas d'une
  estimation** : la Tâche 1 a chronométré ~220 s entre la commande RCON et la
  sortie du processus serveur. Les valeurs initiales du plan (90 s / 120s)
  auraient fait tuer le serveur avant la fin de sa sauvegarde. Voir la section
  « Risque principal » de la spec pour la limite statistique de cette mesure.
- **Pas de guillemets dans `compose.yaml`** autour des valeurs interpolées : uniquement `${VAR}`.
- **Aucun fichier du volume `vrising-persistent-data/` ni le `.env` ne doit être versionné.**

## Structure des fichiers

| Fichier | Responsabilité |
|---|---|
| `Dockerfile` | Construction de l'image, deux étages. Rien d'autre. |
| `.dockerignore` | Exclut le volume et le `.env` du contexte de build. |
| `docker/entrypoint.sh` | Cycle de vie du conteneur : droits, configuration déclarative, lancement, arrêt propre. Seul script exécuté au démarrage. |
| `compose.yaml` | Câblage : build, ports, volumes, interpolation `${VAR}`, politique de redémarrage. Aucune valeur en dur. |
| `.env.example` | Modèle documenté et versionné de toutes les variables. |
| `.env` | Valeurs réelles. Non versionné. |
| `config/ServerGameSettings.json` | Règles de jeu, override partiel versionné. |
| `tests/verify.sh` | Harnais de vérification : encode le tableau d'acceptation de la spec en assertions exécutables. Grandit à chaque tâche. |
| `README.md` | Procédure de déploiement sur le serveur Debian cible. |

Le harnais `tests/verify.sh` est le cœur du cycle de test. Il n'existe pas de framework de test ici : chaque tâche **ajoute d'abord ses assertions** au harnais, le lance pour constater l'échec, implémente, puis le relance pour constater le succès.

---

### Task 1: Valider l'arrêt propre par RCON

C'est le risque principal identifié par la spec, et la seule pièce non prouvée du design. On y répond **avant** d'investir dans le `Dockerfile`, en réutilisant l'image communautaire déjà téléchargée : le jeu (2 Go) y est présent, et le serveur lit les variables `VR_*` nativement — l'entrypoint de cette image ne passe aucun argument RCON, donc nos variables s'appliquent.

Cette tâche ne produit pas de code de production. Son livrable est **une réponse** et la mise à jour de la section « Risques » de la spec.

**Files:**
- Create: `.tmp/` (répertoire de travail jetable, à ignorer par git)
- Create: `.tmp/rcon-probe.compose.yaml` (override jetable)
- Modify: `docs/superpowers/specs/2026-08-21-vrising-server-stack-design.md` (section « Risque principal »)
- Modify: `.gitignore` (ajouter `.tmp/`)

**Interfaces:**
- Consomme : rien.
- Produit : le **verdict** sur la fiabilité de `shutdown` par RCON, et la **syntaxe exacte** de la commande. La Tâche 7 en dépend directement.

- [ ] **Step 1: Ignorer le répertoire de travail jetable**

```bash
cd /home/aymeric/Documents/vrising
printf '.tmp/\n' >> .gitignore
mkdir -p .tmp
```

- [ ] **Step 2: Compiler mcrcon dans un conteneur jetable**

On compile le binaire réel qui sera utilisé dans l'image finale, pour tester la vraie chose et non un substitut.

```bash
docker run --rm -v "$PWD/.tmp:/out" debian:12-slim sh -c '
set -e
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates gcc make git libc6-dev
git clone --depth 1 --branch v0.7.2 https://github.com/Tiiffi/mcrcon.git /src
make -C /src
cp /src/mcrcon /out/mcrcon
'
chmod +x .tmp/mcrcon
./.tmp/mcrcon -h
```

Attendu : `Usage: mcrcon [OPTIONS] [COMMANDS]` s'affiche, sans erreur de
bibliothèque manquante. (`--version` n'existe pas dans mcrcon : l'invoquer
renvoie « invalid option ».)

- [ ] **Step 3: Écrire l'override jetable qui active RCON**

`VR_RCON_BIND_ADDRESS` est mis à `0.0.0.0` et le port publié **uniquement pour cette sonde** : c'est la seule exception à la contrainte globale, parce que le client de test tourne sur l'hôte.

```bash
cat > .tmp/rcon-probe.compose.yaml <<'EOF'
services:
  vrising:
    environment:
      - VR_RCON_ENABLED=true
      - VR_RCON_PASSWORD=probe-only-password
      - VR_RCON_PORT=25575
      - VR_RCON_BIND_ADDRESS=0.0.0.0
    ports:
      - "127.0.0.1:25575:25575/tcp"
EOF
```

- [ ] **Step 4: Démarrer le serveur avec RCON actif**

```bash
docker compose -f compose.yaml -f .tmp/rcon-probe.compose.yaml up -d
```

- [ ] **Step 5: Attendre le démarrage complet**

```bash
for i in $(seq 1 180); do
  if docker compose logs --since 20s 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -q "Server Setup Complete"; then
    echo "PRET"; break
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' vrising-vrising-1 2>/dev/null)" != "true" ]; then
    echo "CONTENEUR MORT code=$(docker inspect -f '{{.State.ExitCode}}' vrising-vrising-1)"; break
  fi
  sleep 5
done
```

Attendu : `PRET`. Le jeu est déjà téléchargé, donc le démarrage est plus rapide que lors du spike.

- [ ] **Step 6: Vérifier que RCON répond et lire la config effective**

```bash
docker compose logs 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -A6 '"Rcon"'
./.tmp/mcrcon -H 127.0.0.1 -P 25575 -p probe-only-password -c "version"
```

Attendu : le dump montre `"Rcon": { "Enabled": true` — ce qui prouve au passage que les variables `VR_*` sont bien lues nativement. Et mcrcon retourne la version du serveur.

**Point de décision.** Si l'authentification RCON échoue ou si le bloc `Rcon` reste `Enabled: false`, arrêter ici et passer directement au Step 10 (repli).

- [ ] **Step 7: Découvrir la syntaxe exacte de `shutdown`**

La documentation officielle note `shutdown <message times> <message>`, formulation ambiguë. On demande au serveur lui-même plutôt que de deviner.

```bash
./.tmp/mcrcon -H 127.0.0.1 -P 25575 -p probe-only-password -c "help shutdown"
```

Noter la syntaxe retournée : la Tâche 7 l'utilisera littéralement.

- [ ] **Step 8: Déclencher l'arrêt et mesurer**

```bash
./.tmp/mcrcon -H 127.0.0.1 -P 25575 -p probe-only-password \
  -c "announce Test d arret propre" -c "shutdown 1 Test"
for i in $(seq 1 120); do
  R=$(docker inspect -f '{{.State.Running}}' vrising-vrising-1 2>/dev/null)
  [ "$R" != "true" ] && break
  sleep 1
done
echo "running=$(docker inspect -f '{{.State.Running}}' vrising-vrising-1)"
echo "exit=$(docker inspect -f '{{.State.ExitCode}}' vrising-vrising-1)"
docker compose logs --tail 20 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
```

Attendu si RCON fonctionne : le serveur s'arrête de lui-même, les logs montrent une séquence de sauvegarde/arrêt ordonnée. Le code de sortie importe moins ici que **le fait que le serveur se termine sur commande** — c'est cela que la Tâche 7 exploitera.

- [ ] **Step 9: Nettoyer la sonde**

```bash
docker compose -f compose.yaml -f .tmp/rcon-probe.compose.yaml down
```

- [ ] **Step 10: Consigner le verdict dans la spec**

Remplacer le contenu de la section « Risque principal » de la spec par le résultat mesuré. Deux rédactions selon l'issue :

*Si RCON fonctionne* — remplacer le paragraphe commençant par « **L'arrêt propre par RCON est la seule pièce du design non prouvée** » par :

```markdown
**Validé le 2026-08-21 (Tâche 1 du plan).** RCON s'active bien par variable
`VR_*` et le serveur répond à la commande `shutdown`, qui déclenche un arrêt
ordonné. Syntaxe retenue : `<syntaxe relevée au Step 7>`. La Tâche 7 du plan
implémente le trap SIGTERM sur cette base.
```

*Si RCON échoue* — remplacer par :

```markdown
**Invalidé le 2026-08-21 (Tâche 1 du plan).** <symptôme observé>. Le repli
documenté s'applique : l'entrypoint envoie SIGTERM au processus serveur et
attend jusqu'à 300 s, en s'appuyant sur les autosaves (toutes les 120 s) pour
borner la perte. La Tâche 7 est adaptée en conséquence et n'utilise pas RCON.
```

- [ ] **Step 11: Commit**

```bash
git add .gitignore docs/superpowers/specs/2026-08-21-vrising-server-stack-design.md
git commit -m "test: valider l'arret propre par RCON avant implementation

Sonde menee sur l'image communautaire deja telechargee, pour repondre au
risque principal de la spec sans attendre la construction de l'image."
```

---

### Task 2: Étage builder du Dockerfile

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`
- Create: `tests/verify.sh`

**Interfaces:**
- Consomme : rien.
- Produit : un étage nommé `builder` exposant `/game` (fichiers du jeu, contenant `VRisingServer.exe`) et `/usr/local/bin/mcrcon`. La Tâche 3 les récupère par `COPY --from=builder`.

- [ ] **Step 1: Écrire le harnais de vérification avec ses premières assertions**

Le harnais échouera : rien n'est encore construit. C'est voulu.

```bash
mkdir -p tests
cat > tests/verify.sh <<'EOF'
#!/usr/bin/env bash
# Harnais de verification. Chaque tache y ajoute ses assertions.
# Usage: ./tests/verify.sh [nom-de-check-partiel]
set -uo pipefail

FILTER="${1:-}"
PASS=0; FAIL=0

# Retourne 0 (vrai) si le check doit etre saute au vu du filtre.
skip() {
  [ -z "$FILTER" ] && return 1
  case "$1" in *"$FILTER"*) return 1;; *) return 0;; esac
}

check() {
  local name="$1"; shift
  skip "$name" && return 0
  if "$@" >/dev/null 2>&1; then
    printf '  PASS  %s\n' "$name"; PASS=$((PASS+1))
  else
    printf '  FAIL  %s\n' "$name"; FAIL=$((FAIL+1))
  fi
}

# Assertion sur la sortie: check_out <nom> <sous-chaine attendue> <commande...>
check_out() {
  local name="$1" expect="$2"; shift 2
  skip "$name" && return 0
  local out
  out="$("$@" 2>&1)"
  if printf '%s' "$out" | grep -qF -- "$expect"; then
    printf '  PASS  %s\n' "$name"; PASS=$((PASS+1))
  else
    printf '  FAIL  %s (attendu: %s)\n' "$name" "$expect"; FAIL=$((FAIL+1))
  fi
}

echo "== Etage builder =="
check_out "builder: VRisingServer.exe present" "VRisingServer.exe" \
  docker run --rm vrising-builder:test ls /game
# `--version` n'existe pas dans mcrcon : l'invoquer renvoie « invalid option »,
# dont le texte contient « mcrcon » — l'assertion passait donc sans rien prouver.
# `-h` est une invocation valide : elle prouve que le binaire s'execute et
# analyse ses options.
check_out "builder: mcrcon compile" "Usage: mcrcon" \
  docker run --rm vrising-builder:test /usr/local/bin/mcrcon -h

echo
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"

# Un filtre mal orthographie ne doit pas passer pour un succes.
if [ -n "$FILTER" ] && [ $((PASS + FAIL)) -eq 0 ]; then
  printf 'ERREUR: le filtre "%s" ne correspond a aucun check.\n' "$FILTER"
  exit 2
fi

[ "$FAIL" -eq 0 ]
EOF
chmod +x tests/verify.sh
```

- [ ] **Step 2: Lancer le harnais pour constater l'échec**

Run: `./tests/verify.sh builder`
Expected: les deux checks en `FAIL`, sortie non nulle — l'image `vrising-builder:test` n'existe pas.

- [ ] **Step 3: Écrire le `.dockerignore`**

```bash
cat > .dockerignore <<'EOF'
.git
.tmp
.env
vrising-persistent-data
docs
tests
README.md
EOF
```

- [ ] **Step 4: Écrire l'étage builder**

Le `test -f` final est l'assertion qui compte : la boucle de reprise existe parce que l'erreur `Failed to install app '1829350' (Missing configuration)` a été **réellement observée** lors du spike.

```dockerfile
# syntax=docker/dockerfile:1

########################################
# Etage builder : jetable
########################################
FROM debian:12-slim AS builder

ARG STEAM_APP_ID=1829350
ARG MCRCON_REF=v0.7.2

# libc6-dev est explicite et NECESSAIRE : sous --no-install-recommends, gcc
# seul ne l'entraine pas, et la compilation de mcrcon echoue sur
# "stdio.h: No such file or directory" (constate en Tache 1). Ne pas retirer.

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl gcc make git libc6-dev lib32gcc-s1 \
 && rm -rf /var/lib/apt/lists/*

# steamcmd
RUN mkdir -p /opt/steamcmd \
 && curl -sSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    | tar -xz -C /opt/steamcmd

# Fichiers du jeu. Reprise sur echec : l'erreur "Missing configuration" de
# steamcmd a ete observee en conditions reelles au premier appel.
RUN for i in 1 2 3; do \
      /opt/steamcmd/steamcmd.sh \
        +@sSteamCmdForcePlatformType windows \
        +force_install_dir /game \
        +login anonymous \
        +app_update ${STEAM_APP_ID} validate \
        +quit && break; \
      echo "steamcmd: tentative $i echouee, nouvelle tentative dans 15s"; \
      sleep 15; \
    done; \
    test -f /game/VRisingServer.exe

# Client RCON, utilise par l'entrypoint pour l'arret propre
RUN git clone --depth 1 --branch ${MCRCON_REF} \
      https://github.com/Tiiffi/mcrcon.git /src/mcrcon \
 && make -C /src/mcrcon \
 && install -m 0755 /src/mcrcon/mcrcon /usr/local/bin/mcrcon
```

- [ ] **Step 5: Construire l'étage builder**

Long : environ 2 Go à télécharger.

Run: `docker build --target builder -t vrising-builder:test .`
Expected: build réussi. Si `test -f /game/VRisingServer.exe` échoue, les trois tentatives steamcmd ont échoué — relancer le build.

- [ ] **Step 6: Lancer le harnais pour constater le succès**

Run: `./tests/verify.sh builder`
Expected: `PASS=2 FAIL=0`, sortie nulle.

- [ ] **Step 7: Commit**

```bash
git add Dockerfile .dockerignore tests/verify.sh
git commit -m "feat: etage builder du Dockerfile (jeu + mcrcon)

Telechargement anonyme de l'AppID 1829350 selon la methode officielle
Stunlock, avec reprise sur l'erreur Missing configuration observee au spike.
mcrcon v0.7.2 compile pour l'arret propre."
```

---

### Task 3: Étage runtime du Dockerfile

**Files:**
- Modify: `Dockerfile` (ajout de l'étage `runtime`)
- Modify: `tests/verify.sh` (nouvelles assertions)

**Interfaces:**
- Consomme : l'étage `builder` (`/game`, `/usr/local/bin/mcrcon`).
- Produit : l'image finale. Chemins fixés dont les tâches suivantes dépendent :
  - jeu : `/opt/vrising/game/VRisingServer.exe`
  - préfixe Wine : `/opt/vrising/.wine` (variable `WINEPREFIX`)
  - volume de données : `/opt/vrising/save-data`
  - utilisateur interne : `vrising`, uid/gid **fixes** `10000`
  - `mcrcon` sur le `PATH`
  - `pgrep` disponible (paquet `procps`), requis par l'assertion non-root de la
    Tâche 5

**Décision d'architecture à respecter.** L'uid interne est **fixe** (`10000`) et non un `ARG` de build, parce que la spec exige `PUID`/`PGID` configurables **au runtime** : un `ARG` imposerait un rebuild à chaque changement. L'entrypoint (Tâche 5) ajustera les droits au démarrage. Le répertoire du jeu reste `root:root` en mode `755` : il est uniquement lu, jamais écrit (les écritures vont dans `-persistentDataPath`), ce qui évite un `chown -R` de 2 Go à chaque démarrage.

- [ ] **Step 1: Ajouter les assertions du runtime au harnais**

Insérer avant la ligne `printf 'PASS=%d FAIL=%d\n'` :

```bash
echo
echo "== Etage runtime =="
# --entrypoint est obligatoire : la Tache 5 ajoute un ENTRYPOINT qui ignore
# les arguments, ces checks casseraient sinon des la Tache 5.
check_out "runtime: wine epingle en 10.0" "wine-10.0" \
  docker run --rm --entrypoint wine vrising-server:local --version
check_out "runtime: jeu present" "VRisingServer.exe" \
  docker run --rm --entrypoint ls vrising-server:local /opt/vrising/game
check_out "runtime: mcrcon present" "Usage: mcrcon" \
  docker run --rm --entrypoint mcrcon vrising-server:local -h
check_out "runtime: prefixe Wine initialise" "system.reg" \
  docker run --rm --entrypoint ls vrising-server:local /opt/vrising/.wine
check_out "runtime: utilisateur vrising en uid 10000" "uid=10000" \
  docker run --rm --entrypoint id vrising-server:local vrising
# `command -v steamcmd` est INTROUVABLE meme dans le builder, ou steamcmd
# existe pourtant a /opt/steamcmd/steamcmd.sh : il n'est jamais sur le PATH.
# L'assertion passait donc dans les DEUX images sans rien discriminer. On teste
# le chemin d'installation reel, verifie present dans le builder et absent ici.
check "runtime: steamcmd absent de l'image finale" \
  sh -c '! docker run --rm --entrypoint sh vrising-server:local -c "ls -d /opt/steamcmd"'
# NOTE: ces deux assertions par negation sont DURCIES au Step 1 de la Tache 4
# (`check_absent`) — une negation confond « absent » et « sonde cassee ».
# L'outillage de compilation ne doit pas non plus avoir survecu a COPY --from.
check "runtime: outillage de build absent" \
  sh -c '! docker run --rm --entrypoint sh vrising-server:local -c "command -v gcc || command -v make || command -v git"'
check_out "runtime: prefixe Wine possede par vrising" "10000" \
  docker run --rm --entrypoint stat vrising-server:local -c %u /opt/vrising/.wine
```

- [ ] **Step 2: Lancer le harnais pour constater l'échec**

Run: `./tests/verify.sh runtime`
Expected: les 7 checks en `FAIL` — l'image `vrising-server:local` n'existe pas.

- [ ] **Step 3: Écrire l'étage runtime**

Ajouter à la fin du `Dockerfile`. Noter l'incantation apt : les quatre paquets sont nommés explicitement, la forme naïve échoue en `unmet dependencies`.

```dockerfile

########################################
# Etage runtime : image finale
########################################
FROM debian:12-slim AS runtime

ARG WINE_VERSION=10.0.0.0~bookworm-1
ARG RUNTIME_UID=10000
ARG RUNTIME_GID=10000

# procps fournit pgrep, dont l'assertion « processus serveur non-root » de la
# Tache 5 a besoin, et donne a l'exploitant un `ps` utilisable pour diagnostiquer
# en production. debian:12-slim ne l'inclut pas.

ENV WINEPREFIX=/opt/vrising/.wine \
    WINEDEBUG=-all \
    HOME=/opt/vrising \
    DISPLAY=:1

# Wine depuis le depot officiel WineHQ. Les quatre paquets doivent etre nommes
# explicitement : wine-stable (amd64) depend de wine-stable-i386, qui n'existe
# qu'en i386, et le resolveur apt echoue si on ne pinne que winehq-stable.
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates wget xvfb tzdata procps \
 && mkdir -pm755 /etc/apt/keyrings \
 && wget -q -O /etc/apt/keyrings/winehq-archive.key \
      https://dl.winehq.org/wine-builds/winehq.key \
 && wget -qNP /etc/apt/sources.list.d/ \
      https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      winehq-stable=${WINE_VERSION} \
      wine-stable=${WINE_VERSION} \
      wine-stable-amd64=${WINE_VERSION} \
      wine-stable-i386:i386=${WINE_VERSION} \
 && rm -rf /var/lib/apt/lists/*

# Utilisateur non-root a uid FIXE. PUID/PGID sont ajustes au runtime par
# l'entrypoint : un ARG de build imposerait un rebuild a chaque changement.
RUN groupadd -g ${RUNTIME_GID} vrising \
 && useradd -u ${RUNTIME_UID} -g ${RUNTIME_GID} -d /opt/vrising -M -s /usr/sbin/nologin vrising \
 && install -d -o root -g root -m 0755 /opt/vrising \
 && install -d -o ${RUNTIME_UID} -g ${RUNTIME_GID} -m 0755 /opt/vrising/save-data

# Le jeu reste root:root 755 : lu seulement, jamais ecrit (les ecritures vont
# dans -persistentDataPath). Evite un chown -R de 2 Go a chaque demarrage.
COPY --from=builder /game /opt/vrising/game
COPY --from=builder /usr/local/bin/mcrcon /usr/local/bin/mcrcon

# Prefixe Wine initialise au build, pour qu'aucun premier demarrage ne paie
# cette latence.
RUN install -d -o ${RUNTIME_UID} -g ${RUNTIME_GID} -m 0755 ${WINEPREFIX} \
 && setpriv --reuid ${RUNTIME_UID} --regid ${RUNTIME_GID} --clear-groups \
      env HOME=/opt/vrising WINEPREFIX=${WINEPREFIX} WINEDEBUG=-all \
      wineboot --init \
 && setpriv --reuid ${RUNTIME_UID} --regid ${RUNTIME_GID} --clear-groups \
      env HOME=/opt/vrising WINEPREFIX=${WINEPREFIX} \
      wineserver -w \
 && test -f ${WINEPREFIX}/system.reg

VOLUME ["/opt/vrising/save-data"]
```

- [ ] **Step 4: Construire l'image complète**

Run: `docker build -t vrising-server:local .`
Expected: build réussi. L'étage `builder` est en cache, seul le runtime est construit.

Si `wineboot --init` échoue faute de display, ajouter `xvfb-run -a` devant : `xvfb-run -a wineboot --init`.

- [ ] **Step 5: Lancer le harnais**

Run: `./tests/verify.sh runtime`
Expected: `PASS=7 FAIL=0` sur le filtre runtime.

- [ ] **Step 6: Constater la taille réelle et vérifier ce que le multi-étages apporte vraiment**

```bash
docker system df -v 2>/dev/null | grep -E "^vrising|REPOSITORY"
```

**Ne compare pas la taille du runtime à celle du builder** : le builder ne
contient pas Wine, la comparaison ne mesurerait rien. Mesuré en pratique, le
runtime est *plus gros* que le builder (7,42 Go contre 3,23 Go), parce que Wine
tire ~180 paquets i386 et que le préfixe initialisé pèse ~1,45 Go de DLL WoW64.

Ce que le multi-étages apporte réellement est vérifié par les deux assertions du
harnais : **steamcmd et l'outillage de compilation sont absents de l'image
finale**. C'est cela le bénéfice — une surface réduite, pas une image petite.

Note l'ordre de grandeur pour la documentation de déploiement (Tâche 8) : image
finale ~7,4 Go, et un cache de build d'environ 10 Go qui reste sur le disque.

- [ ] **Step 7: Commit**

```bash
git add Dockerfile tests/verify.sh
git commit -m "feat: etage runtime du Dockerfile (Wine epingle, non-root)

winehq-stable 10.0.0.0~bookworm-1, la version prouvee au spike. Les quatre
paquets sont nommes explicitement car le resolveur apt echoue sinon sur la
dependance multiarch wine-stable-i386. Utilisateur a uid fixe 10000, ajuste
au runtime par l'entrypoint. Prefixe Wine initialise au build."
```

---

### Task 4: Configuration — .env.example et compose.yaml

**Files:**
- Create: `.env.example`
- Create: `.env` (copie locale, non versionnée)
- Create: `config/ServerGameSettings.json`
- Modify: `compose.yaml` (réécriture complète)
- Modify: `tests/verify.sh`

**Interfaces:**
- Consomme : l'image `vrising-server:local` (Tâche 3).
- Produit : le service compose `vrising`, le conteneur `vrising-vrising-1`, et le contrat de variables que l'entrypoint (Tâches 5-7) consomme : `PUID`, `PGID`, `VRISING_ADMINS`, `VRISING_BANS`, `RCON_PASSWORD`, `SHUTDOWN_TIMEOUT`, plus toutes les `VR_*`.

- [ ] **Step 1: Durcir le harnais — remplacer les assertions par négation**

Les Tâches 2 et 3 ont introduit des assertions de la forme
`check "..." sh -c '! docker run ...'`. Elles sont **structurellement
fragiles** : si `docker run` échoue pour une cause étrangère au fait testé
(image mal nommée, démon arrêté, entrypoint cassé), la négation transforme cet
échec en `PASS`. C'est la mécanique qui a produit quatre faux positifs sur ce
projet.

Ajoute cet assistant dans `tests/verify.sh`, juste après `check_out` :

```bash
# check_absent <nom> <commande...>
# Pour affirmer qu'une chose est ABSENTE. La sonde doit s'executer ET ne rien
# trouver. Codes de sortie MESURES sur ce projet :
#   0        la chose existe            => FAIL
#   1        elle est absente           => PASS
#   125/127  la sonde n'a pas tourne    => FAIL, jamais un faux PASS
# Une negation `! cmd` confondrait les deux derniers cas.
check_absent() {
  local name="$1"; shift
  skip "$name" && return 0
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  case "$rc" in
    0) printf '  FAIL  %s (present alors qu attendu absent)\n' "$name"
       FAIL=$((FAIL+1)) ;;
    1) printf '  PASS  %s\n' "$name"; PASS=$((PASS+1)) ;;
    *) printf '  FAIL  %s (sonde inexploitable, exit %s: %s)\n' \
         "$name" "$rc" "$(printf '%s' "$out" | head -1)"
       FAIL=$((FAIL+1)) ;;
  esac
}
```

Puis remplace les deux assertions de la Tâche 3. Les sondes doivent rendre un
code **déterministe** — `test -e` et la boucle `for` ci-dessous rendent 0 ou 1,
là où `command -v gcc || command -v make || command -v git` rendait 127 quand
rien n'est trouvé, exactement comme un entrypoint cassé :

```bash
check_absent "runtime: steamcmd absent de l'image finale" \
  docker run --rm --entrypoint test vrising-server:local -e /opt/steamcmd
check_absent "runtime: outillage de build absent" \
  docker run --rm --entrypoint sh vrising-server:local -c \
    'for b in gcc make git; do command -v "$b" >/dev/null 2>&1 && exit 0; done; exit 1'
```

Remplace de même l'assertion « config: port RCON jamais publie » du Step 3,
qui souffre du même défaut.

- [ ] **Step 2: Vérifier que le durcissement discrimine**

```bash
# Doit ECHOUER : /opt/steamcmd existe dans le builder
docker run --rm --entrypoint test vrising-builder:test -e /opt/steamcmd; echo "exit=$? (0 attendu)"
# Doit PASSER : absent du runtime
docker run --rm --entrypoint test vrising-server:local -e /opt/steamcmd; echo "exit=$? (1 attendu)"
# Sonde inexploitable : ni 0 ni 1
docker run --rm --entrypoint /absent vrising-server:local; echo "exit=$? (127 attendu)"
./tests/verify.sh runtime
```

Attendu : les trois codes de sortie conformes, et `./tests/verify.sh runtime`
toujours vert.

- [ ] **Step 3: Ajouter les assertions de configuration au harnais**

```bash
echo
echo "== Configuration =="
check_out "config: nom sans guillemets parasites" "VR_SERVER_NAME: Serveur de test" \
  docker compose config
check_out "config: port de jeu 27015" "target: 27015" docker compose config
check_out "config: port de requete 27016" "target: 27016" docker compose config
check "config: ports jeu et requete distincts" \
  sh -c 'test "$(docker compose config | grep -c "target: 2701[56]")" -eq 2'
check_out "config: politique de redemarrage" "restart: unless-stopped" docker compose config
check_out "config: delai de grace 330s" "stop_grace_period: 5m30s" docker compose config
# `grep -q` rend 1 quand rien n'est trouve : sonde deterministe, donc
# check_absent discrimine correctement une vraie absence d'un echec de sonde.
check_absent "config: port RCON jamais publie" \
  sh -c 'docker compose config | grep -q "25575"'
check "config: regles de jeu montees en lecture seule" \
  sh -c 'docker compose config | grep -q "read_only: true"'
```

- [ ] **Step 4: Lancer le harnais pour constater l'échec**

Run: `./tests/verify.sh config`
Expected: tous les checks en `FAIL` — `compose.yaml` est encore l'ancien fichier.

- [ ] **Step 5: Écrire le `.env.example`**

Les valeurs par défaut reprennent celles constatées dans le dump de configuration effective du serveur lors du spike.

```bash
cat > .env.example <<'EOF'
# =============================================================================
# Configuration du serveur V Rising
#
# REGLE IMPORTANTE SUR LES GUILLEMETS, mesuree et verifiee :
#   VR_PASSWORD='Mot$DePasse'   -> Mot$DePasse   CORRECT (guillemets simples)
#   VR_PASSWORD=Mot$$DePasse    -> Mot$DePasse   correct (echappement)
#   VR_PASSWORD="Mot$DePasse"   -> Mot          FAUX : les guillemets doubles
#                                                interpolent la variable
#   VR_PASSWORD=Mot123 #note    -> Mot123       FAUX : " #" ouvre un commentaire
#
# En resume : TOUT SECRET S'ECRIT ENTRE GUILLEMETS SIMPLES.
# =============================================================================

# --- Identite visible des joueurs -------------------------------------------
VR_SERVER_NAME='Serveur de test'
VR_DESCRIPTION='Un serveur V Rising'
# A CHANGER IMPERATIVEMENT avant toute mise en service.
VR_PASSWORD='ChangeMoi'

# --- Reseau -----------------------------------------------------------------
# Ces deux ports DOIVENT rester distincts.
VR_GAME_PORT=27015
VR_QUERY_PORT=27016
VR_BIND_ADDRESS=0.0.0.0

# --- Visibilite -------------------------------------------------------------
VR_LIST_ON_EOS=true
VR_LIST_ON_STEAM=false
VR_HIDE_IP_ADDRESS=true
VR_SECURE=true

# --- Capacite et performance ------------------------------------------------
VR_MAX_USERS=40
VR_LOWER_FPS_WHEN_EMPTY=true

# --- Sauvegardes internes du serveur ----------------------------------------
VR_SAVE_NAME=vrising_world
VR_SAVE_COUNT=20
VR_SAVE_INTERVAL=120

# --- Regles de jeu ----------------------------------------------------------
# DOIT RESTER VIDE si config/ServerGameSettings.json est utilise : un preset
# non vide charge ses propres regles A LA PLACE des tiennes.
VR_PRESET=
VR_DIFFICULTY_PRESET=

# --- Specifique a cette image (pas des variables du jeu) --------------------
# Proprietaire des fichiers de sauvegarde sur l'hote. Mettre l'uid/gid de ton
# compte : `id -u` et `id -g`.
PUID=1000
PGID=1000

# SteamID64 des administrateurs, separes par des virgules. Reecrit
# adminlist.txt a chaque demarrage.
VRISING_ADMINS=

# SteamID64 bannis, separes par des virgules. N'AMORCE banlist.txt que si le
# fichier est absent : les bans faits en jeu ne sont jamais ecrases.
VRISING_BANS=

# RCON, interne au conteneur uniquement, sert a l'arret propre. Obligatoire.
RCON_PASSWORD='ChangeMoiAussi'

# Delai maximal accorde a l'arret ordonne, en secondes. Doit rester inferieur
# au stop_grace_period de compose.yaml (330s). La Tache 1 a mesure ~220s pour
# un arret ordonne complet : ne pas descendre sous 300 sans nouvelle mesure.
SHUTDOWN_TIMEOUT=300

TZ=Europe/Paris
EOF
cp .env.example .env
```

- [ ] **Step 6: Écrire les règles de jeu**

Override **partiel** : uniquement les écarts par rapport aux défauts du jeu, comme la documentation officielle l'autorise. `GameModeType` à `1` correspond à la valeur observée par défaut lors du spike ; l'ajuster selon le mode souhaité.

```bash
mkdir -p config
cat > config/ServerGameSettings.json <<'EOF'
{
  "GameModeType": 1,
  "CastleDamageMode": 2,
  "PlayerDamageMode": 1,
  "VSCompetitiveMode": false,
  "InactivityKillEnabled": true,
  "ClanSize": 4,
  "InventoryStacksModifier": 1.0,
  "MaterialYieldModifier_Global": 1.5,
  "UnitStatModifier_Global": 1.0
}
EOF
```

- [ ] **Step 7: Réécrire le `compose.yaml`**

Aucune valeur en dur, aucun guillemet autour des interpolations, port RCON absent.

```bash
cat > compose.yaml <<'EOF'
services:
  vrising:
    build:
      context: .
      dockerfile: Dockerfile
    image: vrising-server:local
    restart: unless-stopped
    # Strictement superieur au SHUTDOWN_TIMEOUT de l'entrypoint (300s), pour que
    # Docker ne tue jamais le conteneur avant la fin de l'arret ordonne.
    # ~220s mesures en Tache 1 ; la marge couvre un serveur peuple.
    stop_grace_period: 330s
    ports:
      - "${VR_GAME_PORT}:${VR_GAME_PORT}/udp"
      - "${VR_QUERY_PORT}:${VR_QUERY_PORT}/udp"
    environment:
      VR_SERVER_NAME: ${VR_SERVER_NAME}
      VR_DESCRIPTION: ${VR_DESCRIPTION}
      VR_PASSWORD: ${VR_PASSWORD}
      VR_GAME_PORT: ${VR_GAME_PORT}
      VR_QUERY_PORT: ${VR_QUERY_PORT}
      VR_BIND_ADDRESS: ${VR_BIND_ADDRESS}
      VR_LIST_ON_EOS: ${VR_LIST_ON_EOS}
      VR_LIST_ON_STEAM: ${VR_LIST_ON_STEAM}
      VR_HIDE_IP_ADDRESS: ${VR_HIDE_IP_ADDRESS}
      VR_SECURE: ${VR_SECURE}
      VR_MAX_USERS: ${VR_MAX_USERS}
      VR_LOWER_FPS_WHEN_EMPTY: ${VR_LOWER_FPS_WHEN_EMPTY}
      VR_SAVE_NAME: ${VR_SAVE_NAME}
      VR_SAVE_COUNT: ${VR_SAVE_COUNT}
      VR_SAVE_INTERVAL: ${VR_SAVE_INTERVAL}
      VR_PRESET: ${VR_PRESET}
      VR_DIFFICULTY_PRESET: ${VR_DIFFICULTY_PRESET}
      PUID: ${PUID}
      PGID: ${PGID}
      VRISING_ADMINS: ${VRISING_ADMINS}
      VRISING_BANS: ${VRISING_BANS}
      RCON_PASSWORD: ${RCON_PASSWORD}
      SHUTDOWN_TIMEOUT: ${SHUTDOWN_TIMEOUT}
      TZ: ${TZ}
    volumes:
      - ./vrising-persistent-data:/opt/vrising/save-data
      - type: bind
        source: ./config/ServerGameSettings.json
        target: /config/ServerGameSettings.json
        read_only: true
EOF
```

- [ ] **Step 8: Lancer le harnais**

Run: `./tests/verify.sh config`
Expected: `PASS=8 FAIL=0`.

Ce test prouve la correction du défaut n°1 de la spec : `VR_SERVER_NAME: Serveur de test`, **sans** guillemets parasites — à comparer au `'"VRising Containerized"'` mesuré sur l'ancien fichier.

- [ ] **Step 9: Commit**

```bash
git add .env.example compose.yaml config/ServerGameSettings.json tests/verify.sh
git commit -m "feat: configuration externalisee en .env

Reecriture du compose sans aucune valeur en dur ni guillemet autour des
interpolations, ce qui elimine a la racine le bug de guillemets inclus dans
les valeurs. Ports 27015/27016 desormais distincts, restart unless-stopped,
stop_grace_period a 330s. Regles de jeu en override partiel versionne."
```

---

### Task 5: Entrypoint — démarrage du serveur

**Files:**
- Create: `docker/entrypoint.sh`
- Modify: `Dockerfile` (copie de l'entrypoint, directive `ENTRYPOINT`)
- Modify: `tests/verify.sh`

**Interfaces:**
- Consomme : les variables du contrat de la Tâche 4, et les chemins de la Tâche 3.
- Produit : la fonction shell `log()`, les variables internes `DATA`, `GAME`, `PREFIX`, `SRV_PID`, `XVFB_PID`, `GRACE`. Les Tâches 6 et 7 étendent **ce même fichier** et réutilisent ces noms.

- [ ] **Step 1: Ajouter les assertions de démarrage au harnais**

```bash
echo
echo "== Demarrage =="
check_out "demarrage: serveur pret" "Server Setup Complete" \
  sh -c 'docker compose logs 2>&1 | sed "s/\x1b\[[0-9;]*m//g"'
check_out "demarrage: nom effectif sans guillemets" '"Name": "Serveur de test"' \
  sh -c 'docker compose logs 2>&1 | sed "s/\x1b\[[0-9;]*m//g"'
check_out "demarrage: port de jeu effectif" '"Port": 27015' \
  sh -c 'docker compose logs 2>&1 | sed "s/\x1b\[[0-9;]*m//g"'
check_out "demarrage: port de requete effectif" '"QueryPort": 27016' \
  sh -c 'docker compose logs 2>&1 | sed "s/\x1b\[[0-9;]*m//g"'
check "demarrage: volume possede par PUID et non root" \
  sh -c 'test "$(stat -c %u vrising-persistent-data/Settings)" = "$(. ./.env; echo $PUID)"'
# Assertion POSITIVE et non negative. La forme negative initialement prevue
# (`! ps ... | grep -q root`) etait un faux positif : si `ps` echouait, `grep` ne
# trouvait rien et la negation rendait vrai — le check passait sans rien prouver.
# On lit donc l'uid reel et on exige qu'il vaille PUID.
# `pgrep -f` et non `ps -C` : "VRisingServer.exe" fait 17 caracteres alors que
# `comm` est tronque a 15, donc `ps -C VRisingServer.exe` ne matcherait jamais.
# Si le processus est absent, la sortie est vide et le check ECHOUE — ce qui est
# le comportement voulu.
PUID_ATTENDU=$(. ./.env 2>/dev/null; echo "${PUID:-1000}")
check_out "demarrage: processus serveur sous PUID (non root)" "uid=$PUID_ATTENDU" \
  docker compose exec -T vrising sh -c \
    'pid=$(pgrep -f VRisingServer.exe | head -1); [ -n "$pid" ] && sed -n "s/^Uid:[[:space:]]*\([0-9]*\).*/uid=\1/p" /proc/$pid/status'
```

- [ ] **Step 2: Lancer le harnais pour constater l'échec**

Run: `./tests/verify.sh demarrage`
Expected: tous en `FAIL` — aucun conteneur ne tourne.

- [ ] **Step 3: Écrire l'entrypoint**

Le serveur est lancé **en arrière-plan** et non par `exec` : c'est la condition nécessaire pour que la Tâche 7 puisse intercepter SIGTERM. C'est précisément ce que l'image communautaire ne faisait pas, d'où son `exit 137`.

```bash
mkdir -p docker
cat > docker/entrypoint.sh <<'EOF'
#!/usr/bin/env bash
# Cycle de vie du conteneur serveur V Rising.
# Reste PID 1 et lance le serveur en arriere-plan, afin de pouvoir intercepter
# SIGTERM et declencher un arret ordonne.
set -uo pipefail

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
GRACE="${SHUTDOWN_TIMEOUT:-300}"

DATA=/opt/vrising/save-data
GAME=/opt/vrising/game
PREFIX="${WINEPREFIX:-/opt/vrising/.wine}"

log() { printf '%s [entrypoint] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# --- Droits -----------------------------------------------------------------
# Le repertoire du jeu reste root:root et n'est jamais chowne : 2 Go lus
# seulement. Seuls le volume de donnees et le prefixe Wine doivent appartenir
# a PUID/PGID.
log "ajustement des droits vers ${PUID}:${PGID}"
install -d -o "$PUID" -g "$PGID" -m 0755 "$DATA" "$DATA/Settings" "$DATA/Saves"
chown "$PUID:$PGID" "$DATA" "$DATA/Settings" "$DATA/Saves"

if [ "$(stat -c %u "$PREFIX")" != "$PUID" ]; then
  log "reattribution du prefixe Wine a ${PUID}:${PGID}"
  chown -R "$PUID:$PGID" "$PREFIX"
fi

# --- Serveur ----------------------------------------------------------------
log "demarrage de Xvfb"
Xvfb :1 -screen 0 1024x768x16 >/dev/null 2>&1 &
XVFB_PID=$!

log "lancement du serveur V Rising"
setpriv --reuid "$PUID" --regid "$PGID" --clear-groups \
  env HOME=/opt/vrising \
      WINEPREFIX="$PREFIX" \
      WINEDEBUG=-all \
      DISPLAY=:1 \
  wine "$GAME/VRisingServer.exe" \
      -batchmode \
      -nographics \
      -persistentDataPath "$DATA" \
      -logFile /dev/stdout &
SRV_PID=$!
log "serveur lance (pid ${SRV_PID})"

# `wait` est interrompu par les signaux : on boucle jusqu'a la sortie reelle.
while kill -0 "$SRV_PID" 2>/dev/null; do
  wait "$SRV_PID"; RC=$?
done
log "le serveur s'est termine (code ${RC:-0})"
kill "$XVFB_PID" 2>/dev/null || true
exit "${RC:-0}"
EOF
chmod +x docker/entrypoint.sh
```

- [ ] **Step 4: Câbler l'entrypoint dans le Dockerfile**

Ajouter à la fin de l'étage `runtime` :

```dockerfile

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 5: Reconstruire et démarrer**

```bash
docker compose build
docker compose up -d
for i in $(seq 1 180); do
  docker compose logs --since 20s 2>&1 | grep -q "Server Setup Complete" && { echo PRET; break; }
  [ "$(docker inspect -f '{{.State.Running}}' vrising-vrising-1 2>/dev/null)" != "true" ] && { echo MORT; break; }
  sleep 5
done
```

Expected: `PRET`.

Si les logs du serveur n'apparaissent pas, `-logFile /dev/stdout` est refusé au processus non-root. Repli : faire écrire le serveur dans `"$DATA/../server.log"` et ajouter `tail -F` de ce fichier en arrière-plan avant le lancement.

- [ ] **Step 6: Lancer le harnais**

Run: `./tests/verify.sh demarrage`
Expected: `PASS=6 FAIL=0`.

Ces checks prouvent trois corrections d'un coup : nom effectif sans guillemets (défaut n°1), ports distincts (défaut n°2), et fichiers possédés par `PUID` au lieu de `root:root`.

- [ ] **Step 7: Commit**

```bash
git add docker/entrypoint.sh Dockerfile tests/verify.sh
git commit -m "feat: entrypoint de demarrage, serveur non-root

L'entrypoint reste PID 1 et lance le serveur en arriere-plan au lieu d'exec,
condition necessaire a l'interception de SIGTERM. Droits du volume et du
prefixe Wine ajustes vers PUID/PGID ; le repertoire du jeu reste root et n'est
jamais chowne."
```

---

### Task 6: Entrypoint — configuration déclarative

**Files:**
- Modify: `docker/entrypoint.sh`
- Modify: `tests/verify.sh`

**Interfaces:**
- Consomme : `log()`, `DATA`, `PUID`, `PGID` de la Tâche 5 ; `VRISING_ADMINS`, `VRISING_BANS` de la Tâche 4.
- Produit : `$DATA/Settings/adminlist.txt`, `$DATA/Settings/banlist.txt`, `$DATA/Settings/ServerGameSettings.json`.

**Règle de conception à respecter.** `adminlist.txt` est **déclaratif** : réécrit à chaque démarrage depuis le `.env`. `banlist.txt` appartient au **serveur**, qui l'écrit lors d'un bannissement en jeu : le `.env` ne fait que l'amorcer si le fichier est absent. Les écraser tous les deux détruirait des données opérationnelles.

- [ ] **Step 1: Ajouter les assertions au harnais**

```bash
echo
echo "== Configuration declarative =="
check_out "declaratif: adminlist contient le SteamID" "76561198000000000" \
  cat vrising-persistent-data/Settings/adminlist.txt
check_out "declaratif: regles de jeu appliquees" '"MaterialYieldModifier_Global": 1.5' \
  sh -c 'docker compose logs 2>&1 | sed "s/\x1b\[[0-9;]*m//g"'
check_out "declaratif: taille de clan appliquee" '"ClanSize": 4' \
  sh -c 'docker compose logs 2>&1 | sed "s/\x1b\[[0-9;]*m//g"'
check "declaratif: banlist survit a un redemarrage" \
  sh -c '
    # Pas de sudo : depuis la Tache 5 le fichier appartient a PUID.
    echo 76561198999999999 >> vrising-persistent-data/Settings/banlist.txt
    docker compose restart >/dev/null 2>&1
    sleep 20
    grep -q 76561198999999999 vrising-persistent-data/Settings/banlist.txt
  '
```

- [ ] **Step 2: Renseigner un SteamID de test dans le `.env`**

```bash
sed -i "s/^VRISING_ADMINS=.*/VRISING_ADMINS=76561198000000000/" .env
grep VRISING_ADMINS .env
```

- [ ] **Step 3: Lancer le harnais pour constater l'échec**

Run: `./tests/verify.sh declaratif`
Expected: tous en `FAIL` — l'entrypoint ne rend encore aucune configuration.

- [ ] **Step 4: Insérer le rendu de configuration dans l'entrypoint**

Insérer dans `docker/entrypoint.sh` entre le bloc `# --- Droits ---` et le bloc `# --- Serveur ---` :

```bash
# --- Configuration declarative ----------------------------------------------
# adminlist : declaratif. Reecrit a chaque demarrage depuis le .env, car les
# administrateurs relevent de la configuration d'infrastructure.
: > "$DATA/Settings/adminlist.txt"
if [ -n "${VRISING_ADMINS:-}" ]; then
  printf '%s' "$VRISING_ADMINS" \
    | tr ',' '\n' \
    | tr -d '[:space:]' \
    | grep -E '^[0-9]{17}$' \
    >> "$DATA/Settings/adminlist.txt" || true
fi
chown "$PUID:$PGID" "$DATA/Settings/adminlist.txt"
log "adminlist: $(wc -l < "$DATA/Settings/adminlist.txt") entree(s)"

# banlist : propriete du serveur, qui l'ecrit lors d'un bannissement en jeu.
# Le .env ne fait que l'amorcer si le fichier est absent. L'ecraser detruirait
# les bans operationnels.
if [ ! -f "$DATA/Settings/banlist.txt" ]; then
  : > "$DATA/Settings/banlist.txt"
  if [ -n "${VRISING_BANS:-}" ]; then
    printf '%s' "$VRISING_BANS" \
      | tr ',' '\n' \
      | tr -d '[:space:]' \
      | grep -E '^[0-9]{17}$' \
      >> "$DATA/Settings/banlist.txt" || true
  fi
  chown "$PUID:$PGID" "$DATA/Settings/banlist.txt"
  log "banlist amorcee: $(wc -l < "$DATA/Settings/banlist.txt") entree(s)"
else
  log "banlist existante conservee ($(wc -l < "$DATA/Settings/banlist.txt") entree(s))"
fi

# Regles de jeu : declaratives. Le fichier versionne est seul maitre et ecrase
# la cible a chaque demarrage. Le serveur n'ecrit jamais dans ce fichier.
if [ -f /config/ServerGameSettings.json ]; then
  cp /config/ServerGameSettings.json "$DATA/Settings/ServerGameSettings.json"
  chown "$PUID:$PGID" "$DATA/Settings/ServerGameSettings.json"
  log "regles de jeu appliquees depuis /config/ServerGameSettings.json"
else
  log "aucun /config/ServerGameSettings.json : defauts du jeu conserves"
fi
```

- [ ] **Step 5: Reconstruire, redémarrer, vérifier**

```bash
docker compose up -d --build
for i in $(seq 1 180); do
  docker compose logs --since 20s 2>&1 | grep -q "Server Setup Complete" && { echo PRET; break; }
  sleep 5
done
```

Run: `./tests/verify.sh declaratif`
Expected: `PASS=4 FAIL=0`.

- [ ] **Step 6: Commit**

```bash
git add docker/entrypoint.sh tests/verify.sh
git commit -m "feat: configuration declarative adminlist, banlist, regles de jeu

adminlist est reecrite depuis le .env a chaque demarrage. banlist n'est
amorcee que si absente, car le serveur l'ecrit lui-meme lors d'un
bannissement en jeu : l'ecraser detruirait des donnees operationnelles."
```

---

### Task 7: Entrypoint — arrêt propre

C'est la tâche qui corrige le défaut n°4 de la spec, le `exit 137` mesuré. Elle **dépend du verdict de la Tâche 1** : appliquer la variante A si RCON a été validé, la variante B sinon.

**Files:**
- Modify: `docker/entrypoint.sh`
- Modify: `tests/verify.sh`

**Interfaces:**
- Consomme : `log()`, `SRV_PID`, `XVFB_PID`, `GRACE` de la Tâche 5 ; `RCON_PASSWORD` de la Tâche 4 ; la syntaxe de `shutdown` relevée à la Tâche 1.
- Produit : le critère d'acceptation final — `docker compose stop` rend `exit 0`.

- [ ] **Step 1: Ajouter l'assertion d'arrêt propre au harnais**

```bash
echo
echo "== Arret propre =="
check "arret: docker compose stop rend exit 0" \
  sh -c '
    docker compose stop >/dev/null 2>&1
    test "$(docker inspect -f "{{.State.ExitCode}}" vrising-vrising-1)" = "0"
  '
```

- [ ] **Step 2: Lancer le harnais pour constater l'échec**

```bash
docker compose up -d
sleep 60
./tests/verify.sh arret
```

Expected: `FAIL`. Le code de sortie sera `137` (SIGKILL) ou `143` (SIGTERM non géré), reproduisant exactement le défaut mesuré au spike.

- [ ] **Step 3: Ajouter le gestionnaire d'arrêt — variante A, RCON validé**

À appliquer si la Tâche 1 a validé RCON. Insérer dans `docker/entrypoint.sh` **après** l'affectation de `SRV_PID` et **avant** la boucle `while kill -0`. Remplacer la commande `shutdown 1 ...` par la syntaxe exacte relevée au Step 7 de la Tâche 1.

```bash
# --- Arret propre -----------------------------------------------------------
# RCON est force en interne : jamais publie, le protocole est en clair.
export VR_RCON_ENABLED=true
export VR_RCON_BIND_ADDRESS=127.0.0.1
export VR_RCON_PORT="${VR_RCON_PORT:-25575}"
if [ -z "${RCON_PASSWORD:-}" ]; then
  log "ERREUR: RCON_PASSWORD est obligatoire (arret propre)"
  exit 1
fi
export VR_RCON_PASSWORD="$RCON_PASSWORD"

shutdown_handler() {
  log "signal d'arret recu, arret ordonne"
  if mcrcon -H 127.0.0.1 -P "$VR_RCON_PORT" -p "$VR_RCON_PASSWORD" \
       -c "announce Arret du serveur en cours" \
       -c "shutdown 1 Arret du serveur" >/dev/null 2>&1; then
    log "commande shutdown transmise par RCON"
  else
    log "RCON injoignable, envoi de SIGTERM au serveur"
    kill -TERM "$SRV_PID" 2>/dev/null || true
  fi

  local waited=0
  while kill -0 "$SRV_PID" 2>/dev/null && [ "$waited" -lt "$GRACE" ]; do
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$SRV_PID" 2>/dev/null; then
    log "delai de ${GRACE}s depasse, SIGKILL"
    kill -KILL "$SRV_PID" 2>/dev/null || true
  else
    log "serveur arrete proprement en ${waited}s"
  fi
  kill "$XVFB_PID" 2>/dev/null || true
  exit 0
}
trap shutdown_handler TERM INT
```

**Important :** les exports RCON doivent être placés **avant** le lancement du serveur pour qu'il les lise. Si le bloc est inséré après `SRV_PID`, déplacer les cinq lignes `export`/`if` juste avant `log "lancement du serveur V Rising"`.

- [ ] **Step 4: Ajouter le gestionnaire d'arrêt — variante B, RCON invalidé**

À appliquer **uniquement** si la Tâche 1 a invalidé RCON. Ne pas appliquer les deux variantes.

```bash
# --- Arret propre (repli sans RCON) -----------------------------------------
# La Tache 1 a etabli que RCON ne permet pas un arret fiable. On envoie SIGTERM
# et on laisse au serveur le temps d'ecrire, en s'appuyant sur les autosaves
# (toutes les VR_SAVE_INTERVAL secondes) pour borner la perte.
shutdown_handler() {
  log "signal d'arret recu, SIGTERM au serveur"
  kill -TERM "$SRV_PID" 2>/dev/null || true

  local waited=0
  while kill -0 "$SRV_PID" 2>/dev/null && [ "$waited" -lt "$GRACE" ]; do
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$SRV_PID" 2>/dev/null; then
    log "delai de ${GRACE}s depasse, SIGKILL"
    kill -KILL "$SRV_PID" 2>/dev/null || true
  else
    log "serveur arrete en ${waited}s"
  fi
  kill "$XVFB_PID" 2>/dev/null || true
  exit 0
}
trap shutdown_handler TERM INT
```

- [ ] **Step 5: Reconstruire et vérifier l'arrêt propre**

```bash
docker compose up -d --build
for i in $(seq 1 180); do
  docker compose logs --since 20s 2>&1 | grep -q "Server Setup Complete" && { echo PRET; break; }
  sleep 5
done
./tests/verify.sh arret
```

Expected: `PASS=1 FAIL=0`. Les logs doivent montrer `serveur arrete proprement en Ns` avec `N < 300`.

**Patience requise :** la Tâche 1 a mesuré ~220 s pour un arret ordonne complet.
Ce check prend donc environ 4 minutes, ce n'est pas un blocage.

- [ ] **Step 6: Vérifier qu'aucune sauvegarde n'est corrompue**

```bash
docker compose up -d
sleep 90
docker compose stop
ls -la vrising-persistent-data/Saves/v4/*/
docker compose up -d
for i in $(seq 1 180); do
  docker compose logs --since 20s 2>&1 | grep -q "Server Setup Complete" && { echo RECHARGE; break; }
  sleep 5
done
```

Expected: `RECHARGE`. Le monde se recharge sans erreur après un cycle d'arrêt/démarrage.

- [ ] **Step 7: Commit**

```bash
git add docker/entrypoint.sh tests/verify.sh
git commit -m "feat: arret propre du serveur sur SIGTERM

Corrige le exit 137 mesure sur l'image communautaire. RCON est active en
interne uniquement (127.0.0.1, jamais publie) et sert a declencher un arret
ordonne, avec SIGKILL en dernier recours apres 300s."
```

---

### Task 8: Vérification de bout en bout et documentation de déploiement

**Files:**
- Create: `README.md`
- Modify: `tests/verify.sh` (assertion de propreté du dépôt)

**Interfaces:**
- Consomme : tout ce qui précède.
- Produit : le livrable final déployable.

- [ ] **Step 1: Ajouter l'assertion de propreté du dépôt**

```bash
echo
echo "== Proprete du depot =="
check "depot: le .env n'est pas versionne" \
  sh -c '! git ls-files --error-unmatch .env 2>/dev/null'
check "depot: le volume de donnees n'est pas versionne" \
  sh -c 'test -z "$(git ls-files vrising-persistent-data)"'
check "depot: aucun fichier root:root versionne" \
  sh -c 'test -z "$(git ls-files | xargs -r stat -c "%U" | grep -x root)"'
```

- [ ] **Step 2: Lancer le harnais complet**

Run: `./tests/verify.sh`
Expected: tous les checks en `PASS`, `FAIL=0`. C'est le tableau d'acceptation de la spec, exécutable.

- [ ] **Step 3: Écrire le README de déploiement**

```bash
cat > README.md <<'EOF'
# Serveur V Rising auto-héberge

Serveur V Rising dédie en conteneur, image construite localement.
Le binaire serveur est un exécutable Windows exécute sous Wine.

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

Editer `.env`. Au minimum :

- `VR_PASSWORD` — mot de passe des joueurs, **entre guillemets simples**
- `RCON_PASSWORD` — sert a l'arrêt propre, **entre guillemets simples**
- `PUID` / `PGID` — resultat de `id -u` et `id -g`, pour que les sauvegardes
  appartiennent a ton compte
- `VRISING_ADMINS` — ton SteamID64, pour être administrateur en jeu

Puis :

```bash
docker compose build    # long : 2 Go a télécharger
docker compose up -d
docker compose logs -f  # attendre "Server Setup Complete"
```

## Règle sur les guillemets dans le `.env`

Mesurée, pas supposée :

| Ecriture | Valeur réelle | |
|---|---|---|
| `VR_PASSWORD='Mot$X'` | `Mot$X` | correct |
| `VR_PASSWORD=Mot$$X` | `Mot$X` | correct |
| `VR_PASSWORD="Mot$X"` | `Mot` | faux, interpolation |
| `VR_PASSWORD=Mot #x` | `Mot` | faux, commentaire |

**Tout secret s'écrit entre guillemets simples.**

## Pare-feu et redirection de ports

`27015/udp` (jeu) et `27016/udp` (requêtes). Les **deux** doivent être ouverts
et rediriges pour que le serveur apparaisse dans la liste publique. Le port de
jeu seul suffit pour une connexion par IP directe.

```bash
sudo ufw allow 27015/udp
sudo ufw allow 27016/udp
```

## Administration en jeu

Ton SteamID64 dans `VRISING_ADMINS` est écrit dans
`vrising-persistent-data/Settings/adminlist.txt` a chaque démarrage. En jeu :
activer la console dans les options, l'ouvrir avec `~`, taper `adminauth`.
Commandes disponibles ensuite : `kick`, `banuser`, `bancharacter`, `unban`.

## Règles de jeu

`config/ServerGameSettings.json` est un override **partiel** : il ne contient
que les écarts par rapport aux défauts du jeu. `VR_PRESET` doit rester **vide**,
sinon le preset charge ses propres règles a la place des tiennes.

## Mise a jour du jeu

Les fichiers du jeu sont figes dans l'image. Après un patch Stunlock, les
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
s'arrête. Le code de sortie doit être `0`.

## Vérification

```bash
./tests/verify.sh
```

## Limites connues

- La version du jeu n'est pas épinglable : elle est celle du moment du build.
- Le serveur écrit **son mot de passe en clair dans ses logs** au démarrage.
  Comportement du jeu, non corrigeable. A garder en tête avant de partager des
  logs.
- Wine est épinglé en `10.0.0.0~bookworm-1` et ne recevra pas les correctifs
  ultérieurs sans montée de version délibérée et re-test.
- Les sauvegardes automatiques ne sont pas incluses : voir la spec 2.
EOF
```

- [ ] **Step 4: Vérifier une connexion réelle**

Depuis un client V Rising, rejoindre le serveur par son IP et le port `27015`,
avec le mot de passe du `.env` — **sans guillemets**. C'est la validation
finale du défaut n°1 : sur l'ancien compose, il aurait fallu taper les
guillemets.

En jeu : ouvrir la console avec `~`, taper `adminauth`, vérifier que la
commande est acceptée.

- [ ] **Step 5: Commit**

```bash
git add README.md tests/verify.sh
git commit -m "docs: procedure de deploiement et verification de bout en bout

Le harnais tests/verify.sh encode le tableau d'acceptation de la spec en
assertions executables."
```

---

## Self-Review

**Couverture de la spec** — chaque exigence est rattachée a une tâche :

| Exigence de la spec | Tâche |
|---|---|
| Dockerfile multi-étages, jeu figé au build | 2, 3 |
| steamcmd anonyme, AppID 1829350 | 2 |
| Runtime sans steamcmd | 3 (assertion explicite) |
| Wine épinglé 10.0.0.0~bookworm-1 | 3 |
| Préfixe Wine initialisé au build | 3 |
| Exécution non-root, PUID/PGID runtime | 3, 5 |
| Configuration en `.env`, interpolation `${VAR}` | 4 |
| Règles de jeu en override partiel versionné | 4, 6 |
| `VR_PRESET` vide documenté | 4 |
| adminlist déclaratif | 6 |
| banlist propriété du serveur | 6 |
| RCON interne, jamais publié | 4 (assertion), 7 |
| Arrêt propre, `exit 0` | 1, 7 |
| Défaut n°1, guillemets | 4, 5 |
| Défaut n°2, collision de ports | 4, 5 |
| Défaut n°3, `restart: unless-stopped` | 4 |
| Défaut n°4, `exit 137` | 7 |
| Ports et pare-feu | 4, 8 |
| Procédure de déploiement | 8 |
| Tableau de vérification | 2 a 8, harnais incrémental |
| Sauvegardes automatiques | **hors périmètre**, spec 2 |
| Authentification Steam | **hors périmètre**, jamais implémentée |

**Cohérence des noms** — vérifiée entre tâches : `DATA`, `GAME`, `PREFIX`,
`SRV_PID`, `XVFB_PID`, `GRACE`, `log()` sont définis en Tâche 5 et réutilisés
tels quels en Tâches 6 et 7. Le service compose est `vrising` et le conteneur
`vrising-vrising-1` dans toutes les tâches. L'image est `vrising-server:local`
en Tâches 3 a 8, `vrising-builder:test` uniquement en Tâche 2.

**Dépendance conditionnelle** — la Tâche 7 a deux variantes exclusives, A ou B,
selon le verdict de la Tâche 1. L'exécutant doit lire le verdict consigne dans
la spec avant de choisir.
