#!/usr/bin/env bash
# Lance plusieurs instances Chrome isolées et les expose au serveur MCP DevTools.

: "${CHROME_DEFAULT_PORT:=9222}"
: "${CHROME_PROFILE_DIR:=$HOME/.chrome-debug}"
: "${CHROME_KEYMAP=fr}"
: "${CHROME_BIN:=google-chrome}"
: "${CLAUDE_CONFIG_DIR:=$HOME/.claude}"
: "${CHROME_DARK:=1}"
: "${CHROME_MCP_COMMAND:=npx}"

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
try:
    targets = json.load(sys.stdin)
    titles = [" ".join((t.get("title") or t.get("url") or "(sans titre)").split())[:70]
              for t in targets if t.get("type") == "page"]
    print(" | ".join(titles[:3]) if titles else "aucun onglet")
except Exception:
    print("titres indisponibles")
' 2>/dev/null || printf '%s' 'titres indisponibles'
    else
        printf '%s' 'titres indisponibles (python3 absent)'
    fi
}

# Affiche les instances debug existantes et leur session graphique.
_chrome_list_running() {
    local found=0 pid cmdline port display wayland profile titles
    printf '%s\n' "Instances Chrome actuellement lancées :"
    while read -r pid; do
        [ -r "/proc/${pid}/cmdline" ] || continue
        cmdline=$(tr '\0' ' ' <"/proc/${pid}/cmdline")
        [[ "$cmdline" == *"--remote-debugging-port="* ]] || continue
        [[ "$cmdline" == *"--type="* ]] && continue
        port=$(sed -n 's/.*--remote-debugging-port=\([0-9][0-9]*\).*/\1/p' <<<"$cmdline")
        profile=$(sed -n 's/.*--user-data-dir=\([^ ]*\).*/\1/p' <<<"$cmdline")
        display=$(tr '\0' '\n' <"/proc/${pid}/environ" 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -n 1)
        wayland=$(tr '\0' '\n' <"/proc/${pid}/environ" 2>/dev/null | sed -n 's/^WAYLAND_DISPLAY=//p' | head -n 1)
        titles=$(_chrome_tab_titles "$port")
        printf '  PID %-7s port %-5s DISPLAY=%s WAYLAND_DISPLAY=%s profil=%s\n' \
            "$pid" "${port:-?}" "${display:-non défini}" "${wayland:-non défini}" "${profile:-inconnu}"
        printf '    Onglets : %s\n' "$titles"
        found=1
    done < <(pgrep -f 'google-chrome|chrome' 2>/dev/null | sort -nu)
    [ "$found" -eq 1 ] || printf '%s\n' '  Aucune instance Chrome debug trouvée.'
}

# Arrête une seule instance identifiée par son port DevTools.
# Usage : chrome-kill [port] ; sans port, choisir dans le menu.
chrome-kill() {
    local -a pids=() ports=() profiles=() titles=()
    local pid cmdline arg port profile selected answer index=0

    while read -r pid; do
        [ -r "/proc/${pid}/cmdline" ] || continue
        local -a argv=()
        mapfile -d '' -t argv <"/proc/${pid}/cmdline"
        port="" profile=""; local is_browser=1
        for arg in "${argv[@]}"; do
            case "$arg" in
                --remote-debugging-port=*) port="${arg#*=}" ;;
                --user-data-dir=*) profile="${arg#*=}" ;;
                --type=*) is_browser=0 ;;
            esac
        done
        [[ "$is_browser" -eq 1 && "$port" =~ ^[0-9]+$ ]] || continue
        pids+=("$pid"); ports+=("$port"); profiles+=("${profile:-inconnu}")
        titles+=("$(_chrome_tab_titles "$port")")
    done < <(pgrep -f 'google-chrome|chrome' 2>/dev/null | sort -nu)

    if [ "${#pids[@]}" -eq 0 ]; then
        echo "Aucune instance Chrome debug à arrêter."
        return 0
    fi

    echo "Instances Chrome disponibles :"
    for index in "${!pids[@]}"; do
        printf '  %d) port %s — PID %s — %s\n' "$((index + 1))" "${ports[index]}" \
            "${pids[index]}" "${profiles[index]}"
        printf '     Onglets : %s\n' "${titles[index]}"
    done

    if [ "$#" -gt 0 ]; then
        selected=""
        for index in "${!ports[@]}"; do
            if [ "${ports[index]}" = "$1" ]; then selected="$index"; break; fi
        done
        if [ -z "$selected" ]; then
            echo "Aucune instance trouvée sur le port $1." >&2
            return 1
        fi
    else
        printf 'Quelle instance arrêter ? (numéro, Entrée pour annuler) '
        read -r answer </dev/tty || { echo; echo "Arrêt annulé."; return 1; }
        [[ "$answer" =~ ^[0-9]+$ ]] || { echo "Arrêt annulé."; return 0; }
        answer=$((10#$answer))
        (( answer >= 1 && answer <= ${#pids[@]} )) || { echo "Numéro invalide ; arrêt annulé."; return 1; }
        selected=$((answer - 1))
    fi

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

chrome() {
    _chrome_list_running
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
    #   chrome            → 9222 si libre, sinon un port ALÉATOIRE libre (nouvelle instance)
    #   chrome 9223       → force le port 9223 (réutilise l'onglet si déjà actif)
    # Chaque instance MCP indépendante a son port ET son --user-data-dir ; le serveur
    # MCP correspondant doit pointer sur le MÊME port (--browserUrl http://127.0.0.1:PORT).
    local explicit=0 port="$CHROME_DEFAULT_PORT"
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
        port="$1"; explicit=1; shift
    elif [ -n "${CHROME_DEBUG_PORT:-}" ]; then
        port="$CHROME_DEBUG_PORT"; explicit=1
    fi

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
        printf 'Le port %s est déjà utilisé. Lancer une instance Chrome supplémentaire sur le port %s ? [y/N] ' "$port" "$newport"
        if ! read -r answer </dev/tty; then
            echo
            echo "Lancement annulé."
            return 1
        fi
        case "$answer" in
            y|Y|yes|YES|o|O|oui|OUI) ;;
            *) echo "Lancement annulé."; return 0 ;;
        esac
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
        --profile-directory=Default \
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
