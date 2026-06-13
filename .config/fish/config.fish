fish_add_path -g $HOME/.local/bin

set -g fish_greeting

if status is-interactive
    fastfetch
end
