#!/usr/bin/env bash

set -eo pipefail

# PHX_DIR is the directory where phx is installed
# By default, it assumes that the script is being executed from its directory
export PHX_DIR="${HOME}/.phx"
export PHX_VERSIONS_DIR="${PHX_DIR}/versions"

# Ensures that the versions directory exists
mkdir -p "$PHX_VERSIONS_DIR"

# Function to display error and exit
_phx_error() {
    echo "Error: $1" >&2
    exit 1
}

phx_list_remote() {
  local versions_url="https://cdn.jsdelivr.net/gh/NicolasTeles-Dev/phx-binaries@main/versions.json"
  local fallback_url="https://api.github.com/repos/NicolasTeles-Dev/phx-binaries/contents/versions.json"

  echo "Fetching available PHP versions from $versions_url..."
  
  local json=""
  json=$(curl -fsSL "$versions_url") || {
      echo "Primary failed, trying GitHub API fallback..."
      json=$(curl -fsSL -A "phx-cli" -H "Accept: application/vnd.github.v3.raw" "$fallback_url") \
        || _phx_error "Failed to download versions.json from remote for listing."
  }

  echo "Available PHP versions (remote):"
  echo "$json" | jq -r '.versions[] | .version' \
    || _phx_error "Failed to parse remote versions.json."
}

_phx_version_exists() {
    local version="$1"
    [ -d "${PHX_VERSIONS_DIR}/${version}" ]
}

# Function to display help message
phx_help() {
    echo "Usage: phx <command> [arguments]"
    echo ""
    echo "Commands:"
    echo "  install <version>   Install a specific PHP version."
    echo "  use <version>       Switch to a specific PHP version."
    echo "  list                List all installed PHP versions."
    echo "  --help, -h          Display this help message."
    echo ""
    echo "Examples:"
    echo "  phx install 8.1.0"
    echo "  phx use 8.1.0"
    echo "  phx list"
}

# Function to install a PHP version
phx_install() {
  local version="$1"
  if [ -z "$version" ]; then
    _phx_error "Usage: phx install <version>"
  fi

  local install_dir="${PHX_VERSIONS_DIR}/${version}"

  # CDN endpoint
  local versions_url="https://cdn.jsdelivr.net/gh/NicolasTeles-Dev/phx-binaries@main/versions.json"
  # Fallback API
  local fallback_url="https://raw.githubusercontent.com/NicolasTeles-Dev/phx-binaries/main/versions.json"

  echo "Fetching version metadata from $versions_url..."
  
  local json=""
  json=$(curl -fsSL "$versions_url") || {
      echo "Primary failed, trying GitHub API fallback..."
      json=$(curl -fsSL -A "phx-cli" -H "Accept: application/vnd.github.v3.raw" "$fallback_url") \
        || _phx_error "Failed to download versions.json"
  }

  local record
  record=$(echo "$json" | jq -r --arg v "$version" '.versions[] | select(.version == $v)') ||
    _phx_error "Failed to parse versions.json"

  if [ -z "$record" ]; then
    _phx_error "Version '$version' not found in versions.json"
  fi

  local download_url
  download_url=$(echo "$record" | jq -r '.url')
  local sha256_expected
  sha256_expected=$(echo "$record" | jq -r '.sha256')

  local tarball_filename="php-${version}-linux-x64.tar.gz"

  local temp_dir
  temp_dir=$(mktemp -d)
  local tarball_path="${temp_dir}/${tarball_filename}"

  echo "Installing PHP $version"
  echo "Download URL: $download_url"
  echo ""

  if [ -d "$install_dir" ]; then
    echo "PHP $version is already installed at $install_dir"
    rm -rf "$temp_dir"
    return 0
  fi

  echo "Downloading..."
  curl -fsSL -L "$download_url" -o "$tarball_path" ||
    _phx_error "Failed to download tarball"

  echo "Checking SHA256..."
  local sha256_actual
  sha256_actual=$(sha256sum "$tarball_path" | awk '{print $1}')

  if [ "$sha256_expected" != "$sha256_actual" ]; then
    echo "Expected: $sha256_expected"
    echo "Actual:   $sha256_actual"
    _phx_error "Checksum mismatch! Aborting installation."
  fi

  echo "Extracting..."
  mkdir -p "$install_dir"
  tar -xzf "$tarball_path" -C "$install_dir" --strip-components=1 ||
    _phx_error "Extraction failed"

  if [ ! -f "$install_dir/bin/php" ]; then
    rm -rf "$install_dir"
    _phx_error "Extraction complete, but php binary missing at bin/php"
  fi

  echo "PHP $version installed successfully!"
  rm -rf "$temp_dir"
}

main() {
  if [ "$#" -eq 0 ]; then
    phx_help
    exit 1
  fi

  local command="$1"
  shift

  case "$command" in
    "list-remote")
      phx_list_remote "$@"
      ;;
    "install")
      phx_install "$@"
      ;;
    "list")
      phx_list "$@"
      ;;
    "use")
      phx_use "$@"
      ;;
    "local")
      phx_local "$@"
      ;;
    "current")
      phx_current "$@"
      ;;
    "uninstall")
      phx_uninstall "$@"
      ;;
    "init") # Added init case
      phx_init "$@"
      ;;
    "--help"|"-h")
      phx_help
      ;;
    *)
      _phx_error "Unknown command '$command'. For usage, see 'phx --help'."
      ;;
  esac
}

