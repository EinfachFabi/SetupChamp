#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME=${0##*/}
UPDATE_SUMMARY=''
declare -a MENU_NAMES=(
  "Brave Browser"
  "Firefox"
  "Git"
  "Neovim "
  "Visual Studio Code"
  "Deskflow "
  "ONLYOFFICE"
  "Alacritty"
  "Docker Engine"
  "Fastfetch"
  "Chris Titus Bash prompt"
)
declare -a MENU_IDS=(brave firefox git neovim vscode deskflow onlyoffice alacritty docker fastfetch christitus-prompt)
declare -a SELECTED=()

error() {
  printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
}

run_as_root() {
  if (( EUID == 0 )); then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    error "Administrator privileges are required; run as root or install sudo."
    return 1
  fi
}

detect_package_manager() {
  local candidate
  for candidate in apt-get dnf yum microdnf pacman zypper apk; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  error "No supported package manager found (apt, dnf, yum, microdnf, pacman, zypper, apk)."
  return 1
}

get_distribution_name() {
  if [[ -r /etc/os-release ]]; then
    (
      . /etc/os-release
      printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}"
    )
  else
    printf 'Linux (unknown distribution)'
  fi
}

count_lines() {
  awk 'END { print NR + 0 }'
}

count_pending_updates() {
  local output status
  case "$PACKAGE_MANAGER" in
    apt-get)
      run_as_root apt-get -s upgrade | awk '/^Inst / { count++ } END { print count + 0 }'
      ;;
    dnf)
      run_as_root dnf -q repoquery --upgrades --queryformat '%{name}' | sort -u | count_lines
      ;;
    yum)
      if output=$(run_as_root yum -q check-update); then
        status=0
      else
        status=$?
      fi
      if (( status != 0 && status != 100 )); then
        return "$status"
      fi
      printf '%s\n' "$output" |
        awk 'NF >= 3 && $1 !~ /^(Loaded|Last|Obsoleting)/ { count++ } END { print count + 0 }'
      ;;
    microdnf)
      run_as_root microdnf repoquery --upgrades --queryformat '%{name}' | sort -u | count_lines
      ;;
    pacman)
      run_as_root pacman -Qu | count_lines
      ;;
    zypper)
      run_as_root zypper --no-refresh --non-interactive list-updates |
        awk 'BEGIN { rows=0 } /^[[:space:]]*v[[:space:]]*\|/ { rows++ } END { print rows + 0 }'
      ;;
    apk)
      run_as_root apk version -l '<' | awk 'NF { count++ } END { print count + 0 }'
      ;;
  esac
}

pending_update_count() {
  if count_pending_updates; then
    return 0
  fi
  error "Could not determine the pending package count; continuing with the system upgrade."
  printf 'unknown\n'
}

update_system() {
  local pending
  printf 'Refreshing package metadata and checking for updates...\n'
  case "$PACKAGE_MANAGER" in
    apt-get)
      run_as_root apt-get update
      pending=$(pending_update_count)
      run_as_root apt-get upgrade -y
      ;;
    dnf)
      run_as_root dnf makecache --refresh
      pending=$(pending_update_count)
      run_as_root dnf upgrade --refresh -y
      ;;
    yum)
      run_as_root yum makecache
      pending=$(pending_update_count)
      run_as_root yum update -y
      ;;
    microdnf)
      run_as_root microdnf makecache
      pending=$(pending_update_count)
      run_as_root microdnf update -y
      ;;
    pacman)
      pending=$(pending_update_count)
      run_as_root pacman -Syu --noconfirm
      ;;
    zypper)
      run_as_root zypper --non-interactive refresh
      pending=$(pending_update_count)
      run_as_root zypper --non-interactive update
      ;;
    apk)
      run_as_root apk update
      pending=$(pending_update_count)
      run_as_root apk upgrade
      ;;
  esac
  UPDATE_SUMMARY="System update completed successfully. Packages upgraded (pre-upgrade count): $pending"
  printf '\n%s\n\n' "$UPDATE_SUMMARY"
}

