#!/usr/bin/env bash
#
# backup.sh — capture the configs, credentials and settings that make a Mac
#             *yours*, into a single encrypted archive, before you erase it.
#
# The problem this solves: Time Machine restores everything or nothing, and a
# clean install means hand-rebuilding a dev environment from memory. This walks
# the ~90 places that dotfiles, CLI credentials and app settings actually hide,
# captures only what exists, skips the multi-gigabyte caches, and encrypts the
# result with AES-256.
#
#   Usage:  ./backup.sh [options]
#
#   Options:
#     -o, --output DIR     Where to write the archive (default: ~/mac-backup-out)
#     -n, --dry-run        List what would be captured; write nothing
#         --include-env    Also capture project .env files (see warning below)
#         --include-large  Do not skip items over the size limit
#         --max-size MB    Per-item size limit (default: 50)
#         --no-encrypt     Leave a plain .tar.gz (NOT recommended)
#     -h, --help           Show this help
#
#   Restore on the new machine:
#     openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 250000 \
#       -in mac-backup-*.tar.gz.enc | tar -xzf -
#     cp -R home/. ~/
#     brew bundle install --file=manifests/Brewfile
#
#   What this deliberately does NOT capture:
#     - Your source code. Commit and push it before you erase anything.
#     - The macOS login keychain (saved passwords, certificate private keys).
#       Enable iCloud Keychain, or export manually from Keychain Access.
#     - Package caches, node_modules, editor extensions. All re-downloadable.
#

set -uo pipefail

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
outputDirectory="$HOME/mac-backup-out"
isDryRun=false
shouldIncludeEnvironmentFiles=false
shouldIncludeLargeItems=false
shouldEncrypt=true
maximumItemSizeMegabytes=50

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output)        outputDirectory="$2"; shift 2 ;;
        -n|--dry-run)       isDryRun=true; shift ;;
        --include-env)      shouldIncludeEnvironmentFiles=true; shift ;;
        --include-large)    shouldIncludeLargeItems=true; shift ;;
        --max-size)         maximumItemSizeMegabytes="$2"; shift 2 ;;
        --no-encrypt)       shouldEncrypt=false; shift ;;
        -h|--help)          sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
done

if [ "$shouldEncrypt" = true ] && ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl not found. Install it, or re-run with --no-encrypt." >&2
    exit 1
fi

backupTimestamp="$(date +%Y-%m-%d-%H%M)"
backupName="mac-backup-$backupTimestamp"
stagingDirectory="$(mktemp -d "${TMPDIR:-/tmp}/$backupName.XXXXXX")"
homeMirrorDirectory="$stagingDirectory/home"
manifestDirectory="$stagingDirectory/manifests"
mkdir -p "$homeMirrorDirectory" "$manifestDirectory"

capturedItemCount=0
absentItemCount=0
skippedForSizeCount=0
skippedItemLog="$manifestDirectory/skipped-because-too-large.txt"
: > "$skippedItemLog"

# Clean up the unencrypted staging directory on any exit path, including Ctrl-C.
cleanup_staging_directory() {
    [ -d "$stagingDirectory" ] && rm -rf "$stagingDirectory"
}
trap cleanup_staging_directory EXIT INT TERM

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

announce_section() {
    printf '\n\033[1m==> %s\033[0m\n' "$1"
}

