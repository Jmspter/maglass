#!/usr/bin/env bash
set -e

# 🎨 Color definitions - Modern terminal palette
CYAN="\e[36m"
MAGENTA="\e[35m"
AMBER="\e[38;5;214m"
CRIMSON="\e[38;5;197m"
LIME="\e[38;5;154m"
BOLD="\e[1m"
DIM="\e[2m"
RESET="\e[0m"

# 🧩 Function to print sections with style
section() {
    echo -e "\n${CYAN}${BOLD}▸ $1${RESET}\n"
}

# 🪄 Function to print success messages
success() {
    echo -e "${LIME}✓ $1${RESET}"
}

# ⚠️ Function to print warnings
warn() {
    echo -e "${AMBER}⚠ $1${RESET}"
}

# ❌ Function to print errors
error() {
    echo -e "${CRIMSON}✗ $1${RESET}"
}

# Detects the package manager present in the system.
# Rationale: different distributions use different tools (pacman, apt, dnf, apk, zypper).
# To automate dependency installation, we need to adapt commands to the package manager.
section "Detecting package manager..."
detect_pkg_mgr() {
    if command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    elif command -v zypper >/dev/null 2>&1; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

PM=$(detect_pkg_mgr)
success "Package manager detected: $PM"

# Helper function to install a package using the detected manager.
# Rationale: centralizing installation calls avoids duplication and allows adjusting
# flags and manager-specific behaviors (e.g., --noconfirm for pacman
# or 'apt-get update' before install in APT).
install_pkg() {
    pkg="$1"
    case "$PM" in
        pacman)
            sudo pacman -S --needed --noconfirm "$pkg"
            ;;
        apt)
            sudo apt-get update -qq
            sudo apt-get install -y "$pkg"
            ;;
        dnf)
            sudo dnf install -y "$pkg"
            ;;
        apk)
            sudo apk add --no-cache "$pkg"
            ;;
        zypper)
            sudo zypper install -y "$pkg"
            ;;
        *)
            return 2
            ;;
    esac
}

# Tries multiple package names in sequence until one installs successfully.
# Rationale: package names (especially libraries and -dev packages) vary across
# distributions and versions; we try common alternatives before aborting.
try_install_candidates() {
    for candidate in "$@"; do
        echo -e "${MAGENTA}→ Attempting to install: ${candidate}${RESET}"
        if install_pkg "$candidate"; then
            success "$candidate installed successfully."
            return 0
        else
            warn "Failed to install $candidate, trying next..."
        fi
    done
    return 1
}

