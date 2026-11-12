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

- **Hunks and lines:** in a file's diff (Hunk or Inline View), use Stage Hunk / Discard Hunk /
  Unstage Hunk on each `@@` row, or click line numbers to pick lines (Shift-click for a range)
  and use Stage Lines / Discard Lines. Discards can be undone with Undo.
- **File history & blame:** right-click a file → File History or Blame (also the clock and
  person buttons above a diff). History lists every commit that changed the file, following
  renames, with each change; Blame shows who last changed each line. Click a blame line to
  jump to that change; right-click a commit to blame the file as it was then.
- **Compare:** right-click a commit → Compare with Working Copy, Compare with your branch or
  Mark for Compare (then Compare with it on another commit), or select a commit and ⌘-click a
  second one. Right-click a branch → Compare with your branch. Files shows every changed file
  with its diff, Commits shows what each side has that the other doesn't; "Since split" limits
  it to what changed since the branches split off, like a pull request.
- **Hide branches:** hover a branch in the left panel and click the eye to hide it from the
  graph (or right-click → Hide in Graph); right-click a remote → Hide its branches. Solo shows
  only that branch and the one you're on. A bar above the graph shows what's hidden, with
  Show All or Exit Solo. Saved per repository.
- **Merge conflicts:** click a conflicted file. A (yours) and B (theirs) sit side by side; tick
  single lines, a whole conflict, or a whole side with the checkbox in its header. The Output
  below shows the result as you pick (lines picked first come first); ▲▼ jump between
  conflicts, Edit lets you change the result by hand, Save marks the file resolved.
- **Amend:** Commit options → "Amend previous commit" rewrites the last commit with the
  staged files and the edited message.
- **Force push:** when the remote has commits you don't have, Push offers Force Push
  (`--force-with-lease`) or Pull First.
- **New branches:** the first Push of a branch the remote doesn't have asks, in a bar under the
  tabs, which remote and branch to push to (same name by default). The branch then tracks it.
- **Tags:** right-click a commit → Create Tag Here…; right-click a tag to push or delete it.
- **Branches:** right-click a branch to push it, rename it or set its upstream.
- **Ignore:** right-click a file → Ignore, for that file, its extension or its folder.
- **Cherry-pick, revert, reset:** right-click a commit in the graph. Reset offers Soft, Mixed
  and Hard; all three can be undone with Undo.
- **Search commits (⌘F):** type words from the message, an author or a SHA. Matches light up
  in the graph; ↩ / ⇧↩ jump between them.
- **Command palette (⌘P):** run any action or check out / merge a branch by typing its name.
- **Pull Request:** opens the "new pull request" page on GitHub or Bitbucket for the current
  branch, pushing it first when needed.

## Shortcuts

| Action | Keys |
|---|---|
| Add repository | ⌘O |
| Clone | ⇧⌘N |
| Refresh / Fetch / Pull / Push | ⌘R / ⇧⌘F / ⇧⌘P / ⇧⌘U |
| Commit | ⌘↩ (in the message box) |
| Search commits / Command palette | ⌘F / ⌘P |
| Switch tab | ⌘1 … ⌘9 |
| Close tab | ⇧⌘W |

Double-click a branch to check it out. Right-click branches, stashes and files for more.
Opening a file's diff folds the branches panel into a thin rail; click its icon to bring it back.
Drag the lines between panels to resize them. Drag tabs to reorder them; middle-click a tab to close it.
