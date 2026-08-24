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
