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
