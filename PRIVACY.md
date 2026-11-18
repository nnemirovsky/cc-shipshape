# Privacy policy

shipshape runs entirely inside Claude Code on your machine. It has no server and collects no telemetry. Nothing is sent to the author or to any third party.

## What it reads and sends

Its scripts call the GitHub API through your own `gh` login: pull requests, reviews, comments, checks, team membership and notifications. Everything it posts to GitHub is posted as you, on your instruction.

## What it writes

State files in `~/.local/state/shipshape/` (or `$XDG_STATE_HOME/shipshape/`), a directory only you can read: one per pull request a review cycle is running for (`handle-pr-<owner>-<repo>-<num>.json`), and the PR watch's snapshot and pid file (`watch_pr-<owner>-<repo>-<num>.json`). Its hook reads those files on every prompt and adds a line about the current repository's runs to the conversation. Files that older versions left in `/tmp` are read only when you own them.

## Contact

Questions go to [GitHub issues](https://github.com/nnemirovsky/cc-shipshape/issues).