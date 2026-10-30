#!/usr/bin/env bash
# Lance plusieurs instances Chrome isolées et les expose au serveur MCP DevTools.

: "${CHROME_DEFAULT_PORT:=9222}"
: "${CHROME_PROFILE_CONFIG:=$HOME/.config/chromemcp/profile-dir}"
if [ -z "${CHROME_PROFILE_DIR+x}" ]; then
    if [ -r "$CHROME_PROFILE_CONFIG" ]; then
        IFS= read -r CHROME_PROFILE_DIR <"$CHROME_PROFILE_CONFIG" || true
    fi
fi
: "${CHROME_PROFILE_DIR:=$HOME/.chrome-debug}"
: "${CHROME_PROFILE_NAME_CONFIG:=$HOME/.config/chromemcp/profile-name}"
if [ -z "${CHROME_PROFILE_NAME+x}" ]; then
    if [ -r "$CHROME_PROFILE_NAME_CONFIG" ]; then
        IFS= read -r CHROME_PROFILE_NAME <"$CHROME_PROFILE_NAME_CONFIG" || true
    fi
fi
: "${CHROME_PROFILE_NAME:=Default}"
: "${CHROME_HOST_PROFILE_CONFIG:=$HOME/.config/chromemcp/host-user-data-dir}"
if [ -z "${CHROME_HOST_USER_DATA_DIR+x}" ]; then
    if [ -r "$CHROME_HOST_PROFILE_CONFIG" ]; then
        IFS= read -r CHROME_HOST_USER_DATA_DIR <"$CHROME_HOST_PROFILE_CONFIG" || true
    fi
fi
: "${CHROME_KEYMAP=fr}"
: "${CHROME_BIN:=google-chrome}"
: "${CLAUDE_CONFIG_DIR:=$HOME/.claude}"
: "${CHROME_DARK:=1}"
: "${CHROME_MCP_COMMAND:=npx}"
: "${CHROME_SCRIPT_DIR:=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
: "${CHROME_HOST_MCP_LAUNCHER:=$HOME/.local/bin/chrome-windows-mcp}"

_chrome_wslg_ready() {
    # La disposition interne de /mnt/wslg varie selon les versions de WSLg ;
    # vérifier les sockets réellement utilisés, pas un ancien chemin interne.
    if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
        local wayland_socket="${XDG_RUNTIME_DIR:-}/${WAYLAND_DISPLAY:-}"
        local display_number="${DISPLAY:-}"
        display_number="${display_number#:}"
        display_number="${display_number%%.*}"
        local x_socket="/tmp/.X11-unix/X${display_number}"
        if [ -n "${WAYLAND_DISPLAY:-}" ] && [ ! -S "$wayland_socket" ] \
           && { [ -z "${DISPLAY:-}" ] || [ ! -S "$x_socket" ]; }; then
            echo "Les sockets graphiques WSLg ne sont pas disponibles dans ce shell." >&2
            echo "Ouvre un nouveau terminal ; si cela persiste, mets WSL à jour depuis Windows." >&2
            return 1
        fi
    fi
    # Sans ce return, la valeur de retour serait celle du grep ci-dessus : hors
    # Hors WSL, grep échoue ; ce return garantit un code de succès dans ce cas.
    return 0
}

# Chaque port utilise son propre profil Chrome.
_chrome_data_dir() {
    if [ "$1" = "$CHROME_DEFAULT_PORT" ]; then echo "$CHROME_PROFILE_DIR"
    else echo "${CHROME_PROFILE_DIR}-$1"; fi
}

_chrome_process_profile() {
    local pid="$1" arg profile="" next=0
    local -a argv=()
    mapfile -d '' -t argv <"/proc/${pid}/cmdline" 2>/dev/null || return 0
    for arg in "${argv[@]}"; do
        if [ "$next" -eq 1 ]; then profile="$arg"; next=0; continue; fi
        case "$arg" in
            --user-data-dir=*) profile="${arg#*=}" ;;
            --user-data-dir) next=1 ;;
        esac
    done
    printf '%s' "$profile"
}

# Trouve un port TCP libre. La vérification et l'ouverture du port par Chrome
# ne sont pas atomiques ; le contrôle avec ss protège contre deux lancements simultanés.
_chrome_random_free_port() {
    local p tries=0
    while [ "$tries" -lt 50 ]; do
        p=$(( (RANDOM % 700) + 9300 ))   # plage 9300–9999
        if ! ss -ltnH "sport = :${p}" 2>/dev/null | grep -q . \
           && ! curl -s --max-time 1 "http://127.0.0.1:${p}/json/version" >/dev/null 2>&1; then
            echo "$p"; return 0
        fi
        tries=$((tries + 1))
    done
    return 1
}