# Copies a file or directory into the staging area, preserving its path relative
# to $HOME so the archive mirrors the home directory and restore is a plain copy.
# Silently ignores anything that does not exist, so the same capture list works
# on every machine regardless of which tools are installed.
capture_path() {
    local sourcePath="$1"
    if [ ! -e "$sourcePath" ]; then
        absentItemCount=$((absentItemCount + 1))
        return 0
    fi

    local relativePath="${sourcePath#"$HOME"/}"

    # Skip anything huge — these are almost always regenerable caches, and they
    # are what turns a 40MB archive into a 4GB one.
    if [ "$shouldIncludeLargeItems" = false ]; then
        local itemSizeKilobytes
        itemSizeKilobytes="$(du -sk "$sourcePath" 2>/dev/null | cut -f1)"
        if [ -n "$itemSizeKilobytes" ] && [ "$itemSizeKilobytes" -gt $((maximumItemSizeMegabytes * 1024)) ]; then
            printf '    skipped   ~/%s (%sMB > %sMB limit)\n' \
                "$relativePath" "$((itemSizeKilobytes / 1024))" "$maximumItemSizeMegabytes"
            echo "~/$relativePath ($((itemSizeKilobytes / 1024))MB)" >> "$skippedItemLog"
            skippedForSizeCount=$((skippedForSizeCount + 1))
            return 0
        fi
    fi

    if [ "$isDryRun" = true ]; then
        printf '    would capture  ~/%s\n' "$relativePath"
        capturedItemCount=$((capturedItemCount + 1))
        return 0
    fi

    local destinationParentDirectory="$homeMirrorDirectory/$(dirname "$relativePath")"
    mkdir -p "$destinationParentDirectory"
    if cp -R "$sourcePath" "$destinationParentDirectory/" 2>/dev/null; then
        printf '    captured  ~/%s\n' "$relativePath"
        capturedItemCount=$((capturedItemCount + 1))
    else
        printf '    FAILED    ~/%s\n' "$relativePath"
    fi
}

# capture_path for glob patterns that may legitimately match nothing.
capture_glob() {
    local matchedPath
    for matchedPath in $1; do
        [ -e "$matchedPath" ] && capture_path "$matchedPath"
    done
    return 0
}

# Writes a manifest file only if the tool that produces it is installed.
write_manifest_if_available() {
    local requiredCommand="$1" manifestFileName="$2"; shift 2
    command -v "$requiredCommand" >/dev/null 2>&1 || return 0
    if "$@" > "$manifestDirectory/$manifestFileName" 2>/dev/null; then
        printf '    %s\n' "$manifestFileName"
    else
        rm -f "$manifestDirectory/$manifestFileName"
    fi
}

echo "================================================================"
echo " Mac migration backup"
[ "$isDryRun" = true ] && echo " MODE:   dry run — nothing will be written"
echo " Output: $outputDirectory"
echo "================================================================"

# ---------------------------------------------------------------------------
announce_section "Shell environment and dotfiles"
# ---------------------------------------------------------------------------
for shellDotfile in .zshrc .zprofile .zshenv .zlogin .zlogout .bashrc .bash_profile \
                    .bash_login .profile .inputrc .aliases .functions .exports \
                    .p10k.zsh .editorconfig .curlrc .wgetrc .screenrc .digrc \
                    .hushlogin .gemrc .tmux.conf .vimrc .viminfo .vim .ideavimrc; do
    capture_path "$HOME/$shellDotfile"
done
capture_path "$HOME/.oh-my-zsh/custom"      # your own themes/plugins, not the framework
capture_path "$HOME/.config/nvim"
capture_path "$HOME/.config/fish"
capture_path "$HOME/.config/starship.toml"
capture_path "$HOME/.config/zellij"
capture_path "$HOME/.config/atuin"
capture_path "$HOME/.local/bin"             # personal scripts on PATH
capture_path "$HOME/bin"

# ---------------------------------------------------------------------------
announce_section "SSH and GPG keys"
# ---------------------------------------------------------------------------
capture_path "$HOME/.ssh"
capture_path "$HOME/.gnupg"

# ---------------------------------------------------------------------------
announce_section "Git and code forges"
# ---------------------------------------------------------------------------
capture_path "$HOME/.gitconfig"
capture_path "$HOME/.gitignore_global"
capture_path "$HOME/.git-credentials"
capture_path "$HOME/.config/git"
capture_path "$HOME/.config/gh"             # GitHub CLI auth token
capture_path "$HOME/.config/glab-cli"       # GitLab CLI auth token
capture_path "$HOME/.config/hub"

