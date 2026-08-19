# carry-on

captures mac config, credentials and app state into one encrypted tarball
before you erase the disk. probes ~170 known paths, takes what exists, skips
caches.

## use

```
$ ./backup.sh --dry-run     # enumerate, write nothing
$ ./backup.sh               # ~/mac-backup-out/mac-backup-<ts>.tar.gz.enc
```

~40mb, ~8s.

## restore

```
$ openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 250000 \
    -in mac-backup-*.tar.gz.enc | tar -xzf -
$ cp -R home/. ~/
$ chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_*
$ brew bundle install --file=manifests/Brewfile
```

`home/` mirrors `$HOME`. absent paths are skipped at capture time, so the list
is machine-independent.

## captures

shells (zsh/bash/fish, nvim, starship, tmux, `~/.local/bin`) · `~/.ssh`,
`~/.gnupg` · gitconfig, `gh`/`glab` tokens · aws, gcp, azure, kube, docker,
terraform, pulumi, wrangler, vercel, netlify, fly, railway, supabase, doctl ·
npm, yarn, bun, pip, cargo, gem, composer, nuget, maven, gradle, hex ·
pyenv/asdf/mise pins · psqlrc, pgpass, my.cnf · claude, codex, cursor, copilot,
continue, aider · vscode/cursor/windsurf settings, xcode themes · iterm2,
ghostty, alacritty, wezterm, kitty, karabiner, raycast, alfred, rectangle,
hammerspoon, launchagents, quick actions, fonts · shell history · manifests:
brewfile, npm/pip/gem/cargo/go globals, editor extensions, mas, crontab,
`defaults` dump

`~/.aws` covers awscli, sam, cdk and copilot.

## excludes

source code · login keychain (use icloud keychain; regenerate xcode certs) ·
`.m2/repository`, `.gradle/caches`, `node_modules`, `.cursor/extensions` ·
`.env` files unless `--include-env`

## flags

```
-o, --output DIR     destination (default ~/mac-backup-out)
-n, --dry-run        enumerate only
    --include-env    collect project .env files
    --include-large  ignore the size limit
    --max-size MB    per-item limit (default 50)
    --no-encrypt     plain tar.gz
-h, --help
```

## crypto

aes-256-cbc, pbkdf2-sha512, 250k iterations, random salt. re-prompts and
verifies decryption before dropping the plaintext staging dir, which is
trapped on exit/int/term. refuses to write into icloud, dropbox, google drive
or onedrive.

## requires

macos, bash, openssl. brewfile requires homebrew.
