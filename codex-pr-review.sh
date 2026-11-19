#!/usr/bin/env bash
# Copyright (c) 2026 Erik Faulhaber
# SPDX-License-Identifier: MIT
set -euo pipefail

# Input and Dependencies

# Parse input and verify local tool dependencies before doing any network or
# worktree operations.
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <pr-number>" >&2
  exit 2
fi

PR="$1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

command -v gh >/dev/null || { echo "gh is required" >&2; exit 1; }
command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

# Select the review agent with REVIEW_AGENT=claude (default) or REVIEW_AGENT=codex.
REVIEW_AGENT="${REVIEW_AGENT:-claude}"
REVIEW_EFFORT="${REVIEW_EFFORT:-${CODEX_REVIEW_REASONING_EFFORT:-high}}"

case "$REVIEW_AGENT" in
  codex)
    AGENT_NAME="Codex"
    ;;
  claude)
    AGENT_NAME="Claude"
    ;;
  *)
    echo "Unknown REVIEW_AGENT '${REVIEW_AGENT}'. Use 'claude' or 'codex'." >&2
    exit 2
    ;;
esac

# Select a specific Claude Code binary with CLAUDE_BIN, e.g., to compare versions.
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
if [[ "$REVIEW_AGENT" == "claude" ]]; then
  AGENT_BIN="$CLAUDE_BIN"
else
  AGENT_BIN="$REVIEW_AGENT"
fi

command -v "$AGENT_BIN" >/dev/null || {
  echo "$AGENT_BIN is required" >&2
  exit 1
}

# Make sure Codex CLI uses your saved ChatGPT/Codex auth,
# not OpenAI API billing.
unset OPENAI_API_KEY
unset CODEX_API_KEY

CODEX_ARGS=(
  --sandbox read-only
)

CODEX_REVIEW_ARGS=(
  --ephemeral
  --ignore-user-config
  --ignore-rules
)

# Make sure Claude Code uses your saved Claude subscription login,
# not Anthropic API billing.
unset ANTHROPIC_API_KEY

# Run Claude Code non-interactively without user customizations (CLAUDE.md,
# skills, hooks, plugins, MCP servers) and without saving the session. Only
# read-only tools and read-only git commands are allowed; every other tool call
# is denied automatically.
CLAUDE_ARGS=(
  --print
  --safe-mode
  --strict-mcp-config
  --no-session-persistence
  --permission-mode dontAsk
  --output-format json
  --tools "Read,Grep,Glob,Bash"
  --allowedTools
  "Read"
  "Grep"
  "Glob"
  "Bash(git diff *)"
  "Bash(git log *)"
  "Bash(git show *)"
  "Bash(git blame *)"
  "Bash(git grep *)"
  "Bash(git ls-files *)"
  "Bash(git merge-base *)"
  "Bash(git rev-parse *)"
  "Bash(git status *)"
  --effort "$REVIEW_EFFORT"
)

if [[ -n "${CLAUDE_REVIEW_MODEL:-}" ]]; then
  CLAUDE_ARGS+=(--model "$CLAUDE_REVIEW_MODEL")
fi

# JSON Schema for the Claude synthesis pass. Claude validates its final answer
# against this schema, so no Markdown fences or prose end up in the JSON file.
CLAUDE_SYNTHESIS_SCHEMA='{
  "type": "object",
  "additionalProperties": false,
  "required": ["body", "diagnostics"],
  "properties": {
    "body": { "type": "string", "minLength": 1 },
    "diagnostics": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["message", "location", "severity"],
        "properties": {
          "message": { "type": "string" },
          "location": {
            "type": "object",
            "required": ["path", "range"],
            "properties": {
              "path": { "type": "string" },
              "range": {
                "type": "object",
                "required": ["start"],
                "properties": {
                  "start": {
                    "type": "object",
                    "required": ["line"],
                    "properties": {
                      "line": { "type": "integer" },
                      "column": { "type": "integer" }
                    }
                  }
                }
              }
            }
          },
          "severity": { "enum": ["HIGH", "MEDIUM", "LOW"] },
          "code": { "type": "object" },
          "source": { "type": "object" }
        }
      }
    }
  }
}'

