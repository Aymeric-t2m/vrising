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
check_out "builder: mcrcon compile" "mcrcon" \
  docker run --rm vrising-builder:test /usr/local/bin/mcrcon --version

echo
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"

# Un filtre mal orthographie ne doit pas passer pour un succes.
if [ -n "$FILTER" ] && [ $((PASS + FAIL)) -eq 0 ]; then
  printf 'ERREUR: le filtre "%s" ne correspond a aucun check.\n' "$FILTER"
  exit 2
fi

[ "$FAIL" -eq 0 ]
