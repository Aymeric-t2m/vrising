#!/usr/bin/env bash
# Harnais de verification. Chaque tache y ajoute ses assertions.
# Usage: ./tests/verify.sh [nom-de-check-partiel]
set -uo pipefail

FILTER="${1:-}"
PASS=0; FAIL=0

# Lit UNE valeur du .env sans executer le fichier. `. ./.env`, employe ailleurs
# dans ce harnais, execute son contenu : une ligne fabriquee y devient du code
# (I5 de la revue finale). Les guillemets englobants sont retires, conformement
# a la regle du .env documentee dans docs/deploiement.md.
lire_env() {
  sed -n "s/^$1=//p" .env 2>/dev/null | head -1 \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

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
  # D2 (2026-08-28) : plusieurs appelants derivent "$expect" du .env
  # (SERVER_NAME_ATTENDU, ADMIN_ATTENDU). Si cette extraction rend une chaine
  # vide, `grep -qF -- ""` matche n'importe quelle sortie -- faux PASS
  # silencieux, sur une sonde qui ne prouve plus rien. Meme motif que le
  # troisieme cas de check_absent ci-dessous : FAIL, "sonde inexploitable".
  if [ -z "$expect" ]; then
    printf '  FAIL  %s (sonde inexploitable, chaine attendue vide)\n' "$name"
    FAIL=$((FAIL+1))
    return 0
  fi
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

# Image eprouvee : DERIVEE de compose.yaml, jamais codee en dur. Le harnais doit
# eprouver exactement l'image que le deploiement utilisera ; deux constantes a
# tenir synchronisees finissent toujours par diverger, et le harnais passerait
# alors au vert sur une image que personne ne deploie.
#
# Le SERVICE EST NOMME, et ce n'est pas une precaution de style. `--images` sans
# argument rend une ligne par service, dans un ordre NON DETERMINISTE : mesure
# du 2026-08-30 sur ce compose a deux services, 12 appels ont rendu 6 fois
# vrising en premier et 6 fois watchtower. Un `head -1` etait donc un tirage a
# pile ou face, et la CI a effectivement eprouve l'image de watchtower -- un
# binaire Go sans shell, d'ou huit checks en echec sur
# `exec: "sh": executable file not found`.
IMAGE=$(docker compose config --images vrising 2>/dev/null | head -1)
if [ -z "$IMAGE" ]; then
  printf "ERREUR: impossible de deduire l'image depuis compose.yaml.\n" >&2
  exit 2
fi

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
  docker run --rm --entrypoint wine "$IMAGE" --version
check_out "runtime: jeu present" "VRisingServer.exe" \
  docker run --rm --entrypoint ls "$IMAGE" /opt/vrising/game
check_out "runtime: mcrcon present" "Usage: mcrcon" \
  docker run --rm --entrypoint mcrcon "$IMAGE" -h
check_out "runtime: prefixe Wine initialise" "system.reg" \
  docker run --rm --entrypoint ls "$IMAGE" /opt/vrising/.wine
# uid 1000 et non un uid haut : voir le commentaire du Dockerfile — il doit
# correspondre au PUID par defaut pour eviter un copy-up de 1,4 Go au demarrage.
check_out "runtime: utilisateur vrising en uid 1000" "uid=1000" \
  docker run --rm --entrypoint id "$IMAGE" vrising
# `command -v steamcmd` est INTROUVABLE meme dans le builder, ou steamcmd
# existe pourtant a /opt/steamcmd/steamcmd.sh : il n'est jamais sur le PATH.
# L'assertion passait donc dans les DEUX images sans rien discriminer. On teste
# le chemin d'installation reel, verifie present dans le builder et absent ici.
check_absent "runtime: steamcmd absent de l'image finale" \
  docker run --rm --entrypoint test "$IMAGE" -e /opt/steamcmd
# L'outillage de compilation ne doit pas non plus avoir survecu a COPY --from.
check_absent "runtime: outillage de build absent" \
  docker run --rm --entrypoint sh "$IMAGE" -c \
    'for b in gcc make git; do command -v "$b" >/dev/null 2>&1 && exit 0; done; exit 1'
check_out "runtime: prefixe Wine possede par vrising" "1000" \
  docker run --rm --entrypoint stat "$IMAGE" -c %u /opt/vrising/.wine

echo
echo "== Etancheite de l'image =="
# L'image est destinee a etre publiee dans un registre. Ces trois assertions
# prouvent qu'elle n'emporte ni donnees d'exploitation ni secrets. Elles sont
# vraies aujourd'hui PAR CONVENTION (.dockerignore exclut .env, le volume et le
# prefixe de travail) : rien ne le verifiait, et une convention que rien ne
# verifie se perd au premier .dockerignore retouche.
#
# Chaque sonde porte son CONTROLE POSITIF : elle prouve d'abord qu'elle sait
# trouver quelque chose qui existe, avant d'affirmer qu'elle n'a rien trouve.
# Sans lui, une sonde cassee (find absent, chemin deplace) rendrait une chaine
# vide, donc « rien trouve », donc un PASS mensonger -- le meme piege que les
# assertions par negation de la Tache 3 et que le troisieme cas de
# check_absent. La sonde annonce alors "SONDE=cassee", qui ne matche pas
# l'attendu et fait donc echouer le check.
#
# Toutes trois ont ete vues ECHOUER le 2026-08-28 sur une image volontairement
# contaminee (une sauvegarde, un /root/.env, un secret en clair dans
# /etc/fuite.conf, une variable RCON_PASSWORD dans Config.Env).

# `-xdev` : reste dans le systeme de fichiers de l'image, sans descendre dans
# /proc, /sys et /dev que `docker run` y monte.
check_out "image: aucune sauvegarde ni .env embarque" "SONDE=ok RIEN" \
  docker run --rm --entrypoint sh "$IMAGE" -c '
    ctrl=$(find /opt/vrising/game -maxdepth 1 -name "VRisingServer.exe" 2>/dev/null)
    [ -n "$ctrl" ] || { echo "SONDE=cassee"; exit 0; }
    t=$(find / -xdev \( -name "*.save.gz" -o -name "AutoSave*" -o -name ".env" \) 2>/dev/null)
    [ -z "$t" ] && echo "SONDE=ok RIEN" || echo "SONDE=ok TROUVE"
  '

# Les valeurs du .env, recherchees en clair dans l'image.
# Zones fouillees : tout SAUF /opt/vrising/game et /opt/wine-stable. Ces deux
# arbres viennent d'amont (SteamCMD, apt WineHQ) et aucun de nos RUN n'y ecrit,
# ils ne peuvent donc pas contenir un secret a nous ; les fouiller ajouterait
# 3,5 Go de binaires a grep a chaque passe, pour zero menace couverte. Un
# secret de ce depot n'entre que par le contexte de build ou par un RUN, qui
# atterrissent dans les zones listees.
# LIMITE ASSUMEE : `grep -I` saute les fichiers binaires. Un secret enfoui dans
# un binaire nous echapperait ; aucun chemin ne l'y mettrait aujourd'hui.
SECRET_VR=$(lire_env VR_PASSWORD)
SECRET_RCON=$(lire_env RCON_PASSWORD)
check_out "image: aucune valeur secrete du .env en clair" "SONDE=ok RIEN" \
  docker run --rm -e S1="$SECRET_VR" -e S2="$SECRET_RCON" \
    --entrypoint sh "$IMAGE" -c '
    n=0
    for v in "$S1" "$S2"; do [ -n "$v" ] && n=$((n + 1)); done
    [ "$n" -gt 0 ] || { echo "SONDE=cassee-aucun-secret-a-chercher"; exit 0; }
    ctrl=$(grep -rIlF "entrypoint" /usr/local/bin 2>/dev/null | head -1)
    [ -n "$ctrl" ] || { echo "SONDE=cassee"; exit 0; }
    t=""
    for v in "$S1" "$S2"; do
      [ -n "$v" ] || continue
      f=$(grep -rIlF -- "$v" /etc /root /home /usr/local /opt/vrising/.wine \
            2>/dev/null | head -1)
      [ -n "$f" ] && t="$f"
    done
    [ -z "$t" ] && echo "SONDE=ok RIEN" || echo "SONDE=ok TROUVE"
  '

# Config.Env de l'image : un ENV pose au build survit dans les metadonnees et se
# lit par `docker image inspect`, sans meme tirer les couches.
# Le motif accepte n'importe quel prefixe ou suffixe : le premier jet exigeait
# « PASS= » et ne voyait donc pas RCON_PASSWORD=. Faux PASS constate sur
# l'image contaminee, corrige, re-verifie.
check_out "image: aucune variable sensible dans Config.Env" "SONDE=ok RIEN" \
  sh -c '
    e=$(docker image inspect "$1" \
          -f "{{range .Config.Env}}{{println .}}{{end}}" 2>/dev/null)
    printf "%s" "$e" | grep -q "PATH=" || { echo "SONDE=cassee"; exit 0; }
    if printf "%s" "$e" \
         | grep -qE "^[A-Za-z_]*(PASS|SECRET|TOKEN|KEY|CRED)[A-Za-z_]*=."; then
      echo "SONDE=ok TROUVE"
    else
      echo "SONDE=ok RIEN"
    fi
  ' sh "$IMAGE"

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
echo "== Droits du prefixe Wine =="
# C1 de la revue finale de branche (2026-08-28). L'entrypoint chowne le
# REPERTOIRE du prefixe juste avant de comparer `stat -c %u` de ce meme
# repertoire a PUID : la garde etait donc toujours fausse et le `chown -R`
# qu'elle protege, du CODE MORT. Consequence pour PUID != 1000 : `cp -a`
# preserve l'uid 1000 du gabarit, seule la racine passe a PUID, tout le CONTENU
# reste non inscriptible -- et l'avertissement prevu pour ce cas ne s'affiche
# jamais. Panne silencieuse. Ne mord pas avec le PUID=1000 par defaut, mais
# docs/deploiement.md demande explicitement `id -u`.
#
# La sonde n'utilise pas la pile compose : un prefixe jetable d'UN SEUL fichier
# suffit, puisque la sentinelle `system.reg` presente fait sauter la copie
# initiale. Le conteneur est tue des la fin de la section « Droits » de
# l'entrypoint, que la ligne « adminlist: » suit immediatement : une a deux
# secondes, et le serveur n'est jamais lance.
check "droits: le prefixe Wine est reattribue quand PUID differe de son uid" \
  sh -c '
    # Deux niveaux, et ce n est pas du zele : le conteneur chowne le REPERTOIRE
    # du prefixe, ce qui nous en retirerait l acces (mktemp -d cree en 0700) --
    # ni lecture de l uid ensuite, ni nettoyage. Le prefixe jetable est donc un
    # sous-repertoire en 0777, abrite des tiers par un parent en 0700.
    base=$(mktemp -d) || exit 1
    d="$base/prefixe"
    mkdir -m 0777 "$d" || { rm -rf "$base"; exit 1; }
    : >"$d/system.reg" || { rm -rf "$base"; exit 1; }
    # Cible = uid du fichier + 1 : garantit un ecart quel que soit l uid qui
    # execute le harnais, sans coder 1001 en dur.
    cible=$(( $(stat -c %u "$d/system.reg") + 1 ))
    cid=$(docker run -d -e PUID="$cible" -e PGID="$cible" \
            -v "$d":/opt/vrising/.wine-run "$1" 2>/dev/null) \
      || { rm -rf "$base"; exit 1; }
    i=0
    while [ "$i" -lt 30 ]; do
      docker logs "$cid" 2>&1 | grep -q "adminlist:" && break
      sleep 1; i=$((i + 1))
    done
    docker rm -f "$cid" >/dev/null 2>&1
    uid=$(stat -c %u "$d/system.reg")
    # Nettoyage PAR CONTENEUR, et non `rm -rf` : Wine a le temps d amorcer le
    # prefixe avant d etre tue et y laisse des repertoires en 0700 sous l uid
    # cible, que l hote ne peut pas supprimer (mesure du 2026-08-28). Meme
    # image que la sonde, donc aucune dependance nouvelle pour le harnais.
    docker run --rm --entrypoint rm -v "$base":/nettoyage "$1" \
      -rf /nettoyage/prefixe >/dev/null 2>&1
    rmdir "$base" 2>/dev/null
    test "$uid" = "$cible"
  ' sh "$IMAGE"

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
# Valeur attendue derivee du .env (premier identifiant de VRISING_ADMINS)
# plutot que codee en dur : l'humain a remplace la valeur de test posee au
# Step 2 par son vrai SteamID64 pendant le Round 1. Coder la valeur en dur
# aurait echoue des le prochain redemarrage du conteneur, sans lien avec un
# vrai defaut de cette tache.
ADMIN_ATTENDU=$(. ./.env 2>/dev/null; printf '%s' "$VRISING_ADMINS" | cut -d',' -f1 | tr -d ' \t')
check_out "declaratif: adminlist contient le SteamID" "$ADMIN_ATTENDU" \
  cat vrising-persistent-data/Settings/adminlist.txt
check_out "declaratif: regles de jeu appliquees" '"MaterialYieldModifier_Global": 1.5' \
  sh -c 'docker compose logs 2>&1 | sed "s/\x1b\[[0-9;]*m//g"'
check_out "declaratif: taille de clan appliquee" '"ClanSize": 4' \
  sh -c 'docker compose logs 2>&1 | sed "s/\x1b\[[0-9;]*m//g"'
# Trois checks du parseur commun docker/steamids.sh, sur l'hote, sans
# conteneur : ils tournent en millisecondes, contrairement a un aller-retour
# reconstruction d'image + redemarrage (plusieurs minutes).
# Regression du defaut F5 : tr -d '[:space:]' supprimait aussi les retours a
# la ligne inseres par tr ',' '\n', concatenant tous les identifiants des le
# deuxieme. Doit produire deux lignes distinctes.
check "declaratif: steamids virgule produit deux lignes" \
  bash -c '
    source docker/steamids.sh
    tmp=$(mktemp)
    ecrire_steamids "76561198000000000,76561198000000001" "$tmp"
    n=$(wc -l < "$tmp")
    rm -f "$tmp"
    test "$n" -eq 2
  '
check "declaratif: steamids identifiant malformise rejete" \
  bash -c '
    source docker/steamids.sh
    tmp=$(mktemp)
    ecrire_steamids "76561198000000000,trop-court,76561198abcde0000" "$tmp"
    n=$(wc -l < "$tmp")
    rm -f "$tmp"
    test "$n" -eq 1
  '
check "declaratif: steamids espaces autour virgule toleres" \
  bash -c '
    source docker/steamids.sh
    tmp=$(mktemp)
    ecrire_steamids "76561198000000000 , 76561198000000001" "$tmp"
    n=$(wc -l < "$tmp")
    rm -f "$tmp"
    test "$n" -eq 2
  '
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
echo "== Secrets =="
check_absent "secrets: mot de passe du serveur absent des journaux" \
  sh -c '
    V=$(. ./.env; printf "%s" "$VR_PASSWORD")
    test -n "$V" || exit 2          # sonde inexploitable, jamais un faux PASS
    docker compose logs 2>&1 | grep -qF "$V"
  '
check_absent "secrets: mot de passe RCON absent des journaux" \
  sh -c '
    V=$(. ./.env; printf "%s" "$RCON_PASSWORD")
    test -n "$V" || exit 2
    docker compose logs 2>&1 | grep -qF "$V"
  '
check_out "secrets: le masque apparait bien dans les journaux" "***MASQUE***" \
  sh -c 'docker compose logs 2>&1'

echo
echo "== Proprete du depot =="
# D1 (2026-08-28) : le plan exigeait .env et vrising-persistent-data/ non
# verses. L'humain a choisi de les verser deliberement ("since it's a test
# private repo", commit d3786c6) -- son choix explicite prime sur le plan.
# skip() plutot que suppression : le code de l'assertion reste dans ce
# fichier, lisible par qui reprendrait ce depot hors de ce contexte de test.
# Le prefixe FILTER="..." ne force le skip QUE pour cet appel de check() : une
# affectation de variable devant un nom de fonction bash n'est active que
# pour la duree de cet appel (mesure ci-dessous), le FILTER global -- donc les
# checks suivants, y compris le troisieme de cette section -- n'en est pas
# affecte.
#   $ bash -c 'FILTER=x f() { echo $FILTER; }; FILTER=y f; echo $FILTER'
#   y
#   x
FILTER="perime-D1-2026-08-28" check "depot: le .env n'est pas versionne" \
  sh -c '! git ls-files --error-unmatch .env 2>/dev/null'
FILTER="perime-D1-2026-08-28" check "depot: le volume de donnees n'est pas versionne" \
  sh -c 'test -z "$(git ls-files vrising-persistent-data)"'
check "depot: aucun fichier root:root versionne" \
  sh -c 'test -z "$(git ls-files | xargs -r stat -c "%U" | grep -x root)"'

echo
echo "== Arret propre =="
# Le budget de grace, prouve sur l'hote en quelques secondes plutot qu'en
# arretant un vrai serveur : c'est la raison d'etre de docker/attente_arret.sh.
check "arret: le budget de grace se compte en secondes, pas en tours de boucle" \
  bash -c '
    source docker/attente_arret.sh
    # `sleep` remplace par une attente 100 fois plus courte : un budget compte
    # en TOURS s epuise alors en ~0,03 s, un budget compte a l horloge tient
    # ses 3 secondes. C est l ecart MESURE en production le 2026-08-28, dans
    # l autre sens -- le serveur en cours de demarrage rendait chaque tour six
    # fois plus cher qu une seconde, si bien que 300 tours ont dure 1996 s.
    # Le conteneur depassait donc de six fois le stop_grace_period de Docker.
    sleep() { command sleep 0.01; }
    command sleep 60 & p=$!
    debut=$(date +%s)
    attendre_sortie "$p" 3
    rc=$?
    reel=$(( $(date +%s) - debut ))
    kill "$p" 2>/dev/null
    test "$rc" -eq 1 && test "$reel" -ge 2
  '
# Contre-partie du budget : l attente doit rendre la main des que le processus
# sort, sans consommer le budget entier. Un arret reel dure ~220s pour un
# budget de 300s, la difference est du temps ou le conteneur serait fige.
check "arret: l attente rend la main des que le processus sort" \
  bash -c '
    source docker/attente_arret.sh
    command sleep 1 & p=$!
    debut=$(date +%s)
    attendre_sortie "$p" 300
    rc=$?
    reel=$(( $(date +%s) - debut ))
    test "$rc" -eq 0 && test "$reel" -lt 10
  '

# PRECONDITION de tout ce qui suit : un serveur REELLEMENT demarre. Le check de
# banlist ci-dessus redemarre le conteneur et attend 20 s en dur, ce qui suffit
# a SA preuve mais pas au serveur, qui met ~90 s a charger son monde. Mesure du
# 2026-08-28 : la section arretait donc un serveur lance 24 s plus tot, ou RCON
# ACCEPTE la commande shutdown sans que le serveur y donne suite -- le budget de
# grace s'epuisait en entier (300 s), SIGKILL, et les deux assertions d'arret
# propre echouaient sur un defaut qui n'existait pas. Sans cette porte, elles
# sont une loterie sur la vitesse de demarrage.
# Le marqueur est la FIN DU CHARGEMENT DU MONDE et non "Server Setup Complete",
# qui arrive trop tot. Mesure du 2026-08-28, horodatages d'un meme demarrage :
#   19:38:53  [rcon] Started listening         <- RCON accepte deja des commandes
#   19:38:54  commande shutdown transmise      <- le harnais arretait ICI
#   19:39:07  PersistenceV2 - Finished Loading <- monde reellement charge
# Dans cette fenetre de 14 s le serveur AUTHENTIFIE le client RCON, execute
# l'annonce ("[rcon] Executing command: sendserverannouncement") et laisse
# tomber le `shutdown` qui suit, sans erreur ni trace. mcrcon rend 0, le
# gestionnaire croit avoir transmis l'arret, et le budget de grace s'epuise en
# entier avant SIGKILL. Un serveur joignable par RCON n'est donc pas encore un
# serveur arretable.
# La fenetre est bornee au demarrage de l'INSTANCE COURANTE et non a un
# horodatage pris ici : une ligne du meme texte issue d'un demarrage precedent,
# conservee dans le journal JSON de Docker, ferait passer la precondition sans
# qu'aucun serveur soit pret.
check "arret: serveur pret avant l'arret (precondition)" \
  sh -c '
    cid=$(docker compose ps -q vrising)
    test -n "$cid" || exit 1
    depuis=$(docker inspect -f "{{.State.StartedAt}}" "$cid")
    test -n "$depuis" || exit 1
    i=0
    while [ "$i" -lt 60 ]; do
      docker compose logs --since "$depuis" 2>&1 | sed "s/\x1b\[[0-9;]*m//g" \
        | grep -qF "PersistenceV2 - Finished Loading" && exit 0
      sleep 3; i=$((i + 1))
    done
    exit 1
  '

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
#
# SINCE_ARRET (F1, 2026-08-28) : capture d'horodatage NUE, hors de tout
# `check`/`check_out`, donc executee inconditionnellement quel que soit le
# filtre passe a verify.sh -- meme patron que SINCE dans la section
# "redemarrage" plus haut. Necessaire pour le check D6 juste apres : mesure
# du 2026-08-27 sur ce depot, les journaux cumules du conteneur contiennent
# DEJA 3 occurrences de "serveur arrete proprement" et 2 de
# "delai de 300s depasse, SIGKILL", issues des passes anterieures du harnais.
# Un `grep` sans borne temporelle trouverait l'une des trois lignes anciennes
# meme si l'arret DE CE RUN tombait dans le repli SIGKILL -- faux PASS, et le
# check precedent ne rattrape rien puisque shutdown_handler fait exit 0 dans
# les deux branches.
SINCE_ARRET=$(date -u +%Y-%m-%dT%H:%M:%SZ)
check "arret: docker compose stop rend exit 0" \
  sh -c '
    cid=$(docker compose ps -q vrising)
    test -n "$cid" || exit 1
    docker compose stop >/dev/null 2>&1
    test "$(docker inspect -f "{{.State.ExitCode}}" "$cid")" = "0"
  '
# D6 (2026-08-28) : le check precedent ne prouve que l'ExitCode 0, pas que
# l'arret est passe par RCON -- un conteneur peut sortir en 0 sans que
# shutdown_handler ait jamais tourne. Sa branche RCON journalise
# "serveur arrete proprement en ${waited}s" (docker/entrypoint.sh) ; sa
# branche de repli SIGKILL journalise "delai de ${GRACE}s depasse, SIGKILL" a
# la place -- un texte different, donc ce check echouerait bien si l'arret
# tombait dans ce repli. `--since "$SINCE_ARRET"` (capture ci-dessus, AVANT le
# stop) borne la lecture au seul arret de CE run : une ligne ancienne, meme
# identique, est hors fenetre et ne peut plus produire de faux PASS (F1). Le
# conteneur est deja arrete (check precedent) : `docker compose logs` reste
# consultable, `--since` y compris, sur un conteneur sorti.
check_out "arret: arret ordonne effectivement journalise" "serveur arrete proprement" \
  docker compose logs --since "$SINCE_ARRET"

echo
echo "== Arret degrade (RCON injoignable) =="
# C3 de la revue finale de branche (2026-08-28). `shutdown_handler` faisait
# `exit 0` dans LES DEUX branches, et journalisait « serveur arrete proprement »
# des que le processus avait disparu -- y compris quand RCON etait injoignable
# et que le repli SIGTERM avait tue Wine SANS sauvegarde. Les deux sondes de la
# section precedente passent donc aussi bien sur un arret reussi que sur un
# arret perdu : le defaut n4 de la spec, raison d'etre de la moitie du projet,
# n'avait aucune assertion valide derriere lui.
#
# On reproduit le repli sans le simuler : on arrete le serveur PENDANT son
# demarrage, avant que son RCON n'ecoute. mcrcon echoue alors pour de vrai.
# `docker compose start` et non `up -d` : `up` recreerait le conteneur au
# moindre ecart de configuration. Le monde n'est pas encore charge a cet
# instant, il n'y a donc rien a perdre a cet arret.
#
# Le conteneur reste arrete a la fin, comme apres la section precedente.
DEG_LOG=/tmp/verify-arret-degrade.log
DEG_RC=/tmp/verify-arret-degrade.rc
DEG_N1="arret degrade: le repli SIGTERM a bien ete exerce"
DEG_N2="arret degrade: aucune annonce d'arret propre mensongere"
DEG_N3="arret degrade: le conteneur ne sort pas en 0"
rm -f "$DEG_LOG" "$DEG_RC"
# La mise en scene est couteuse (un demarrage et un arret) : elle ne tourne que
# si au moins une des trois assertions est selectionnee par le filtre.
if ! skip "$DEG_N1" || ! skip "$DEG_N2" || ! skip "$DEG_N3"; then
  # La mise en scene exige un demarrage NEUF : sur un conteneur deja lance, la
  # ligne « serveur lance » attendue plus bas appartient au demarrage
  # precedent et n'apparaitra jamais dans la fenetre. No-op immediat dans la
  # passe complete, ou la section precedente a deja arrete le conteneur.
  docker compose stop >/dev/null 2>&1
  DEG_SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  docker compose start >/dev/null 2>&1
  DEG_CID=$(docker compose ps -q vrising)
  # On attend la ligne de lancement et non « Server Setup Complete » : c'est
  # precisement la fenetre ou RCON n'ecoute pas encore. Le trap est installe
  # dans la foulee de cette ligne, sans E/S intercalee.
  DEG_I=0
  while [ "$DEG_I" -lt 120 ]; do
    docker compose logs --since "$DEG_SINCE" 2>&1 \
      | grep -qF "serveur lance (pid" && break
    sleep 1; DEG_I=$((DEG_I + 1))
  done
  # Le `trap` est installe juste APRES cette ligne de journal (defaut I1 de la
  # revue : la fenetre de course est reelle, mesuree le 2026-08-28 -- un stop
  # tombe une seconde trop tot a coute les 330s de grace puis un SIGKILL).
  # Cette seconde d'attente met la mise en scene hors de cette fenetre.
  sleep 1
  DEG_SINCE_STOP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  docker compose stop >/dev/null 2>&1
  docker inspect -f '{{.State.ExitCode}}' "$DEG_CID" >"$DEG_RC" 2>/dev/null
  docker compose logs --since "$DEG_SINCE_STOP" >"$DEG_LOG" 2>&1
fi

# Precondition, et non un simple confort : sans elle, un arret qui serait passe
# par RCON (demarrage plus rapide que prevu) ferait passer les deux assertions
# suivantes sans avoir exerce la branche qu'elles couvrent -- test vide.
check_out "$DEG_N1" "RCON injoignable" cat "$DEG_LOG"
# `grep -qF` sur un fichier : sonde deterministe (0 trouve / 1 absent), donc
# check_absent distingue bien une absence d'un echec de sonde.
check_absent "$DEG_N2" sh -c 'grep -qF "serveur arrete proprement" "$1"' sh "$DEG_LOG"
# Le code de sortie doit DISCRIMINER : 0 est reserve a l'arret dont la
# sauvegarde est prouvee. La garde `-s` interdit le faux PASS d'un fichier vide
# (mise en scene non jouee), ou `test "" != "0"` serait vrai.
check "$DEG_N3" sh -c 'test -s "$1" && test "$(cat "$1")" != "0"' sh "$DEG_RC"

echo
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"

# Un filtre mal orthographie ne doit pas passer pour un succes.
if [ -n "$FILTER" ] && [ $((PASS + FAIL)) -eq 0 ]; then
  printf 'ERREUR: le filtre "%s" ne correspond a aucun check.\n' "$FILTER"
  exit 2
fi

[ "$FAIL" -eq 0 ]