# Repository and PR Metadata

# Resolve repository identity and PR metadata from the caller's current git
# repository. All later git operations run from the repository root.
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

REPO_SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
OWNER="${REPO_SLUG%/*}"
REPO="${REPO_SLUG#*/}"

TOKEN="$(gh auth token 2>/dev/null || true)"

if [[ -z "$TOKEN" ]]; then
  echo "No GitHub token available." >&2
  echo "Run: gh auth login" >&2
  exit 1
fi

echo
echo "Repository: ${OWNER}/${REPO}" >&2
echo "PR: #${PR}" >&2

CUSTOM_INSTRUCTIONS_FILE="${SCRIPT_DIR}/custom-instructions/${OWNER}/${REPO}.md"
CUSTOM_INSTRUCTIONS=""

if [[ -f "$CUSTOM_INSTRUCTIONS_FILE" ]]; then
  CUSTOM_INSTRUCTIONS="$(<"$CUSTOM_INSTRUCTIONS_FILE")"
  echo "Custom review instructions: loaded ${CUSTOM_INSTRUCTIONS_FILE}" >&2
else
  echo "Custom review instructions: none found at ${CUSTOM_INSTRUCTIONS_FILE}" >&2
fi

BASE_REF="$(gh pr view "$PR" --json baseRefName -q .baseRefName)"
HEAD_SHA="$(gh pr view "$PR" --json headRefOid -q .headRefOid)"
TITLE="$(gh pr view "$PR" --json title -q .title)"
PR_BODY="$(gh pr view "$PR" --json body -q .body)"

echo "Base: ${BASE_REF}" >&2
echo "Head SHA: ${HEAD_SHA}" >&2

# A description whose first line starts with "Based on" marks a stacked PR, as
# in "Based on #123 and #124.". The changes of these PRs are not reviewed.
BASED_ON_PRS=()
pr_body_first_line="$(printf '%s\n' "$PR_BODY" | tr -d '\r' |
  sed -n '/[^[:space:]]/{s/^[[:space:]]*//;p;q;}')"
if [[ "$pr_body_first_line" == "Based on"* ]]; then
  while read -r based_on_pr; do
    BASED_ON_PRS+=("$based_on_pr")
  done < <(grep -oE '(#|/pull/)[0-9]+' <<< "$pr_body_first_line" |
    grep -oE '[0-9]+')
fi

if [[ "${#BASED_ON_PRS[@]}" -gt 0 ]]; then
  BASED_ON_TEXT="$(printf '#%s, ' "${BASED_ON_PRS[@]}")"
  BASED_ON_TEXT="${BASED_ON_TEXT%, }"
  echo "Based on: ${BASED_ON_TEXT}" >&2
fi

# Temporary Workspace

# Keep all generated prompts, logs, outputs, and the detached review worktree in
# a single temporary directory so cleanup can be centralized.
TMPDIR="$(mktemp -d)"
WORKTREE="$TMPDIR/worktree"
REAL_CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
ISOLATED_CODEX_HOME="$TMPDIR/codex-home"

