# SSH commit signing

The baseline ruleset requires signed commits on the default branch. Merges made on GitHub are signed by GitHub, so a squash merge always passes. Sign your own commits too, so every commit you push shows as verified.

Do this once per machine you push from.

## 1. Pick the key

Use the SSH key that already authenticates the machine to GitHub. `ssh -T git@github.com` greets you by login, and `ssh -G github.com | grep -i identityfile` shows the candidate files. A key the machine uses only for other servers is the wrong one.

The key must sign without a prompt, or every commit hangs:

- **No passphrase:** fine as it is.
- **Passphrase, held by an agent:** fine, as long as git's `ssh-keygen` can reach that agent (see Windows below).
- **Passphrase, no agent:** load the key into an agent first, or use another key.

## 2. Configure git

```bash
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub   # the key's .pub file
git config --global commit.gpgsign true
git config --global tag.gpgsign true
```

For local verification (`git log --show-signature`), also add an allowed-signers file:

```bash
mkdir -p ~/.config/git
printf '%s namespaces="git" %s\n' "$(git config --global user.email)" "$(cat ~/.ssh/id_ed25519.pub)" > ~/.config/git/allowed_signers
git config --global gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers
```

If the machine already has GPG signing configured (`user.signingkey` holding a GPG key id, or `gpg.program`), write down the old values before you overwrite them.

## 3. Register the key on GitHub as a signing key

A key registered for authentication is not trusted for signing until it is added again as a signing key:

```bash
gh auth refresh -h github.com -s admin:ssh_signing_key   # once: a browser approval
gh ssh-key add ~/.ssh/id_ed25519.pub --type signing --title "<machine> (signing)"
```

GitHub shows a commit as verified when the signing key is registered **and** the commit's email is a verified address on the account.

## 4. Test

```bash
cd "$(mktemp -d)" && git init -q && git commit -q --allow-empty -m test
git cat-file commit HEAD | grep -c 'BEGIN SSH SIGNATURE'   # 1 means signed
```

## Windows

- Git for Windows ships its own `ssh-keygen`, which cannot use the Windows ssh-agent. When the key has a passphrase held by that agent, sign with Windows OpenSSH instead:
  `git config --global gpg.ssh.program "C:/Windows/System32/OpenSSH/ssh-keygen.exe"`
- Windows OpenSSH's `ssh-keygen -Y verify` waits on stdin when git calls it, so `git log --show-signature` hangs. Leave `gpg.ssh.allowedSignersFile` unset on Windows. GitHub verifies signatures on its side anyway.
- Test with `git cat-file commit HEAD` as above, not with `--show-signature`.

## 1Password and other agents

When the private key lives only in an agent such as 1Password, set `user.signingkey` to `key::<public key line>` and `gpg.ssh.program` to the agent's signer (1Password's is `op-ssh-sign`).