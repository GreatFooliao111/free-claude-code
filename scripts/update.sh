#!/bin/sh
set -eu

REPO_ARCHIVE_URL="https://github.com/Alishahryar1/free-claude-code/archive/refs/heads/main.zip"
PYTHON_VERSION="3.14.0"
MIN_UV_VERSION="0.11.16"
FCC_MACOS_BUNDLE_ID="io.github.alishahryar1.free-claude-code"
FCC_MACOS_OWNER_FILE=".free-claude-code-owner"
# Include retired entry points so updates reject older FCC processes before replacement.
FCC_COMMANDS="fcc-desktop fcc-server fcc-claude fcc-codex fcc-pi fcc-init free-claude-code"

dry_run=0
voice_nim=0
voice_local=0
voice_all=0
torch_backend=""
tool_bin=""

show_usage() {
    cat <<'USAGE'
Usage: update.sh [options]

Updates an existing Free Claude Code installation to the latest version from the main branch.
This script is faster than the full installer since it skips coding agent verification.

Options:
  --voice-nim              Install NVIDIA NIM voice transcription support.
  --voice-local            Install local Whisper voice transcription support.
  --voice-all              Install all voice transcription backends.
  --torch-backend VALUE    Use a uv PyTorch backend, such as cu130. Requires local voice.
  --dry-run                Print commands without running them.
  --help                   Show this help text.
USAGE
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

step() {
    printf '\n==> %s\n' "$1"
}

quote_arg() {
    case "$1" in
        *[!A-Za-z0-9_./:@%+=,-]*|"")
            escaped=$(printf '%s' "$1" | sed 's/\\\\/\\\\\\\\/g; s/"/\\"/g')
            printf '"%s"' "$escaped"
            ;;
        *)
            printf '%s' "$1"
            ;;
    esac
}

print_command() {
    printf '+'
    for arg in "$@"; do
        printf ' '
        quote_arg "$arg"
    done
    printf '\n'
}

run() {
    print_command "$@"
    if [ "$dry_run" -eq 1 ]; then
        return 0
    fi

    if "$@"; then
        return 0
    else
        status=$?
    fi

    fail "Command failed with exit code $status: $1"
}

add_path_entry() {
    [ -n "$1" ] || return 0
    case ":$PATH:" in
        *":$1:"*) ;;
        *) PATH="$1:$PATH" ;;
    esac
}

add_known_bin_directories() {
    if [ -n "${XDG_BIN_HOME:-}" ]; then
        add_path_entry "$XDG_BIN_HOME"
    fi

    if [ -n "${HOME:-}" ]; then
        add_path_entry "$HOME/.local/bin"
        add_path_entry "$HOME/.cargo/bin"
    fi

    export PATH
    hash -r 2>/dev/null || true
}

fcc_process_ids() {
    command_name=$1

    if command -v pgrep >/dev/null 2>&1; then
        {
            pgrep -x "$command_name" 2>/dev/null || true
            pgrep -f "(^|/)${command_name}([[:space:]]|$)" 2>/dev/null || true
        } | sort -nu
        return 0
    fi

    ps -A -o pid= -o args= 2>/dev/null |
        awk -v command_name="$command_name" '
            BEGIN {
                pattern = "(^|/)" command_name "([[:space:]]|$)"
            }
            {
                process_id = $1
                sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
                if ($0 ~ pattern) {
                    print process_id
                }
            }
        ' || true
}

assert_fcc_is_installed() {
    add_known_bin_directories
    
    if ! command -v fcc-server >/dev/null 2>&1; then
        fail "Free Claude Code is not installed. Please run install.sh first."
    fi
    
    if command -v uv >/dev/null 2>&1; then
        tool_bin=$(uv tool dir --bin 2>/dev/null) || true
        if [ -n "$tool_bin" ] && [ -x "$tool_bin/fcc-server" ]; then
            return 0
        fi
    fi
    
    # Check common locations
    for check_path in "$HOME/.local/bin/fcc-server" "$HOME/.cargo/bin/fcc-server"; do
        if [ -x "$check_path" ]; then
            return 0
        fi
    done
    
    fail "Free Claude Code installation not found in standard locations."
}

assert_no_fcc_processes_running() {
    running=""
    for command_name in $FCC_COMMANDS; do
        process_ids=$(fcc_process_ids "$command_name")
        [ -n "$process_ids" ] || continue

        for process_id in $process_ids; do
            process="$command_name (PID $process_id)"
            if [ -n "$running" ]; then
                running="$running, $process"
            else
                running=$process
            fi
        done
    done

    if [ -n "$running" ]; then
        fail "Free Claude Code is still running ($running). Stop those processes, then rerun the updater."
    fi
}

