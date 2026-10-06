#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME=${0##*/}
declare -a MENU_NAMES=(
  "Brave Browser"
  "Firefox"
  "Git"
  "Neovim"
  "VLC"
  "LazyGit"
)
declare -a MENU_IDS=(brave firefox git neovim vlc lazygit)
declare -A SELECTED=()

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
  printf '\nSystem update completed successfully. Packages upgraded (pre-upgrade count): %s\n\n' "$pending"
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
    vlc:*) printf 'vlc\n' ;;
    lazygit:*) printf 'lazygit\n' ;;
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
      run_as_root zypper --non-interactive addrepo --refresh \
        https://brave-browser-rpm-release.s3.brave.com/x86_64 brave-browser
      install_packages brave-browser
      ;;
    *)
      return 1
      ;;
  esac
}

install_brave_from_flatpak() {
  if ! command -v flatpak >/dev/null 2>&1; then
    install_packages flatpak
  fi
  run_as_root flatpak remote-add --if-not-exists --system flathub \
    https://flathub.org/repo/flathub.flatpakrepo
  run_as_root flatpak install --system --assumeyes flathub com.brave.Browser
}

fetch_file() {
  local url=$1
  local destination=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$destination"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$destination" "$url"
  else
    error "GitHub fallback requires curl or wget."
    return 1
  fi
}

install_lazygit_from_github() {
  local workdir api_file tag version arch archive
  workdir=$(mktemp -d)
  api_file=$workdir/release.json

  if ! fetch_file https://api.github.com/repos/jesseduffield/lazygit/releases/latest "$api_file"; then
    rm -rf "$workdir"
    error "Could not query the latest LazyGit release from GitHub."
    return 1
  fi
  tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$api_file" | head -n 1)
  if [[ ! $tag =~ ^v?[0-9][A-Za-z0-9.+_-]*$ ]]; then
    rm -rf "$workdir"
    error "GitHub returned an invalid LazyGit release tag."
    return 1
  fi
  version=${tag#v}
  case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l|armv7*) arch=armv7 ;;
    *)
      rm -rf "$workdir"
      error "LazyGit GitHub releases do not support architecture $(uname -m)."
      return 1
      ;;
  esac
  archive="$workdir/lazygit.tar.gz"
  if ! fetch_file \
    "https://github.com/jesseduffield/lazygit/releases/download/${tag}/lazygit_${version}_Linux_${arch}.tar.gz" \
    "$archive"; then
    rm -rf "$workdir"
    error "Could not download the LazyGit release for Linux $arch."
    return 1
  fi
  if ! tar -tzf "$archive" | grep -Fxq lazygit; then
    rm -rf "$workdir"
    error "The downloaded LazyGit archive does not contain the expected binary."
    return 1
  fi
  if ! tar -xzf "$archive" -C "$workdir" lazygit; then
    rm -rf "$workdir"
    error "Could not extract the LazyGit binary."
    return 1
  fi
  if ! run_as_root install -m 0755 "$workdir/lazygit" /usr/local/bin/lazygit; then
    rm -rf "$workdir"
    error "Could not install LazyGit in /usr/local/bin."
    return 1
  fi
  rm -rf "$workdir"
}

install_program() {
  local program=$1
  local package
  case "$program" in
    brave)
      if [[ $PACKAGE_MANAGER == apt-get || $PACKAGE_MANAGER == dnf ||
        $PACKAGE_MANAGER == yum || $PACKAGE_MANAGER == microdnf ||
        $PACKAGE_MANAGER == zypper ]]; then
        install_brave_from_vendor_repo
      else
        install_brave_from_flatpak
      fi
      ;;
    lazygit)
      package=$(package_name "$program")
      if ! install_packages "$package"; then
        printf 'Native LazyGit installation failed; trying the official GitHub release instead.\n' >&2
        install_lazygit_from_github
      fi
      ;;
    *)
      package=$(package_name "$program")
      install_packages "$package"
      ;;
  esac
}

show_menu() {
  local index
  printf 'Select programs to install (comma-separated numbers, or q to quit):\n'
  for index in "${!MENU_NAMES[@]}"; do
    printf '  %d) %s\n' "$((index + 1))" "${MENU_NAMES[index]}"
  done
  printf '> '
}

select_programs() {
  local input token index
  local -a choices=()
  show_menu
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
    index=$((token - 1))
    SELECTED[${MENU_IDS[index]}]=1
  done
  if (( ${#SELECTED[@]} == 0 )); then
    printf 'No programs selected.\n'
    return 0
  fi

  printf '\nSelected programs:\n'
  for index in "${!MENU_IDS[@]}"; do
    if [[ ${SELECTED[${MENU_IDS[index]}]+yes} ]]; then
      printf '  - %s\n' "${MENU_NAMES[index]}"
    fi
  done
  printf 'Install the selected programs? [y/N] '
  if ! IFS= read -r input || [[ ! $input =~ ^[Yy]([Ee][Ss])?$ ]]; then
    printf 'Installation cancelled.\n'
    return 0
  fi

  for index in "${!MENU_IDS[@]}"; do
    if [[ ${SELECTED[${MENU_IDS[index]}]+yes} ]]; then
      printf '\nInstalling %s...\n' "${MENU_NAMES[index]}"
      install_program "${MENU_IDS[index]}"
    fi
  done
  printf '\nSelected program installation completed.\n'
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