# Écrit le fichier MCP DevTools correspondant au port et renvoie son chemin.
_chrome_write_mcp_config() {
    local port="$1"
    local file="${CLAUDE_CONFIG_DIR}/chrome-${port}.mcp.json"
    mkdir -p "$CLAUDE_CONFIG_DIR"
    cat > "$file" <<EOF
{
  "mcpServers": {
    "chrome-${port}": {
      "type": "stdio",
      "command": "${CHROME_MCP_COMMAND}",
      "args": ["-y", "chrome-devtools-mcp@latest", "--browser-url", "http://127.0.0.1:${port}", "--no-usage-statistics"],
      "env": {}
    }
  }
}
EOF
    echo "$file"
}

# Lit les titres des onglets ouverts via le endpoint DevTools de l'instance.
_chrome_tab_titles() {
    local port="$1" response
    response=$(curl -fsS --max-time 1 "http://127.0.0.1:${port}/json/list" 2>/dev/null) || {
        printf '%s' 'titres indisponibles'
        return 0
    }
    if command -v python3 >/dev/null 2>&1; then
        printf '%s\n' "$response" | python3 -c '
import json, sys
from urllib.parse import urlparse
try:
    targets = json.load(sys.stdin)
    titles = []
    for target in targets:
        if target.get("type") != "page":
            continue
        url = target.get("url") or ""
        host = urlparse(url).hostname
        title = " ".join((target.get("title") or url or "(sans titre)").split())
        label = f"{host} — {title}" if host else title
        titles.append(label[:77] + "…" if len(label) > 78 else label)
    print("\n".join(titles[:5]) if titles else "aucun onglet")
except Exception:
    print("titres indisponibles")
' 2>/dev/null || printf '%s' 'titres indisponibles'
    else
        printf '%s' 'titres indisponibles (python3 absent)'
    fi
}

# Affiche les instances debug existantes avec leurs informations utiles.
_chrome_list_running() {
    local found=0 pid cmdline port profile titles state title active orphan
    local -a active_profiles=() profile_dirs=()
    _CHROME_RUNNING_COUNT=0
    printf '%s\n' "Instances Chrome actuellement lancées :"
    while read -r pid; do
        [ -r "/proc/${pid}/cmdline" ] || continue
        cmdline=$(tr '\0' ' ' <"/proc/${pid}/cmdline")
        [[ "$cmdline" == *"--remote-debugging-port="* ]] || continue
        [[ "$cmdline" == *"--type="* ]] && continue
        port=$(sed -n 's/.*--remote-debugging-port=\([0-9][0-9]*\).*/\1/p' <<<"$cmdline")
        profile=$(_chrome_process_profile "$pid")
        titles=$(_chrome_tab_titles "$port")
        printf '  Port %s — PID %s — Profil : %s\n' \
            "${port:-?}" "$pid" "${profile:-inconnu}"
        if curl -fsS --max-time 1 "http://127.0.0.1:${port}/json/version" >/dev/null 2>&1; then
            state="DevTools disponible"
        else
            state="DevTools indisponible"
        fi
        printf '    État : %s\n' "$state"
        while IFS= read -r title; do printf '    • %s\n' "$title"; done <<<"$titles"
        active_profiles+=("${profile:-inconnu}")
        found=1
        _CHROME_RUNNING_COUNT=$((_CHROME_RUNNING_COUNT + 1))
    done < <(pgrep -f 'google-chrome|chrome' 2>/dev/null | sort -nu)
    [ "$found" -eq 1 ] || printf '%s\n' '  Aucune instance Chrome debug trouvée.'

    profile_dirs=("$CHROME_PROFILE_DIR" "$CHROME_PROFILE_DIR"-*)
    orphan=0
    for profile in "${profile_dirs[@]}"; do
        [ -d "$profile" ] || continue
        active=0
        for pid in "${active_profiles[@]}"; do
            [ "$pid" = "$profile" ] && { active=1; break; }
        done
        if [ "$active" -eq 0 ]; then
            if [ "$orphan" -eq 0 ]; then printf '\nProfils sans instance active :\n'; fi
            printf '  %s\n' "$profile"
            orphan=1
        fi
    done
}

