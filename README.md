# SetupChamp

SetupChamp is to setup a new Linux system, apply updates, and provide an interactive menu for installing useful applications and terminal tools.

## Features

- Updates the system using its detected package manager.
- Interactive app picker: arrow keys to navigate, Space to select, Enter to continue.
- Supports apt, dnf, yum, microdnf, pacman, zypper, and apk.

## Apps

- Brave Browser and Firefox
- Git and Neovim
- Visual Studio Code
- Deskflow (native package first, Flathub fallback)
- ONLYOFFICE Desktop Editors
- Alacritty Terminal with Chris Titus settings
- Docker Engine
- Fastfetch
- Chris Titus Bash prompt with Meslo Nerd Font

Run with `./setupchamp.sh`. Requires Bash and administrator
privileges (`sudo`).
