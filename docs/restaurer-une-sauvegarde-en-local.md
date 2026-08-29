# Rejouer une sauvegarde du serveur en solo

Récupérer le monde du serveur distant et l'ouvrir dans le jeu en partie solo,
sans faire tourner de serveur.

C'est possible parce que **le format de sauvegarde est identique** entre un
serveur dédié et une partie solo. Seul le dossier d'accueil change : le serveur
écrit sous `VRisingServer`, le client solo sous `VRising`. Toute la procédure
consiste à déplacer un dossier du premier vers le second.

> **Statut de vérification.** Les étapes 1 et 2 ont été exécutées et mesurées le
> 2026-08-25 contre le serveur de production. L'étape 3 ne l'a pas été : ni
> Steam ni V Rising ne sont installés sur la machine où cette procédure a été
> écrite. Les chemins qu'elle donne viennent de la documentation de Stunlock et
> de la convention Proton, pas d'une observation. Voir « Ce qui n'a pas été
> vérifié » en fin de page.

---

## Étape 1 — Récupérer le monde depuis le serveur

**Le serveur peut rester allumé.** V Rising écrit ses sauvegardes dans un
sous-dossier `.TEMP` puis les déplace à leur emplacement définitif : un fichier
`.save.gz` visible dans le dossier est donc toujours complet. On exclut `.TEMP`
et on ne risque pas de capturer une écriture en cours.

```bash
SERVEUR=<utilisateur>@<adresse-du-serveur>
DEPOT=<chemin-du-depot-sur-le-serveur>
MONDE=vrising_world          # valeur de VR_SAVE_NAME dans .env

ssh "$SERVEUR" \
  "tar czf - -C $DEPOT/vrising-persistent-data/Saves/v4 --exclude=.TEMP $MONDE" \
  | tar xzf - -C .
```

`tar` par-dessus SSH plutôt que `rsync` : `tar` et `ssh` suffisent, là où
`rsync` doit être présent des **deux** côtés — ce qui n'est pas acquis sur une
installation minimale. Mesure du 2026-08-25 : 2,9 s pour 8 sauvegardes, soit
une soixantaine de mégaoctets.

Vous obtenez un dossier `vrising_world/` contenant :

| Fichier | Rôle |
|---|---|
| `AutoSave_<n>.save.gz` | les sauvegardes, la plus haute est la plus récente |
| `StartDate.json` | date de création du monde |
| `SessionId.json` | identifiant de session |

## Étape 2 — Vérifier l'intégrité avant d'aller plus loin

Une sauvegarde tronquée se voit à ce test et pas au poids du fichier. À faire
systématiquement : c'est deux secondes, et ça évite de découvrir le problème
une fois le monde écrasé.

```bash
for f in vrising_world/*.save.gz; do
  gzip -t "$f" && echo "OK   $f" || echo "CORROMPU  $f"
done
```

Tout doit être `OK`. Une seule ligne `CORROMPU` : relancez l'étape 1, et si le
fichier reste illisible, écartez-le — les autres `AutoSave_<n>` plus anciens
restent utilisables.

## Étape 3 — Installer dans le jeu solo

**Fermez V Rising avant de copier.** Le client lit ses sauvegardes au
démarrage et réécrit le dossier en quittant ; copier pendant qu'il tourne fait
perdre l'opération.

Le dossier de destination dépend du système :

**Windows**

```
%USERPROFILE%\AppData\LocalLow\Stunlock Studios\VRising\Saves\v4\
```

**Linux (Steam Proton)** — AppID `1604030` :

```
~/.steam/steam/steamapps/compatdata/1604030/pfx/drive_c/users/steamuser/AppData/LocalLow/Stunlock Studios/VRising/Saves/v4/
```

Selon l'installation, la racine Steam peut être `~/.local/share/Steam` au lieu
de `~/.steam/steam`. Pour la trouver sans deviner :

```bash
find ~ -type d -path "*compatdata/1604030/pfx*" -name VRising 2>/dev/null
```

Copiez-y le dossier récupéré :

```bash
DEST="$HOME/.steam/steam/steamapps/compatdata/1604030/pfx/drive_c/users/steamuser/AppData/LocalLow/Stunlock Studios/VRising/Saves/v4"
cp -r vrising_world "$DEST/"
```

Le piège à connaître : la destination est **`VRising`**, pas `VRisingServer`.
Se tromper de dossier est l'erreur la plus courante, et elle est silencieuse —
le monde n'apparaît simplement pas dans la liste.

Relancez le jeu, le monde doit apparaître parmi les parties solo.

---

## Ce qui n'a pas été vérifié

À traiter comme des hypothèses raisonnables, pas comme des faits mesurés :

- **Les chemins de l'étape 3.** Celui de Windows est documenté par Stunlock ;
  celui de Linux est déduit de la convention Proton et de l'AppID `1604030`.
  Aucun des deux n'a été testé ici, faute de jeu installé.
- **Le sort de `SessionId.json`.** Le dossier est copié tel quel. Si le monde
  n'apparaît pas dans la liste, supprimer ce seul fichier est la première chose
  à essayer — le jeu le régénère. C'est une piste, pas une solution établie.
- **La compatibilité de version.** La sauvegarde est en `PersistenceVersion 4`
  (d'où le `v4` du chemin) et le serveur tournait en `v1.1.14.0-r100531-b2` au
  2026-08-25. Un client plus ancien que le serveur ne saura pas la lire. Un
  client plus récent la migrera, en général sans retour en arrière possible :
  gardez la copie d'origine.

## Points à savoir

- **Le monde est copié, pas déplacé.** Le serveur continue sa partie de son
  côté ; les deux divergent dès la copie. Rien ne les resynchronise ensuite.
- **Votre personnage suit.** Il est rattaché à votre compte Steam, qui est le
  même en solo et sur le serveur.
- **Les règles de jeu ne suivent pas.** `config/ServerGameSettings.json` reste
  côté serveur ; la partie solo applique les réglages choisis à sa création.
- **Faites une copie avant d'écraser.** Si un monde solo du même nom existe
  déjà, `cp -r` l'écrase sans prévenir.

## Voir aussi

- [README](../README.md) — vue d'ensemble du projet
- [Spécification](superpowers/specs/2026-08-21-vrising-server-stack-design.md) —
  décisions de conception, dont l'emplacement des données persistantes