current_uv_version() {
    if output=$(uv --version); then
        :
    else
        return 1
    fi

    case "$output" in
        uv\ *) version=${output#uv} ;;
        *) version=$output ;;
    esac
    version=${version%% *}

    case "$version" in
        [0-9]*.[0-9]*.[0-9]*) printf '%s\n' "$version" ;;
        *) return 1 ;;
    esac
}

uv_version_is_supported() {
    case "$1" in
        *-*) return 1 ;;
    esac

    current=${1%%+*}
    minimum=${2%%+*}

    old_ifs=$IFS
    IFS=.
    set -- $current
    current_major=${1:-0}
    current_minor=${2:-0}
    current_patch=${3:-0}
    set -- $minimum
    minimum_major=${1:-0}
    minimum_minor=${2:-0}
    minimum_patch=${3:-0}
    IFS=$old_ifs

    case "$current_major$current_minor$current_patch$minimum_major$minimum_minor$minimum_patch" in
        *[!0-9]*) return 1 ;;
    esac

    [ "$current_major" -gt "$minimum_major" ] && return 0
    [ "$current_major" -lt "$minimum_major" ] && return 1
    [ "$current_minor" -gt "$minimum_minor" ] && return 0
    [ "$current_minor" -lt "$minimum_minor" ] && return 1
    [ "$current_patch" -ge "$minimum_patch" ]
}

verify_uv() {
    if [ "$dry_run" -eq 1 ]; then
        print_command uv --version
        return 0
    fi

    command -v uv >/dev/null 2>&1 || fail "uv is required but not found on PATH."
    version=$(current_uv_version) || fail "uv is present, but 'uv --version' did not return a valid version."
    if ! uv_version_is_supported "$version" "$MIN_UV_VERSION"; then
        fail "Stable uv $MIN_UV_VERSION or newer is required; found uv $version."
    fi

    printf 'Verified uv %s.\n' "$version"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --voice-nim)
                voice_nim=1
                ;;
            --voice-local)
                voice_local=1
                ;;
            --voice-all)
                voice_all=1
                ;;
            --torch-backend)
                shift
                [ "$#" -gt 0 ] || fail "--torch-backend requires a value."
                torch_backend=$1
                [ -n "$torch_backend" ] || fail "--torch-backend requires a non-empty value."
                ;;
            --torch-backend=*)
                torch_backend=${1#*=}
                [ -n "$torch_backend" ] || fail "--torch-backend requires a non-empty value."
                ;;
            --dry-run)
                dry_run=1
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                show_usage >&2
                fail "unknown option: $1"
                ;;
        esac
        shift
    done
}

validate_args() {
    include_local=$voice_local
    if [ "$voice_all" -eq 1 ]; then
        include_local=1
    fi

    if [ -n "$torch_backend" ] && [ "$include_local" -ne 1 ]; then
        fail "--torch-backend requires --voice-local or --voice-all."
    fi
}

package_spec() {
    include_nim=$voice_nim
    include_local=$voice_local

    if [ "$voice_all" -eq 1 ]; then
        include_nim=1
        include_local=1
    fi

    if [ "$include_nim" -eq 1 ] && [ "$include_local" -eq 1 ]; then
        printf 'free-claude-code[voice,voice_local] @ %s' "$REPO_ARCHIVE_URL"
    elif [ "$include_nim" -eq 1 ]; then
        printf 'free-claude-code[voice] @ %s' "$REPO_ARCHIVE_URL"
    elif [ "$include_local" -eq 1 ]; then
        printf 'free-claude-code[voice_local] @ %s' "$REPO_ARCHIVE_URL"
    else
        printf 'free-claude-code @ %s' "$REPO_ARCHIVE_URL"
    fi
}

update_free_claude_code() {
    assert_no_fcc_processes_running
    spec=$(package_spec)

    step "Updating Free Claude Code to latest version"
    printf "This will replace your current installation with the latest version from main branch.\n"

    if [ -n "$torch_backend" ]; then
        run uv tool install --force --refresh-package free-claude-code --python "$PYTHON_VERSION" --torch-backend "$torch_backend" "$spec"
    else
        run uv tool install --force --refresh-package free-claude-code --python "$PYTHON_VERSION" "$spec"
    fi
}