# Arrête une seule instance identifiée par son port DevTools.
_chrome_stop_instance() {
    local -a pids=() ports=() profiles=() titles=()
    local pid cmdline port profile selected answer index=0

    while read -r pid; do
        [ -r "/proc/${pid}/cmdline" ] || continue
        # Employer exactement le même critère que l'affichage : certaines
        # versions de Chrome exposent les arguments différemment dans argv.
        # /proc/<pid>/cmdline conserve la ligne complète séparée par des NUL ;
        # sa représentation avec espaces est celle déjà utilisée ci-dessus.
        cmdline=$(tr '\0' ' ' <"/proc/${pid}/cmdline")
        [[ "$cmdline" == *"--remote-debugging-port="* ]] || continue
        [[ "$cmdline" == *"--type="* ]] && continue
        port=$(sed -n 's/.*--remote-debugging-port=\([0-9][0-9]*\).*/\1/p' <<<"$cmdline")
        profile=$(_chrome_process_profile "$pid")
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        pids+=("$pid"); ports+=("$port"); profiles+=("${profile:-inconnu}")
        titles+=("$(_chrome_tab_titles "$port")")
    done < <(pgrep -f 'google-chrome|chrome' 2>/dev/null | sort -nu)

    if [ "${#pids[@]}" -eq 0 ]; then
        echo "Aucune instance Chrome debug à arrêter."
        return 0
    fi

    echo "Instances Chrome disponibles :"
    for index in "${!pids[@]}"; do
        printf '  %d) port %s — PID %s — profil : %s\n' "$((index + 1))" "${ports[index]}" \
            "${pids[index]}" "${profiles[index]}"
        if curl -fsS --max-time 1 "http://127.0.0.1:${ports[index]}/json/version" >/dev/null 2>&1; then
            printf '     DevTools : disponible\n'
        else
            printf '     DevTools : indisponible\n'
        fi
        while IFS= read -r title; do printf '     • %s\n' "$title"; done <<<"${titles[index]}"
    done

    printf 'Quelle instance arrêter ? (numéro, Entrée pour annuler) '
    read -r answer </dev/tty || { echo; echo "Arrêt annulé."; return 1; }
    [[ "$answer" =~ ^[0-9]+$ ]] || { echo "Arrêt annulé."; return 0; }
    answer=$((10#$answer))
    (( answer >= 1 && answer <= ${#pids[@]} )) || { echo "Numéro invalide ; arrêt annulé."; return 1; }
    selected=$((answer - 1))

    printf 'Arrêter Chrome sur le port %s (PID %s) ? [y/N] ' \
        "${ports[selected]}" "${pids[selected]}"
    read -r answer </dev/tty || { echo; echo "Arrêt annulé."; return 1; }
    case "$answer" in
        y|Y|yes|YES|o|O|oui|OUI) ;;
        *) echo "Arrêt annulé."; return 0 ;;
    esac

    pid="${pids[selected]}"; port="${ports[selected]}"; profile="${profiles[selected]}"
    [ -r "/proc/${pid}/cmdline" ] || { echo "Le processus a déjà quitté."; return 0; }
    cmdline=$(tr '\0' ' ' <"/proc/${pid}/cmdline")
    if [[ "$cmdline" != *"--remote-debugging-port=${port}"* || "$cmdline" != *"--user-data-dir=${profile}"* ]]; then
        echo "Le processus ne correspond plus à l'instance choisie ; arrêt refusé." >&2
        return 1
    fi
    kill -TERM "$pid" || return 1
    echo "Signal d'arrêt envoyé à Chrome sur le port ${port} (PID ${pid})."
}

# Met à jour le dépôt puis recharge la configuration du shell courant.
_chrome_update() {
    if ! git -C "$CHROME_SCRIPT_DIR" pull --ff-only; then
        echo "Mise à jour impossible. Vérifie l'état du dépôt : $CHROME_SCRIPT_DIR" >&2
        return 1
    fi
    if [ ! -r "$HOME/.bashrc" ]; then
        echo "Dépôt mis à jour, mais $HOME/.bashrc est introuvable ou illisible." >&2
        return 1
    fi
    # shellcheck disable=SC1090
    source "$HOME/.bashrc"
    echo "Script actualisé et ~/.bashrc rechargé."
}

# Recharge la copie locale sans modifier le dépôt ni ~/.bashrc.
_chrome_reload() {
    # shellcheck disable=SC1090
    source "$CHROME_SCRIPT_DIR/chrome.sh" || return 1
    echo "Script local rechargé depuis $CHROME_SCRIPT_DIR/chrome.sh."
}

# Renvoie les noms de profils Chrome présents dans un dossier de données.
_chrome_profile_children() {
    local root="$1" entry
    local -a names=()
    for entry in "$root"/Default "$root"/Profile\ * "$root"/Guest\ Profile; do
        [ -d "$entry" ] && names+=("${entry##*/}")
    done
    if [ "${#names[@]}" -gt 0 ]; then printf '%s' "${names[*]}"
    else printf '%s' 'aucun sous-profil détecté'; fi
}

_chrome_select_wsl_profile_name() {
    local root="$1" action entry name index selected
    local -a names=()
    for entry in "$root"/Default "$root"/Profile\ * "$root"/Guest\ Profile; do
        [ -d "$entry" ] && names+=("${entry##*/}")
    done
    if [ "${#names[@]}" -eq 0 ]; then
        name='Default'
    elif [ "${#names[@]}" -eq 1 ]; then
        name="${names[0]}"
    else
        printf '\nSous-profils dans %s\n' "$root"
        for index in "${!names[@]}"; do printf '  %d) %s\n' "$((index + 1))" "${names[index]}"; done
        printf '  [m] Saisir un nom\n  [q] Annuler\nChoix : '
        read -r action </dev/tty || { echo; return 1; }
        case "$action" in
            m|M)
                printf 'Nom du sous-profil (ex. Profile 1) : '
                read -r name </dev/tty || { echo; return 1; }
                [ -n "$name" ] || { echo 'Choix annulé.'; return 1; }
                ;;
            q|Q) return 1 ;;
            *)
                [[ "$action" =~ ^[0-9]+$ ]] || { echo 'Choix invalide.'; return 1; }
                selected=$((10#$action - 1))
                (( selected >= 0 && selected < ${#names[@]} )) || { echo 'Choix invalide.'; return 1; }
                name="${names[selected]}"
                ;;
        esac
    fi
    mkdir -p "$(dirname -- "$CHROME_PROFILE_NAME_CONFIG")" || return 1
    printf '%s\n' "$name" >"$CHROME_PROFILE_NAME_CONFIG" || return 1
    CHROME_PROFILE_NAME="$name"
    printf 'Sous-profil WSL enregistré : %s\n' "$CHROME_PROFILE_NAME"
}

_chrome_windows_local_appdata() {
    command -v powershell.exe >/dev/null 2>&1 || return 1
    powershell.exe -NoProfile -Command '[Environment]::GetFolderPath("LocalApplicationData")' 2>/dev/null | tr -d '\r'
}

_chrome_windows_path() {
    case "$1" in
        /*) wslpath -w -- "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

_chrome_profile_menu_wsl() {
    local action path answer index selected
    local -a candidates=() roots=()
    roots+=("$CHROME_PROFILE_DIR" "$CHROME_PROFILE_DIR"-*)
    roots+=("$HOME/.chrome-debug" "$HOME/.chrome-debug"-*)
    roots+=("$HOME/.config/google-chrome" "$HOME/.config/google-chrome"-*)
    roots+=("$HOME/.config/chromium")
    for path in "${roots[@]}"; do
        [ -d "$path" ] || continue
        local duplicate=0
        for answer in "${candidates[@]}"; do [ "$answer" = "$path" ] && duplicate=1; done
        [ "$duplicate" -eq 1 ] || candidates+=("$path")
    done

    printf '\nProfil racine de Chrome WSL (actuel : %s)\n' "$CHROME_PROFILE_DIR"
    if [ "${#candidates[@]}" -eq 0 ]; then
        printf '  Aucun dossier de profil connu trouvé.\n'
    else
        for index in "${!candidates[@]}"; do
            printf '  %d) %s — profils : %s\n' "$((index + 1))" "${candidates[index]}" \
                "$(_chrome_profile_children "${candidates[index]}")"
        done
    fi
    printf '  [m] Saisir un chemin manuellement\n  [d] Restaurer ~/.chrome-debug\n  [r] Retour\nChoix : '
    read -r action </dev/tty || { echo; return 1; }
    case "$action" in
        m|M)
            printf 'Chemin WSL (Entrée pour annuler) : '
            read -r path </dev/tty || { echo; return 1; }
            [ -n "$path" ] || { echo 'Modification annulée.'; return 0; }
            case "$path" in
                '~') path="$HOME" ;;
                '~/'*) path="$HOME/${path#~/}" ;;
            esac
            ;;
        d|D) path="$HOME/.chrome-debug" ;;
        r|R) return 0 ;;
        *)
            [[ "$action" =~ ^[0-9]+$ ]] || { echo 'Choix invalide.'; return 1; }
            selected=$((10#$action - 1))
            (( selected >= 0 && selected < ${#candidates[@]} )) || { echo 'Choix invalide.'; return 1; }
            path="${candidates[selected]}"
            ;;
    esac
    mkdir -p "$(dirname -- "$CHROME_PROFILE_CONFIG")" || return 1
    printf '%s\n' "$path" >"$CHROME_PROFILE_CONFIG" || return 1
    CHROME_PROFILE_DIR="$path"
    printf 'Profil WSL par défaut enregistré : %s\n' "$CHROME_PROFILE_DIR"
    _chrome_select_wsl_profile_name "$CHROME_PROFILE_DIR" || return $?
}

_chrome_profile_menu_host() {
    local action path appdata appdata_linux candidate_win candidate_linux answer index selected
    local -a candidates_win=() candidates_unix=()
    appdata=$(_chrome_windows_local_appdata) || {
        echo 'PowerShell Windows est nécessaire pour rechercher les profils de l’hôte.' >&2
        return 1
    }
    appdata_linux=$(wslpath -u "$appdata") || return 1
    if [ -z "${CHROME_HOST_USER_DATA_DIR:-}" ]; then
        CHROME_HOST_USER_DATA_DIR="$appdata\Google\Chrome\User Data"
    fi
    CHROME_HOST_USER_DATA_DIR=$(_chrome_windows_path "$CHROME_HOST_USER_DATA_DIR") || return 1
    candidates_win+=("$CHROME_HOST_USER_DATA_DIR")
    for candidate_win in \
        "$appdata\Google\Chrome\User Data" \
        "$appdata\Google\Chrome Beta\User Data" \
        "$appdata\Google\Chrome Dev\User Data" \
        "$appdata\Google\Chrome SxS\User Data" \
        "$appdata\Google\Chrome for Testing\User Data" \
        "$appdata\Chromium\User Data"; do
        candidate_linux=$(wslpath -u "$candidate_win" 2>/dev/null) || continue
        [ -d "$candidate_linux" ] || continue
        local duplicate=0
        for answer in "${candidates_win[@]}"; do [ "$answer" = "$candidate_win" ] && duplicate=1; done
        [ "$duplicate" -eq 1 ] || candidates_win+=("$candidate_win")
    done
    for candidate_win in "${candidates_win[@]}"; do
        [ -n "$candidate_win" ] || continue
        candidate_linux=$(wslpath -u "$candidate_win" 2>/dev/null) || candidate_linux=''
        candidates_unix+=("$candidate_linux")
    done

    printf '\nDossiers de données Chrome Windows (actuel : %s)\n' "${CHROME_HOST_USER_DATA_DIR:-non défini}"
    for index in "${!candidates_win[@]}"; do
        candidate_linux="${candidates_unix[index]}"
        if [ -n "$candidate_linux" ] && [ -d "$candidate_linux" ]; then
            printf '  %d) %s — profils : %s\n' "$((index + 1))" "${candidates_win[index]}" \
                "$(_chrome_profile_children "$candidate_linux")"
        else
            printf '  %d) %s\n' "$((index + 1))" "${candidates_win[index]}"
        fi
    done
    printf '  [m] Saisir un chemin manuellement\n  [d] Profil Chrome Stable par défaut\n  [r] Retour\nChoix : '
    read -r action </dev/tty || { echo; return 1; }
    case "$action" in
        m|M)
            printf 'Dossier de données Windows (Entrée pour annuler) : '
            read -r path </dev/tty || { echo; return 1; }
            [ -n "$path" ] || { echo 'Modification annulée.'; return 0; }
            case "$path" in
                /*) path=$(wslpath -w "$path") || return 1 ;;
            esac
            ;;
        d|D) path="$appdata\Google\Chrome\User Data" ;;
        r|R) return 0 ;;
        *)
            [[ "$action" =~ ^[0-9]+$ ]] || { echo 'Choix invalide.'; return 1; }
            selected=$((10#$action - 1))
            (( selected >= 0 && selected < ${#candidates_win[@]} )) || { echo 'Choix invalide.'; return 1; }
            path="${candidates_win[selected]}"
            ;;
    esac
    mkdir -p "$(dirname -- "$CHROME_HOST_PROFILE_CONFIG")" || return 1
    printf '%s\n' "$path" >"$CHROME_HOST_PROFILE_CONFIG" || return 1
    CHROME_HOST_USER_DATA_DIR="$path"
    printf 'Profil hôte enregistré : %s\n' "$CHROME_HOST_USER_DATA_DIR"
    printf 'Ce réglage désigne le dossier de données Chrome, qui peut contenir plusieurs profils.\n'
    if [ -x "$CHROME_HOST_MCP_LAUNCHER" ]; then
        _chrome_write_windows_mcp_launcher >/dev/null || return 1
    fi
}

_chrome_write_windows_mcp_launcher() {
    local appdata appdata_linux node_path node_win npm_cli mcp_cli mcp_cli_win data_dir
    local node_q cli_q data_q
    appdata=$(_chrome_windows_local_appdata) || {
        echo 'PowerShell Windows est nécessaire pour configurer Chrome hôte.' >&2
        return 1
    }
    appdata_linux=$(wslpath -u "$appdata") || return 1
    if [ -z "${CHROME_HOST_USER_DATA_DIR:-}" ]; then
        CHROME_HOST_USER_DATA_DIR="$appdata\Google\Chrome\User Data"
    fi
    CHROME_HOST_USER_DATA_DIR=$(_chrome_windows_path "$CHROME_HOST_USER_DATA_DIR") || return 1
    data_dir=$(wslpath -u "$CHROME_HOST_USER_DATA_DIR" 2>/dev/null) || data_dir=''
    [ -n "$data_dir" ] && [ -d "$data_dir" ] || {
        echo "Dossier de données Chrome Windows introuvable : $CHROME_HOST_USER_DATA_DIR" >&2
        echo 'Choisis d’abord un dossier existant dans Configuration > Profil hôte.' >&2
        return 1
    }

    node_path="${CHROME_HOST_NODE:-}"
    if [ -n "$node_path" ]; then
        case "$node_path" in [A-Za-z]:*) node_path=$(wslpath -u "$node_path") ;; esac
    else
        for node_path in \
            "$appdata_linux/codex-chrome-mcp/node-v24.22.2-win-x64/node.exe" \
            "$appdata_linux/chromemcp/node/node.exe"; do
            [ -x "$node_path" ] && break
            node_path=''
        done
        if [ -z "$node_path" ]; then
            node_win=$(powershell.exe -NoProfile -Command '(Get-Command node.exe -ErrorAction SilentlyContinue).Source' 2>/dev/null | tr -d '\r')
            [ -n "$node_win" ] && node_path=$(wslpath -u "$node_win" 2>/dev/null)
        fi
    fi
    [ -n "$node_path" ] && [ -x "$node_path" ] || {
        echo 'Node.js pour Windows est requis pour lancer le MCP sur l’hôte.' >&2
        echo 'Installe Node.js LTS pour Windows ou définis CHROME_HOST_NODE.' >&2
        return 1
    }

    mcp_cli="$appdata_linux/chromemcp/mcp/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js"
    if [ ! -r "$mcp_cli" ]; then
        npm_cli="$(dirname -- "$node_path")/node_modules/npm/bin/npm-cli.js"
        [ -r "$npm_cli" ] || {
            echo 'npm-cli.js introuvable à côté du Node Windows sélectionné.' >&2
            echo 'Installe Node.js LTS pour Windows avec npm, puis réessaie.' >&2
            return 1
        }
        npm_cli=$(wslpath -w "$npm_cli") || return 1
        mkdir -p "$appdata_linux/chromemcp" || return 1
        if ! (cd "$appdata_linux/chromemcp" && "$node_path" "$npm_cli" install \
            --prefix "$appdata\chromemcp\mcp" --no-audit --no-fund chrome-devtools-mcp@latest); then
            echo 'Installation de Chrome DevTools MCP côté Windows impossible.' >&2
            return 1
        fi
    fi
    mcp_cli_win=$(wslpath -w "$mcp_cli") || return 1
    printf -v node_q '%q' "$node_path"
    printf -v cli_q '%q' "$mcp_cli_win"
    printf -v data_q '%q' "$CHROME_HOST_USER_DATA_DIR"
    mkdir -p "$(dirname -- "$CHROME_HOST_MCP_LAUNCHER")" || return 1
    cat >"$CHROME_HOST_MCP_LAUNCHER" <<EOF
#!/usr/bin/env bash
set -e
exec ${node_q} ${cli_q} --autoConnect --user-data-dir ${data_q} --no-usage-statistics
EOF
    chmod 700 "$CHROME_HOST_MCP_LAUNCHER" || return 1
    printf '%s\n' "$CHROME_HOST_MCP_LAUNCHER"
}

_chrome_mcp_add_server() {
    local client="$1" target="$2" port="$3" name command json
    local -a args=()
    if [ "$target" = 'windows' ]; then
        name='chrome-windows'
        command="$CHROME_HOST_MCP_LAUNCHER"
    else
        name="chrome-wsl-${port}"
        command="$CHROME_MCP_COMMAND"
        args=(-y chrome-devtools-mcp@latest --browser-url "http://127.0.0.1:${port}" --no-usage-statistics)
    fi

    case "$client" in
        codex)
            if ! command -v codex >/dev/null 2>&1; then echo 'Codex CLI introuvable.' >&2; return 1; fi
            if [ "$target" = 'wsl' ] && [ "$port" = "$CHROME_DEFAULT_PORT" ]; then
                local current_codex
                current_codex=$(codex mcp get chrome 2>/dev/null || true)
                if [[ "$current_codex" == *"127.0.0.1:${port}"* ]]; then
                    echo "Codex utilise déjà Chrome WSL sur le port ${port} (serveur chrome conservé)."
                    return 0
                fi
            fi
            codex mcp remove "$name" >/dev/null 2>&1 || true
            codex mcp add "$name" -- "$command" "${args[@]}" || return 1
            echo "Serveur Codex configuré : $name"
            ;;
        claude)
            if ! command -v claude >/dev/null 2>&1; then echo 'Claude Code introuvable.' >&2; return 1; fi
            if [ "$target" = 'wsl' ]; then name="chrome-${port}"; fi
            if [ "$target" = 'wsl' ] && claude mcp get "$name" >/dev/null 2>&1; then
                echo "Claude Code possède déjà le serveur WSL ${name} ; configuration conservée."
                return 0
            fi
            json=$(python3 - "$command" "${args[@]}" <<'PY'
import json, sys
print(json.dumps({"type": "stdio", "command": sys.argv[1], "args": sys.argv[2:]}))
PY
) || return 1
            claude mcp remove --scope user "$name" >/dev/null 2>&1 || true
            claude mcp add-json --scope user "$name" "$json" || return 1
            echo "Serveur Claude Code configuré : $name"
            ;;
    esac
}

_chrome_mcp_config_menu() {
    local target client port
    while true; do
    printf '\nConfigurer les connexions MCP\n  [w] Chrome WSL\n  [h] Chrome hôte Windows\n  [r] Retour\nChoix [w/h/r] : '
    read -r target </dev/tty || { echo; return 1; }
    case "$target" in
        w|W)
            printf 'Port DevTools WSL à configurer [%s] : ' "$CHROME_DEFAULT_PORT"
            read -r port </dev/tty || { echo; return 1; }
            port="${port:-$CHROME_DEFAULT_PORT}"
            [[ "$port" =~ ^[0-9]+$ ]] || { echo 'Port invalide.'; return 1; }
            target='wsl'
            ;;
        h|H)
            _chrome_write_windows_mcp_launcher >/dev/null || return 1
            target='windows'
            ;;
        r|R) return 0 ;;
        *) echo 'Choix invalide.'; continue ;;
    esac
    printf '  [b] Codex et Claude Code\n  [c] Codex\n  [l] Claude Code\n  [r] Retour\nClients [b/c/l/r] : '
    read -r client </dev/tty || { echo; return 1; }
    case "$client" in
        b|B)
            _chrome_mcp_add_server codex "$target" "$port" || return 1
            _chrome_mcp_add_server claude "$target" "$port" || return 1
            ;;
        c|C) _chrome_mcp_add_server codex "$target" "$port" || return 1 ;;
        l|L) _chrome_mcp_add_server claude "$target" "$port" || return 1 ;;
        r|R) continue ;;
        *) echo 'Choix invalide.'; continue ;;
    esac
    printf 'Redémarre les clients configurés pour charger le nouveau serveur MCP.\n'
    done
}

_chrome_config_menu() {
    local action
    while true; do
    printf '\nConfiguration Chrome\n'
    printf '  [w] Choisir le profil par défaut de Chrome WSL\n'
    printf '  [h] Choisir le profil de Chrome hôte Windows\n'
    printf '  [m] Configurer les connexions MCP de Claude/Codex\n'
    printf '  [r] Retour\nChoix [w/h/m/r] : '
    read -r action </dev/tty || { echo; return 1; }
    case "$action" in
        w|W) _chrome_profile_menu_wsl ;;
        h|H) _chrome_profile_menu_host ;;
        m|M) _chrome_mcp_config_menu ;;
        r|R) return 0 ;;
        *) echo 'Choix invalide.' ;;
    esac
    done
}

chrome() {
    _chrome_list_running

    # Un port passé en argument (ou dans CHROME_DEBUG_PORT) exprime déjà le choix.
    local explicit=0 port="$CHROME_DEFAULT_PORT" action launch_confirmed=0
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
        port="$1"; explicit=1; shift
    elif [ -n "${CHROME_DEBUG_PORT:-}" ]; then
        port="$CHROME_DEBUG_PORT"; explicit=1
    fi

    if [ "$explicit" -eq 0 ]; then
      while true; do
        if [ "${_CHROME_RUNNING_COUNT:-0}" -gt 0 ]; then
            printf '\nQue veux-tu faire ?\n  [n] Lancer une instance Chrome\n  [k] Arrêter une instance existante\n  [c] Configuration\n  [r] Recharger le script local\n  [g] Actualiser depuis Git\n  [q] Annuler\nChoix [n/k/c/r/g/q] : '
        else
            printf '\nQue veux-tu faire ?\n  [n] Lancer une instance Chrome\n  [c] Configuration\n  [r] Recharger le script local\n  [g] Actualiser depuis Git\n  [q] Annuler\nChoix [n/c/r/g/q] : '
        fi
        if ! read -r action </dev/tty; then
            echo
            echo "Action annulée."
            return 1
        fi
        case "$action" in
            n|N) launch_confirmed=1 ;;
            k|K) _chrome_stop_instance; return $? ;;
            c|C) _chrome_config_menu; _chrome_list_running ;;
            r|R) _chrome_reload; return $? ;;
            g|G) _chrome_update; return $? ;;
            *) echo "Action annulée."; return 0 ;;
        esac
        [ "$launch_confirmed" -eq 1 ] && break
      done
    fi

    [ -n "$CHROME_KEYMAP" ] && command -v setxkbmap >/dev/null 2>&1 \
        && setxkbmap "$CHROME_KEYMAP" 2>/dev/null
    _chrome_wslg_ready || return 125

    # Interface sombre. Chrome lit l'apparence système via le portail
    # xdg-desktop, qui reflète cette clé dconf ; sous WSLg elle vaut 'default'
    # (= clair) et prime sur --force-dark-mode. Réaffirmée à chaque lancement,
    # au cas où un reset la remettrait à 'default'.
    local gtk_theme="${GTK_THEME:-}"
    local -a appearance_args=()
    if [ "$CHROME_DARK" = "1" ]; then
        appearance_args+=(--force-dark-mode)
        # Adwaita:dark est fourni par la libgtk ; son absence de
        # /usr/share/themes est normale. Assombrit les menus natifs.
        gtk_theme="Adwaita:dark"
        if command -v gsettings >/dev/null 2>&1 &&
           [ "$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null)" != "'prefer-dark'" ]; then
            gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null
        fi
    fi

    # Port : 1er argument numérique, sinon $CHROME_DEBUG_PORT, sinon 9222 (par défaut).
    #   chrome            → menu si une instance existe ; sinon lance sur le port par défaut
    #   chrome 9223       → force le port 9223 (réutilise l'onglet si déjà actif)
    # Chaque instance MCP indépendante a son port ET son --user-data-dir ; le serveur
    # MCP correspondant doit pointer sur le MÊME port (--browserUrl http://127.0.0.1:PORT).
    # Instance debug déjà vivante sur ce port ?
    if curl -s --max-time 2 "http://127.0.0.1:${port}/json/version" >/dev/null 2>&1; then
        if [ "$explicit" -eq 1 ]; then
            # Port demandé explicitement → réutiliser (nouvel onglet), ne pas relancer.
            echo "Chrome debug déjà actif sur ${port} — ouverture d'un onglet."
            if [ "$#" -gt 0 ]; then
                command "$CHROME_BIN" --user-data-dir="$(_chrome_data_dir "$port")" \
                    "${appearance_args[@]}" "$@" >/dev/null 2>&1 &
            fi
            local mcp_flag=""
            [ "$port" != "$CHROME_DEFAULT_PORT" ] && mcp_flag="--mcp-config $(_chrome_write_mcp_config "$port") --disallowedTools \"mcp__chrome-${CHROME_DEFAULT_PORT}__*\""
            echo "Session Claude Code : claude --resume ${mcp_flag}"
            echo "         ou (yolo) : claude --dangerously-skip-permissions --resume ${mcp_flag}"
            return 0
        fi
        # Port par défaut (9222) occupé → nouvelle instance sur un port aléatoire libre.
        local newport answer
        newport="$(_chrome_random_free_port)" || { echo "Aucun port libre trouvé (9300–9999)." >&2; return 1; }
        if [ "$launch_confirmed" -eq 0 ]; then
            local answer
            printf 'Le port %s est déjà utilisé. Lancer une instance sur le port %s ? [y/N] ' "$port" "$newport"
            if ! read -r answer </dev/tty; then
                echo
                echo "Lancement annulé."
                return 1
            fi
            case "$answer" in
                y|Y|yes|YES|o|O|oui|OUI) ;;
                *) echo "Lancement annulé."; return 0 ;;
            esac
        else
            echo "Port ${port} déjà utilisé → lancement sur le port ${newport}."
        fi
        port="$newport"
    fi

    local data_dir; data_dir="$(_chrome_data_dir "$port")"

    # Ne jamais tuer un Chrome ni supprimer ses verrous sur une simple
    # supposition. Un port en écoute sans endpoint DevTools est un conflit.
    if ss -ltnH "sport = :${port}" 2>/dev/null | grep -q .; then
        echo "Le port ${port} est déjà occupé, mais ne répond pas à DevTools." >&2
        echo "Choisis un autre port (ex. : chrome 9223) ou ferme le processus qui l'utilise." >&2
        return 1
    fi

    # Commande Claude Code prête à copier pour lier une session à CE Chrome.
    # (Pour 9222 : rien à passer, chrome-9222 est déjà dans la config globale.)
    local mcp_flag=""
    [ "$port" != "$CHROME_DEFAULT_PORT" ] && mcp_flag="--mcp-config $(_chrome_write_mcp_config "$port") --disallowedTools \"mcp__chrome-${CHROME_DEFAULT_PORT}__*\""

    mkdir -p "$data_dir" || { echo "Impossible de créer ${data_dir}" >&2; return 1; }

    echo "════════════════════════════════════════════════════"
    echo "  Chrome debug sur le port : ${port}"
    echo "  Profil : ${data_dir}"
    echo "  ────────────────────────────────────────────────"
    echo "  Session Claude Code liée à ce Chrome :"
    echo "    claude --resume ${mcp_flag}"
    echo "    claude --dangerously-skip-permissions --resume ${mcp_flag}   # yolo"
    [ "$port" = "$CHROME_DEFAULT_PORT" ] && echo "    (chrome-${CHROME_DEFAULT_PORT} est déjà dans ta config globale)"
    echo "    (--resume ouvre le sélecteur de sessions du dossier courant ; à retirer pour une session vierge)"
    echo "════════════════════════════════════════════════════"

    # Un profil dédié isole déjà chaque instance ; conserver D-Bus permet à
    # Chrome de s'intégrer normalement à la session Wayland/WSLg.
    # Adwaita:dark est fourni par la libgtk (absent de /usr/share/themes, normal).
    # Complète le réglage gsettings color-scheme=prefer-dark, que Chrome lit via
    # le portail xdg-desktop pour décider de l'apparence de sa fenêtre.
    # Seule l'UI est forcée : le rendu des pages reste à la main des sites.
    GTK_THEME="$gtk_theme" \
    nohup "$CHROME_BIN" \
        --remote-debugging-port="${port}" \
        --remote-debugging-address=127.0.0.1 \
        --user-data-dir="${data_dir}" \
        --profile-directory="${CHROME_PROFILE_NAME}" \
        --no-first-run \
        --no-default-browser-check \
        --disable-sync \
        --disable-extensions \
        --disable-background-networking \
        --disable-popup-blocking \
        --new-window \
        --start-maximized \
        "${appearance_args[@]}" \
        "$@" >"${data_dir}/chrome.stderr.log" 2>&1 &
    local chrome_pid=$!
    disown "$chrome_pid" 2>/dev/null || true

    local tries=0
    while [ "$tries" -lt 50 ]; do
        if curl -s --max-time 1 "http://127.0.0.1:${port}/json/version" >/dev/null 2>&1; then
            echo "Chrome prêt (PID ${chrome_pid}) — journal : ${data_dir}/chrome.stderr.log"
            return 0
        fi
        kill -0 "$chrome_pid" 2>/dev/null || break
        sleep 0.1
        tries=$((tries + 1))
    done

    echo "Chrome n'a pas démarré correctement ; consulte ${data_dir}/chrome.stderr.log" >&2
    return 1
}
