# chromemcp

Lance plusieurs instances Chrome isolées et connecte chacune à une session d’agent via [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp).

Le script est conçu pour Bash sous Linux. La configuration décrite ici a été utilisée sous Debian avec WSL2 et WSLg ; elle peut aussi servir de base sur d’autres distributions.

Exemple fictif. Les titres d’onglets sont visibles ; les PID, ports et noms sont inventés.

```console
$ chrome
Instances Chrome actuellement lancées :
  PID 18421   port 9222  DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 profil=~/.chrome-debug
    Onglets : Documentation API | Tableau de bord local | Tests de connexion
  PID 18703   port 9922  DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 profil=~/.chrome-debug-9922
    Onglets : Pull requests | Logs de test
Que veux-tu faire ?
  [l] Lancer une instance Chrome
  [a] Arrêter une instance existante
  [q] Annuler
Choix [l/a/q] : a
Instances Chrome disponibles :
  1) port 9222 — PID 18421 — ~/.chrome-debug
     Onglets : Documentation API | Tableau de bord local | Tests de connexion
  2) port 9922 — PID 18703 — ~/.chrome-debug-9922
     Onglets : Pull requests | Logs de test
Quelle instance arrêter ? (numéro, Entrée pour annuler) 2
Arrêter Chrome sur le port 9922 (PID 18703) ? [y/N] y
Signal d’arrêt envoyé à Chrome sur le port 9922 (PID 18703).
```

## Fonctions

- `chrome` affiche les instances de débogage déjà lancées : port, PID, profil, environnement graphique et titres de quelques onglets.
- Si une instance existe et qu’aucun port n’est donné, `chrome` propose de lancer une autre instance, d’en arrêter une ou d’annuler.
- Chaque instance utilise un port DevTools et un profil Chrome distincts. Le port par défaut est `9222` ; les autres ports sont choisis dans la plage `9300–9999`.
- L’option d’arrêt du menu affiche les ports et titres, puis demande le numéro de l’instance et une confirmation.
- DevTools écoute sur `127.0.0.1` uniquement.

## Prérequis

