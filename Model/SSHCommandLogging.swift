import Foundation

/// Only this fixed vocabulary may cross the logging boundary. Unknown program
/// names can themselves be pasted passwords; never persist them verbatim.
enum SSHCommandLogging {
    static let oscCode = 6301
    static let names: Set<String> = Set("awk bash brew cat cd chmod chown clear cp curl date df diff dig docker du echo env exit find free git grep head history hostname id ip journalctl kill less ln ls make man mkdir mount mv nano netstat npm open passwd ping podman printf ps pwd python python3 read reboot rm rmdir rsync scp sed sh sleep sort ssh stat sudo su systemctl tail tar tee test top touch uname unzip uptime vi vim wc wget which who whoami xargs zsh".split(separator: " ").map(String.init))

    enum Event: Equatable {
        case ready, unavailable, command(String)
    }

    static func event(_ bytes: ArraySlice<UInt8>) -> Event? {
        guard bytes.count <= 96, let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        if text == "fc1;ready" { return .ready }
        if text == "fc1;unavailable" { return .unavailable }
        guard text.hasPrefix("fc1;command;") else { return nil }
        let name = String(text.dropFirst("fc1;command;".count))
        guard names.contains(name) || name == "other" else { return nil }
        return .command(name)
    }

    /// Sent as a remote command, never injected as terminal input. Authentication
    /// finishes before the shell starts. No user command/output is captured.
    static var remoteCommand: String {
        let script = bootstrap.replacingOccurrences(of: "__NAMES__", with: names.sorted().joined(separator: "|"))
        return "/bin/sh -c '" + script.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    // Temporary startup wrappers contain only fixed integration code. The user's
    // startup files are sourced, never changed. The parent removes wrappers on exit.
    static let bootstrap = #"""
    _fjarr_shell=${SHELL:-/bin/sh}
    case "${_fjarr_shell##*/}" in
      bash|zsh) ;;
      *) printf '\033]6301;fc1;unavailable\007'; exec "$_fjarr_shell" -l ;;
    esac
    _fjarr_dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fjarrconnect.XXXXXXXX") || {
      printf '\033]6301;fc1;unavailable\007'; exec "$_fjarr_shell" -l
    }
    trap 'rm -rf -- "$_fjarr_dir"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    cat > "$_fjarr_dir/integration" <<'FJARR_INTEGRATION'
    _fjarr_emit() {
      local line="$1" name
      while :; do
        case "$line" in [[:space:]]*) line=${line#?} ;; *) break ;; esac
      done
      name=${line%%[[:space:]\;\|\&\(\)\<\>]*}
      name=${name##*/}
      case "$name" in __NAMES__) ;; *) name=other ;; esac
      builtin printf '\033]6301;fc1;command;%s\007' "$name"
    }
    if [ -n "${ZSH_VERSION:-}" ]; then
      _fjarr_preexec() { _fjarr_emit "$1"; }
      preexec_functions+=(_fjarr_preexec)
      builtin printf '\033]6301;fc1;ready\007'
    elif [ -n "${BASH_VERSION:-}" ] && [ -z "$(trap -p DEBUG)" ]; then
      _fjarr_ready=0
      _fjarr_original_prompt=("${PROMPT_COMMAND[@]}")
      _fjarr_restore_status() { return "$1"; }
      _fjarr_prompt() {
        local result=$? command
        _fjarr_ready=0
        for command in "${_fjarr_original_prompt[@]}"; do
          if [ -n "$command" ]; then
            _fjarr_restore_status "$result"
            eval "$command"
          fi
        done
        _fjarr_ready=1
        return "$result"
      }
      _fjarr_debug() {
        case "$1" in _fjarr_prompt) _fjarr_ready=0; return ;; esac
        if [ "$_fjarr_ready" = 1 ]; then
          _fjarr_ready=0
          _fjarr_emit "$1"
        fi
        return 0
      }
      PROMPT_COMMAND=_fjarr_prompt
      builtin printf '\033]6301;fc1;ready\007'
      trap '_fjarr_debug "$BASH_COMMAND"' DEBUG
    else
      builtin printf '\033]6301;fc1;unavailable\007'
    fi
    FJARR_INTEGRATION
    export FJARR_INTEGRATION="$_fjarr_dir/integration"
    if [ "${_fjarr_shell##*/}" = bash ]; then
      cat > "$_fjarr_dir/bashrc" <<'FJARR_BASHRC'
    [ ! -r "$HOME/.bashrc" ] || . "$HOME/.bashrc"
    . "$FJARR_INTEGRATION"
    unset FJARR_INTEGRATION
    FJARR_BASHRC
      "$_fjarr_shell" --rcfile "$_fjarr_dir/bashrc" -i
    else
      export FJARR_ORIGINAL_ZDOTDIR="${ZDOTDIR:-$HOME}"
      cat > "$_fjarr_dir/.zshenv" <<'FJARR_ZSHENV'
    ZDOTDIR="$FJARR_ORIGINAL_ZDOTDIR"
    [ ! -r "$FJARR_ORIGINAL_ZDOTDIR/.zshenv" ] || . "$FJARR_ORIGINAL_ZDOTDIR/.zshenv"
    FJARR_ORIGINAL_ZDOTDIR="${ZDOTDIR:-$HOME}"
    ZDOTDIR="${FJARR_INTEGRATION%/*}"
    FJARR_ZSHENV
      cat > "$_fjarr_dir/.zshrc" <<'FJARR_ZSHRC'
    ZDOTDIR="$FJARR_ORIGINAL_ZDOTDIR"
    [ ! -r "$ZDOTDIR/.zshrc" ] || . "$ZDOTDIR/.zshrc"
    . "$FJARR_INTEGRATION"
    unset FJARR_INTEGRATION FJARR_ORIGINAL_ZDOTDIR
    FJARR_ZSHRC
      ZDOTDIR="$_fjarr_dir" "$_fjarr_shell" -i
    fi
    exit $?
    """#
}