package_name() {
  local program=$1
  case "$program:$PACKAGE_MANAGER" in
    brave:*) printf 'brave-browser\n' ;;
    firefox:apt-get) printf 'firefox-esr\n' ;;
    firefox:dnf|firefox:yum|firefox:microdnf|firefox:pacman|firefox:apk) printf 'firefox\n' ;;
    firefox:zypper) printf 'MozillaFirefox\n' ;;
    git:*) printf 'git\n' ;;
    neovim:*) printf 'neovim\n' ;;
    deskflow:*) printf 'deskflow\n' ;;
    alacritty:*) printf 'alacritty\n' ;;
    docker:apt-get) printf 'docker.io\n' ;;
    docker:*) printf 'docker\n' ;;
    fastfetch:*) printf 'fastfetch\n' ;;
    *) error "No package mapping for '$program' on $PACKAGE_MANAGER."; return 1 ;;
  esac
}

install_packages() {
  local package=$1
  case "$PACKAGE_MANAGER" in
    apt-get) run_as_root apt-get install -y "$package" ;;
    dnf) run_as_root dnf install -y "$package" ;;
    yum) run_as_root yum install -y "$package" ;;
    microdnf) run_as_root microdnf install -y "$package" ;;
    pacman) run_as_root pacman -S --needed --noconfirm "$package" ;;
    zypper) run_as_root zypper --non-interactive install "$package" ;;
    apk) run_as_root apk add "$package" ;;
  esac
}

install_brave_from_vendor_repo() {
  case "$PACKAGE_MANAGER" in
    apt-get)
      run_as_root apt-get install -y curl ca-certificates gnupg
      local key_file
      key_file=$(mktemp)
      if ! curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-core.asc |
        gpg --dearmor >"$key_file"; then
        rm -f "$key_file"
        error "Could not download Brave's signing key."
        return 1
      fi
      run_as_root install -m 0644 "$key_file" /usr/share/keyrings/brave-browser-archive-keyring.gpg
      rm -f "$key_file"
      printf '%s\n' \
        'deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main' |
        run_as_root tee /etc/apt/sources.list.d/brave-browser-release.list >/dev/null
      run_as_root apt-get update
      install_packages brave-browser
      ;;
    dnf|yum|microdnf)
      run_as_root mkdir -p /etc/yum.repos.d
      printf '%s\n' \
        '[brave-browser]' \
        'name=Brave Browser' \
        'baseurl=https://brave-browser-rpm-release.s3.brave.com/$basearch' \
        'enabled=1' \
        'gpgcheck=1' \
        'gpgkey=https://brave-browser-rpm-release.s3.brave.com/brave-core.asc' |
        run_as_root tee /etc/yum.repos.d/brave-browser.repo >/dev/null
      install_packages brave-browser
      ;;
      zypper)
        if ! run_as_root zypper --non-interactive repos --uri |
          grep -Fq 'brave-browser-rpm-release.s3.brave.com'; then
          run_as_root zypper --non-interactive addrepo --refresh \
            https://brave-browser-rpm-release.s3.brave.com/x86_64 brave-browser
        fi
        install_packages brave-browser
      ;;
    *)
      return 1
      ;;
  esac
}

install_brave_from_flatpak() {
  install_flatpak_app com.brave.Browser
}

install_flatpak_app() {
  local app_id=$1
  if ! command -v flatpak >/dev/null 2>&1; then
    install_packages flatpak
  fi
  if ! command -v flatpak >/dev/null 2>&1; then
    error "Flatpak is not available after installation."
    return 1
  fi
  run_as_root flatpak remote-add --if-not-exists --system flathub \
    https://flathub.org/repo/flathub.flatpakrepo
  run_as_root flatpak install --system --assumeyes flathub "$app_id"
}

