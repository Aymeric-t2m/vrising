# Serveur V Rising conteneurisé

Stack Docker pour héberger un serveur dédié V Rising. Le serveur du jeu n'existe
qu'en binaire Windows : il tourne ici sous **Wine**, dans une image Debian, avec
un affichage virtuel Xvfb.

## Structure

| Chemin | Rôle |
| --- | --- |
| [`Dockerfile`](Dockerfile) | Deux étages. `builder` télécharge le jeu par SteamCMD et compile `mcrcon` ; `runtime` installe Wine, construit le préfixe et récupère les deux. |
| [`compose.yaml`](compose.yaml) | Service, ports, montages, `stop_grace_period`. |
| [`docker/entrypoint.sh`](docker/entrypoint.sh) | Cycle de vie : droits, préfixe Wine, Xvfb, lancement, arrêt ordonné. |
| [`tests/verify.sh`](tests/verify.sh) | Harnais de vérification incrémental, une assertion par exigence de la spec. |
| [`.env.example`](.env.example) | Modèle commenté de toute la configuration. Le `.env` réel en dérive. |
| `vrising-persistent-data/` | Sauvegardes et réglages. **C'est la seule chose irremplaçable.** |
| `vrising-wine-prefix/` | Préfixe Wine (~1,4 Go), reconstruit tout seul si supprimé. |

## Deux particularités à connaître avant de toucher au code

**Les variables `VR_*` ne sont lues par aucun script.** C'est
`VRisingServer.exe` qui lit son environnement et surcharge ses réglages, une
fonctionnalité native du jeu. Un `grep VR_ docker/entrypoint.sh` vide ne veut
donc pas dire que la variable est morte. Pour savoir ce qu'un réglage vaut
réellement :

```bash
docker compose logs | grep "overridden by Process Environment Variable"
```

**L'arrêt passe par RCON, pas par un signal.** Le serveur tourne sous Wine, où
un signal Unix ne se traduit pas en arrêt applicatif. L'entrypoint active RCON
en interne (`127.0.0.1:25575`, jamais publié) et lui envoie `shutdown`, ce qui
fait sortir le serveur de lui-même après sauvegarde. Un `trap` est indispensable
pour cela : un PID 1 ne reçoit du noyau que les signaux dont il a explicitement
installé un gestionnaire. Sans lui, `docker compose stop` attendait les 330 s de
`stop_grace_period` puis tuait le serveur sans sauvegarde.

## Exploitation

```bash
docker compose pull              # tirer l'image publiee
docker compose up -d             # demarrer
docker compose logs -f           # suivre
docker compose stop              # arrêt ordonné, ~3 min 30
./tests/verify.sh                # tout vérifier (destructif : arrête le serveur)
./tests/verify.sh arret          # une seule section
```

Le serveur est prêt quand les logs affichent `Server Setup Complete`.

Ports **27015** (jeu) et **27016** (query), en UDP, seuls exposés — RCON ne
l'est pas. Le référencement passe par EOS, pas par le master server Steam
(`VR_LIST_ON_STEAM=false`).

## Documentation

| Document | Contenu |
| --- | --- |
| [Rejouer une sauvegarde en solo](docs/restaurer-une-sauvegarde-en-local.md) | Récupérer le monde du serveur et l'ouvrir en partie solo. |
| [Déploiement](docs/deploiement.md) | Installation sur une machine neuve, pare-feu, administration, limites connues. |
| [Administration](docs/administration.md) | Déclarer les administrateurs dans le `.env`, s'authentifier en jeu, ce que RCON ne fait pas. |
| [Spécification](docs/superpowers/specs/2026-08-21-vrising-server-stack-design.md) | Conception, contraintes, décisions et leurs justifications. |
| [Plan d'implémentation](docs/superpowers/plans/2026-08-21-vrising-server-stack.md) | Découpage en tâches, avec le détail de chacune. |
| [Journal d'exécution](.superpowers/sdd/2026-08-21-vrising-server-stack/) | Briefs, rapports et mesures tâche par tâche. |

Les commentaires du code citent des mesures plutôt que des intentions : chacun
nomme le symptôme observé et le chiffre relevé. Ils valent la lecture avant
toute modification.

## État du plan

Le plan compte 9 tâches, toutes exécutées. La 9 est le masquage des secrets
dans les journaux du conteneur (voir « Limites connues » dans
[la documentation de déploiement](docs/deploiement.md)). Le détail
tâche par tâche est dans le
[journal d'exécution](.superpowers/sdd/2026-08-21-vrising-server-stack/).
