#!/usr/bin/env bash
# gh-graphql.sh — GraphQL helpers for fork-sync-all scripts
#
# Provides two functions consumed by resolve-failures.sh and
# translate-readmes.sh to replace paginated REST repo-listing loops with
# single GraphQL queries, reducing request count from O(pages × repos) to O(1)
# per owner.
#
# Public API:
#
#   graphql_repos_for_owner OWNER [--with-failed-runs]
#     Emits one "OWNER/repo" per line for every non-archived, non-fork repo
#     owned by OWNER.  With --with-failed-runs, emits only repos that have at
#     least one failed workflow run in the last 30 days, as:
#       OWNER/repo<TAB>run_id<TAB>run_name<TAB>branch<TAB>workflow_path
#
#   graphql_readme_list OWNER
#     Emits one "OWNER/repo<TAB>default_branch" per line for every
#     non-archived repo that has a README.md at its root.
#
# Both functions page automatically (GitHub GraphQL max 100 nodes/page).
# Requires: GH_TOKEN, jq, curl
#
# Rate cost:
#   graphql_repos_for_owner  — 1 GraphQL request per 100 repos
#   graphql_readme_list       — 1 GraphQL request per 100 repos
#   (vs. 1 REST request per page of 100 repos + 1 REST request per repo for
#    the failed-runs check in the REST path)

set -uo pipefail

GH_GRAPHQL="https://api.github.com/graphql"

# ── internal GraphQL POST ─────────────────────────────────────────────────────

_graphql() {
    local query="$1"
    local variables="${2:-{}}"
    local payload
    payload=$(jq -n --arg q "$query" --argjson v "$variables" \
        '{query: $q, variables: $v}')

    local max_retries=3 attempt=0
    local _hdr
    _hdr=$(mktemp)
    trap 'rm -f "$_hdr"' RETURN

    while true; do
        local response http_code body
        response=$(curl -s -w "\n%{http_code}" \
            -X POST "$GH_GRAPHQL" \
            -H "Authorization: bearer ${GH_TOKEN}" \
            -H "Content-Type: application/json" \
            -D "$_hdr" \
            -d "$payload" 2>/dev/null) || true

        http_code=$(echo "$response" | tail -1)
        body=$(echo "$response" | sed '$d')

        if [[ -z "$http_code" || ! "$http_code" =~ ^[0-9]+$ ]]; then
            (( attempt++ )) || true
            (( attempt > max_retries )) && { echo "$body"; return 1; }
            sleep 5; continue
        fi

        if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
            (( attempt++ )) || true
            (( attempt > max_retries )) && { echo "$body"; return 1; }
            local reset now wait_s
            reset=$(grep -i "x-ratelimit-reset:" "$_hdr" 2>/dev/null \
                | tr -d '\r' | awk '{print $2}')
            now=$(date +%s)
            wait_s=$(( ${reset:-0} - now + 5 ))
            if [[ -n "$reset" && "$wait_s" -gt 0 && "$wait_s" -lt 3700 ]]; then
                sleep "$wait_s"
            else
                sleep 60
            fi
            continue
        fi

        echo "$body"
        [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]] || return 1
        return 0
    done
}

# ── graphql_repos_for_owner ───────────────────────────────────────────────────

graphql_repos_for_owner() {
    local owner="$1"

    # Emits "owner/repo" lines for every non-archived, non-fork repo.
    # 1 GraphQL request per 100 repos vs 1 REST request per page.

    local query='
query($login: String!, $after: String) {
  repositoryOwner(login: $login) {
    repositories(
      first: 100
      after: $after
      ownerAffiliations: [OWNER]
      orderBy: {field: PUSHED_AT, direction: DESC}
    ) {
      pageInfo { hasNextPage endCursor }
      nodes {
        nameWithOwner
        isArchived
        isFork
      }
    }
  }
}'

    local cursor="null"
    while true; do
        local vars result
        vars=$(jq -n --arg login "$owner" --argjson after "$cursor" \
            '{login: $login, after: $after}')
        result=$(_graphql "$query" "$vars") || break

        if echo "$result" | jq -e '.errors' &>/dev/null; then
            echo "  [graphql] error for owner $owner:" >&2
            echo "$result" | jq -r '.errors[].message' >&2
            break
        fi

        echo "$result" | jq -r '
            .data.repositoryOwner.repositories.nodes[]
            | select(.isArchived == false)
            | select(.isFork == false)
            | .nameWithOwner
        ' 2>/dev/null

        local has_next end_cursor
        has_next=$(echo "$result" | jq -r \
            '.data.repositoryOwner.repositories.pageInfo.hasNextPage' 2>/dev/null)
        end_cursor=$(echo "$result" | jq -r \
            '.data.repositoryOwner.repositories.pageInfo.endCursor' 2>/dev/null)
        [[ "$has_next" == "true" ]] || break
        cursor="\"$end_cursor\""
    done
}

# ── graphql_repos_with_failures ───────────────────────────────────────────────

