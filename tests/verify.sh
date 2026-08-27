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
# ATTENTION au pipe vers grep : NE PAS ecrire `printf ... | grep -qF ...`.
# Mesure sur ce projet (Tache 6, logs cumules sur plusieurs jours de
# redemarrages, 400-800 Ko) : `grep -q` sort DES QU IL TROUVE une
# correspondance, sans lire le reste de son entree. Si la sortie captee
# depasse le tampon de pipe Linux (64 Ko) et que la correspondance se trouve
# avant la fin, `printf` encore en train d ecrire recoit SIGPIPE et sort en
# 141. Sous `set -o pipefail` (tete de ce fichier), le code de sortie du
# pipeline devient celui de `printf` (141, non nul) au lieu de celui de
# `grep` (0) : le check echoue A TORT alors que la chaine est bien presente.
# Touchait ici "demarrage: serveur pret" et consorts des que les logs
# grossissaient. La here-string evite le pipe : pas de second processus,
# pas de SIGPIPE possible.
check_out() {
  local name="$1" expect="$2"; shift 2
  skip "$name" && return 0
  local out
  out="$("$@" 2>&1)"
  if grep -qF -- "$expect" <<<"$out"; then
    printf '  PASS  %s\n' "$name"; PASS=$((PASS+1))
  else
    printf '  FAIL  %s (attendu: %s)\n' "$name" "$expect"; FAIL=$((FAIL+1))
  fi
}

# check_absent <nom> <commande...>
# Pour affirmer qu'une chose est ABSENTE. La sonde doit s'executer ET ne rien
# trouver. Codes de sortie MESURES sur ce projet :
#   0        la chose existe            => FAIL
#   1        elle est absente           => PASS
#   125/127  la sonde n'a pas tourne    => FAIL, jamais un faux PASS
# Une negation `! cmd` confondrait les deux derniers cas.
# Verifie non affectee par le bug SIGPIPE/pipefail de check_out ci-dessus :
# pas de pipe vers grep ici, la capture est un `$(...)` direct sur "$@".
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

echo "== Etage builder =="
check_out "builder: VRisingServer.exe present" "VRisingServer.exe" \
  docker run --rm vrising-builder:test ls /game
# `--version` n'existe pas dans mcrcon : l'invoquer renvoie « invalid option »,
# dont le texte contient « mcrcon » -- l'assertion passait donc sans rien prouver.
# `-h` est une invocation valide : elle prouve que le binaire s'execute et
# analyse ses options.
check_out "builder: mcrcon compile" "Usage: mcrcon" \
  docker run --rm vrising-builder:test /usr/local/bin/mcrcon -h

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
# uid 1000 et non un uid haut : voir le commentaire du Dockerfile — il doit
# correspondre au PUID par defaut pour eviter un copy-up de 1,4 Go au demarrage.
check_out "runtime: utilisateur vrising en uid 1000" "uid=1000" \
  docker run --rm --entrypoint id vrising-server:local vrising
# `command -v steamcmd` est INTROUVABLE meme dans le builder, ou steamcmd
# existe pourtant a /opt/steamcmd/steamcmd.sh : il n'est jamais sur le PATH.
# L'assertion passait donc dans les DEUX images sans rien discriminer. On teste
# le chemin d'installation reel, verifie present dans le builder et absent ici.
check_absent "runtime: steamcmd absent de l'image finale" \
  docker run --rm --entrypoint test vrising-server:local -e /opt/steamcmd
# L'outillage de compilation ne doit pas non plus avoir survecu a COPY --from.
check_absent "runtime: outillage de build absent" \
  docker run --rm --entrypoint sh vrising-server:local -c \
    'for b in gcc make git; do command -v "$b" >/dev/null 2>&1 && exit 0; done; exit 1'
check_out "runtime: prefixe Wine possede par vrising" "1000" \
  docker run --rm --entrypoint stat vrising-server:local -c %u /opt/vrising/.wine

