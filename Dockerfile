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
# 1000 et non un uid haut : il DOIT correspondre au PUID par defaut, sinon
# l'entrypoint chowne le prefixe Wine a chaque demarrage. Or sur overlayfs, un
# chown sur des fichiers d'une couche en lecture seule force un COPY-UP : 1,4 Go
# recopies dans la couche inscriptible, mesure a plusieurs minutes en etat D
# (attente d'E/S). Avec 1000, la garde de l'entrypoint saute le chown.
ARG RUNTIME_UID=1000
ARG RUNTIME_GID=1000

# procps fournit pgrep, dont l'assertion « processus serveur non-root » de la
# Tache 5 a besoin, et donne a l'exploitant un `ps` utilisable pour diagnostiquer
# en production. debian:12-slim ne l'inclut pas.

# WINEDLLOVERRIDES desactive wine-mono et wine-gecko. Ce n'est PAS une
# optimisation : ils ne sont pas fournis par le paquet WineHQ, donc Wine tente de
# les TELECHARGER. Mesure : `wineboot --init` restait bloque >8 min sur
# `appwiz.cpl install_mono` et produisait un prefixe incomplet, ce qui faisait
# lever EXCEPTION_BREAKPOINT au serveur. Avec l'override, wineboot prend 11 s.
# Le serveur V Rising n'a besoin ni de .NET ni de HTML. NE PAS RETIRER.
ENV WINEPREFIX=/opt/vrising/.wine \
    WINEDEBUG=-all \
    WINEDLLOVERRIDES=mscoree,mshtml= \
    HOME=/opt/vrising \
    DISPLAY=:1

# Wine depuis le depot officiel WineHQ. Les quatre paquets doivent etre nommes
# explicitement : wine-stable (amd64) depend de wine-stable-i386, qui n'existe
# qu'en i386, et le resolveur apt echoue si on ne pinne que winehq-stable.
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates wget xvfb xauth tzdata procps cabextract unzip p7zip-full \
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
 && install -d -o ${RUNTIME_UID} -g ${RUNTIME_GID} -m 0755 /opt/vrising \
 && install -d -o ${RUNTIME_UID} -g ${RUNTIME_GID} -m 0755 /opt/vrising/save-data

# Le jeu reste root:root 755 : lu seulement, jamais ecrit (les ecritures vont
# dans -persistentDataPath). Evite un chown -R de 2 Go a chaque demarrage.
COPY --from=builder /game /opt/vrising/game
COPY --from=builder /usr/local/bin/mcrcon /usr/local/bin/mcrcon

# Prefixe Wine initialise au build, pour qu'aucun premier demarrage ne paie
# cette latence.
# Le dossier /opt/vrising doit rester inscriptible par l'utilisateur : Unity y
# ecrit son cache de shaders et resout le home depuis passwd, PAS depuis $HOME.
# Sans cela : « Failed to create /opt/vrising/.cache ... Permission denied ».
# Le sous-dossier game/, lui, reste root:root (voir COPY ci-dessus).
RUN install -d -o ${RUNTIME_UID} -g ${RUNTIME_GID} -m 0755 ${WINEPREFIX} \
 && setpriv --reuid ${RUNTIME_UID} --regid ${RUNTIME_GID} --clear-groups \
      env HOME=/opt/vrising WINEPREFIX=${WINEPREFIX} WINEDEBUG=-all \
      WINEDLLOVERRIDES=mscoree,mshtml= \
      wineboot --init \
 && setpriv --reuid ${RUNTIME_UID} --regid ${RUNTIME_GID} --clear-groups \
      env HOME=/opt/vrising WINEPREFIX=${WINEPREFIX} \
      wineserver -w \
 && test -f ${WINEPREFIX}/system.reg

# Runtime Visual C++ REEL, via winetricks. Ce n'est pas optionnel : sans lui,
# Wine substitue ses reimplementations partielles de VCRUNTIME140/MSVCP140 et le
# serveur se FIGE apres l'initialisation memoire d'Unity, sans jamais charger de
# scene. Preuve par comparaison avec une image tierce dont le fonctionnement est
# prouve : msvcp140.dll y pese 447 616 octets (Microsoft) contre 3 593 434 pour
# la version Wine. corefonts, que la reference installe aussi, est volontairement
# omis : inutile pour un serveur sans affichage et tres lent a telecharger.
# `-q` = non interactif ; xvfb-run car winetricks veut un display.
ADD --chmod=0755 https://raw.githubusercontent.com/Winetricks/winetricks/20250102/src/winetricks /usr/local/bin/winetricks
RUN setpriv --reuid ${RUNTIME_UID} --regid ${RUNTIME_GID} --clear-groups \
      env HOME=/opt/vrising WINEPREFIX=${WINEPREFIX} WINEDEBUG=-all \
          WINEDLLOVERRIDES=mscoree,mshtml= W_OPT_UNATTENDED=1 \
      xvfb-run -a winetricks -q vcrun2022 \
 && MSVCP=$(find ${WINEPREFIX} -iname msvcp140.dll | head -1) \
 && test -n "$MSVCP" \
 && SZ=$(stat -c %s "$MSVCP") \
 && echo "msvcp140.dll = $SZ octets" \
 && test "$SZ" -lt 1000000   # la version Microsoft pese ~447 Ko, celle de Wine ~3,6 Mo

VOLUME ["/opt/vrising/save-data"]

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