- Bash 4.4 ou plus récent.
- Google Chrome Stable.
- `curl`, `iproute2` (`ss`) et `procps` (`pgrep`).
- Python 3 pour afficher les titres d’onglets. Sans Python, le reste du script fonctionne.
- Node.js 20.19 ou une version LTS plus récente, avec `npx`, pour Chrome DevTools MCP. Vérifie les [prérequis actuels du serveur](https://github.com/ChromeDevTools/chrome-devtools-mcp#requirements) avant installation.

Sous Debian/WSL2, les outils système s’installent avec :

```bash
sudo apt update
sudo apt install curl iproute2 procps python3
```

Installe Chrome Stable en suivant les [instructions officielles pour Linux](https://www.google.com/chrome/).

## Installation

Clone le dépôt à l’emplacement utilisé dans les exemples :

```bash
git clone https://github.com/germain-italic/chromemcp.git "$HOME/dev/germain-italic/chromemcp"
```

Ajoute cette ligne à `~/.bashrc` :

```bash
source "$HOME/dev/germain-italic/chromemcp/chrome.sh"
```

Recharge la configuration :

```bash
source ~/.bashrc
```

Le script ne modifie pas lui-même `.bashrc`. Adapte le chemin si tu as cloné le dépôt ailleurs.

## Configurer Chrome DevTools MCP

Ajoute le serveur du port par défaut au champ `mcpServers` de la configuration de Claude Code (`~/.claude.json`). Fusionne cette entrée avec les serveurs déjà présents :

```json
{
  "mcpServers": {
    "chrome-9222": {
      "type": "stdio",
      "command": "npx",
      "args": [
        "-y",
        "chrome-devtools-mcp@latest",
        "--browser-url",
        "http://127.0.0.1:9222",
        "--no-usage-statistics"
      ]
    }
  }
}
```

Redémarre Claude Code après avoir modifié sa configuration MCP. Pour un port non standard, `chrome` écrit automatiquement un fichier de configuration et affiche la commande `claude --mcp-config …` à utiliser.

## Utilisation

```bash
chrome                         # lance Chrome sur 9222 s'il est libre
chrome https://example.org     # ouvre une URL dans la nouvelle instance
chrome 9633                    # lance ou rejoint l'instance sur 9633
chrome 9633 https://example.org
```

Quand une instance existe et que tu lances `chrome` sans port, le menu propose de lancer, d’arrêter ou d’annuler. Pour arrêter, choisis `a`, sélectionne l’instance par son numéro, puis confirme. Le script vérifie à nouveau le port et le profil avant d’envoyer `SIGTERM` au processus maître. Aucun PID n’est à saisir.

Si `9222` est déjà utilisé et que tu choisis de lancer, `chrome` sélectionne un port libre dans `9300–9999`. Un port passé en argument, par exemple `chrome 9633`, cible directement cette instance et saute le menu.

Les profils sont enregistrés dans `~/.chrome-debug` pour le port par défaut, puis dans `~/.chrome-debug-PORT` pour les autres ports. Les journaux d’une instance se trouvent dans `chrome.stderr.log`, dans son profil.

## Réglages

Déclare ces variables avant la ligne `source` dans `.bashrc` pour remplacer les valeurs par défaut :

| Variable | Valeur par défaut | Rôle |
| --- | --- | --- |
| `CHROME_DEFAULT_PORT` | `9222` | Port de l’instance par défaut |
| `CHROME_PROFILE_DIR` | `$HOME/.chrome-debug` | Répertoire racine des profils |
| `CHROME_KEYMAP` | `fr` | Disposition clavier appliquée au lancement ; vide pour la désactiver |
| `CHROME_BIN` | `google-chrome` | Binaire Chrome |
| `CLAUDE_CONFIG_DIR` | `$HOME/.claude` | Répertoire des configurations MCP générées |
| `CHROME_DARK` | `1` | Active l’apparence sombre de l’interface Chrome |
| `CHROME_MCP_COMMAND` | `npx` | Commande qui lance Chrome DevTools MCP |
| `CHROME_DEBUG_PORT` | vide | Port explicite par défaut pour l’appel `chrome` |

Exemple :

```bash
export CHROME_DEFAULT_PORT=9222
export CHROME_DARK=1
source "$HOME/dev/germain-italic/chromemcp/chrome.sh"
```

Sous WSL2, le script vérifie la disponibilité des sockets graphiques Wayland/X11 avant de démarrer Chrome. Il ne déplace pas les fenêtres depuis Windows.

## Dépannage

Vérifie que DevTools répond sur le port attendu :

```bash
curl -s http://127.0.0.1:9222/json/version
```

La réponse doit contenir une version Chrome et une URL WebSocket. Vérifie que le serveur MCP utilise le même port. `127.0.0.1` évite les problèmes de résolution IPv6 que `localhost` peut provoquer dans certaines configurations WSL.

Si un port écoute sans endpoint DevTools, le script refuse de démarrer dessus et n’arrête aucun processus à l’aveugle. Identifie son propriétaire avec :

```bash
ss -ltnp 'sport = :9222'
```

Si DevTools répond mais qu’aucune fenêtre n’apparaît, vérifie que Chrome n’est pas masqué derrière une autre fenêtre, puis consulte `chrome.stderr.log` dans le profil concerné. Pour redémarrer complètement WSL, utilise `wsl --shutdown` depuis PowerShell uniquement après avoir enregistré ton travail : cette commande ferme toutes les distributions WSL et leurs processus.

## Confidentialité

Chrome DevTools MCP peut lire et modifier les données accessibles dans les onglets de l’instance connectée. Évite de le connecter à un profil contenant des données sensibles si l’agent n’en a pas besoin. Les configurations générées désactivent les statistiques d’utilisation avec `--no-usage-statistics` ; consulte la [documentation officielle](https://github.com/ChromeDevTools/chrome-devtools-mcp#disclaimers) pour les détails.

## Licence

Ce projet est distribué sous licence MIT. Voir [LICENSE](LICENSE).

## Documentation complémentaire

