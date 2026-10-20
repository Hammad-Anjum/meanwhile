#!/bin/sh
# Installs Meanwhile from the latest GitHub release:
#   curl -fsSL https://raw.githubusercontent.com/Hammad-Anjum/meanwhile/main/install.sh | sh
#
# Downloads the release tarball and SHA256SUMS, checks the SHA-256, runs `meanwhile setup`
# (which copies the binaries to ~/Library/Application Support/Meanwhile/bin, installs the
# agent hooks and the login item), and links ~/.local/bin/meanwhile to the installed copy.
# No sudo.
#
# Environment:
#   MEANWHILE_VERSION=0.2.0   install this version instead of the latest
#   MEANWHILE_BIN_DIR=dir     where to put the `meanwhile` link (default ~/.local/bin)
# For testing:
#   MEANWHILE_BASE_URL=url    files at <url>/v<version>/<file>, latest release JSON at <url>/latest
#   MEANWHILE_SKIP_SETUP=1    don't run setup; copy the files to MEANWHILE_INSTALL_DIR instead
#   MEANWHILE_INSTALL_DIR=dir where the files go with MEANWHILE_SKIP_SETUP=1
#                             (default ~/Library/Application Support/Meanwhile/bin, where setup puts them)

set -eu

REPOSITORY="Hammad-Anjum/meanwhile"

fail() {
    echo "error: $*" >&2
    exit 1
}

main() {
    [ "$(uname -s)" = "Darwin" ] || fail "Meanwhile runs on macOS only."
    macos="$(sw_vers -productVersion)"
    [ "${macos%%.*}" -ge 14 ] 2>/dev/null || fail "Meanwhile needs macOS 14 or later (this Mac has $macos)."
    case "$(uname -m)" in
        arm64 | x86_64) ;;
        *) fail "Unsupported CPU: $(uname -m)." ;;
    esac
    command -v curl >/dev/null 2>&1 || fail "curl is missing."

    base="${MEANWHILE_BASE_URL:-https://github.com/$REPOSITORY/releases/download}"
    if [ -n "${MEANWHILE_BASE_URL:-}" ]; then
        latest_url="$MEANWHILE_BASE_URL/latest"
    else
        latest_url="https://api.github.com/repos/$REPOSITORY/releases/latest"
    fi

    version="${MEANWHILE_VERSION:-}"
    if [ -z "$version" ]; then
        json="$(curl -fsSL -H "Accept: application/vnd.github+json" "$latest_url")" ||
            fail "Couldn't find the latest release at $latest_url. Is a release published?"
        version="$(printf '%s\n' "$json" | sed -n -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1)"
        [ -n "$version" ] || fail "Couldn't read the latest release version from $latest_url."
    fi
    version="${version#v}"
    printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' ||
        fail "'$version' is not a version like 1.2.3."

    name="meanwhile-$version-macos"
    tarball="$name.tar.gz"
    url="$base/v$version"

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/meanwhile-install.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT INT TERM

    echo "Downloading Meanwhile $version"
    curl -fsSL -o "$tmp/$tarball" "$url/$tarball" || fail "Couldn't download $url/$tarball."
    curl -fsSL -o "$tmp/SHA256SUMS" "$url/SHA256SUMS" || fail "Couldn't download $url/SHA256SUMS."

    grep -E "^[0-9a-fA-F]{64} [ *]$tarball\$" "$tmp/SHA256SUMS" >"$tmp/check" ||
        fail "SHA256SUMS has no line for $tarball."
    (cd "$tmp" && shasum -a 256 -c check >/dev/null 2>&1) ||
        fail "$tarball failed its SHA-256 check. The download is damaged or was changed; nothing was installed."
    echo "✓ SHA-256 matches"

    tar -xzf "$tmp/$tarball" -C "$tmp" || fail "Couldn't unpack $tarball."
    [ -x "$tmp/$name/meanwhile" ] || fail "$tarball has no $name/meanwhile."

    default_install="$HOME/Library/Application Support/Meanwhile/bin"
    if [ "${MEANWHILE_SKIP_SETUP:-}" = "1" ]; then
        install_dir="${MEANWHILE_INSTALL_DIR:-$default_install}"
        mkdir -p "$install_dir"
        rm -rf "$install_dir/meanwhile" "$install_dir/meanwhile-hook" "$install_dir"/*.bundle
        cp -R "$tmp/$name"/. "$install_dir/"
        echo "Skipped setup (MEANWHILE_SKIP_SETUP=1). Copied the files to $install_dir."
    else
        install_dir="$default_install"
        echo
        # Under `curl | sh` the script itself is stdin, so setup's questions read the terminal.
        if (exec </dev/tty) 2>/dev/null; then
            "$tmp/$name/meanwhile" setup </dev/tty || fail "meanwhile setup failed. See the messages above."
        else
            echo "No terminal to ask on; running setup with --yes."
            "$tmp/$name/meanwhile" setup --yes || fail "meanwhile setup failed. See the messages above."
        fi
    fi

    installed="$install_dir/meanwhile"
    if [ ! -x "$installed" ]; then
        echo
        echo "Meanwhile wasn't installed (setup made no changes). Run the installer again to retry."
        exit 1
    fi

    bin_dir="${MEANWHILE_BIN_DIR:-$HOME/.local/bin}"
    mkdir -p "$bin_dir" || fail "Couldn't create $bin_dir."
    ln -sf "$installed" "$bin_dir/meanwhile"
    echo
    echo "✓ Linked $bin_dir/meanwhile → $installed"

    case ":$PATH:" in
        *":$bin_dir:"*) ;;
        *)
            echo
            echo "$bin_dir is not on your PATH. Add this line to ~/.zshrc (or your shell's profile), then open a new terminal:"
            echo
            echo "    export PATH=\"$bin_dir:\$PATH\""
            ;;
    esac
    echo
    echo "Meanwhile $version is installed. Later, run \`meanwhile update\` to update it."
}

main "$@"