install_vscode_from_vendor_repo() {
  local key_file
  case "$PACKAGE_MANAGER" in
    apt-get)
      if ! run_as_root apt-get install -y curl ca-certificates gnupg; then
        return 1
      fi
      key_file=$(mktemp)
      if ! curl -fsSL https://packages.microsoft.com/keys/microsoft.asc |
        gpg --dearmor >"$key_file"; then
        rm -f "$key_file"
        error "Could not download Microsoft's package signing key."
        return 1
      fi
      if ! run_as_root install -m 0644 "$key_file" /usr/share/keyrings/microsoft.gpg; then
        rm -f "$key_file"
        return 1
      fi
      rm -f "$key_file"
      if ! printf '%s\n' \
        'deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main' |
        run_as_root tee /etc/apt/sources.list.d/vscode.list >/dev/null; then
        return 1
      fi
      if ! run_as_root apt-get update; then
        return 1
      fi
      install_packages code || return 1
      ;;
    dnf|yum)
      if ! run_as_root rpm --import https://packages.microsoft.com/keys/microsoft.asc; then
        return 1
      fi
      if ! run_as_root mkdir -p /etc/yum.repos.d; then
        return 1
      fi
      if ! printf '%s\n' \
        '[code]' \
        'name=Visual Studio Code' \
        'baseurl=https://packages.microsoft.com/yumrepos/vscode' \
        'enabled=1' \
        'gpgcheck=1' \
        'gpgkey=https://packages.microsoft.com/keys/microsoft.asc' |
        run_as_root tee /etc/yum.repos.d/vscode.repo >/dev/null; then
        return 1
      fi
      install_packages code || return 1
      ;;
    *)
      return 1
      ;;
  esac
}

install_vscode() {
  if [[ $PACKAGE_MANAGER == apt-get || $PACKAGE_MANAGER == dnf || $PACKAGE_MANAGER == yum ]]; then
    if install_vscode_from_vendor_repo; then
      return 0
    fi
    printf 'Native VS Code installation failed; trying the official Flatpak instead.\n' >&2
  fi
  install_flatpak_app com.visualstudio.code
}

install_alacritty_settings() {
  local config_dir temp_dir backup_dir url
  config_dir="$HOME/.config/alacritty"
  temp_dir=$(mktemp -d)

  for url in \
    https://raw.githubusercontent.com/ChrisTitusTech/dwm-titus/main/config/alacritty/alacritty.toml \
    https://raw.githubusercontent.com/ChrisTitusTech/dwm-titus/main/config/alacritty/keybinds.toml \
    https://raw.githubusercontent.com/ChrisTitusTech/dwm-titus/main/config/alacritty/nordic.toml; do
    if ! fetch_file "$url" "$temp_dir/${url##*/}"; then
      rm -rf "$temp_dir"
      error "Could not download the Chris Titus Alacritty settings."
      return 1
    fi
  done

  # Alacritty 0.13 expects imports at the top level, not under the newer [general] section.
  # Use the included Nordic theme and start in a larger window instead of importing a desktop-only theme.
  if ! sed \
    -e '/^\[general\]$/d' \
    -e '/^working_directory = "None"$/d' \
    -e 's/active-theme\.toml/nordic.toml/' \
    -e 's/^columns = 100$/columns = 140/' \
    -e 's/^lines = 30$/lines = 42/' \
    "$temp_dir/alacritty.toml" >"$temp_dir/alacritty.toml.new"; then
    rm -rf "$temp_dir"
    error "Could not prepare the downloaded Alacritty settings."
    return 1
  fi
  mv "$temp_dir/alacritty.toml.new" "$temp_dir/alacritty.toml"

  mkdir -p "$HOME/.config"
  if [[ -e $config_dir || -L $config_dir ]]; then
    backup_dir="$config_dir.backup.$(date +%Y%m%d%H%M%S)"
    if ! mv "$config_dir" "$backup_dir"; then
      rm -rf "$temp_dir"
      error "Could not back up the existing Alacritty configuration."
      return 1
    fi
    printf 'Existing Alacritty settings backed up to %s\n' "$backup_dir"
  fi
  if ! mv "$temp_dir" "$config_dir"; then
    error "Could not install the Alacritty settings."
    return 1
  fi
}

