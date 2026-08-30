# Administrer le serveur en jeu

Deux choses distinctes, et les confondre fait perdre du temps : **déclarer** qui
est administrateur, ce qui se fait dans le `.env` et demande un redémarrage, et
**utiliser** ces pouvoirs, ce qui se fait dans la console du jeu.

> **Statut de vérification.** « Déclarer les administrateurs » est prouvé par le
> harnais de ce dépôt et a été appliqué sur le serveur de production le
> 2026-08-30. La liste des commandes RCON a été relevée le même jour, en
> interrogeant le serveur lui-même. « Utiliser en jeu » ne l'a pas été : ni
> Steam ni V Rising ne sont installés sur la machine où cette page a été
> écrite. Cette partie vient de la documentation des hébergeurs, pas d'une
> observation. Voir « Ce qui n'a pas été vérifié » en fin de page.

## Déclarer les administrateurs

Dans le `.env` **du serveur** — pas celui de ta machine de développement, qui
n'a aucun effet sur la production :

```bash
VRISING_ADMINS=76561198055911111,76561198048378205
```

Le séparateur est la virgule, et les espaces autour sont tolérés. Le
SteamID64 fait **17 chiffres** ; on le lit dans l'URL d'un profil Steam en
`/profiles/<17 chiffres>`, ou via n'importe quel convertisseur si le profil a
une URL personnalisée.

Trois règles du parseur ([`docker/steamids.sh`](../docker/steamids.sh)), chacune
couverte par une assertion du harnais :

| Entrée | Résultat |
| --- | --- |
| `id1,id2` | deux administrateurs |
| `id1 , id2` | deux administrateurs, espaces retirés |
| `12345` | **rejeté en silence** — aucun message, aucune erreur |

Cette dernière ligne est le vrai piège : un identifiant tronqué ou mal copié ne
produit aucun avertissement, ni au démarrage ni en jeu. Il disparaît, c'est
tout. Le compteur du journal est le seul moyen de s'en apercevoir — voir
« Vérifier » ci-dessous.

Une valeur **vide** ne donne aucun administrateur, également sans le signaler.
Le serveur de production a tourné ainsi pendant plusieurs jours sans que rien
ne l'indique.

### N'édite jamais `adminlist.txt` à la main

L'entrypoint le **réécrit intégralement à chaque démarrage** depuis
`VRISING_ADMINS`. Toute modification directe du fichier est perdue au
redémarrage suivant. C'est délibéré : les administrateurs relèvent de la
configuration d'infrastructure, pas de l'état du monde.

La banlist obéit à la règle inverse — le serveur en est propriétaire, le `.env`
ne fait que l'amorcer si le fichier est absent.

### Appliquer

Un redémarrage est nécessaire : le fichier n'est écrit qu'au démarrage.

```bash
docker compose up -d
```

Compter environ **six minutes** : ~230 s d'arrêt ordonné, pendant lesquelles le
jeu prévient les joueurs puis écrit son monde, puis ~90 s de rechargement. La
commande reste silencieuse tout du long — ce n'est pas un blocage, et
l'interrompre laisse le serveur à terre.

### Vérifier

```bash
docker compose logs vrising | grep adminlist
```

```
[entrypoint] adminlist: 2 entree(s)
```

Le compte doit correspondre au nombre d'identifiants attendus. S'il est
inférieur, un identifiant a été rejeté pour mauvais format.

## Utiliser les pouvoirs en jeu

1. **Activer la console** — Options → General → activer *Console*.
2. **L'ouvrir** — touche `~` en jeu.
3. **S'authentifier** — taper `adminauth`. Le jeu confirme dans le chat :
   *« You now have Administrator priveleges (SuperAdmin)! »*
4. **Lister ce qui est disponible** — taper `list`.

La quatrième étape vaut mieux que n'importe quelle liste recopiée ici : elle
affiche les commandes que **ton** serveur, dans **sa** version, expose
réellement. Une liste figée dans cette page serait périmée à la première mise à
jour du jeu.

Être dans `adminlist.txt` ne suffit pas : `adminauth` est à retaper à chaque
session de jeu.

> **Attention aux tutoriels en ligne.** La plupart des pages qui listent des
> commandes V Rising décrivent des commandes préfixées d'un point (`.kick`,
> `.help`…). Elles appartiennent à **VCF, un framework de mods**, et non au jeu
> vanilla. Ce serveur n'a aucun mod : ces commandes n'y existent pas.

## Ce que RCON permet, et ne permet pas

RCON ne sert pas à l'administration. Relevé le 2026-08-30 en interrogeant le
serveur de production, voici **l'intégralité** de ce qu'il expose :

```
runcommand  announce  announcerestart  shutdown  cancelshutdown
version     time      name             description  password     help
```

Aucune commande n'y gère les administrateurs, les bannissements ou les joueurs.
`runcommand <console command>` est la seule porte vers la console du serveur, et
sa propre aide prévient : *« no feedback for this unfortunately! »* — la
commande part, rien ne revient.

RCON n'est d'ailleurs **pas joignable depuis le réseau** : le protocole est en
clair, le port 25575 n'est jamais publié, et le serveur ne l'écoute que sur
`127.0.0.1`. Son unique client est l'entrypoint lui-même, pour l'arrêt ordonné.

## Ce qui n'a pas été vérifié

- La procédure « Utiliser les pouvoirs en jeu » n'a **pas** été exécutée. Ni
  Steam ni V Rising ne sont installés sur la machine où cette page a été
  écrite. Le nom des commandes, la touche `~` et le texte de confirmation
  viennent de la documentation des hébergeurs.
- Que `adminauth` soit à retaper à chaque session vient de la même source.
- Il n'a pas été vérifié si le serveur relit `adminlist.txt` à chaud. La
  procédure ci-dessus passe par un redémarrage, qui fonctionne dans tous les
  cas.
