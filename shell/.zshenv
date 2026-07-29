#
# Defines environment variables.
#
# Authors:
#   Sorin Ionescu <sorin.ionescu@gmail.com>
#

# Ensure that a non-login, non-interactive shell has a defined environment.
if [[ ( "$SHLVL" -eq 1 && ! -o LOGIN ) && -s "${ZDOTDIR:-$HOME}/.zprofile" ]]; then
  source "${ZDOTDIR:-$HOME}/.zprofile"
fi

# Vite+ bin (https://viteplus.dev)
. "$HOME/.vite-plus/env"

# ~/.local/bin (claude CLI 等) は非対話シェルからも見えるようにする。
# .zshrc は対話シェルでしか読まれず、GUI アプリ (LightDeskHub 等) が
# 起動するシェルから claude が見つからなくなるため .zshenv 側に置く。
export PATH="$HOME/.local/bin:$PATH"
