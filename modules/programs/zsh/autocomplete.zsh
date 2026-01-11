# ds autocomplete (if installed)
if command -v ds &> /dev/null; then
  eval "$(_DS_COMPLETE=zsh_source ds)"
fi

# Additional tool completions

# fzf integration for better history search (fish-like experience)
if command -v fzf &> /dev/null; then
  # Use fzf for Ctrl+R history search
  source <(fzf --zsh 2>/dev/null || true)
fi

# direnv integration
if command -v direnv &> /dev/null; then
  eval "$(direnv hook zsh)"
fi

# zoxide integration (if installed, provides better cd)
if command -v zoxide &> /dev/null; then
  eval "$(zoxide init zsh)"
fi