# ---------------------------------------------------------------------------
announce_section "Cloud provider and deploy CLI credentials"
# ---------------------------------------------------------------------------
# AWS: the awscli, SAM, Copilot and CDK all read credentials from ~/.aws, so
# this single directory is what restores the whole AWS toolchain.
capture_path "$HOME/.aws"
capture_path "$HOME/.aws-sam/metadata.json"
capture_path "$HOME/.cdk"
capture_path "$HOME/.copilot"
capture_path "$HOME/.ecs"
capture_path "$HOME/.azure"
capture_path "$HOME/.config/gcloud/credentials.db"
capture_path "$HOME/.config/gcloud/access_tokens.db"
capture_glob "$HOME/.config/gcloud/configurations"
capture_path "$HOME/.kube"
capture_path "$HOME/.docker/config.json"
capture_path "$HOME/.docker/daemon.json"
capture_path "$HOME/.docker/contexts"
capture_path "$HOME/.terraform.d"
capture_path "$HOME/.terraformrc"
capture_path "$HOME/.pulumi/credentials.json"
capture_path "$HOME/.ansible.cfg"
capture_path "$HOME/.config/doctl"          # DigitalOcean
capture_path "$HOME/.linode-cli"
capture_path "$HOME/.oci"                   # Oracle Cloud
capture_path "$HOME/.netlify"
capture_path "$HOME/.fly"
capture_path "$HOME/.railway"
capture_path "$HOME/.supabase"
capture_path "$HOME/.ngrok2"
capture_path "$HOME/.config/temporalio"
# macOS keeps some CLI state under Library rather than a dotfile.
capture_path "$HOME/Library/Preferences/.wrangler/config"          # Cloudflare Workers
capture_path "$HOME/Library/Application Support/com.vercel.cli"    # Vercel auth
capture_path "$HOME/Library/Application Support/ngrok"
capture_path "$HOME/Library/Application Support/Herd"

# ---------------------------------------------------------------------------
announce_section "Package registry credentials and toolchain config"
# ---------------------------------------------------------------------------
capture_path "$HOME/.npmrc"
capture_path "$HOME/.yarnrc"
capture_path "$HOME/.yarnrc.yml"
capture_path "$HOME/.bunfig.toml"
capture_path "$HOME/.pypirc"
capture_path "$HOME/.netrc"                 # used by heroku and many others
capture_path "$HOME/.config/pip/pip.conf"
capture_path "$HOME/.condarc"
capture_path "$HOME/.cargo/credentials"
capture_path "$HOME/.cargo/credentials.toml"
capture_path "$HOME/.cargo/config.toml"
capture_path "$HOME/.gem/credentials"
capture_path "$HOME/.bundle/config"
capture_path "$HOME/.composer/auth.json"
capture_path "$HOME/.nuget/NuGet/NuGet.Config"
capture_path "$HOME/.hex/hex.config"
# Take the settings files, never the multi-hundred-megabyte artifact caches
# that sit beside them (.m2/repository, .gradle/caches).
capture_path "$HOME/.m2/settings.xml"
capture_path "$HOME/.m2/settings-security.xml"
capture_path "$HOME/.gradle/gradle.properties"
capture_path "$HOME/.sbt/1.0/global.sbt"
capture_path "$HOME/.Renviron"
capture_path "$HOME/.Rprofile"
# Runtime version pins, so the new machine installs the same versions.
capture_glob "$HOME/.*-version"             # .node-version, .python-version, .ruby-version
capture_path "$HOME/.tool-versions"         # asdf / mise
capture_path "$HOME/.config/mise"
capture_path "$HOME/.asdfrc"

# ---------------------------------------------------------------------------
announce_section "Database and terminal tool config"
# ---------------------------------------------------------------------------
capture_path "$HOME/.psqlrc"
capture_path "$HOME/.pgpass"
capture_path "$HOME/.my.cnf"
capture_path "$HOME/.sqliterc"
capture_path "$HOME/.mongodb"
capture_path "$HOME/.config/htop"
capture_path "$HOME/.config/lazygit"
capture_path "$HOME/.config/bat"
capture_path "$HOME/.config/gh-dash"
capture_path "$HOME/.config/k9s"

