#!/usr/bin/env bash
# Attente bornee de la sortie d'un processus, source par l'entrypoint pour
# borner l'arret ordonne du serveur.
#
#   attendre_sortie <pid> <budget_en_secondes>
#     rc 0 : le processus est sorti dans le budget
#     rc 1 : le budget est epuise, le processus vit encore
#   ECOULE recoit le nombre de secondes REELLES attendues.
#
# Fichier separe plutot que boucle interne a entrypoint.sh, meme motif que
# docker/steamids.sh : le budget est une regle qui se prouve en secondes sur
# l'hote (voir tests/verify.sh, section "Arret propre"), alors que la meme
# logique enfouie dans le gestionnaire de signaux ne se prouverait qu'en
# arretant un vrai serveur, soit plusieurs minutes par essai.
#
# Le budget se mesure a l'horloge et NON en nombre de tours : un tour coute
# `sleep 1` PLUS le cout de ses appels systeme, et ce supplement n'est pas
# borne. Mesure du 2026-08-28 : pendant le demarrage du serveur, chaque tour
# revenait a ~6,6 s, si bien qu'un budget de 300 « tours » a dure 1996 s
# reelles. Le conteneur depassait alors de six fois le stop_grace_period de
# Docker, qui l'aurait tue en pleine sauvegarde -- le defaut meme que ce
# budget existe pour eviter.
# `SECONDS` est un compteur natif de bash, donc sans fork par tour,
# contrairement a `date +%s`.
attendre_sortie() {
  local pid="$1" budget="$2"
  local debut=$SECONDS
  while kill -0 "$pid" 2>/dev/null && [ $((SECONDS - debut)) -lt "$budget" ]; do
    sleep 1
  done
  ECOULE=$((SECONDS - debut))
  kill -0 "$pid" 2>/dev/null && return 1
  return 0
}