configure_and_verify_free_claude_code() {
    run uv tool update-shell

    if [ "$dry_run" -eq 1 ]; then
        print_command uv tool dir --bin
        printf '+ verify fcc-desktop, fcc-server, fcc-claude, fcc-codex, and fcc-pi in the uv tool bin directory\n'
        print_command fcc-server --version
        return 0
    fi

    print_command uv tool dir --bin
    if tool_bin=$(uv tool dir --bin); then
        :
    else
        status=$?
        fail "Could not determine the uv tool bin directory (exit code $status)."
    fi
    [ -n "$tool_bin" ] || fail "uv returned an empty tool bin directory."

    add_path_entry "$tool_bin"
    export PATH
    hash -r 2>/dev/null || true

    for command_name in fcc-desktop fcc-server fcc-claude fcc-codex fcc-pi; do
        [ -x "$tool_bin/$command_name" ] || fail "Free Claude Code installation did not create $tool_bin/$command_name."
    done

    run "$tool_bin/fcc-server" --version
}

macos_app_is_fcc_owned() {
    app_dir=$1
    owner_file="$app_dir/Contents/$FCC_MACOS_OWNER_FILE"
    [ -d "$app_dir" ] &&
        [ ! -L "$app_dir" ] &&
        [ -f "$owner_file" ] &&
        [ "$(cat "$owner_file")" = "$FCC_MACOS_BUNDLE_ID" ]
}

update_macos_desktop_app() {
    [ "$(uname -s)" = "Darwin" ] || return 0

    app_dir="$HOME/Applications/Free Claude Code.app"
    contents_dir="$app_dir/Contents"
    owner_file="$contents_dir/$FCC_MACOS_OWNER_FILE"
    executable_dir="$contents_dir/MacOS"
    executable_path="$executable_dir/fcc-desktop"
    resources_dir="$contents_dir/Resources"
    icon_path="$resources_dir/AppIcon.icns"
    desktop_dir="$HOME/Desktop"
    desktop_link="$desktop_dir/Free Claude Code.app"

    if [ ! -e "$app_dir" ] || [ -L "$app_dir" ]; then
        printf 'macOS desktop app not found at %s; skipping desktop app update.\n' "$app_dir"
        return 0
    fi

    macos_app_is_fcc_owned "$app_dir" || {
        printf 'An app not managed by Free Claude Code exists at %s; leaving it unchanged.\n' "$app_dir"
        return 0
    }

    if [ "$dry_run" -eq 1 ]; then
        print_command mkdir -p "$executable_dir" "$resources_dir" "$desktop_dir"
        print_command fcc-desktop --export-icon "$icon_path"
        printf '+ update %s and %s\n' "$owner_file" "$executable_path"
        return 0
    fi

    mkdir -p "$executable_dir" "$resources_dir" "$desktop_dir"
    run "$tool_bin/fcc-desktop" --export-icon "$icon_path"
    [ -f "$icon_path" ] || fail "Free Claude Code did not export its macOS app icon to $icon_path."
    printf '%s\n' "$FCC_MACOS_BUNDLE_ID" > "$owner_file"

    shell_quote() {
        escaped=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
        printf "'%s'" "$escaped"
    }

    desktop_command=$(shell_quote "$tool_bin/fcc-desktop")
    {
        printf '%s\n' '#!/bin/sh'
        printf 'exec %s\n' "$desktop_command"
    } > "$executable_path"
    chmod +x "$executable_path"

    printf 'Updated macOS desktop app at %s\n' "$app_dir"
}

parse_args "$@"
validate_args
add_known_bin_directories

step "Checking Free Claude Code installation"
assert_fcc_is_installed

step "Checking uv"
verify_uv

update_free_claude_code

step "Configuring PATH and verifying Free Claude Code"
configure_and_verify_free_claude_code

if [ "$(uname -s)" = "Darwin" ]; then
    step "Updating macOS desktop app"
    update_macos_desktop_app
fi

if [ "$dry_run" -eq 1 ]; then
    printf '\nDry run complete. No changes were made.\n'
else
    printf '\n✅ Free Claude Code has been updated to the latest version!\n\n'
    printf 'Start the proxy with: fcc-server\n'
    printf 'Run Claude Code with: fcc-claude\n'
    printf 'Run Codex with: fcc-codex\n'
    printf 'Run Pi with: fcc-pi\n'
    
    if [ "$(uname -s)" = "Darwin" ]; then
        printf '\nTip: You can also launch Free Claude Code from Applications or your Desktop.\n'
    fi
fi
