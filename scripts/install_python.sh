#!/usr/bin/env bash

#
# Generic script to install and set Python 3.11 as the default on Ubuntu 22.04 or macOS.
#
# On Ubuntu, it uses `update-alternatives` to safely manage the default `python` command.
#

# Exit immediately if a command exits with a non-zero status.
set -e

## -----------------------------------------------------------------------------
## Installation function for Ubuntu/Debian
## -----------------------------------------------------------------------------
install_on_ubuntu() {
  echo "🔵 Detected Ubuntu/Debian-based system."

  # Step 1: Install Python 3.11 if it's not present
  if ! command -v python3.11 &>/dev/null; then
    echo "🚀 Python 3.11 not found. Proceeding with installation..."

    echo "Updating package list..."
    sudo apt-get update

    echo "Installing prerequisites..."
    sudo apt-get install -y software-properties-common

    echo "Adding deadsnakes PPA for up-to-date Python versions..."
    sudo add-apt-repository -y ppa:deadsnakes/ppa

    echo "Updating package list after adding PPA..."
    sudo apt-get update

    echo "Installing Python 3.11 and related packages..."
    sudo apt-get install -y python3.11 python3.11-venv python3.11-dev
    echo "✅ Python 3.11 has been installed."
  else
    echo "✅ Python 3.11 is already installed."
  fi

  # Step 2: Configure `update-alternatives` to make python3.11 the default `python`
  echo "⚙️  Configuring 'python' command to point to Python 3.11..."

  # Install python3.11 as an alternative for 'python' with a high priority (110)
  sudo update-alternatives --install /usr/bin/python python /usr/bin/python3.11 110

  # Also add the system's default python3 as an alternative with a lower priority (100)
  # This allows for easy switching back if needed.
  # Note: On Ubuntu 22.04, /usr/bin/python3 usually points to python3.10
  if [ -f /usr/bin/python3 ]; then
      sudo update-alternatives --install /usr/bin/python python /usr/bin/python3 100
  fi

  # The --install command with the highest priority automatically sets the default.
  # We can verify it.
  echo -e "\n🎉 Configuration complete!"
  echo "The 'python' command is now set to:"
  python --version
}


## -----------------------------------------------------------------------------
## Installation function for macOS
## -----------------------------------------------------------------------------
install_on_macos() {
  echo "🍏 Detected macOS."

  # On macOS, Homebrew handles the PATH priority, which effectively sets the default.
  # If `python3.11` is callable, it's usually because Homebrew's path is already active.
  if command -v python3.11 &>/dev/null; then
    INSTALLED_VERSION=$(python3.11 --version)
    echo "✅ Python 3.11 is already installed ($INSTALLED_VERSION). No action needed."
    exit 0
  fi

  echo "🚀 Python 3.11 not found. Proceeding with installation via Homebrew..."

  # Check if Homebrew is installed
  if ! command -v brew &>/dev/null; then
    echo "🍺 Homebrew not found. Installing Homebrew first..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    echo "Adding Homebrew to your shell configuration..."
    ARCH_NAME="$(uname -m)"
    if [[ "$ARCH_NAME" == "arm64" ]]; then # Apple Silicon
        BREW_PATH="/opt/homebrew/bin/brew"
    else # Intel
        BREW_PATH="/usr/local/bin/brew"
    fi
    
    eval "$($BREW_PATH shellenv)"

    # Detect shell and update the correct config file
    SHELL_CONFIG_FILE=""
    CURRENT_SHELL=$(basename "$SHELL")
    if [[ "$CURRENT_SHELL" == "zsh" ]]; then
        SHELL_CONFIG_FILE="$HOME/.zshrc"
    elif [[ "$CURRENT_SHELL" == "bash" ]]; then
        SHELL_CONFIG_FILE="$HOME/.bash_profile"
    else
        SHELL_CONFIG_FILE="$HOME/.profile" # Fallback
    fi
    
    echo "Updating $SHELL_CONFIG_FILE..."
    echo "eval \"\$($BREW_PATH shellenv)\"" >> "$SHELL_CONFIG_FILE"
  else
    echo "🍺 Homebrew is already installed."
  fi
  
  echo "Updating Homebrew..."
  brew update

  echo "Installing Python 3.11..."
  brew install python@3.11

  echo -e "\n🎉 Python 3.11 installation complete!"
  echo "To use it, please restart your terminal or run 'source $SHELL_CONFIG_FILE'"
  brew --prefix python@3.11/bin/python3.11 --version
}

## -----------------------------------------------------------------------------
## Main Script Logic
## -----------------------------------------------------------------------------
main() {
  echo "Starting Python 3.11 installation and configuration..."

  OS="$(uname -s)"

  case "$OS" in
    Linux)
      if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" == "ubuntu" || "$ID_LIKE" == *"debian"* ]]; then
          install_on_ubuntu
        else
          echo "❌ This script is for Ubuntu/Debian-based systems. Your system ID is '$ID'." >&2
          exit 1
        fi
      else
        echo "❌ Cannot determine Linux distribution: /etc/os-release not found." >&2
        exit 1
      fi
      ;;
    Darwin)
      install_on_macos
      ;;
    *)
      echo "❌ Unsupported operating system: $OS" >&2
      exit 1
      ;;
  esac
}

# Run the main function
main