echo
echo "== Configuration =="
# Valeur attendue derivee du .env plutot que codee en dur ("Serveur de test"
# a l'origine) : l'humain a personnalise VR_SERVER_NAME='V Rising BIZU'.
# Sourcer le .env retire deja les guillemets simples encadrants (syntaxe
# bash) : c'est donc la valeur EFFECTIVE attendue, sans guillemets parasites.
# L'intention du check est preservee -- si de tels guillemets fuitaient dans
# le nom effectif, il ne correspondrait plus a cette valeur et le check
# echouerait toujours.
SERVER_NAME_ATTENDU=$(. ./.env 2>/dev/null; echo "$VR_SERVER_NAME")
check_out "config: nom sans guillemets parasites" "VR_SERVER_NAME: $SERVER_NAME_ATTENDU" \
  docker compose config
# ATTENTION sur le nommage : ces deux assertions testent les ports PUBLIES,
# que l'ancien compose defectueux publiait deja correctement (27015 et 27016).
# Elles ne couvrent donc PAS le defaut n2, qui vivait dans les variables d'env
# (QUERY_PORT=27015, identique a GAME_PORT). Nommees en consequence.
check_out "config: port de jeu publie 27015" "target: 27015" docker compose config
check_out "config: port de requete publie 27016" "target: 27016" docker compose config
check "config: deux ports UDP publies et pas plus" \
  sh -c 'test "$(docker compose config | grep -c "target: 2701[56]")" -eq 2'

# C'EST CETTE ASSERTION qui couvre le defaut n2. Elle porte sur les variables
# d'environnement resolues, la ou le defaut se trouvait reellement.
# Les gardes `test -n` sont indispensables, et le cas de risque est ASYMETRIQUE
# (mesure) : si UNE SEULE extraction echoue, `test "" != "27016"` est VRAI et le
# check passerait a tort. Le cas ou les DEUX echouent, lui, echoue deja sans
# garde (`test "" != ""` est faux) — ne pas retirer les gardes en croyant que
# seul ce second cas etait vise.
check "config: ports de jeu et de requete distincts EN ENV (defaut n2)" \
  sh -c '
    C=$(docker compose config)
    G=$(printf "%s" "$C" | sed -n "s/^ *VR_GAME_PORT: *\"\?\([0-9]\+\)\"\?/\1/p")
    Q=$(printf "%s" "$C" | sed -n "s/^ *VR_QUERY_PORT: *\"\?\([0-9]\+\)\"\?/\1/p")
    test -n "$G" && test -n "$Q" && test "$G" != "$Q"
  '
check_out "config: politique de redemarrage" "restart: unless-stopped" docker compose config
check_out "config: delai de grace 330s" "stop_grace_period: 5m30s" docker compose config
# `grep -q` rend 1 quand rien n'est trouve : sonde deterministe, donc
# check_absent discrimine correctement une vraie absence d'un echec de sonde.
check_absent "config: port RCON jamais publie" \
  sh -c 'docker compose config | grep -q "25575"'
check "config: regles de jeu montees en lecture seule" \
  sh -c 'docker compose config | grep -q "read_only: true"'

echo
echo "== Demarrage =="
check_out "demarrage: serveur pret" "Server Setup Complete" \
  sh -c 'docker compose logs 2>&1 | sed "s/\x1b\[[0-9;]*m//g"'
check_out "demarrage: nom effectif sans guillemets" "\"Name\": \"$SERVER_NAME_ATTENDU\"" \
  sh -c 'docker compose logs 2>&1 | sed "s/\x1b\[[0-9;]*m//g"'
check_out "demarrage: port de jeu effectif" '"Port": 27015' \
  sh -c 'docker compose logs 2>&1 | sed "s/\x1b\[[0-9;]*m//g"'
check_out "demarrage: port de requete effectif" '"QueryPort": 27016' \
  sh -c 'docker compose logs 2>&1 | sed "s/\x1b\[[0-9;]*m//g"'
check "demarrage: volume possede par PUID et non root" \
  sh -c 'test "$(stat -c %u vrising-persistent-data/Settings)" = "$(. ./.env; echo $PUID)"'
