# SetupChamp

## Linux system updater and software installer

Run `./setupchamp.sh` to detect the Linux distribution and its package manager,
refresh package metadata, upgrade installed packages, and see the package
manager's pre-upgrade count of available package updates. Afterward, choose one
or more programs from the interactive menu and confirm before installation.

The script supports `apt`, `dnf`, `yum`, `microdnf`, `pacman`, `zypper`, and
`apk`. It needs Bash and administrator access (either run it as root or have
`sudo` installed). The menu includes Brave Browser, Firefox, Git, Neovim, VLC,
and LazyGit. Brave uses its vendor repository on apt-, dnf/yum-, and
zypper-based systems, and Flathub on other supported systems. If native
LazyGit installation fails, the script downloads its Linux binary from the
official GitHub releases and installs it in `/usr/local/bin`.

Package upgrades require an internet connection. GitHub fallback requires
`curl` or `wget`; the script does not install either automatically.
