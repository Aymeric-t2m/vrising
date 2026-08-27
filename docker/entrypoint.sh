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
PREFIX_TEMPLATE=/opt/vrising/.wine   # construit dans l image, lecture seule
PREFIX=/opt/vrising/.wine-run        # copie de travail, volume nomme

log() { printf '%s [entrypoint] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# --- Droits -----------------------------------------------------------------
# Le repertoire du jeu reste root:root et n'est jamais chowne : 2 Go lus
# seulement. Seuls le volume de donnees et le prefixe Wine doivent appartenir
# a PUID/PGID.
log "ajustement des droits vers ${PUID}:${PGID}"
install -d -o "$PUID" -g "$PGID" -m 0755 "$DATA" "$DATA/Settings" "$DATA/Saves"
# RECURSIF, et ce n'est pas une precaution de style : un chown limite aux trois
# repertoires laisse a root les FICHIERS qu'un demarrage anterieur y a ecrits.
# Mesure : avec banlist.txt en root:root, le serveur leve
# « UnauthorizedAccessException: Access to the path
# Z:\opt\vrising\save-data\Settings\banlist.txt is denied », puis plante
# (EXCEPTION_BREAKPOINT, exit 3) sans jamais atteindre Server Setup Complete.
# Le cout reste negligeable : ce volume pese quelques dizaines de Mo et c'est un
# bind mount, donc aucun copy-up overlayfs — contrairement au prefixe Wine.
chown -R "$PUID:$PGID" "$DATA"

# Le prefixe Wine ne peut PAS etre utilise en place depuis la couche image :
# mesure, le serveur leve EXCEPTION_BREAKPOINT (0x80000003) a ~35 s. Copier le
# MEME prefixe vers un systeme de fichiers inscriptible fait disparaitre le
# crash. On le copie une fois vers un volume nomme, qui persiste.
if [ ! -f "$PREFIX/system.reg" ]; then
  log "premiere initialisation : copie du prefixe Wine vers le volume"
  mkdir -p "$PREFIX"
  cp -a "$PREFIX_TEMPLATE/." "$PREFIX/"
  log "copie terminee"
fi
chown "$PUID:$PGID" "$PREFIX" 2>/dev/null || true

# Ce chown est COUTEUX : sur overlayfs il force un copy-up de ~1,4 Go, soit
# plusieurs minutes. Il ne se declenche que si PUID differe de l'uid de
# construction de l'image (1000 par defaut). Voir la note du .env.example.
if [ "$(stat -c %u "$PREFIX")" != "$PUID" ]; then
  log "ATTENTION: reattribution du prefixe Wine a ${PUID}:${PGID}"
  log "  copy-up overlayfs de ~1,4 Go, comptez plusieurs minutes."
  log "  pour l'eviter: reconstruire avec --build-arg RUNTIME_UID=${PUID}"
  chown -R "$PUID:$PGID" "$PREFIX"
  log "reattribution terminee"
fi

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

# --- Serveur ----------------------------------------------------------------
# Xvfb laisse /tmp/.X1-lock derriere lui. Ce fichier SURVIT a un redemarrage du
# conteneur (meme couche inscriptible) et Xvfb refuse alors de demarrer, car le
# pid inscrit dans le verrou a de bonnes chances d'avoir ete reattribue a un
# autre processus dans l'espace de pids neuf : le verrou passe pour actif. Le
# serveur sort aussitot sur « Failed to create batch mode window » (exit 1) et,
# avec restart: unless-stopped, le conteneur boucle sans jamais se retablir.
# Mesure : premier demarrage OK, tout redemarrage ensuite en exit 1.
# Supprimer le verrou est sans risque : nous sommes PID 1 dans un espace de pids
# neuf, aucun serveur X legitime ne peut deja tourner ici.
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1

log "demarrage de Xvfb"
# La sortie de Xvfb va dans un fichier et non dans /dev/null : c'est elle qui
# nomme la panne quand le display ne s'ouvre pas.
Xvfb :1 -screen 0 1024x768x16 >/tmp/xvfb.log 2>&1 &
XVFB_PID=$!

# Attendre que le display soit REELLEMENT ouvert, plutot qu'un delai arbitraire.
# Sans cette attente, le serveur peut demarrer avant le socket X et echouer.
XVFB_TRIES=0
while [ ! -S /tmp/.X11-unix/X1 ] && [ "$XVFB_TRIES" -lt 100 ]; do
  sleep 0.1; XVFB_TRIES=$((XVFB_TRIES + 1))
done
if [ ! -S /tmp/.X11-unix/X1 ]; then
  log "ERREUR: Xvfb n'a pas ouvert le display :1 en 10s, journal ci-dessous"
  cat /tmp/xvfb.log >&2
  exit 1
fi
log "display :1 pret"

# Le conteneur n'a pas CAP_SYS_PTRACE (non ajoute dans compose.yaml, et ce
# n'est pas a cette tache de le faire). Sans cette capacite, une exception
# non geree fait que Wine invoque `winedbg --auto ... 3600` en interne, qui
# reste bloque (mesure : >20 min a 0% CPU, sans jamais produire de
# backtrace ; le delai de 3600s inscrit dans l'appel n'a pas ete attendu
# jusqu'au bout). On desactive le dialogue de crash : le processus termine
# alors normalement sur exception au lieu de bloquer indefiniment.
setpriv --reuid "$PUID" --regid "$PGID" --clear-groups \
  env HOME=/opt/vrising WINEPREFIX="$PREFIX" WINEDEBUG=-all DISPLAY=:1 \
      WINEDLLOVERRIDES=mscoree,mshtml= \
  wine reg add 'HKEY_CURRENT_USER\Software\Wine\WineDbg' \
      /v ShowCrashDialog /t REG_DWORD /d 0 /f >/dev/null 2>&1

# Unity exige un VRAI FICHIER de log. Avec `-logFile /dev/stdout` le serveur
# demarre, ecrit son en-tete, puis SE FIGE apres l initialisation memoire sans
# jamais charger de scene (mesure). Avec un fichier, il atteint
# « Server Setup Complete » et charge le monde. On relaie vers la sortie
# standard par `tail -F` pour que `docker compose logs` fonctionne.
SRV_LOG=/opt/vrising/logs/VRisingServer.log
install -d -o "$PUID" -g "$PGID" -m 0755 /opt/vrising/logs
: > "$SRV_LOG"; chown "$PUID:$PGID" "$SRV_LOG"
tail -F "$SRV_LOG" 2>/dev/null &
TAIL_PID=$!

# --- Arret propre : reglages RCON -------------------------------------------
# RCON est force ici et jamais publie dans compose.yaml : le protocole est en
# clair. Il ne sert qu'a un client local, l'entrypoint lui-meme.
# Ces exports doivent PRECEDER le lancement : le serveur ne lit les VR_* qu'a
# son demarrage, les poser apres n'aurait aucun effet.
# Le nom VR_RCON_BIND_ADDRESS est celui valide en Tache 1, ou les logs ont
# montre 'BindAddress' surchargee par cette variable.
export VR_RCON_ENABLED=true
export VR_RCON_BIND_ADDRESS=127.0.0.1
export VR_RCON_PORT="${VR_RCON_PORT:-25575}"
if [ -z "${RCON_PASSWORD:-}" ]; then
  log "ERREUR: RCON_PASSWORD est obligatoire (arret propre)"
  exit 1
fi
export VR_RCON_PASSWORD="$RCON_PASSWORD"

log "lancement du serveur V Rising"
setpriv --reuid "$PUID" --regid "$PGID" --clear-groups \
  env HOME=/opt/vrising \
      WINEPREFIX="$PREFIX" \
      WINEDEBUG=-all \
      DISPLAY=:1 \
      WINEDLLOVERRIDES=mscoree,mshtml= \
  wine "$GAME/VRisingServer.exe" \
      -batchmode \
      -nographics \
      -persistentDataPath "$DATA" \
      -logFile "$SRV_LOG" &
SRV_PID=$!
log "serveur lance (pid ${SRV_PID})"

# Sans ce trap, le SIGTERM de `docker compose stop` n'est meme pas DELIVRE : le
# noyau ne remet a PID 1 que les signaux dont un gestionnaire est installe, si
# bien que bash l'ignore, Docker attend tout le stop_grace_period puis envoie
# SIGKILL. Mesure du defaut le 2026-08-25 : 5m30 d'attente, puis Exited (137),
# monde non sauvegarde. Installer le gestionnaire suffit a rendre le signal
# delivrable.
shutdown_handler() {
  log "signal d'arret recu, arret ordonne"
  # RCON plutot que SIGTERM : le serveur tourne sous Wine, ou un signal Unix ne
  # se traduit pas en arret applicatif. La Tache 1 a mesure que la commande
  # `shutdown` fait sortir le processus de lui-meme, apres sauvegarde.
  if mcrcon -H 127.0.0.1 -P "$VR_RCON_PORT" -p "$VR_RCON_PASSWORD" \
       -c "announce Arret du serveur en cours" \
       -c "shutdown 1 Arret du serveur" >/dev/null 2>&1; then
    log "commande shutdown transmise par RCON"
  else
    # Repli : mieux vaut un SIGTERM qui echoue qu'aucune tentative d'arret.
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

# `wait` est interrompu par les signaux : on boucle jusqu'a la sortie reelle.
while kill -0 "$SRV_PID" 2>/dev/null; do
  wait "$SRV_PID"; RC=$?
done
log "le serveur s'est termine (code ${RC:-0})"
kill "$XVFB_PID" 2>/dev/null || true
exit "${RC:-0}"