# ---------------------------------------------------------------------------
announce_section "AI coding tools"
# ---------------------------------------------------------------------------
capture_path "$HOME/.claude.json"           # MCP server config and auth
capture_path "$HOME/.claude/settings.json"
capture_path "$HOME/.claude/CLAUDE.md"
capture_path "$HOME/.claude/keybindings.json"
capture_path "$HOME/.claude/agents"
capture_path "$HOME/.claude/commands"
capture_path "$HOME/.claude/skills"
capture_path "$HOME/.claude/plugins/config.json"
capture_glob "$HOME/.codex/*.json"          # auth.json etc, not the session history
capture_glob "$HOME/.codex/*.toml"
capture_path "$HOME/.codex/prompts"
capture_glob "$HOME/.cursor/*.json"         # mcp.json, not the extensions directory
capture_path "$HOME/.config/opencode"
capture_path "$HOME/.aider.conf.yml"
capture_path "$HOME/.continue/config.json"
capture_path "$HOME/.config/github-copilot"

# ---------------------------------------------------------------------------
announce_section "Editor settings"
# ---------------------------------------------------------------------------
for editorSupportDirectory in "Code" "Code - Insiders" "VSCodium" "Cursor" "Windsurf"; do
    editorUserDirectory="$HOME/Library/Application Support/$editorSupportDirectory/User"
    capture_path "$editorUserDirectory/settings.json"
    capture_path "$editorUserDirectory/keybindings.json"
    capture_path "$editorUserDirectory/snippets"
done
capture_path "$HOME/Library/Developer/Xcode/UserData/KeyBindings"
capture_path "$HOME/Library/Developer/Xcode/UserData/FontAndColorThemes"
capture_path "$HOME/Library/Developer/Xcode/UserData/CodeSnippets"
capture_path "$HOME/.swiftpm/configuration"
capture_path "$HOME/.cocoapods/config.yaml"
capture_path "$HOME/Library/Application Support/Sublime Text/Packages/User"
capture_path "$HOME/Library/Application Support/JetBrains/consentOptions"

# ---------------------------------------------------------------------------
announce_section "Terminal and desktop app settings"
# ---------------------------------------------------------------------------
capture_path "$HOME/Library/Preferences/com.googlecode.iterm2.plist"
capture_path "$HOME/.config/iterm2"
capture_path "$HOME/Library/Application Support/com.mitchellh.ghostty"
capture_path "$HOME/.config/ghostty"
capture_path "$HOME/.config/alacritty"
capture_path "$HOME/.config/wezterm"
capture_path "$HOME/.config/kitty"
capture_path "$HOME/.config/karabiner"
capture_path "$HOME/.config/linearmouse"
capture_path "$HOME/.hammerspoon"
capture_path "$HOME/.config/raycast/config.json"
capture_path "$HOME/Library/Application Support/Alfred/Alfred.alfredpreferences"
capture_path "$HOME/Library/Preferences/com.knollsoft.Rectangle.plist"
capture_path "$HOME/Library/KeyBindings"
capture_path "$HOME/Library/Services"       # Automator Quick Actions you built
capture_path "$HOME/Library/LaunchAgents"   # your own background jobs
capture_path "$HOME/Library/Fonts"          # purchased or hand-installed fonts

# ---------------------------------------------------------------------------
announce_section "Shell history"
# ---------------------------------------------------------------------------
# Worth keeping: years of hard-won one-liners. Note that shell history often
# contains secrets typed inline, which is part of why this archive is encrypted.
capture_path "$HOME/.zsh_history"
capture_path "$HOME/.bash_history"
capture_path "$HOME/.psql_history"
capture_path "$HOME/.mysql_history"
capture_path "$HOME/.node_repl_history"
capture_path "$HOME/.python_history"
capture_path "$HOME/.irb_history"
capture_path "$HOME/.local/share/atuin"

