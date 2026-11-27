# GitHub issue completion

- Use `gh` with `--repo wbrisenold/negs-fork` for this fork's issues and pull requests.
- When reporting issue status, inspect linked pull requests and their merge commit in addition to the issue's open/closed state.
- A PR merged into `studio-port-upstream-sync` may leave `Closes #N` issues open when that branch is not GitHub's default branch. After checking that the merge commit contains the ticket work and its acceptance evidence is complete, close the linked issue explicitly and reference the PR and commit.
- Keep an issue open when the code merged but its stated acceptance checks are incomplete. Report implementation, merge, and runtime/UI verification as separate facts.
