# Contributing

Thanks for looking at `{{NAME}}`. This covers the dev loop, the tests and how changes land.

## Dev loop

Load the plugin from a working tree instead of through the marketplace:

```
claude --plugin-dir /path/to/{{NAME}}
```

Every Claude Code restart re-reads the plugin from disk, with no `/plugin install` and no marketplace cache to flush. What needs a restart depends on the part you changed:

- `plugin.json`, `hooks/hooks.json`, skills and commands load at session start: restart, or run `/reload-plugins`.
- A hook's handler script runs from disk on every call, so an edit applies at once.
- A function-hook module (a mod) reloads by itself when its files change.

## Tests

```
claude plugin validate .
claude plugin test .
```

<!-- TODO: any extra suites (bats, shellcheck) and what they cover. -->

CI runs them on every PR.

## Pull requests

- Open a PR against `{{DEFAULT_BRANCH}}`. Direct pushes are blocked.
- CI must be green and every review thread resolved before a PR can merge.
- PRs are squash-merged, and the PR title becomes the commit subject, so write it as a commit message.
- Bump `version` in `.claude-plugin/plugin.json` in the PR that should ship as a release.

## Commits

Scoped conventional commits with a lowercase description:

```
feat(scope): add the thing
fix(scope): stop doing the wrong thing
```