# ---------------------------------------------------------------------------
# Project .env files — opt in only.
# ---------------------------------------------------------------------------
if [ "$shouldIncludeEnvironmentFiles" = true ]; then
    announce_section "Project .env files (--include-env)"
    echo "    WARNING: this collects live application secrets into one archive."
    echo "    Keep it on physical media. Never put it in cloud storage."
    environmentFileList="$manifestDirectory/env-files-captured.txt"
    : > "$environmentFileList"
    while IFS= read -r environmentFilePath; do
        capture_path "$environmentFilePath"
        echo "$environmentFilePath" >> "$environmentFileList"
    done < <(find "$HOME" -maxdepth 6 \
                \( -name node_modules -o -name Library -o -name .Trash -o -name .git \
                   -o -name vendor -o -name .venv -o -name venv -o -name .next \) -prune \
                -o -type f \( -name ".env" -o -name ".env.*" \) \
                   ! -name "*.example" ! -name "*.sample" ! -name "*.template" \
                -print 2>/dev/null)
else
    announce_section "Project .env files"
    echo "    skipped — re-run with --include-env to collect them"
fi

# ---------------------------------------------------------------------------
announce_section "Building reinstall manifests"
# ---------------------------------------------------------------------------
if [ "$isDryRun" = false ]; then
    # A Brewfile restores every formula, cask and tap with a single command.
    if command -v brew >/dev/null 2>&1; then
        brew bundle dump --file="$manifestDirectory/Brewfile" --force --describe 2>/dev/null \
            && printf '    Brewfile (%s entries)\n' "$(grep -c . "$manifestDirectory/Brewfile")"
    fi

    write_manifest_if_available npm    npm-global-packages.txt   npm ls -g --depth=0
    write_manifest_if_available pnpm   pnpm-global-packages.txt  pnpm ls -g --depth=0
    write_manifest_if_available pip3   pip-packages.txt          pip3 list --format=freeze
    write_manifest_if_available pipx   pipx-packages.txt         pipx list
    write_manifest_if_available gem    gem-packages.txt          gem list
    write_manifest_if_available cargo  cargo-crates.txt          cargo install --list
    write_manifest_if_available go     go-binaries.txt           ls "$(go env GOPATH 2>/dev/null)/bin"
    write_manifest_if_available pyenv  pyenv-versions.txt        pyenv versions
    write_manifest_if_available rustup rustup-toolchains.txt     rustup toolchain list
    write_manifest_if_available asdf   asdf-versions.txt         asdf list
    write_manifest_if_available mise   mise-versions.txt         mise ls
    write_manifest_if_available code   vscode-extensions.txt     code --list-extensions
    write_manifest_if_available cursor cursor-extensions.txt     cursor --list-extensions
    write_manifest_if_available mas    mac-app-store-apps.txt    mas list
    write_manifest_if_available crontab crontab.txt              crontab -l

    ls /Applications "$HOME/Applications" 2>/dev/null | sort -u > "$manifestDirectory/installed-applications.txt"
    defaults read > "$manifestDirectory/macos-defaults-full-dump.txt" 2>/dev/null
    security find-identity -v -p codesigning > "$manifestDirectory/code-signing-identities.txt" 2>/dev/null
    { sw_vers; echo; uname -a; echo; system_profiler SPHardwareDataType 2>/dev/null; } \
        > "$manifestDirectory/system-info.txt" 2>/dev/null
    printf '    system info, macOS defaults, installed applications\n'

fi

# ---------------------------------------------------------------------------
announce_section "Restore guide"
# ---------------------------------------------------------------------------
if [ "$isDryRun" = false ]; then
cat > "$stagingDirectory/RESTORE.md" <<'EORESTORE'
# Restore guide

`home/` mirrors the old home directory exactly, so restoring is a plain copy.

## 1. Configs and credentials
    cp -R home/. ~/
    chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_* 2>/dev/null
    chmod 600 ~/.aws/credentials ~/.netrc ~/.pgpass 2>/dev/null
    chmod 700 ~/.gnupg 2>/dev/null

## 2. Homebrew and everything installed through it
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    brew bundle install --file=manifests/Brewfile

## 3. Language runtimes and global packages
See `manifests/` for npm, pip, gem, cargo, go, pyenv, asdf/mise and editor
extension lists. Reinstall from those rather than restoring binaries.

