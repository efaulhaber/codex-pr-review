# codex-pr-review

`codex-pr-review.sh` runs Codex against a GitHub pull request diff and posts the result as a GitHub pull request review.
It uses Codex CLI to work with included quota of a ChatGPT subscription instead of OpenAI API billing, and it uses GitHub CLI to post reviews.

The script checks out the pull request head in a temporary detached worktree, builds a zero-context unified diff against the pull request base branch, asks Codex for structured JSON findings, validates that JSON with `jq`, and posts any diagnostics as inline review comments.

## Requirements

- `bash`
- `git`
- `gh`
- `jq`
- `codex`
- GitHub CLI authentication with a token that can read the repository and create pull request reviews
- Codex CLI authentication through saved ChatGPT/Codex auth

The script unsets `OPENAI_API_KEY` and `CODEX_API_KEY` before invoking Codex so that the Codex CLI uses saved account authentication instead of OpenAI API billing.

## Setup

1. Install and authenticate the required tools:

   ```bash
   gh auth login
   codex login
   ```

2. Make sure the script is executable:

   ```bash
   chmod +x ./codex-pr-review.sh
   ```

3. Use the script from any directory inside the Git repository that contains the pull request you want to review. The script resolves the repository root with `git rev-parse --show-toplevel`.

   For forked repositories, it might be necessary to first run `gh repo set-default` to set the repository context for GitHub CLI.
   See `gh repo set-default --help` for details.

## Usage

Before running a review, change into the Git repository that contains the pull request.
Make sure GitHub CLI and Codex CLI are authenticated; run `gh auth login` and `codex login` if needed.

Review pull request `123` and post the review to GitHub:

```bash
./codex-pr-review.sh 123
```

Optionally, create an alias for the script by adding the following line to `~/.bash_profile`:

```bash
alias review="~/git/codex-pr-review/codex-pr-review.sh"
```

Then, the review command becomes:

```bash
review 123
```

Run without posting anything:

```bash
DRY_RUN=1 ./codex-pr-review.sh 123
```

By default, the script refuses to review diffs larger than 300000 bytes. Override that limit with `CODEX_REVIEW_MAX_DIFF_BYTES`:

```bash
CODEX_REVIEW_MAX_DIFF_BYTES=600000 ./codex-pr-review.sh 123
```

## Custom Review Instructions

Repository-specific review instructions can be stored next to `codex-pr-review.sh` in the `custom-instructions` directory.
The script looks for a Markdown file named after the GitHub repository slug:

```text
<script-dir>/custom-instructions/<owner>/<repo>.md
```

For example, reviews for `efaulhaber/codex-pr-review` load:

```text
<script-dir>/custom-instructions/efaulhaber/codex-pr-review.md
```

When a matching file exists, its contents are included in the Codex review prompt.
The terminal output reports whether custom instructions were loaded or no matching file was found.

## What Gets Posted

The posted review includes:

- A top-level `Codex Review` body with a factual Markdown summary of the pull request changes.
- Inline comments for diagnostics that Codex ties to changed lines in the pull request diff.

Diagnostics use these severities:

- `ERROR` for likely bugs, security issues, or data-loss issues.
- `WARNING` for important risks.
- `INFO` for remaining issues.

The posted review is created with GitHub's `COMMENT` event, so it does not approve the pull request or request changes.

## Notes

- Pull request titles, bodies, and diffs are treated as untrusted input in the review prompt
  to reduce the risk of prompt injections.
- The temporary worktree and intermediate files are removed when the script exits.
- Codex runs with `--ephemeral --sandbox read-only` against the temporary worktree.
