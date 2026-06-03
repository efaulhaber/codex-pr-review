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
PASS_TEMPLATE_DIR="$SCRIPT_DIR/review-prompts"

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

PASS_TEMPLATE_FILES=(
  "$PASS_TEMPLATE_DIR/01-correctness.md"
  "$PASS_TEMPLATE_DIR/02-tests.md"
  "$PASS_TEMPLATE_DIR/03-maintainability.md"
  "$PASS_TEMPLATE_DIR/04-docs.md"
)

for pass_template_file in "${PASS_TEMPLATE_FILES[@]}"; do
  if [[ ! -f "$pass_template_file" ]]; then
    echo "Review pass prompt not found: ${pass_template_file}" >&2
    exit 1
  fi
done

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
PASS_PROMPT_DIR="$TMPDIR/pass-prompts"
PASS_OUTPUT_DIR="$TMPDIR/pass-outputs"
SYNTHESIS_PROMPT_FILE="$TMPDIR/synthesis-prompt.md"
REVIEW_BODY_FILE="$TMPDIR/review-body.md"
REVIEW_PAYLOAD_FILE="$TMPDIR/review-payload.json"

mkdir -p "$ISOLATED_CODEX_HOME" "$PASS_PROMPT_DIR" "$PASS_OUTPUT_DIR"

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
  local pass_template_file="$4"

  {
    echo "Review this PR against origin/${BASE_REF}."
    echo ""
    echo "Use git diff origin/${BASE_REF}...HEAD."
    echo ""
    echo "This is pass ${pass_number} of 4: ${pass_title}."
    echo "Only perform this pass. Do not cover other review categories except where they"
    echo "directly affect this pass."
    echo "Report concrete, actionable findings. If there are no findings for this pass,"
    echo "say so clearly."
    echo ""
    cat "$pass_template_file"
    echo ""
    echo "Output Markdown. Lead with findings, ordered by severity. Include exact file"
    echo "and line references when possible."
    echo ""
    if [[ -n "$CUSTOM_INSTRUCTIONS" ]]; then
      echo "$CUSTOM_INSTRUCTIONS"
      echo ""
    fi
  } > "$prompt_file"
}

run_codex_review() {
  local label="$1"
  local prompt_file="$2"
  local output_file="$3"

  echo "Running Codex review pass: ${label}" >&2
  (
    cd "$WORKTREE"
    codex "${CODEX_ARGS[@]}" exec review \
      "${CODEX_REVIEW_ARGS[@]}" \
      -c "model_reasoning_effort=\"${CODEX_REVIEW_REASONING_EFFORT:-medium}\"" \
      --title "${TITLE} (${label})" \
      - \
      < "$prompt_file" \
      > "$output_file" \
      2> >(tee -a "$CODEX_LOG_FILE" >&2)
  )
}

write_pass_prompt \
  "$PASS_PROMPT_DIR/01-correctness.md" \
  1 \
  "Correctness and regressions" \
  "${PASS_TEMPLATE_FILES[0]}"

write_pass_prompt \
  "$PASS_PROMPT_DIR/02-tests.md" \
  2 \
  "Tests" \
  "${PASS_TEMPLATE_FILES[1]}"

write_pass_prompt \
  "$PASS_PROMPT_DIR/03-maintainability.md" \
  3 \
  "Maintainability and code quality" \
  "${PASS_TEMPLATE_FILES[2]}"

write_pass_prompt \
  "$PASS_PROMPT_DIR/04-docs.md" \
  4 \
  "Documentation, comments, and text quality" \
  "${PASS_TEMPLATE_FILES[3]}"

run_codex_review \
  "Pass 1: Correctness and regressions" \
  "$PASS_PROMPT_DIR/01-correctness.md" \
  "$PASS_OUTPUT_DIR/01-correctness.md"
run_codex_review \
  "Pass 2: Tests" \
  "$PASS_PROMPT_DIR/02-tests.md" \
  "$PASS_OUTPUT_DIR/02-tests.md"
run_codex_review \
  "Pass 3: Maintainability and code quality" \
  "$PASS_PROMPT_DIR/03-maintainability.md" \
  "$PASS_OUTPUT_DIR/03-maintainability.md"
run_codex_review \
  "Pass 4: Documentation, comments, and text quality" \
  "$PASS_PROMPT_DIR/04-docs.md" \
  "$PASS_OUTPUT_DIR/04-docs.md"

{
  echo "Merge the four Codex review pass reports for PR #${PR} in ${OWNER}/${REPO}."
  echo ""
  echo "Use the pass reports below as the source material. Deduplicate overlapping"
  echo "findings, resolve contradictions conservatively, and keep only findings that"
  echo "are concrete and actionable."
  echo "Order final findings by severity. Preserve useful file and line references."
  echo "Do not invent new findings that are not supported by the pass reports."
  echo "If all passes found no issues, say that clearly and mention any residual test"
  echo "or review limitations reported by the passes."
  echo ""
  if [[ -n "$CUSTOM_INSTRUCTIONS" ]]; then
    echo "$CUSTOM_INSTRUCTIONS"
    echo ""
  fi
  echo "## Pass 1: Correctness and regressions"
  echo
  cat "$PASS_OUTPUT_DIR/01-correctness.md"
  echo
  echo "## Pass 2: Tests"
  echo
  cat "$PASS_OUTPUT_DIR/02-tests.md"
  echo
  echo "## Pass 3: Maintainability and code quality"
  echo
  cat "$PASS_OUTPUT_DIR/03-maintainability.md"
  echo
  echo "## Pass 4: Documentation, comments, and text quality"
  echo
  cat "$PASS_OUTPUT_DIR/04-docs.md"
} > "$SYNTHESIS_PROMPT_FILE"

run_codex_review "Final synthesis" "$SYNTHESIS_PROMPT_FILE" "$REVIEW_BODY_FILE"

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
  printf '%s%s\n' \
    "_This is an AI-generated code review. Please verify the findings and summary " \
    "before acting on them._"
  echo
  echo
  cat "$REVIEW_BODY_FILE"
} > "${REVIEW_BODY_FILE}.tmp"
mv "${REVIEW_BODY_FILE}.tmp" "$REVIEW_BODY_FILE"

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
    body: $body
  }' \
  --null-input \
  > "$REVIEW_PAYLOAD_FILE"

env GITHUB_TOKEN="$TOKEN" \
  gh api \
  --method POST \
  "repos/${OWNER}/${REPO}/pulls/${PR}/reviews" \
  --input "$REVIEW_PAYLOAD_FILE" \
  >/dev/null
