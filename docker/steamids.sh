#!/usr/bin/env bash
# Parseur commun d'une liste de SteamID64 separes par des virgules (format
# documente dans .env.example), source par l'entrypoint pour adminlist.txt
# et banlist.txt.
#
# Mesure du defaut initial : le pipeline utilisait `tr -d '[:space:]'`, qui
# supprime AUSSI les retours a la ligne que `tr ',' '\n'` vient d'inserer.
# Des le deuxieme SteamID, tout se retrouve concatene sur une seule ligne,
# aucune "ligne" ne fait plus 17 caracteres, et `grep -E '^[0-9]{17}$'` ne
# matche plus rien : le fichier cible reste VIDE en silence.
#   printf '%s' "76561198000000000,76561198000000001" \
#     | tr ',' '\n' | tr -d '[:space:]' | grep -E '^[0-9]{17}$'
#   => rien (rc=1), alors que le format documente ("separes par des
#      virgules") suppose explicitement plusieurs identifiants.
# Correctif : ne retirer QUE espaces et tabulations, jamais les retours a la
# ligne qui separent les identifiants.
#
# Fichier separe plutot que fonction interne a entrypoint.sh : cette forme se
# prouve en millisecondes sur l'hote (voir tests/verify.sh, section
# "Configuration declarative"), alors que la meme logique enfouie dans
# l'entrypoint ne se testerait qu'en reconstruisant l'image et en
# redemarrant un conteneur (plusieurs minutes par essai).
#
# Usage: ecrire_steamids "<liste separee par des virgules>" "<fichier cible>"
ecrire_steamids() {
  local raw="$1" dest="$2"
  : > "$dest"
  if [ -n "$raw" ]; then
    printf '%s' "$raw" \
      | tr ',' '\n' \
      | tr -d ' \t' \
      | grep -E '^[0-9]{17}$' \
      >> "$dest" || true
  fi
}