install_docker() {
  install_packages "$(package_name docker)"
  if command -v systemctl >/dev/null 2>&1; then
    run_as_root systemctl enable --now docker
  elif command -v rc-update >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
    run_as_root rc-update add docker default
    run_as_root service docker start
  else
    printf 'Docker was installed, but this init system could not be configured automatically.\n' >&2
  fi
  printf 'Docker is installed. Using it without sudo requires manual docker-group setup and a new login.\n'
}

install_fastfetch() {
  if install_packages "$(package_name fastfetch)"; then
    return 0
  fi
  printf 'Native Fastfetch installation failed; trying the official GitHub release.\n' >&2
  install_fastfetch_from_github
}

install_fastfetch_from_github() {
  local workdir api_file asset tag url arch archive_path binary
  workdir=$(mktemp -d)
  api_file="$workdir/release.json"
  if ! fetch_file https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest "$api_file"; then
    rm -rf "$workdir"
    error "Could not query the latest Fastfetch release from GitHub."
    return 1
  fi
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *)
      rm -rf "$workdir"
      error "Fastfetch GitHub fallback does not support architecture $(uname -m)."
      return 1
      ;;
  esac
  tag=$(sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p' "$api_file" | head -n 1)
  asset=$(grep -oE "\"name\"[[:space:]]*:[[:space:]]*\"fastfetch-linux-${arch}[^\\\"]*\\.tar\\.gz\"" \
    "$api_file" | head -n 1 | sed -E 's/^.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
  if [[ -z $tag || -z $asset ]]; then
    rm -rf "$workdir"
    error "No matching Linux archive was found in the latest Fastfetch release."
    return 1
  fi
  url="https://github.com/fastfetch-cli/fastfetch/releases/download/$tag/$asset"
  if ! fetch_file "$url" "$workdir/fastfetch.tar.gz"; then
    rm -rf "$workdir"
    error "Could not download a valid Fastfetch archive."
    return 1
  fi
  archive_path=$(tar -tzf "$workdir/fastfetch.tar.gz" |
    awk '$0 == "fastfetch" || $0 ~ /\/fastfetch$/ { print; exit }')
  if [[ -z $archive_path || $archive_path == /* || $archive_path == *../* ]]; then
    rm -rf "$workdir"
    error "The Fastfetch archive does not contain a safe binary path."
    return 1
  fi
  if ! tar -xzf "$workdir/fastfetch.tar.gz" -C "$workdir" "$archive_path"; then
    rm -rf "$workdir"
    error "Could not extract Fastfetch from the GitHub archive."
    return 1
  fi
  binary="$workdir/$archive_path"
  if [[ ! -f $binary || ! -x $binary ]]; then
    rm -rf "$workdir"
    error "Fastfetch archive contained no executable binary."
    return 1
  fi
  if ! run_as_root install -m 0755 "$binary" /usr/local/bin/fastfetch; then
    rm -rf "$workdir"
    error "Could not install Fastfetch in /usr/local/bin."
    return 1
  fi
  rm -rf "$workdir"
}

install_meslo_nerd_font() {
  local workdir font_archive font_dir font_extract
  if ! command -v fc-list >/dev/null 2>&1 && ! install_packages fontconfig; then
    error "Could not install fontconfig."
    return 1
  fi
  if ! command -v fc-list >/dev/null 2>&1; then
    error "Font installation requires fontconfig."
    return 1
  fi
  if fc-list :family 2>/dev/null | grep -qi 'MesloLGS Nerd Font Mono'; then
    return 0
  fi
  if ! command -v unzip >/dev/null 2>&1 && ! install_packages unzip; then
    error "Could not install unzip for the Meslo Nerd Font."
    return 1
  fi
  if ! command -v unzip >/dev/null 2>&1; then
    error "Font installation requires unzip."
    return 1
  fi

  workdir=$(mktemp -d)
  font_archive="$workdir/Meslo.zip"
  font_extract="$workdir/fonts"
  mkdir -p "$font_extract"
  if ! fetch_file \
    https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip \
    "$font_archive"; then
    rm -rf "$workdir"
    error "Could not download the Meslo Nerd Font."
    return 1
  fi
  if ! unzip -q "$font_archive" -d "$font_extract"; then
    rm -rf "$workdir"
    error "Could not extract the Meslo Nerd Font."
    return 1
  fi
  if ! find "$font_extract" -type f -iname '*.ttf' -print -quit | grep -q .; then
    rm -rf "$workdir"
    error "The Nerd Font archive contained no TrueType font files."
    return 1
  fi
  font_dir="$HOME/.local/share/fonts/MesloLGSNerdFontMono"
  mkdir -p "$font_dir"
  if ! find "$font_extract" -type f -iname '*.ttf' -exec cp -f '{}' "$font_dir/" \;; then
    rm -rf "$workdir"
    error "Could not install the Meslo Nerd Font files."
    return 1
  fi
  if ! fc-cache -f >/dev/null; then
    rm -rf "$workdir"
    error "Could not refresh the user font cache."
    return 1
  fi
  rm -rf "$workdir"
  printf 'MesloLGS Nerd Font Mono installed.\n'
}

install_christitus_prompt() {
  local workdir repository backup destination
  local installer
  workdir=$(mktemp -d)
  repository="$workdir/mybash"
  destination="$HOME/.local/share/mybash"

  if ! command -v git >/dev/null 2>&1; then
    install_packages "$(package_name git)"
  fi
  if ! git init -q "$repository" ||
    ! git -C "$repository" remote add origin https://github.com/ChrisTitusTech/mybash.git ||
    ! git -C "$repository" fetch --quiet --depth 1 origin b96e064f232e056efb413baa396e1c5320f8f950 ||
    ! git -C "$repository" checkout --quiet --detach FETCH_HEAD; then
    rm -rf "$workdir"
    error "Could not download the Chris Titus Bash prompt configuration."
    return 1
  fi

  if ! command -v starship >/dev/null 2>&1 && [[ ! -x $HOME/.local/bin/starship ]]; then
    installer=$(mktemp)
    if ! fetch_file https://starship.rs/install.sh "$installer"; then
      rm -f "$installer"
      rm -rf "$workdir"
      error "Could not download the Starship installer."
      return 1
    fi
    mkdir -p "$HOME/.local/bin"
    if ! sh "$installer" -y -b "$HOME/.local/bin"; then
      rm -f "$installer"
      rm -rf "$workdir"
      error "Starship installation failed."
      return 1
    fi
    rm -f "$installer"
  fi

  if ! install_meslo_nerd_font; then
    rm -rf "$workdir"
    return 1
  fi
  rm -rf "$workdir"

  # Preserve the user's existing configuration and repository before linking the selected prompt.
  if [[ -e $HOME/.bashrc || -L $HOME/.bashrc ]]; then
    backup="$HOME/.bashrc.backup.$(date +%Y%m%d%H%M%S).$$"
    if ! cp -L "$HOME/.bashrc" "$backup"; then
      rm -rf "$workdir"
      error "Could not back up ~/.bashrc."
      return 1
    fi
    printf 'Existing Bash configuration backed up to %s\n' "$backup"
  fi
  if [[ -e $HOME/.config/starship.toml || -L $HOME/.config/starship.toml ]]; then
    backup="$HOME/.config/starship.toml.backup.$(date +%Y%m%d%H%M%S).$$"
    if ! cp -L "$HOME/.config/starship.toml" "$backup"; then
      rm -rf "$workdir"
      error "Could not back up ~/.config/starship.toml."
      return 1
    fi
  fi
  if [[ -e $destination || -L $destination ]]; then
    backup="$destination.backup.$(date +%Y%m%d%H%M%S).$$"
    if ! mv "$destination" "$backup"; then
      rm -rf "$workdir"
      error "Could not back up the existing mybash directory."
      return 1
    fi
  fi
  mkdir -p "$(dirname "$destination")" "$HOME/.config" "$HOME/.local/bin"
  if ! mv "$repository" "$destination"; then
    rm -rf "$workdir"
    error "Could not install the Chris Titus Bash prompt files."
    return 1
  fi
  rm -rf "$workdir"
  {
    printf 'export PATH="$HOME/.local/bin:$PATH"\n'
    cat "$destination/.bashrc"
  } >"$destination/.bashrc.new"
  mv "$destination/.bashrc.new" "$destination/.bashrc"
  rm -f "$HOME/.bashrc" "$HOME/.config/starship.toml"
  ln -sfn "$destination/.bashrc" "$HOME/.bashrc"
  ln -sfn "$destination/starship.toml" "$HOME/.config/starship.toml"
  if [[ -f $HOME/.bash_profile ]]; then
    backup="$HOME/.bash_profile"
  else
    backup="$HOME/.profile"
  fi
  if ! grep -Fq 'export PATH="$HOME/.local/bin:$PATH"' "$backup" 2>/dev/null; then
    printf '\n# Add user-installed command-line tools to PATH.\nexport PATH="$HOME/.local/bin:$PATH"\n' >>"$backup"
  fi
  printf 'Chris Titus Bash prompt installed. Restart Bash to apply it.\n'
}

fetch_file() {
  local url=$1
  local destination=$2
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    if ! install_packages curl; then
      error "Could not install curl or find wget for downloading $url."
      return 1
    fi
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$destination"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$destination" "$url"
  else
    error "GitHub fallback requires curl or wget."
    return 1
  fi
}

install_program() {
  local program=$1
  local package
  case "$program" in
    brave)
      if [[ $PACKAGE_MANAGER == apt-get || $PACKAGE_MANAGER == dnf ||
        $PACKAGE_MANAGER == yum || $PACKAGE_MANAGER == microdnf ||
        $PACKAGE_MANAGER == zypper ]]; then
        if [[ $PACKAGE_MANAGER == zypper && $(uname -m) != x86_64 ]]; then
          install_brave_from_flatpak
        else
          install_brave_from_vendor_repo
        fi
      else
        install_brave_from_flatpak
      fi
      ;;
    vscode) install_vscode ;;
    deskflow)
      if ! install_packages "$(package_name "$program")"; then
        printf 'Deskflow is not available from this distro repository; trying Flathub.\n' >&2
        install_flatpak_app org.deskflow.deskflow
      fi
      ;;
    onlyoffice) install_flatpak_app org.onlyoffice.desktopeditors ;;
    alacritty)
      install_packages "$(package_name "$program")"
      install_meslo_nerd_font
      install_alacritty_settings
      ;;
    docker) install_docker ;;
    fastfetch) install_fastfetch ;;
    christitus-prompt) install_christitus_prompt ;;
    *)
      package=$(package_name "$program")
      install_packages "$package"
      ;;
  esac
}

show_menu() {
  local index selected
  printf '\033[2J\033[H'
  printf '%s\n\n' "$UPDATE_SUMMARY"
  printf 'Choose programs: Up/Down to move, Space to toggle, Enter to continue, q to quit.\n\n'
  for index in "${!MENU_NAMES[@]}"; do
    selected=' '
    [[ ${SELECTED[index]:-0} == 1 ]] && selected='x'
    if (( index == MENU_INDEX )); then
      printf ' > [%s] %s\n' "$selected" "${MENU_NAMES[index]}"
    else
      printf '   [%s] %s\n' "$selected" "${MENU_NAMES[index]}"
    fi
  done
}

confirm_and_install() {
  local index input
  local selected_count=0
  for index in "${!MENU_NAMES[@]}"; do
    if [[ ${SELECTED[index]:-0} == 1 ]]; then
      ((selected_count += 1))
      printf '  - %s\n' "${MENU_NAMES[index]}"
    fi
  done
  if (( selected_count == 0 )); then
    printf 'No programs selected.\n'
    return 0
  fi

  printf '\nInstall the selected programs? [y/N] '
  if ! IFS= read -r input || [[ ! $input =~ ^[Yy]([Ee][Ss])?$ ]]; then
    printf 'Installation cancelled.\n'
    return 0
  fi

  for index in "${!MENU_IDS[@]}"; do
    if [[ ${SELECTED[index]:-0} == 1 ]]; then
      printf '\nInstalling %s...\n' "${MENU_NAMES[index]}"
      install_program "${MENU_IDS[index]}"
    fi
  done
  printf '\nSelected program installation completed.\n'
}

select_programs() {
  local input token index key sequence original_tty
  local -a choices=()
  MENU_INDEX=0

  if [[ -t 0 && -t 1 ]]; then
    original_tty=$(stty -g)
    trap 'stty "$original_tty" 2>/dev/null || true; printf "\033[?25h"; exit 130' INT TERM HUP
    stty -echo -icanon min 1 time 0
    printf '\033[?25l'
    while true; do
      show_menu
      if ! IFS= read -r -s -N 1 key; then
        break
      fi
      case "$key" in
        $'\x1b')
          sequence=''
          IFS= read -r -s -n 2 -t 0.1 sequence || true
          case "$sequence" in
            '[A')
              if (( MENU_INDEX > 0 )); then
                MENU_INDEX=$((MENU_INDEX - 1))
              fi
              ;;
            '[B')
              if (( MENU_INDEX < ${#MENU_NAMES[@]} - 1 )); then
                MENU_INDEX=$((MENU_INDEX + 1))
              fi
              ;;
          esac
          ;;
        ' ')
          if [[ ${SELECTED[MENU_INDEX]:-0} == 1 ]]; then
            SELECTED[MENU_INDEX]=0
          else
            SELECTED[MENU_INDEX]=1
          fi
          ;;
        $'\n'|$'\r') break ;;
        q|Q)
          SELECTED=()
          break
          ;;
      esac
    done
    stty "$original_tty"
    trap - INT TERM HUP
    printf '\033[?25h\033[2J\033[H'
  else
    printf 'Choose programs by number (comma-separated), or q to quit:\n'
    for index in "${!MENU_NAMES[@]}"; do
      printf '  %d) %s\n' "$((index + 1))" "${MENU_NAMES[index]}"
    done
    printf '> '
    if ! IFS= read -r input; then
      printf '\nNo selection received; skipping program installation.\n'
      return 0
    fi
    if [[ $input == q || $input == Q ]]; then
      return 0
    fi
    IFS=', ' read -r -a choices <<< "$input"
    for token in "${choices[@]}"; do
      if [[ ! $token =~ ^[0-9]+$ ]] || (( token < 1 || token > ${#MENU_NAMES[@]} )); then
        error "Invalid menu choice '$token'."
        return 1
      fi
      SELECTED[token-1]=1
    done
  fi
  printf 'Selected programs:\n'
  confirm_and_install
}

main() {
  local distribution
  PACKAGE_MANAGER=$(detect_package_manager)
  distribution=$(get_distribution_name)
  printf 'Detected distribution: %s\nPackage manager: %s\n\n' "$distribution" "$PACKAGE_MANAGER"
  update_system
  select_programs
}

main "$@"
