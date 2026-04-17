#
# Executes commands at the start of an interactive session.
#
# Authors:
#   Sorin Ionescu <sorin.ionescu@gmail.com>
#

# Source Prezto.
if [[ -s "${ZDOTDIR:-$HOME}/.zprezto/init.zsh" ]]; then
  source "${ZDOTDIR:-$HOME}/.zprezto/init.zsh"
fi

# Customize to your needs...
export PATH="$HOME/.anyenv/bin:$PATH"
eval "$(anyenv init - zsh)"

# The next line updates PATH for the Google Cloud SDK.
if [ -f '$HOME/google-cloud-sdk/path.zsh.inc' ]; then . '$HOME/google-cloud-sdk/path.zsh.inc'; fi

# The next line enables shell command completion for gcloud.
if [ -f '$HOME/google-cloud-sdk/completion.zsh.inc' ]; then . '$HOME/google-cloud-sdk/completion.zsh.inc'; fi
export PATH="/usr/local/opt/openjdk/bin:$PATH"
export PATH="/opt/homebrew/opt/openjdk/bin:$PATH"


eval "$(direnv hook zsh)"
export PATH="$PATH:$(go env GOPATH)/bin"
eval "$(/opt/homebrew/bin/mise activate zsh)"

. "$HOME/.local/bin/env"

eval "$(anyenv init -)"
# Claude Code: auto compact window size
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000
