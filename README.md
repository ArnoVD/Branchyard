# Branchyard

A small native macOS git client: Bitbucket clone over SSH, repo library with tabs,
staged/unstaged files with diffs, commit/pull/push/stash/pop, branches, and a merge
conflict resolver. Built with SwiftUI on top of the `git` command line.

## Build & run

```bash
swift run Branchyard              # run from source
./scripts/make-app.sh             # build dist/Branchyard.app
swift run GitCoreCheck            # end-to-end checks of the git layer
```

Needs macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

## Bitbucket setup

1. Add your SSH public key in Bitbucket → Personal settings → SSH keys.
2. Key has a passphrase? Run once: `ssh-add --apple-use-keychain ~/.ssh/id_ed25519`
3. In Branchyard: Settings (⌘,) → enter your Atlassian email + an API token with
   scope `read:repository:bitbucket` (and `read:workspace:bitbucket`).
   Create it at id.atlassian.com → Security → API tokens.
4. File → Clone… → pick repositories → Clone.

The token is only used to list repositories and is kept in your Keychain.
Clone, pull and push go over SSH with your own keys.
Bitbucket Server / Data Center: use the "SSH URL" tab in the Clone window.

## Profiles & GitHub

Settings → Profiles: one profile per identity (e.g. Work, Personal), each with its own
commit name/email. Add folders to a profile and every repository inside them uses it
automatically. Switch the default profile from the menu at the top right.

Settings → Accounts: connect a GitHub token to a profile. Repository → Publish to GitHub…
creates the repository on that account and pushes. Identity and token are passed to git
per command; your ~/.gitconfig is never changed.

## Git options

Settings → Git: fetch automatically (every 1–30 min), pick what the Pull button does
(fast-forward if possible, fast-forward only, or rebase) and push after every commit.
The Pull button's dropdown switches the mode too.

- **Amend:** Commit options → "Amend previous commit" rewrites the last commit with the
  staged files and the edited message.
- **Force push:** when the remote has commits you don't have, Push offers Force Push
  (`--force-with-lease`) or Pull First.
- **Tags:** right-click a commit → Create Tag Here…; right-click a tag to push or delete it.
- **Branches:** right-click a branch to push it, rename it or set its upstream.
- **Ignore:** right-click a file → Ignore, for that file, its extension or its folder.

## Shortcuts

| Action | Keys |
|---|---|
| Add repository | ⌘O |
| Clone | ⇧⌘N |
| Refresh / Fetch / Pull / Push | ⌘R / ⇧⌘F / ⇧⌘P / ⇧⌘U |
| Commit | ⌘↩ (in the message box) |
| Switch tab | ⌘1 … ⌘9 |
| Close tab | ⇧⌘W |

Double-click a branch to check it out. Right-click branches, stashes and files for more.
Opening a file's diff folds the branches panel into a thin rail; click its icon to bring it back.
Drag the lines between panels to resize them.
