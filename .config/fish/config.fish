fish_add_path -g $HOME/.local/bin

set -g fish_greeting

if status is-interactive
    fastfetch
end

# tint the lava lamp with the active theme accent (written by theme-colors.sh)
function lavat --wraps lavat --description 'lavat in the active theme accent'
    set -l accent fcee0a
    set -l rim 7c7a3a
    test -r $HOME/.cache/theme/accent; and set accent (cat $HOME/.cache/theme/accent)
    test -r $HOME/.cache/theme/accent_dim; and set rim (cat $HOME/.cache/theme/accent_dim)
    command lavat -g -c $accent -k $rim $argv
end