phx_list() {
  echo "Installed PHP versions:"
  if [ -z "$(ls -A "$PHX_VERSIONS_DIR" 2>/dev/null)" ]; then
    echo "  No PHP versions installed yet. Run 'phx install <version>'."
    return 0
  fi

  local current_version=""
  if [ -L "$PHX_DIR/current" ]; then
    current_version=$(basename "$(readlink "$PHX_DIR/current")")
  fi

  for version_dir in "$PHX_VERSIONS_DIR"/*/;
  do
    if [ -d "$version_dir" ]; then
      local version=$(basename "$version_dir")
      local local_version_file=".php_version"
      local is_local=""

      # Check if this version is the one specified in .php_version in the current directory
      if [ -f "$PWD/$local_version_file" ] && [ "$(cat "$PWD/$local_version_file")" = "$version" ]; then
          is_local=" (local)"
      fi

      if [ "$version" = "$current_version" ]; then
        echo "  * $version (currently in use)$is_local"
      else
        echo "    $version$is_local"
      fi
    fi
  done
}

phx_use() {
  local version="$1"
  if [ -z "$version" ]; then
    _phx_error "Usage: phx use <version>"
  fi

  local version_path="${PHX_VERSIONS_DIR}/${version}"

  if [ ! -d "$version_path" ]; then
    _phx_error "PHP version '$version' is not installed."
  fi

# Create or update the 'current' symlink
  ln -sf "$version_path" "$PHX_DIR/current"
  if [ $? -ne 0 ]; then
    _phx_error "Failed to create symlink to active PHP version."
  fi
  echo "Using PHP version $version."
  echo "To activate this version in your current shell, run:"
  echo "  export PATH=\"$PHX_DIR/current/bin:\$PATH\""
  echo "To make it permanent, add the above line to your shell's startup file (e.g., ~/.bashrc or ~/.zshrc)."
}

phx_local() {
  local version="$1"
  if [ -z "$version" ]; then
    _phx_error "Usage: phx local <version>"
  fi

  local version_path="${PHX_VERSIONS_DIR}/${version}"

  if [ ! -d "$version_path" ]; then
    _phx_error "PHP version '$version' is not installed. Please install it first."
  fi

  echo "$version" > .php_version
  echo "Local PHP version set to $version in $(pwd)/.php_version"
  echo "Add 'eval \"\$(./phx.sh init)\"' to your shell startup file (e.g., ~/.bashrc or ~/.zshrc) to enable automatic local version switching."
}

phx_current() {
  if [ -L "$PHX_DIR/current" ]; then
    local current_version=$(basename "$(readlink "$PHX_DIR/current")")
    echo "Currently active PHP version: $current_version"
  else
    echo "No PHP version currently active. Run 'phx use <version>'."
  fi
}

phx_uninstall() {
  local version="$1"
  if [ -z "$version" ]; then
    _phx_error "Usage: phx uninstall <version>"
  fi

  local version_path="${PHX_VERSIONS_DIR}/${version}"

  if [ ! -d "$version_path" ]; then
    _phx_error "PHP version '$version' is not installed."
  fi

  local current_version=""
  if [ -L "$PHX_DIR/current" ]; then
    current_version=$(basename "$(readlink "$PHX_DIR/current")")
  fi

  if [ -f ".php_version" ] && [ "$(cat ".php_version")" = "$version" ]; then
    _phx_error "Cannot uninstall currently active PHP version (set by .php_version). Please change the version in .php_version or remove the file."
  fi

  if [ "$version" = "$current_version" ]; then
    _phx_error "Cannot uninstall currently active PHP version. Please run 'phx use <another_version>' first."
  fi

  echo "Uninstalling PHP version $version from $version_path..."
  rm -rf "$version_path"
  echo "PHP version $version uninstalled successfully."

  # If the uninstalled version was set as local, remove the .php_version file
  if [ -f ".php_version" ] && [ "$(cat ".php_version")" = "$version" ]; then
    rm .php_version
    echo "Removed local .php_version file as it pointed to the uninstalled version."
  fi
}

phx_init() {
  local current_phx_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cat << 'EOF'
# PHX shell integration
export PHX_DIR="$current_phx_dir"
export PHX_VERSIONS_DIR="$PHX_DIR/versions"

phx_auto_use() {
  local local_php_version_file=".php_version"
  if [ -f "$local_php_version_file" ]; then
    local version=$(cat "$local_php_version_file")
    if [ -d "$PHX_VERSIONS_DIR/$version" ]; then
      local phx_version_bin="$PHX_VERSIONS_DIR/$version/bin"
      # Only change PATH if it's not already pointing to the local version
      if [[ ":$PATH:" != ":$phx_version_bin:"* ]]; then
        export PATH="$phx_version_bin:$PATH"
        echo "PHX: Using local PHP $version"
      fi
    fi
  else
    # If no local .php_version, ensure global current version is in PATH
    local current_symlink_path="$PHX_DIR/current/bin"
    # Only change PATH if it's not already pointing to the global current
    if [[ ":$PATH:" != ":$current_symlink_path:"* ]]; then
      export PATH="$current_symlink_path:$PATH"
      # Only echo if current symlink exists and is readable
      if [ -L "$PHX_DIR/current" ]; then
        echo "PHX: Using global PHP $(basename "$(readlink "$PHX_DIR/current")")"
      fi
    fi
  fi
}

# Add phx to PATH
export PATH="$PHX_DIR:$PATH"

# Set up auto-use for Bash
PROMPT_COMMAND="phx_auto_use;$PROMPT_COMMAND"

# Set up auto-use for Zsh
add-zsh-hook chpwd phx_auto_use
EOF
}

main "$@"