# Print token usage of every Claude session from its JSON result envelope.
print_claude_usage() {
  local result_file

  for result_file in "$TMPDIR"/*.claude.json "$PASS_OUTPUT_DIR"/*.claude.json; do
    [[ -s "$result_file" ]] || continue
    jq -r --arg name "$(basename "$result_file" .claude.json)" '
      "\($name): \(.num_turns) turns, \(.duration_ms / 1000 | floor) s, "
      + "$\(.total_cost_usd * 100 | round / 100) list price",
      (.modelUsage // {} | to_entries[] |
        "  \(.key): input \(.value.inputTokens), "
        + "output \(.value.outputTokens), "
        + "cache read \(.value.cacheReadInputTokens), "
        + "cache write \(.value.cacheCreationInputTokens)")
    ' "$result_file" 2>/dev/null || true
  done
}

cleanup() {
  if [[ "$REVIEW_AGENT" == "claude" ]]; then
    {
      echo
      echo "## Claude Usage"
      echo
      print_claude_usage
    } >&2
  fi
  if [[ -d "$WORKTREE/.git" ]] || [[ -f "$WORKTREE/.git" ]]; then
    git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

AGENT_LOG_FILE="$TMPDIR/agent.log"
PASS_LOG_DIR="$TMPDIR/pass-logs"
PASS_PROMPT_DIR="$TMPDIR/pass-prompts"
PASS_OUTPUT_DIR="$TMPDIR/pass-outputs"
PASS_STATUS_DIR="$TMPDIR/pass-statuses"
SYNTHESIS_PROMPT_FILE="$TMPDIR/synthesis-prompt.md"
JSON_FILE="$TMPDIR/synthesis.json"
REVIEW_BODY_FILE="$TMPDIR/review-body.md"
REVIEW_PAYLOAD_FILE="$TMPDIR/review-payload.json"

mkdir -p \
  "$ISOLATED_CODEX_HOME" \
  "$PASS_LOG_DIR" \
  "$PASS_PROMPT_DIR" \
  "$PASS_OUTPUT_DIR" \
  "$PASS_STATUS_DIR"

# Run Codex from an isolated CODEX_HOME containing only auth. This keeps the
# review independent of the user's local config while still using saved login
# credentials. Claude Code is isolated through CLAUDE_ARGS instead.
if [[ "$REVIEW_AGENT" == "codex" ]]; then
  copied_codex_auth=0
  for auth_file in auth.json auth.toml; do
    if [[ -f "$REAL_CODEX_HOME/$auth_file" ]]; then
      cp "$REAL_CODEX_HOME/$auth_file" "$ISOLATED_CODEX_HOME/$auth_file"
      copied_codex_auth=1
    fi
  done

  if [[ "$copied_codex_auth" -eq 0 ]]; then
    echo "No Codex auth file found in ${REAL_CODEX_HOME}." >&2
    echo "Run codex login or set CODEX_HOME to a directory containing Codex auth." >&2
    exit 1
  fi

  export CODEX_HOME="$ISOLATED_CODEX_HOME"
fi

# Worktree Preparation

# Fetch the base branch and GitHub's synthetic PR head ref, then check out the
# exact PR head SHA in a detached worktree. Fetching refs/pull/<PR>/head makes
# fork PR commits available locally without adding the fork as a remote.
git fetch origin "+refs/heads/${BASE_REF}:refs/remotes/origin/${BASE_REF}" --quiet
git fetch origin "+refs/pull/${PR}/head" --quiet

FETCHED_HEAD_SHA="$(git rev-parse "FETCH_HEAD^{commit}")"
if [[ "$FETCHED_HEAD_SHA" != "$HEAD_SHA" ]]; then
  echo "Fetched PR head ${FETCHED_HEAD_SHA}, but GitHub reported ${HEAD_SHA}." >&2
  echo "The pull request may have changed while the review was starting; retry." >&2
  exit 1
fi

git worktree add --detach "$WORKTREE" "$FETCHED_HEAD_SHA"

# Determine the commit to diff against. This is the merge base with the base
# branch, or, for stacked PRs, the latest commit already contained in the base
# branch or one of the PRs this PR is based on.
review_bases=("$(git merge-base "origin/${BASE_REF}" "$FETCHED_HEAD_SHA")")
for based_on_pr in ${BASED_ON_PRS[@]+"${BASED_ON_PRS[@]}"}; do
  git fetch origin "+refs/pull/${based_on_pr}/head" --quiet
  review_bases+=("$(git merge-base FETCH_HEAD "$FETCHED_HEAD_SHA")")
done

# Drop every candidate that is already contained in another one.
independent_bases=()
while read -r commit; do
  independent_bases+=("$commit")
done < <(git merge-base --independent "${review_bases[@]}")

# If the PR is based on several independent PRs, diff against a merge of all of
# them. The merge commit is not referenced by any ref, so git collects it later.
REVIEW_BASE_SHA="${independent_bases[0]}"
for commit in "${independent_bases[@]:1}"; do
  merged_tree="$(git merge-tree --write-tree "$REVIEW_BASE_SHA" "$commit" |
    head -n 1)" || {
    echo "The PRs ${BASED_ON_TEXT} cannot be merged without conflicts." >&2
    echo "Cannot determine which changes are new in PR #${PR}." >&2
    exit 1
  }
  REVIEW_BASE_SHA="$(git commit-tree "$merged_tree" \
    -p "$REVIEW_BASE_SHA" -p "$commit" -m "Review base")"
done

echo "Review base: ${REVIEW_BASE_SHA}" >&2

STACKED_PR_NOTE=""
if [[ "${#BASED_ON_PRS[@]}" -gt 0 ]]; then
  STACKED_PR_NOTE="
This PR is based on ${BASED_ON_TEXT}. The changes of these PRs are excluded from
the diff above and are reviewed separately. Review only the changes in this
diff. You may read the code of these PRs for context, but do not report
findings about it.
"
fi

# Print a compact diff size summary before launching the review passes.
git -C "$WORKTREE" diff --no-ext-diff --numstat "$REVIEW_BASE_SHA" HEAD |
  awk '
    {
      files += 1
      if ($1 != "-") {
        added += $1
      }
      if ($2 != "-") {
        deleted += $2
      }
    }
    END {
      printf "Files changed: %d\n" \
             "Lines added: %d\n" \
             "Lines deleted: %d\n", files, added, deleted
    }
  ' >&2

# Review Pass Helpers

# Write the review prompt. A single session covers all review categories, so
# the diff and the surrounding code are only read once. Custom repository
# instructions are appended to apply project-specific expectations.
write_review_prompt() {
  local prompt_file="$1"

  cat > "$prompt_file" <<PROMPT
Review this PR against origin/${BASE_REF}.

Use git diff ${REVIEW_BASE_SHA} HEAD.
${STACKED_PR_NOTE}
Review the entire diff in all four categories below. Read the diff and the code
it touches once and cover all categories from there, instead of exploring the
code separately for each category.
Report concrete, actionable findings. Do not stop at the first finding. Report
each finding only once, in the category it fits best.

1. Correctness and regressions: Review changed production behavior for bugs,
   edge cases, invalid assumptions, error handling, compatibility, security,
   race conditions, data loss, performance, and appropriate data type handling.
2. Tests: Review changed tests and missing tests. Assess whether the tests
   would actually catch regressions. Look for weak assertions, missing
   edge/negative cases, brittle tests, over-mocking, implementation-detail
   testing, and changed behavior without test coverage.
3. Maintainability and code quality: Review readability, naming, complexity,
   duplication, abstractions, coupling, style, project conventions, and
   consistency with surrounding code.
4. Documentation, comments, and text quality: Review docs, comments, examples,
   names, error messages, logs, and user/developer-facing text as human-facing
   writing. Look for wording, clarity, coherence, formatting, structure, reader
   flow, completeness, terminology consistency, misleading implications, stale
   explanations, awkward phrasing, and general quality.

Output Markdown with the following sections, in this order:

## Summary
Summarize the *intended* PR changes, not the review findings. Keep the summary
factual and concise with bullets and do not mention any of your findings.

## Correctness and regressions
## Tests
## Maintainability and code quality
## Documentation, comments, and text quality

In each category section, order the findings by severity and include exact file
and line references. If a category has no findings, say so clearly.
PROMPT

  if [[ -n "$CUSTOM_INSTRUCTIONS" ]]; then
    {
      echo
      cat <<PROMPT
${CUSTOM_INSTRUCTIONS}
PROMPT
    } >> "$prompt_file"
  fi
}

# Execute one review pass inside the detached PR worktree with the selected
# agent. Any additional arguments are passed on to the agent CLI.
run_agent_review() {
  local label="$1"
  local prompt_file="$2"
  local output_file="$3"
  local stderr_file="$4"
  shift 4

  (
    cd "$WORKTREE"
    case "$REVIEW_AGENT" in
      codex)
        codex "${CODEX_ARGS[@]}" exec review \
          "${CODEX_REVIEW_ARGS[@]}" \
          -c "model_reasoning_effort=\"${REVIEW_EFFORT}\"" \
          --title "${TITLE} (${label})" \
          "$@" \
          - \
          < "$prompt_file" \
          > "$output_file" \
          2> "$stderr_file"
        ;;
      claude)
        # Keep Claude's JSON result envelope next to the output for the usage
        # summary, and extract the schema-validated answer or the plain text.
        local result_file="${output_file%.*}.claude.json"
        "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}" "$@" \
          < "$prompt_file" \
          > "$result_file" \
          2> "$stderr_file" &&
          jq -er '
            if .is_error then error("Claude returned an error: \(.result)")
            elif .structured_output then .structured_output
            else .result
            end
          ' "$result_file" > "$output_file"
        ;;
    esac
  )
}

# Render a small in-place status table while the review passes run in parallel.
render_pass_statuses() {
  local frame="$1"
  local status
  local status_file
  local label
  local rc
  local dots

  if [[ "${PASS_STATUS_RENDERED:-0}" -eq 1 ]]; then
    printf '\033[%dA' "${#PASS_LABELS[@]}" >&2
  fi

  for i in "${!PASS_LABELS[@]}"; do
    label="${PASS_LABELS[$i]}"
    status_file="${PASS_STATUS_FILES[$i]}"
    if [[ -f "$status_file" ]]; then
      rc="$(<"$status_file")"
      if [[ "$rc" -eq 0 ]]; then
        status="completed"
      else
        status="failed (${rc})"
      fi
    else
      printf -v dots '%*s' "$(((frame % 3) + 1))" ''
      status="running ${dots// /.}"
    fi

    printf '\033[2K%s: %s\n' "$label" "$status" >&2
  done

  PASS_STATUS_RENDERED=1
}

# Wait for all review passes, collect their stderr logs, and fail the whole
# review if any pass failed.
wait_for_review_passes() {
  local remaining="${#PASS_STATUS_FILES[@]}"
  local frame=0
  local status_file
  local rc
  local failed=0

  render_pass_statuses "$frame"
  while [[ "$remaining" -gt 0 ]]; do
    sleep 1
    remaining=0
    for status_file in "${PASS_STATUS_FILES[@]}"; do
      if [[ ! -f "$status_file" ]]; then
        remaining=$((remaining + 1))
      fi
    done
    frame=$((frame + 1))
    render_pass_statuses "$frame"
  done

  for i in "${!PASS_PIDS[@]}"; do
    wait "${PASS_PIDS[$i]}" || true
  done

  for i in "${!PASS_LABELS[@]}"; do
    {
      echo "## ${PASS_LABELS[$i]}"
      echo
      if [[ -s "${PASS_LOG_FILES[$i]}" ]]; then
        cat "${PASS_LOG_FILES[$i]}"
      else
        echo "(empty)"
      fi
      echo
    } >> "$AGENT_LOG_FILE"
  done

  for status_file in "${PASS_STATUS_FILES[@]}"; do
    rc="$(<"$status_file")"
    if [[ "$rc" -ne 0 ]]; then
      failed=1
    fi
  done

  if [[ "$failed" -ne 0 ]]; then
    {
      echo
      echo "## ${AGENT_NAME} Log"
      echo
      cat "$AGENT_LOG_FILE"
      echo "One or more ${AGENT_NAME} review passes failed."
    } >&2
    return 1
  fi
}

# Start one review pass in the background and record its PID, output log, and
# status file so wait_for_review_passes can monitor it.
start_review_pass() {
  local index="$1"
  local label="$2"
  local prompt_file="$3"
  local output_file="$4"
  local log_file="$PASS_LOG_DIR/${index}.log"
  local status_file="$PASS_STATUS_DIR/${index}.status"

  PASS_LABELS+=("$label")
  PASS_LOG_FILES+=("$log_file")
  PASS_STATUS_FILES+=("$status_file")

  (
    if run_agent_review "$label" "$prompt_file" "$output_file" "$log_file"; then
      echo 0 > "$status_file"
    else
      echo "$?" > "$status_file"
    fi
  ) &
  PASS_PIDS+=("$!")
}

# Review Passes

write_review_prompt "$PASS_PROMPT_DIR/01-review.md"

PASS_LABELS=()
PASS_LOG_FILES=()
PASS_PIDS=()
PASS_STATUS_FILES=()
PASS_STATUS_RENDERED=0

start_review_pass \
  "01-review" \
  "Review" \
  "$PASS_PROMPT_DIR/01-review.md" \
  "$PASS_OUTPUT_DIR/01-review.md"

wait_for_review_passes

# Final Synthesis

# Ask the agent to convert the Markdown report into the GitHub code scanning
# diagnostic shape. Keeping this as JSON makes validation and payload rendering
# deterministic.
{
  cat <<PROMPT
Convert the review report for PR #${PR} in ${OWNER}/${REPO} into JSON.

Return ONLY valid JSON.

Use the review report below as the source material. Deduplicate overlapping
findings, resolve contradictions conservatively, and keep only findings that
are concrete and actionable.
Order final findings by severity. Preserve file and line references.
Do not invent new findings that are not supported by the review report.

Hard requirements:
- Return a single JSON object.
- Top-level keys must be "body" and "diagnostics".
- "body" must contain the summary of the PR changes from the "Summary" section of the report, not the review findings.
- "diagnostics" must be an array.
- Each diagnostic must be actionable and tied to a changed line in the diff.
- Use severity "HIGH" for likely bugs/security/data-loss issues, "MEDIUM"
  for important risks, "LOW" for remaining issues.
- Paths must match the diff paths exactly, without leading "a/" or "b/".
- Line numbers must be new-file line numbers visible in the PR diff.

JSON shape:
{
  "body": "PR summary.",
  "diagnostics": [
    {
      "message": "Explain the problem and a concrete fix.",
      "location": {
        "path": "path/from/repo/root.ext",
        "range": {
          "start": { "line": 123, "column": 1 }
        }
      },
      "severity": "HIGH",
      "code": {
        "value": "codex-review"
      },
      "source": {
        "name": "codex-pr-review"
      }
    }
  ]
}

PROMPT
  if [[ -n "$CUSTOM_INSTRUCTIONS" ]]; then
    cat <<PROMPT
${CUSTOM_INSTRUCTIONS}

PROMPT
  fi

  cat <<'PROMPT'
# Review Report

PROMPT
  cat "$PASS_OUTPUT_DIR/01-review.md"
} > "$SYNTHESIS_PROMPT_FILE"

echo "Running ${AGENT_NAME} review pass: Final synthesis" >&2
case "$REVIEW_AGENT" in
  codex)
    run_agent_review \
      "Final synthesis" \
      "$SYNTHESIS_PROMPT_FILE" \
      "$JSON_FILE" \
      >(tee -a "$AGENT_LOG_FILE" >&2)
    ;;
  claude)
    run_agent_review \
      "Final synthesis" \
      "$SYNTHESIS_PROMPT_FILE" \
      "$JSON_FILE" \
      >(tee -a "$AGENT_LOG_FILE" >&2) \
      --json-schema "$CLAUDE_SYNTHESIS_SCHEMA"
    ;;
esac

# Validation and Review Body

# Validate the minimum structure needed to render a GitHub review. jq will exit
# non-zero here if the agent returns invalid JSON or omits required fields.
jq -e '
  type == "object"
  and (keys | sort == ["body", "diagnostics"])
  and (.body | type == "string")
  and (.body | length > 0)
  and (.diagnostics | type == "array")
  and all(.diagnostics[]?;
    (.message | type == "string") and
    (.location.path | type == "string") and
    (.location.range.start.line | type == "number")
  )
' "$JSON_FILE" >/dev/null

{
  echo
  echo "## ${AGENT_NAME} Log"
  echo
  if [[ -s "$AGENT_LOG_FILE" ]]; then
    echo "Full ${AGENT_NAME} log was printed above."
  else
    echo "(empty)"
  fi
} >&2

# Build the top-level PR review body. Inline comments are created separately
# from diagnostics below.
{
  echo "## ${AGENT_NAME} Review"
  echo
  jq -r '.body' "$JSON_FILE"
  echo
  echo "_This is an AI-generated code review. Please verify the findings and summary before acting on them._"
  echo "<sub>Review generated by [codex-pr-review](https://github.com/efaulhaber/codex-pr-review)</sub>"
} > "$REVIEW_BODY_FILE"

high_count="$(jq '[.diagnostics[]? | select(.severity == "HIGH")] | length' \
  "$JSON_FILE")"
medium_count="$(jq \
  '[.diagnostics[]? | select((.severity // "MEDIUM") == "MEDIUM")] | length' \
  "$JSON_FILE")"
low_count="$(jq '[.diagnostics[]? | select(.severity == "LOW")] | length' \
  "$JSON_FILE")"

# Report the generated severity distribution before posting anything to GitHub.
printf '%s produced %s high, %s medium, %s low findings.\n' \
  "$AGENT_NAME" \
  "$high_count" \
  "$medium_count" \
  "$low_count" \
  >&2

{
  echo
  cat "$REVIEW_BODY_FILE"
} >&2

# Print all findings ordered by severity, with their location and an indented
# message, so the full review can be read in the terminal.
print_findings() {
  {
    echo
    echo "## ${AGENT_NAME} Findings"
    echo
    jq -r '
      def rank:
        if .severity == "HIGH" then 0
        elif .severity == "LOW" then 2
        else 1
        end;

      if (.diagnostics | length) == 0 then
        "No findings."
      else
        .diagnostics
        | sort_by(rank)
        | to_entries[]
        | "\(.key + 1). [\(.value.severity // "MEDIUM")] "
          + "\(.value.location.path):\(.value.location.range.start.line)\n"
          + (.value.message | split("\n") | map("   " + .) | join("\n"))
          + "\n"
      end
    ' "$JSON_FILE"
  } >&2
}

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  print_findings
  echo
  echo "DRY_RUN=1, not posting GitHub review." >&2
  exit 0
fi

# GitHub Review Payload

# Convert diagnostics into GitHub review comments. GitHub gets human-facing
# severity labels, while the JSON file keeps the structured HIGH/MEDIUM/LOW
# values used for counting and validation.
jq \
  --rawfile body "$REVIEW_BODY_FILE" \
  --arg commit_id "$HEAD_SHA" \
  '{
    commit_id: $commit_id,
    event: "COMMENT",
    body: $body,
    comments: [
      .diagnostics[] | {
        path: .location.path,
        line: .location.range.start.line,
        side: "RIGHT",
        body: (
          (
            if .severity == "HIGH" then "**High:**"
            elif .severity == "LOW" then "**Low:**"
            else "**Medium:**"
            end
          ) + " " + .message
        )
      }
    ]
  }' "$JSON_FILE" \
  > "$REVIEW_PAYLOAD_FILE"

env GITHUB_TOKEN="$TOKEN" \
  gh api \
  --method POST \
  "repos/${OWNER}/${REPO}/pulls/${PR}/reviews" \
  --input "$REVIEW_PAYLOAD_FILE" \
  >/dev/null

print_findings