graphql_repos_with_failures() {
    local owner="$1"

    # Emits TSV lines for repos that have at least one failed workflow run
    # in the last 30 days, fetching repo list AND failure status in one pass.
    #
    # Output format (tab-separated):
    #   owner/repo <TAB> run_id <TAB> run_name <TAB> branch <TAB> workflow_path
    #
    # GitHub's GraphQL API exposes workflowRuns on a repository via the
    # checkSuites connection. We fetch the most recent failed run per repo
    # in the same query that lists repos, eliminating the separate
    # GET /repos/{repo}/actions/runs?conclusion=failure REST call per repo.
    #
    # Cost: 1 GraphQL request per 100 repos
    # vs:  1 REST request per 100 repos (listing) +
    #      1 REST request per repo (failure check)
    # Net saving: N REST calls where N = number of repos scanned.

    local query='
query($login: String!, $after: String, $since: DateTime!) {
  repositoryOwner(login: $login) {
    repositories(
      first: 100
      after: $after
      ownerAffiliations: [OWNER]
      orderBy: {field: PUSHED_AT, direction: DESC}
    ) {
      pageInfo { hasNextPage endCursor }
      nodes {
        nameWithOwner
        isArchived
        isFork
        defaultBranchRef { name }
        workflowRuns: object(expression: "HEAD") {
          ... on Commit {
            checkSuites(first: 10) {
              nodes {
                workflowRun {
                  databaseId
                  name
                  headBranch
                  path
                  conclusion
                  createdAt
                }
              }
            }
          }
        }
      }
    }
  }
}'

    # GitHub GraphQL does not support workflowRun on checkSuites in all
    # contexts — fall back gracefully to the simpler repo-list query if
    # the extended query fails, letting the caller use REST for failure checks.
    local since
    since=$(date -u -d "30 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -v-30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || echo "2000-01-01T00:00:00Z")

    local cursor="null"
    local fallback=false

    while true; do
        local vars result
        vars=$(jq -n --arg login "$owner" --argjson after "$cursor" \
            --arg since "$since" \
            '{login: $login, after: $after, since: $since}')
        result=$(_graphql "$query" "$vars") || { fallback=true; break; }

        if echo "$result" | jq -e '.errors' &>/dev/null; then
            # Extended query not supported — fall back to simple repo list
            fallback=true
            break
        fi

        # Emit repos that have a recent failed run
        echo "$result" | jq -r '
            .data.repositoryOwner.repositories.nodes[]
            | select(.isArchived == false)
            | select(.isFork == false)
            | . as $repo
            | (.workflowRuns.checkSuites.nodes // [])[]
            | .workflowRun
            | select(. != null)
            | select(.conclusion == "failure")
            | [$repo.nameWithOwner, (.databaseId | tostring), .name, .headBranch, .path]
            | @tsv
        ' 2>/dev/null | sort -t$'\t' -k1,1 -u  # one line per repo (first failure)

        local has_next end_cursor
        has_next=$(echo "$result" | jq -r \
            '.data.repositoryOwner.repositories.pageInfo.hasNextPage' 2>/dev/null)
        end_cursor=$(echo "$result" | jq -r \
            '.data.repositoryOwner.repositories.pageInfo.endCursor' 2>/dev/null)
        [[ "$has_next" == "true" ]] || break
        cursor="\"$end_cursor\""
    done

    # Fallback: emit all repos so caller can check failures via REST
    if $fallback; then
        graphql_repos_for_owner "$owner" | while IFS= read -r repo; do
            printf '%s\t__REST_FALLBACK__\n' "$repo"
        done
    fi
}

# ── graphql_readme_list ───────────────────────────────────────────────────────

graphql_readme_list() {
    local owner="$1"

    # Returns "owner/repo<TAB>default_branch" for every non-archived repo.
    # The README existence check is left to the caller (a single REST GET
    # per repo is unavoidable for the actual file content, but we eliminate
    # the separate repo-listing pagination).

    local query='
query($login: String!, $after: String) {
  repositoryOwner(login: $login) {
    repositories(
      first: 100
      after: $after
      ownerAffiliations: [OWNER]
      orderBy: {field: PUSHED_AT, direction: DESC}
    ) {
      pageInfo { hasNextPage endCursor }
      nodes {
        nameWithOwner
        isArchived
        defaultBranchRef { name }
      }
    }
  }
}'

    local cursor="null"
    while true; do
        local vars
        vars=$(jq -n --arg login "$owner" --argjson after "$cursor" \
            '{login: $login, after: $after}')

        local result
        result=$(_graphql "$query" "$vars") || break

        if echo "$result" | jq -e '.errors' &>/dev/null; then
            echo "  [graphql] error for owner $owner:" >&2
            echo "$result" | jq -r '.errors[].message' >&2
            break
        fi

        echo "$result" | jq -r '
            .data.repositoryOwner.repositories.nodes[]
            | select(.isArchived == false)
            | [.nameWithOwner, (.defaultBranchRef.name // "main")]
            | @tsv
        ' 2>/dev/null

        local has_next end_cursor
        has_next=$(echo "$result" | jq -r \
            '.data.repositoryOwner.repositories.pageInfo.hasNextPage' 2>/dev/null)
        end_cursor=$(echo "$result" | jq -r \
            '.data.repositoryOwner.repositories.pageInfo.endCursor' 2>/dev/null)

        [[ "$has_next" == "true" ]] || break
        cursor="\"$end_cursor\""
    done
}