## 4. Verify credentials survived
    ssh -T git@github.com
    gh auth status
    aws sts get-caller-identity
    kubectl config get-contexts

## Not in this archive
- Your source code — clone it from your remotes
- macOS login keychain — use iCloud Keychain, or export from Keychain Access
- Xcode signing certificates — regenerate in Xcode > Settings > Accounts
- Package caches, node_modules, editor extensions — reinstall from manifests
EORESTORE
    printf '    RESTORE.md\n'
fi

# ---------------------------------------------------------------------------
announce_section "Summary"
# ---------------------------------------------------------------------------
printf '    %s items captured, %s paths not present, %s skipped for size\n' \
    "$capturedItemCount" "$absentItemCount" "$skippedForSizeCount"

if [ "$isDryRun" = true ]; then
    echo ""
    echo "Dry run complete — nothing was written."
    exit 0
fi

# ---------------------------------------------------------------------------
announce_section "Packaging"
# ---------------------------------------------------------------------------
mkdir -p "$outputDirectory"

# Refuse to write into a cloud-synced folder. An archive of every credential you
# own should not be uploaded anywhere, and these directories upload silently.
resolvedOutputDirectory="$(cd "$outputDirectory" && pwd -P)"
for cloudSyncedDirectory in "$HOME/Library/Mobile Documents" "$HOME/Library/CloudStorage" \
                            "$HOME/Dropbox" "$HOME/Google Drive" "$HOME/OneDrive"; do
    [ -d "$cloudSyncedDirectory" ] || continue
    resolvedCloudDirectory="$(cd "$cloudSyncedDirectory" && pwd -P)"
    case "$resolvedOutputDirectory" in
        "$resolvedCloudDirectory"*)
            echo ""
            echo "REFUSING TO WRITE: $outputDirectory is inside $cloudSyncedDirectory."
            echo "That would upload every credential on this machine to a third party."
            echo "Write to an external drive instead:  $0 --output /Volumes/YourDrive"
            exit 1 ;;
    esac
done

printf '    staged %s of data\n' "$(du -sh "$stagingDirectory" | cut -f1)"

if [ "$shouldEncrypt" = true ]; then
    finalArchivePath="$outputDirectory/$backupName.tar.gz.enc"
    echo ""
    echo "    Choose a passphrase. WRITE IT DOWN SOMEWHERE THAT SURVIVES THE ERASE."
    echo "    There is no recovery path without it."
    echo ""
    if ! tar -czf - -C "$stagingDirectory" . \
        | openssl enc -aes-256-cbc -md sha512 -pbkdf2 -iter 250000 -salt -out "$finalArchivePath"; then
        echo "ERROR: encryption failed. Nothing usable was written." >&2
        exit 1
    fi

    echo ""
    echo "    Re-enter the passphrase to prove the archive is readable:"
    if openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 250000 -in "$finalArchivePath" 2>/dev/null \
        | tar -tzf - >/dev/null 2>&1; then
        echo "    VERIFIED — the archive decrypts and lists cleanly."
    else
        echo ""
        echo "    VERIFICATION FAILED — do NOT erase this Mac." >&2
        echo "    The passphrases likely did not match. Delete $finalArchivePath and retry." >&2
        exit 1
    fi
else
    finalArchivePath="$outputDirectory/$backupName.tar.gz"
    tar -czf "$finalArchivePath" -C "$stagingDirectory" . || { echo "ERROR: tar failed" >&2; exit 1; }
    echo "    WARNING: archive is UNENCRYPTED and contains credentials in plain text."
fi

chmod 600 "$finalArchivePath"

cat <<EOSUMMARY

================================================================
 Done.

 Archive: $finalArchivePath
 Size:    $(du -h "$finalArchivePath" | cut -f1)

 Before you erase this Mac:
   1. Copy the archive to an external drive, and verify it opens there.
   2. Commit and push your code — this archive does not contain any.
   3. Confirm iCloud Keychain is on, or export your keychain manually.
================================================================
EOSUMMARY
