#!/usr/bin/env bash
# Copyright (c) 2026 Erik Faulhaber
# SPDX-License-Identifier: MIT
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <pr-number>" >&2
  exit 2
fi

PR="$1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

command -v gh >/dev/null || { echo "gh is required" >&2; exit 1; }
command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v codex >/dev/null || { echo "codex is required" >&2; exit 1; }

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

echo "Base: ${BASE_REF}" >&2
echo "Head SHA: ${HEAD_SHA}" >&2

TMPDIR="$(mktemp -d)"
WORKTREE="$TMPDIR/worktree"
REAL_CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
ISOLATED_CODEX_HOME="$TMPDIR/codex-home"

cleanup() {
  if [[ -d "$WORKTREE/.git" ]] || [[ -f "$WORKTREE/.git" ]]; then
    git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

CODEX_LOG_FILE="$TMPDIR/codex.log"
PASS_LOG_DIR="$TMPDIR/pass-logs"
PASS_PROMPT_DIR="$TMPDIR/pass-prompts"
PASS_OUTPUT_DIR="$TMPDIR/pass-outputs"
PASS_STATUS_DIR="$TMPDIR/pass-statuses"
SYNTHESIS_PROMPT_FILE="$TMPDIR/synthesis-prompt.md"
JSON_FILE="$TMPDIR/codex-review.json"
REVIEW_BODY_FILE="$TMPDIR/review-body.md"
REVIEW_PAYLOAD_FILE="$TMPDIR/review-payload.json"

mkdir -p \
  "$ISOLATED_CODEX_HOME" \
  "$PASS_LOG_DIR" \
  "$PASS_PROMPT_DIR" \
  "$PASS_OUTPUT_DIR" \
  "$PASS_STATUS_DIR"

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

git fetch origin "+refs/heads/${BASE_REF}:refs/remotes/origin/${BASE_REF}" --quiet
git fetch origin "+refs/pull/${PR}/head:refs/remotes/origin/pr/${PR}" --quiet
git worktree add --detach "$WORKTREE" "$HEAD_SHA" >/dev/null 2>&1

BASE_SHA="$(git -C "$WORKTREE" merge-base "origin/${BASE_REF}" HEAD)"

git -C "$WORKTREE" diff --no-ext-diff --numstat "$BASE_SHA"...HEAD |
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

write_pass_prompt() {
  local prompt_file="$1"
  local pass_number="$2"
  local pass_title="$3"
  local pass_template

  pass_template="$(cat)"

  cat > "$prompt_file" <<PROMPT
Review this PR against origin/${BASE_REF}.

Use git diff origin/${BASE_REF}...HEAD.

This is pass ${pass_number} of 4: ${pass_title}.
Only perform this pass. Do not cover other review categories except where they
directly affect this pass.
Report concrete, actionable findings. If there are no findings for this pass,
say so clearly.
Do not stop at the first finding. Review the entire diff and report all findings
in this pass.

${pass_template}

Output Markdown. Order your findings by severity. Include exact file
and line references.
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

run_codex_review() {
  local label="$1"
  local prompt_file="$2"
  local output_file="$3"
  local stderr_file="$4"

  (
    cd "$WORKTREE"
    codex "${CODEX_ARGS[@]}" exec review \
      "${CODEX_REVIEW_ARGS[@]}" \
      -c "model_reasoning_effort=\"${CODEX_REVIEW_REASONING_EFFORT:-medium}\"" \
      --title "${TITLE} (${label})" \
      - \
      < "$prompt_file" \
      > "$output_file" \
      2> "$stderr_file"
  )
}

render_pass_statuses() {
  local frame="$1"
  local status
  local status_file
  local label
  local rc
  local dots

  if [[ "${PASS_STATUS_RENDERED:-0}" -eq 1 ]]; then
    printf '\033[4A' >&2
  fi

  for i in 0 1 2 3; do
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

wait_for_review_passes() {
  local remaining=4
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

  for i in 0 1 2 3; do
    wait "${PASS_PIDS[$i]}" || true
  done

  for i in 0 1 2 3; do
    {
      echo "## ${PASS_LABELS[$i]}"
      echo
      if [[ -s "${PASS_LOG_FILES[$i]}" ]]; then
        cat "${PASS_LOG_FILES[$i]}"
      else
        echo "(empty)"
      fi
      echo
    } >> "$CODEX_LOG_FILE"
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
      echo "## Codex Log"
      echo
      cat "$CODEX_LOG_FILE"
      echo "One or more Codex review passes failed."
    } >&2
    return 1
  fi
}

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
    if run_codex_review "$label" "$prompt_file" "$output_file" "$log_file"; then
      echo 0 > "$status_file"
    else
      echo "$?" > "$status_file"
    fi
  ) &
  PASS_PIDS+=("$!")
}

write_pass_prompt \
  "$PASS_PROMPT_DIR/01-correctness.md" \
  1 \
  "Correctness and regressions" <<'PROMPT'