# Le check ci-dessus ne porte que sur les REPERTOIRES, les seuls que l'entrypoint
# chownait. Le defaut vivait dans les FICHIERS : banlist.txt et consorts, laisses
# a root par un demarrage anterieur, faisaient lever au serveur
# « UnauthorizedAccessException: Access to the path ...banlist.txt is denied »
# puis planter (exit 3). D'ou cette assertion recursive.
# La premiere ligne garantit que la sonde a bien enumere quelque chose : sans
# elle, un `find` en echec rendrait une liste vide, donc un PASS mensonger.
check "demarrage: aucun fichier du volume laisse a un autre uid que PUID" \
  sh -c '
    P=$(. ./.env; echo "${PUID:-1000}")
    test -n "$(find vrising-persistent-data -type f -print -quit)" || exit 1
    test -z "$(find vrising-persistent-data ! -uid "$P" -print -quit)"
  '

# Avec restart: unless-stopped, un conteneur qui ne sait pas repartir boucle
# indefiniment. Mesure du defaut : Xvfb laisse /tmp/.X1-lock dans la couche du
# conteneur ; au redemarrage suivant il refuse de demarrer, et le serveur sort
# aussitot sur « Failed to create batch mode window » (exit 1).
# On lit les journaux DEPUIS le restart uniquement (--since), sinon le
# « Server Setup Complete » du demarrage precedent ferait passer le check sans
# rien prouver.
check "redemarrage: le serveur repart apres un restart du conteneur" \
  sh -c '
    SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    docker compose restart >/dev/null 2>&1 || exit 1
    i=0
    while [ "$i" -lt 48 ]; do
      L=$(docker compose logs --since "$SINCE" 2>&1 | sed "s/\x1b\[[0-9;]*m//g")
      printf "%s" "$L" | grep -qF "Server Setup Complete" && exit 0
      printf "%s" "$L" | grep -qF "Failed to create batch mode window" && exit 1
      sleep 5; i=$((i+1))
    done
    exit 1
  '
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
    rc=$?
    # Nettoyage APRES la preuve : vrising-persistent-data/ est versionne dans
    # ce depot, le harnais doit rester relancable sans accumuler un ban bidon
    # dans un fichier suivi par git. Le code de sortie reste celui du grep.
    sed -i "/^76561198999999999$/d" vrising-persistent-data/Settings/banlist.txt
    exit "$rc"
  '

echo
echo "== Arret propre =="
# Ce check est DESTRUCTIF (il arrete le serveur) : il doit rester le dernier.
#
# Le defaut qu'il couvre, mesure le 2026-08-25 sur le serveur de production :
# `docker compose stop` a pris 5m30 exactement — la totalite du
# stop_grace_period — puis rendu `Exited (137)`, soit 128+9 = SIGKILL.
# Cause : un PID 1 ne recoit du noyau que les signaux dont il a explicitement
# installe un gestionnaire. Sans `trap`, bash n'a jamais vu passer le SIGTERM,
# le serveur n'a pas ete prevenu et le monde n'a jamais ete sauvegarde.
# Un ExitCode 0 est donc la seule preuve que le gestionnaire a bien tourne.
#
# On releve l'id AVANT l'arret : `docker compose ps -q` ne rend plus rien une
# fois le conteneur sorti, et l'inspection porterait alors sur une chaine vide.
check "arret: docker compose stop rend exit 0" \
  sh -c '
    cid=$(docker compose ps -q vrising)
    test -n "$cid" || exit 1
    docker compose stop >/dev/null 2>&1
    test "$(docker inspect -f "{{.State.ExitCode}}" "$cid")" = "0"
  '

echo
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"

# Un filtre mal orthographie ne doit pas passer pour un succes.
if [ -n "$FILTER" ] && [ $((PASS + FAIL)) -eq 0 ]; then
  printf 'ERREUR: le filtre "%s" ne correspond a aucun check.\n' "$FILTER"
  exit 2
fi

[ "$FAIL" -eq 0 ]
