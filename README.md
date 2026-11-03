# codex-pr-review

`codex-pr-review.sh` runs Claude Code or Codex against a GitHub pull request diff and posts the result as a GitHub pull request review.
By default, it uses Claude Code with the included quota of a Claude subscription instead of Anthropic API billing.
Alternatively, it can use Codex CLI with the included quota of a ChatGPT subscription instead of OpenAI API billing (see [Choosing the Review Agent](#choosing-the-review-agent)).
It uses GitHub CLI to post reviews.

The script checks out the pull request head in a temporary detached worktree, runs several focused review passes against the pull request base branch, asks the agent to merge the findings of the individual passes, and posts any diagnostics as inline review comments.

## Requirements

- `bash`
- `git`
- `gh`
- `jq`
- `claude` (Claude Code, default agent) or `codex` (Codex CLI, with `REVIEW_AGENT=codex`)
- GitHub CLI authentication with a token that can read the repository and create pull request reviews
- Codex CLI authentication through saved ChatGPT/Codex auth, or Claude Code authentication through a saved Claude subscription login

The script unsets `OPENAI_API_KEY` and `CODEX_API_KEY` before invoking Codex so that the Codex CLI uses saved account authentication instead of OpenAI API billing.
For review execution, it creates a temporary `CODEX_HOME` and copies only top-level Codex auth files into it, so personal Codex or VS Code extension instructions are not loaded.
Likewise, it unsets `ANTHROPIC_API_KEY` before invoking Claude Code so that the saved subscription login is used instead of Anthropic API billing.

## Setup

1. Install and authenticate the required tools:

   ```bash
   gh auth login
   claude       # log in with your Claude account, or run `codex login` for Codex
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
Make sure GitHub CLI and Claude Code (or Codex CLI) are authenticated; run `gh auth login` and `claude` (or `codex login`) if needed.

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
DRY_RUN=1 review 123
```

## Choosing the Review Agent

The script uses Claude Code by default.
To run the review with Codex instead, set `REVIEW_AGENT=codex`:

```bash
REVIEW_AGENT=codex review 123
```

To always use Codex, export the variable in `~/.bash_profile`:

```bash
export REVIEW_AGENT=codex
```

Further optional environment variables:

- `REVIEW_EFFORT` sets the reasoning effort of all passes (default: `medium`).
  Codex accepts `minimal`, `low`, `medium`, `high`, and `xhigh`; Claude Code accepts `low`, `medium`, `high`, `xhigh`, and `max`.
  The previous variable `CODEX_REVIEW_REASONING_EFFORT` is still honored when `REVIEW_EFFORT` is unset.
- `CLAUDE_REVIEW_MODEL` selects the Claude model, for example `opus` or `sonnet`.
  Without it, Claude Code uses its default model.

The top-level review heading and terminal output name the selected agent.

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

When a matching file exists, its contents are included in each review pass and in the final synthesis prompt.
The terminal output reports whether custom instructions were loaded or no matching file was found.

## What Gets Posted

The posted review includes:

- A top-level `Codex Review` or `Claude Review` body with a factual Markdown summary of the pull request changes.
- An AI-generated review notice and a small `codex-pr-review` attribution link.
- Inline comments for diagnostics that the agent ties to changed lines in the pull request diff.

Diagnostics use these severities:

- `HIGH` for likely bugs, security issues, or data-loss issues.
- `MEDIUM` for important risks.
- `LOW` for remaining issues.

The posted review is created with GitHub's `COMMENT` event, so it does not approve the pull request or request changes.

## Security

- The script runs the agent with isolated settings to ignore local custom instructions.
- Codex passes run with `--ephemeral --ignore-user-config --ignore-rules --sandbox read-only` against a temporary detached worktree and temporary auth-only `CODEX_HOME`.
- The final synthesis pass uses the same isolation flags.
- Claude Code passes run with `--print --safe-mode --strict-mcp-config --no-session-persistence --permission-mode dontAsk`, so `CLAUDE.md` files, skills, hooks, plugins, and MCP servers are not loaded and no session is saved.
  Only the `Read`, `Grep`, and `Glob` tools and read-only `git` commands (`diff`, `log`, `show`, `blame`, `grep`, `ls-files`, `merge-base`, `rev-parse`, `status`) are allowed; any other tool call is denied automatically.
- The Claude Code synthesis pass returns its JSON through `--json-schema` structured output.
- The temporary worktree and intermediate files are removed when the script exits.
- GitHub API requests use the local `gh` authentication token through `GITHUB_TOKEN`.

## Notes

- For forked repositories, it might be necessary to first run `gh repo set-default`
  to set the repository context for GitHub CLI.

## License

MIT License. See [LICENSE](LICENSE).
