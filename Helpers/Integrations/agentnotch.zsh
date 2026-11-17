# AgentNotch shell integration for zsh.
# Reports commands that ran for 2s or longer (command, exit code, duration, directory) to
# AgentNotch over its local Unix socket. The app decides which ones to show.
# Sending happens in the background, so your prompt never waits.

[[ -o interactive ]] || return 0
zmodload zsh/datetime 2>/dev/null || return 0

typeset -g __agentnotch_cmd="" __agentnotch_start=0

__agentnotch_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\t'/\\t}
    s=${s//[[:cntrl:]]/}
    print -rn -- "$s"
}

__agentnotch_preexec() {
    __agentnotch_cmd=$1
    __agentnotch_start=$EPOCHREALTIME
}

__agentnotch_precmd() {
    local exit_code=$?
    [[ -n $__agentnotch_cmd ]] || return 0
    local cmd=$__agentnotch_cmd start=$__agentnotch_start
    __agentnotch_cmd=""

    local -F duration=$(( EPOCHREALTIME - start ))
    (( duration >= 2 )) || return 0

    local sock="$HOME/Library/Application Support/AgentNotch/agentnotch.sock"
    [[ -S $sock ]] || return 0

    # Interactive programs aren't "jobs that finished".
    local first=${${(z)cmd}[1]}
    case ${first:t} in
        vim|nvim|vi|nano|emacs|less|more|man|top|htop|btop|ssh|mosh|tmux|screen|claude|watch|fzf|lazygit|tig) return 0 ;;
    esac
    # Bare REPLs (but not `python train.py`).
    case $cmd in
        python|python3|node|irb|psql|mysql|sqlite3|bun|deno|ipython) return 0 ;;
    esac

    local json
    json=$(printf '{"command":"%s","exit":%d,"duration":%.2f,"cwd":"%s"}' \
        "$(__agentnotch_escape "$cmd")" $exit_code $duration "$(__agentnotch_escape "$PWD")")

    ( /usr/bin/curl -s --max-time 1 --unix-socket "$sock" \
        -H "Content-Type: application/json" \
        -H "X-Term-Program: ${TERM_PROGRAM:-}" \
        -H "X-Bundle-Id: ${__CFBundleIdentifier:-}" \
        --data-binary "$json" http://localhost/v1/command >/dev/null 2>&1 & )
    return 0
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec __agentnotch_preexec
# Run first so $? is still the user's command's exit status.
precmd_functions=(__agentnotch_precmd ${precmd_functions:#__agentnotch_precmd})