# General rationale for this step:
# - cmake, make, and a C compiler are required to build the project;
# - X11 development libraries are needed because the project links with X11;
# - 'grim' is useful for capturing screenshots in Wayland (the program uses 'grim' by default).
section "Installing essential dependencies..."
case "$PM" in
    pacman)
        # In Arch/Manjaro, the 'base-devel' group contains build tools (make, gcc, etc.).
        # Rationale: installing the group avoids listing all tools individually.
        # On Arch, the raylib package is usually named 'raylib', so we try installing it directly.
        install_pkg cmake || true
        install_pkg base-devel || install_pkg make || true
        install_pkg raylib || true
        install_pkg grim || true
        ;;
    apt)
        # Debian/Ubuntu: use 'build-essential' to group compiler and utilities.
        # Rationale: -dev packages (like libx11-dev) are required to link against X11.
        install_pkg cmake || true
        install_pkg build-essential || (install_pkg make && install_pkg gcc) || true
        install_pkg libx11-dev || true
        # Raylib doesn't have a standardized name in all Debian/Ubuntu repositories,
        # so we try several candidates before failing.
        if ! try_install_candidates libraylib-dev raylib libraylib4 libraylib-dev; then
            warn "Raylib not found in apt — install manually."
            echo "Please install raylib (e.g. 'sudo apt-get install libraylib-dev' or build from source) and re-run this script."
        fi
        install_pkg grim || true
        ;;
    dnf)
        # Fedora/RHEL: development package names usually end with '-devel'.
        # Rationale: install both runtime and development packages when applicable.
        install_pkg cmake || true
        install_pkg make || true
        install_pkg gcc || true
        install_pkg libX11-devel || true
        if ! try_install_candidates raylib raylib-devel libraylib-devel; then
            warn "Raylib not found in dnf — install manually."
            echo "Please install raylib or its -devel package and re-run."
        fi
        install_pkg grim || true
        ;;
    apk)
        # Alpine: 'build-base' includes build tools similar to build-essential.
        # Rationale: packages and names in Alpine (musl-based) may differ, so we use candidates.
        install_pkg cmake || true
        install_pkg build-base || (install_pkg make && install_pkg gcc) || true
        install_pkg libx11 || true
        if ! try_install_candidates raylib raylib-dev libraylib-dev; then
            warn "Raylib not found in apk — install manually."
            echo "Please install raylib manually and re-run."
        fi
        install_pkg grim || true
        ;;
    zypper)
        # openSUSE: naming follows a similar pattern (libX11-devel, raylib-devel).
        # Rationale: use the same candidate-trying strategy for raylib and ensure basic tools.
        install_pkg cmake || true
        install_pkg make || true
        install_pkg gcc || true
        install_pkg libX11-devel || true
        if ! try_install_candidates raylib raylib-devel libraylib-devel; then
            warn "Raylib not found in zypper — install manually."
            echo "Please install raylib manually and re-run."
        fi
        install_pkg grim || true
        ;;
    *)
        error "Unknown package manager: $PM"
        echo "Please install the following packages manually: cmake, make, gcc, raylib (dev), libX11 development libraries, and grim (optional)."
        ;;
esac

# Early verification of essential tools.
# Rationale: detecting missing dependencies before building
# avoids compiling only to find errors later, giving actionable feedback to the user.
section "Verifying dependencies..."
missing=0
check_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "$1 not found."
        missing=1
    else
        success "$1 found."
    fi
}

check_tool cmake
check_tool gcc
check_tool make

# Heuristic to detect if raylib was properly installed.
# Rationale: use 'pkg-config' when available (most reliable method),
# but also check for 'raylib.h' in standard include paths.
# This warns the user before the build fails due to missing raylib.
check_raylib_installed() {
    if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists raylib; then
        return 0
    fi
    if [ -f /usr/include/raylib.h ] || [ -f /usr/local/include/raylib.h ]; then
        return 0
    fi
    return 1
}

if ! check_raylib_installed; then
    warn "Raylib not detected — compilation may fail."
    echo "Please install raylib development package for your distribution and re-run the script."
    missing=1
fi

if [ "$missing" -ne 0 ]; then
    error "Missing dependencies. Aborting."
    exit 1
fi

section "Building the project..."
rm -rf build
mkdir build && cd build

echo -ne "${MAGENTA}🏗 Running cmake...${RESET}\n"
cmake .. >/dev/null && success "Configuration completed."

echo -ne "${MAGENTA}⚙ Compiling maglass...${RESET}\n"
make -j"$(nproc)" >/dev/null && success "Compilation completed."

section "Installing..."
if [ -f maglass ]; then
    sudo cp maglass /usr/local/bin && success "Binary installed to /usr/local/bin"
else
    error "maglass binary not found after compilation."
    exit 1
fi

# Rationale: the code in 'src/spotlight.c' loads the shader from an absolute path
# (when installed). We copy 'assets/' to '/usr/local/share/maglass' so the installed
# binary can locate shaders and other assets without additional adjustments.
sudo mkdir -p /usr/local/share/maglass
sudo cp -r ../assets /usr/local/share/maglass/
success "Assets copied to /usr/local/share/maglass"

section "🧹 Cleaning up build..."
cd ..
rm -rf build
success "Build cleaned."

echo -e "\n${LIME}${BOLD}✨ Installation completed successfully!${RESET}"
echo -e "Run ${BOLD}${CYAN}maglass${RESET} to start."