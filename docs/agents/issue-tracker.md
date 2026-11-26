# Issue tracker: GitHub

Issues and specs for this repo live in `wbrisenold/negs-fork`. Use `gh` and always pass `--repo wbrisenold/negs-fork`; the checkout's current branch can otherwise resolve to the upstream repository.

## Conventions

- Create: `gh issue create --repo wbrisenold/negs-fork --title "..." --body "..."`
- Read: `gh issue view <number> --repo wbrisenold/negs-fork`
- List: `gh issue list --repo wbrisenold/negs-fork --state open`
- Use GitHub's native issue dependencies for blocking edges when available; otherwise write `Blocked by: #<number>` in the issue body.
- PRs as a request surface: off.