Review changed production behavior for bugs, edge cases, invalid assumptions,
error handling, compatibility, security, race conditions, data loss,
performance, and appropriate data type handling.

Add a summary section, which summarizes the *intended* PR changes, not the review findings.
Keep the summary factual and concise with bullets and do not mention any of your findings.
PROMPT

write_pass_prompt \
  "$PASS_PROMPT_DIR/02-tests.md" \
  2 \
  "Tests" <<'PROMPT'
Review changed tests and missing tests. Assess whether the tests would actually
catch regressions. Look for weak assertions, missing edge/negative cases,
brittle tests, over-mocking, implementation-detail testing, and changed behavior
without test coverage.
PROMPT

write_pass_prompt \
  "$PASS_PROMPT_DIR/03-maintainability.md" \
  3 \
  "Maintainability and code quality" <<'PROMPT'
Review readability, naming, complexity, duplication, abstractions, coupling,
style, project conventions, and consistency with surrounding code.
PROMPT

write_pass_prompt \
  "$PASS_PROMPT_DIR/04-docs.md" \
  4 \
  "Documentation, comments, and text quality" <<'PROMPT'
Review docs, comments, examples, names, error messages, logs, and
user/developer-facing text as human-facing writing. Look for wording, clarity,
coherence, formatting, structure, reader flow, completeness, terminology
consistency, misleading implications, stale explanations, awkward phrasing, and
general quality.
PROMPT

PASS_LABELS=()
PASS_LOG_FILES=()
PASS_PIDS=()
PASS_STATUS_FILES=()
PASS_STATUS_RENDERED=0

start_review_pass \
  "01-correctness" \
  "Pass 1: Correctness and regressions" \
  "$PASS_PROMPT_DIR/01-correctness.md" \
  "$PASS_OUTPUT_DIR/01-correctness.md"
start_review_pass \
  "02-tests" \
  "Pass 2: Tests" \
  "$PASS_PROMPT_DIR/02-tests.md" \
  "$PASS_OUTPUT_DIR/02-tests.md"
start_review_pass \
  "03-maintainability" \
  "Pass 3: Maintainability and code quality" \
  "$PASS_PROMPT_DIR/03-maintainability.md" \
  "$PASS_OUTPUT_DIR/03-maintainability.md"
start_review_pass \
  "04-docs" \
  "Pass 4: Documentation, comments, and text quality" \
  "$PASS_PROMPT_DIR/04-docs.md" \
  "$PASS_OUTPUT_DIR/04-docs.md"

wait_for_review_passes

{
  cat <<PROMPT
Merge the four Codex review pass reports for PR #${PR} in ${OWNER}/${REPO}.

Return ONLY valid JSON.

Use the pass reports below as the source material. Deduplicate overlapping
findings, resolve contradictions conservatively, and keep only findings that
are concrete and actionable.
Order final findings by severity. Preserve file and line references.
Do not invent new findings that are not supported by the pass reports.

Hard requirements:
- Return a single JSON object.
- Top-level keys must be "body" and "diagnostics".
- "body" must contain the summary of the PR changes, as returned by Pass 1, not the review findings.
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
## Pass 1: Correctness and regressions

PROMPT
  cat "$PASS_OUTPUT_DIR/01-correctness.md"

  cat <<'PROMPT'

## Pass 2: Tests

PROMPT
  cat "$PASS_OUTPUT_DIR/02-tests.md"

  cat <<'PROMPT'

## Pass 3: Maintainability and code quality

PROMPT
  cat "$PASS_OUTPUT_DIR/03-maintainability.md"

  cat <<'PROMPT'

## Pass 4: Documentation, comments, and text quality

PROMPT
  cat "$PASS_OUTPUT_DIR/04-docs.md"
} > "$SYNTHESIS_PROMPT_FILE"

echo "Running Codex review pass: Final synthesis" >&2
(
  cd "$WORKTREE"
  codex "${CODEX_ARGS[@]}" exec review \
    "${CODEX_REVIEW_ARGS[@]}" \
    -c "model_reasoning_effort=\"${CODEX_REVIEW_REASONING_EFFORT:-medium}\"" \
    --title "${TITLE} (Final synthesis)" \
    - \
    < "$SYNTHESIS_PROMPT_FILE" \
    > "$JSON_FILE" \
    2> >(tee -a "$CODEX_LOG_FILE" >&2)
)

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
  echo "## Codex Log"
  echo
  if [[ -s "$CODEX_LOG_FILE" ]]; then
    echo "Full Codex log was printed above."
  else
    echo "(empty)"
  fi
} >&2

{
  echo "## Codex Review"
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

printf 'Codex produced %s high, %s medium, %s low findings.\n' \
  "$high_count" \
  "$medium_count" \
  "$low_count" \
  >&2

{
  echo
  cat "$REVIEW_BODY_FILE"
} >&2

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo
  echo "DRY_RUN=1, not posting GitHub review." >&2
  exit 0
fi

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
