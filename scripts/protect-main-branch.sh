#!/usr/bin/env bash
# Apply NotchFlow's main-branch protection through the GitHub API.
#
# Requires `gh auth login` with repository administration access. This is
# intentionally an explicit maintenance command: branch protection is remote
# repository state, not source-controlled workflow configuration.
set -euo pipefail

repository="${1:-sidhxntt/NotchFlow}"

gh api --method PUT "repos/${repository}/branches/main/protection" \
  --header 'Accept: application/vnd.github+json' \
  --header 'X-GitHub-Api-Version: 2022-11-28' \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["Validate Pull Request / app-verification"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0,
    "require_last_push_approval": false
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON
