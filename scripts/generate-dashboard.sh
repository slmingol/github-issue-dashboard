#!/bin/bash

# GitHub Issue Dashboard Generator
# Fetches all repos and open issues/PRs, generates HTML dashboard for GitHub Pages

OUTPUT_FILE="docs/index.html"
STATE_FILE="docs/state.json"
USERNAME="slmingol"
MAX_PARALLEL=8

mkdir -p docs

echo "🔍 Fetching repository list..."

ALL_REPO_DATA=$(gh repo list "$USERNAME" --limit 200 \
  --json name,owner,hasIssuesEnabled,isArchived,repositoryTopics,isFork,parent)

REPOS=$(echo "$ALL_REPO_DATA" | jq -r \
  '.[] | select((.hasIssuesEnabled or .isFork) and (.isArchived | not)) |
   if ((.repositoryTopics // []) | map(.name) | any(. == "eol" or . == "end-of-life"))
   then empty else "\(.owner.login)/\(.name)" end')

EOL_REPOS=$(echo "$ALL_REPO_DATA" | \
  jq '[.[] | select((.repositoryTopics // []) | map(.name) | any(. == "eol" or . == "end-of-life"))] | length')

FORK_COUNT=$(echo "$ALL_REPO_DATA" | jq '[.[] | select(.isFork)] | length')

UPSTREAM_PAIRS=$(echo "$ALL_REPO_DATA" | \
  jq -r '.[] | select(.isFork and (.parent != null)) | "\(.parent.owner.login)/\(.parent.name)|\(.name)"' | sort -u)

# Repos where slmingol has open PRs but doesn't own (org repos, third-party contributions)
CONTRIBUTED_REPOS=$(gh search prs --author "$USERNAME" --state open --limit 100 --json repository \
  2>/dev/null | jq -r '.[].repository.nameWithOwner' | sort -u | \
  grep -v "^${USERNAME}/" || true)

TOTAL_REPOS=$(echo "$REPOS" | grep -c . || echo 0)

# Load previous state for new-item diff
PREV_STATE="{}"
[ -f "$STATE_FILE" ] && PREV_STATE=$(cat "$STATE_FILE")

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# ── fetch functions (run in background subshells) ─────────────────────────────

fetch_own_repo() {
  local repo=$1
  local key; key=$(echo "$repo" | tr '/' '__')
  local out="$WORK_DIR/own_${key}.json"

  local ISSUES PRS ISSUE_COUNT PR_COUNT ASSIGNED WITH_MILESTONE
  local NEWEST_ISSUE_TS NEWEST_PR_TS NEWEST_TS

  ISSUES=$(gh issue list --repo "$repo" --state open \
    --json number,title,labels,createdAt,updatedAt,url,milestone,assignees 2>/dev/null || echo "[]")
  PRS=$(gh pr list --repo "$repo" --state open \
    --json number,title,labels,createdAt,updatedAt,url,milestone,assignees,isDraft,reviewDecision,headRefName,statusCheckRollup \
    2>/dev/null || echo "[]")

  ISSUE_COUNT=$(echo "$ISSUES" | jq '. | length')
  PR_COUNT=$(echo "$PRS"    | jq '. | length')
  [ "$ISSUE_COUNT" -eq 0 ] && [ "$PR_COUNT" -eq 0 ] && return

  ASSIGNED=$(echo "$ISSUES" | jq '[.[] | select(.assignees | length > 0)] | length')
  WITH_MILESTONE=$(echo "$ISSUES" | jq '[.[] | select(.milestone != null)] | length')
  NEWEST_ISSUE_TS=$(echo "$ISSUES" | jq -r 'if length>0 then [.[].createdAt]|max|fromdate else 0 end')
  NEWEST_PR_TS=$(echo "$PRS"    | jq -r 'if length>0 then [.[].createdAt]|max|fromdate else 0 end')
  NEWEST_TS=$(( NEWEST_ISSUE_TS > NEWEST_PR_TS ? NEWEST_ISSUE_TS : NEWEST_PR_TS ))

  jq -n \
    --arg    repo           "$repo" \
    --argjson issue_count   "$ISSUE_COUNT" \
    --argjson pr_count      "$PR_COUNT" \
    --argjson assigned      "$ASSIGNED" \
    --argjson with_milestone "$WITH_MILESTONE" \
    --argjson newest_ts     "$NEWEST_TS" \
    --argjson issues        "$ISSUES" \
    --argjson prs           "$PRS" \
    '{repo:$repo,issue_count:$issue_count,pr_count:$pr_count,
      assigned:$assigned,with_milestone:$with_milestone,
      newest_ts:$newest_ts,issues:$issues,prs:$prs}' > "$out"
}

fetch_upstream() {
  local upstream_repo=$1 fork_name=$2
  local key; key=$(echo "$upstream_repo" | tr '/' '__')
  local out="$WORK_DIR/upstream_${key}.json"

  # Skip archived repos — PRs will never be merged
  local is_archived
  is_archived=$(gh repo view "$upstream_repo" --json isArchived 2>/dev/null | jq -r '.isArchived // false')
  [ "$is_archived" = "true" ] && return

  local MY_PRS UP_ISSUES MY_PR_COUNT UP_ISSUE_COUNT
  local MY_PR_TS UP_ISS_TS NEWEST_TS

  MY_PRS=$(gh pr list --repo "$upstream_repo" --state open --author "$USERNAME" \
    --json number,title,labels,createdAt,updatedAt,url,milestone,assignees,isDraft,reviewDecision,headRefName,statusCheckRollup \
    2>/dev/null || echo "[]")
  # Drop PRs older than 730 days — stale upstream PRs are unlikely to ever merge
  MY_PRS=$(echo "$MY_PRS" | jq '[.[] | select(((now - (.createdAt | fromdateiso8601)) / 86400) < 730)]')
  UP_ISSUES=$(gh issue list --repo "$upstream_repo" --state open --limit 30 \
    --json number,title,labels,createdAt,updatedAt,url,milestone,assignees 2>/dev/null || echo "[]")

  MY_PR_COUNT=$(echo "$MY_PRS"    | jq '. | length')
  UP_ISSUE_COUNT=$(echo "$UP_ISSUES" | jq '. | length')
  [ "$MY_PR_COUNT" -eq 0 ] && [ "$UP_ISSUE_COUNT" -eq 0 ] && return

  MY_PR_TS=$(echo "$MY_PRS"    | jq -r 'if length>0 then [.[].createdAt]|max|fromdate else 0 end')
  UP_ISS_TS=$(echo "$UP_ISSUES" | jq -r 'if length>0 then [.[].createdAt]|max|fromdate else 0 end')
  NEWEST_TS=$(( MY_PR_TS > UP_ISS_TS ? MY_PR_TS : UP_ISS_TS ))

  jq -n \
    --arg    upstream_repo   "$upstream_repo" \
    --arg    fork_name       "$fork_name" \
    --argjson my_pr_count    "$MY_PR_COUNT" \
    --argjson up_issue_count "$UP_ISSUE_COUNT" \
    --argjson newest_ts      "$NEWEST_TS" \
    --argjson my_prs         "$MY_PRS" \
    --argjson up_issues      "$UP_ISSUES" \
    '{upstream_repo:$upstream_repo,fork_name:$fork_name,
      my_pr_count:$my_pr_count,up_issue_count:$up_issue_count,
      newest_ts:$newest_ts,my_prs:$my_prs,up_issues:$up_issues}' > "$out"
}

# ── throttled parallel launcher ───────────────────────────────────────────────
run_parallel() {
  local cmd="$1"; shift
  local PIDS=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    $cmd "$line" &
    PIDS+=($!)
    while [ ${#PIDS[@]} -ge $MAX_PARALLEL ]; do
      local NEW_PIDS=()
      for pid in "${PIDS[@]}"; do
        kill -0 "$pid" 2>/dev/null && NEW_PIDS+=("$pid")
      done
      PIDS=("${NEW_PIDS[@]}")
      [ ${#PIDS[@]} -ge $MAX_PARALLEL ] && sleep 0.2
    done
  done
  wait
}

run_parallel_pairs() {
  local cmd="$1"
  local PIDS=()
  while IFS='|' read -r a b; do
    [ -z "$a" ] && continue
    $cmd "$a" "$b" &
    PIDS+=($!)
    while [ ${#PIDS[@]} -ge $MAX_PARALLEL ]; do
      local NEW_PIDS=()
      for pid in "${PIDS[@]}"; do
        kill -0 "$pid" 2>/dev/null && NEW_PIDS+=("$pid")
      done
      PIDS=("${NEW_PIDS[@]}")
      [ ${#PIDS[@]} -ge $MAX_PARALLEL ] && sleep 0.2
    done
  done
  wait
}

echo "📝 Fetching own repo data (parallel, max ${MAX_PARALLEL} concurrent)..."
run_parallel fetch_own_repo <<< "$REPOS"
echo "✓ Own repo fetches complete"

echo "⬆️  Fetching upstream data (parallel)..."
run_parallel_pairs fetch_upstream <<< "$UPSTREAM_PAIRS"
echo "✓ Upstream fetches complete"

# Contributed repos: open PRs on repos not owned by user and not already fetched as fork-upstream
UPSTREAM_REPOS_TRACKED=$(echo "$UPSTREAM_PAIRS" | cut -d'|' -f1 | sort -u)
CONTRIBUTED_PAIRS=$(echo "$CONTRIBUTED_REPOS" | while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  echo "$UPSTREAM_REPOS_TRACKED" | grep -qxF "$repo" && continue
  echo "${repo}|"
done)

if [ -n "$CONTRIBUTED_PAIRS" ]; then
  echo "🔀 Fetching contributed repo data (parallel)..."
  run_parallel_pairs fetch_upstream <<< "$CONTRIBUTED_PAIRS"
  echo "✓ Contributed repo fetches complete"
fi

# ── aggregate stats ───────────────────────────────────────────────────────────

TOTAL_ISSUES=0; TOTAL_PRS=0; REPOS_WITH_ACTIVITY=0
TOTAL_ASSIGNED=0; TOTAL_WITH_MILESTONE=0
UPSTREAM_MY_PRS=0; UPSTREAM_ISSUES_TOTAL=0
UPSTREAM_REPOS_WITH_MY_PRS=0; UPSTREAM_REPOS_WITH_ISSUES=0

for f in "$WORK_DIR"/own_*.json; do
  [ -f "$f" ] || continue
  TOTAL_ISSUES=$((TOTAL_ISSUES   + $(jq -r '.issue_count'   "$f")))
  TOTAL_PRS=$((TOTAL_PRS         + $(jq -r '.pr_count'      "$f")))
  TOTAL_ASSIGNED=$((TOTAL_ASSIGNED + $(jq -r '.assigned'    "$f")))
  TOTAL_WITH_MILESTONE=$((TOTAL_WITH_MILESTONE + $(jq -r '.with_milestone' "$f")))
  ((REPOS_WITH_ACTIVITY++))
done

for f in "$WORK_DIR"/upstream_*.json; do
  [ -f "$f" ] || continue
  mpc=$(jq -r '.my_pr_count'    "$f"); uic=$(jq -r '.up_issue_count' "$f")
  UPSTREAM_MY_PRS=$((UPSTREAM_MY_PRS         + mpc))
  UPSTREAM_ISSUES_TOTAL=$((UPSTREAM_ISSUES_TOTAL + uic))
  [ "$mpc" -gt 0 ] && ((UPSTREAM_REPOS_WITH_MY_PRS++))
  [ "$uic" -gt 0 ] && ((UPSTREAM_REPOS_WITH_ISSUES++))
done

LAST_UPDATED=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

# ── build new state (for next run diff) ───────────────────────────────────────

NEW_STATE='{"own_issues":{},"own_prs":{},"upstream_prs":{}}'
for f in "$WORK_DIR"/own_*.json; do
  [ -f "$f" ] || continue
  repo=$(jq -r '.repo' "$f")
  inums=$(jq '[.issues[].number]' "$f")
  pnums=$(jq '[.prs[].number]'    "$f")
  NEW_STATE=$(echo "$NEW_STATE" | jq \
    --arg repo "$repo" --argjson i "$inums" --argjson p "$pnums" \
    '.own_issues[$repo]=$i | .own_prs[$repo]=$p')
done
for f in "$WORK_DIR"/upstream_*.json; do
  [ -f "$f" ] || continue
  up=$(jq -r '.upstream_repo' "$f")
  pnums=$(jq '[.my_prs[].number]' "$f")
  NEW_STATE=$(echo "$NEW_STATE" | jq \
    --arg up "$up" --argjson p "$pnums" '.upstream_prs[$up]=$p')
done

# ── helpers ───────────────────────────────────────────────────────────────────

age_class_icon() {
  local days=$1
  if   [ "$days" -ge 90 ]; then echo "age-old   🕰️"
  elif [ "$days" -ge 30 ]; then echo "age-month 📅"
  elif [ "$days" -ge 7  ]; then echo "age-week  🗓️"
  else                          echo "age-new   🆕"
  fi
}

priority_from_labels() {
  echo "$1" | jq -r '
    .labels | map(.name | ascii_downcase) |
    if   any(. == "critical" or . == "p0" or . == "blocker" or . == "urgent") then "critical"
    elif any(. == "high"     or . == "p1" or . == "high-priority"   or . == "priority: high")   then "high"
    elif any(. == "medium"   or . == "p2" or . == "medium-priority" or . == "priority: medium") then "medium"
    elif any(. == "low"      or . == "p3" or . == "low-priority"    or . == "priority: low" or . == "minor") then "low"
    else "none" end'
}

ci_status_from_rollup() {
  echo "$1" | jq -r '
    .statusCheckRollup // [] |
    if length == 0 then "none"
    elif any(.state == "FAILURE" or .state == "ERROR" or .state == "TIMED_OUT" or .state == "CANCELLED") then "failure"
    elif any(.state == "PENDING" or .state == "WAITING" or .state == "EXPECTED" or .state == "IN_PROGRESS") then "pending"
    elif all(.state == "SUCCESS" or .state == "NEUTRAL" or .state == "SKIPPED") then "success"
    else "none" end'
}

is_new() {
  local num="$1" prev_nums="$2"
  echo " $prev_nums " | grep -q " ${num} " && echo "false" || echo "true"
}

emit_issue_rows() {
  local issues="$1" repo_name="$2" prev_nums="$3"
  echo "$issues" | jq -r 'sort_by(.createdAt) | reverse | .[] | @json' | while read -r ij; do
    local NUM TITLE URL LABELS_HTML CREATED UPDATED CREATED_TS DAYS_OLD
    NUM=$(echo "$ij" | jq -r '.number')
    TITLE=$(echo "$ij" | jq -r '.title' | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    URL=$(echo "$ij" | jq -r '.url')
    LABELS_HTML=$(echo "$ij" | jq -r '.labels | if length==0 then "—" else map("<span class=\"label-tag\">\(.name)</span>") | join(" ") end')
    CREATED=$(echo "$ij" | jq -r '.createdAt | fromdate | strftime("%Y-%m-%d")')
    UPDATED=$(echo "$ij" | jq -r '.updatedAt | fromdate | strftime("%Y-%m-%d")')
    CREATED_TS=$(echo "$ij" | jq -r '.createdAt | fromdate')
    DAYS_OLD=$(( ($(date +%s) - CREATED_TS) / 86400 ))

    read -r AGE_CLASS AGE_ICON <<< "$(age_class_icon "$DAYS_OLD")"
    local PRIORITY; PRIORITY=$(priority_from_labels "$ij")
    local PRI_DISPLAY
    case "$PRIORITY" in
      critical) PRI_DISPLAY='<span class="pri-critical">🔴 Critical</span>' ;;
      high)     PRI_DISPLAY='<span class="pri-high">🟠 High</span>'         ;;
      medium)   PRI_DISPLAY='<span class="pri-medium">🟡 Medium</span>'     ;;
      low)      PRI_DISPLAY='<span class="pri-low">🔵 Low</span>'           ;;
      *)        PRI_DISPLAY='<span class="pri-none">—</span>'               ;;
    esac

    local ASSIGNEES_HTML HAS_ASSIGNEE MILESTONE_TITLE HAS_MILESTONE MILESTONE_DISPLAY
    ASSIGNEES_HTML=$(echo "$ij" | jq -r '.assignees | if length==0 then "—" else map("<a href=\"https://github.com/\(.login)\">\(.login)</a>") | join(", ") end')
    HAS_ASSIGNEE=$(echo "$ij" | jq -r 'if (.assignees|length)>0 then "true" else "false" end')
    MILESTONE_TITLE=$(echo "$ij" | jq -r '.milestone | if .==null then "" else .title | gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;") end')
    HAS_MILESTONE=$(echo "$ij" | jq -r 'if .milestone!=null then "true" else "false" end')
    [ "$HAS_MILESTONE" = "true" ] \
      && MILESTONE_DISPLAY="<span class=\"milestone-tag\">🏁 $MILESTONE_TITLE</span>" \
      || MILESTONE_DISPLAY="—"

    local IS_NEW NEW_BADGE ROW_CLASS
    IS_NEW=$(is_new "$NUM" "$prev_nums")
    [ "$IS_NEW" = "true" ] && NEW_BADGE='<span class="new-badge">NEW</span>' && ROW_CLASS="issue-row new-item" || NEW_BADGE="" && ROW_CLASS="issue-row"

    cat >> "$OUTPUT_FILE" << ISSUE_ROW
<tr class="$ROW_CLASS" data-type="issue" data-age="$DAYS_OLD" data-priority="$PRIORITY" data-assigned="$HAS_ASSIGNEE" data-milestone="$HAS_MILESTONE" data-repo="$repo_name">
  <td class="num"><a href="$URL"><b>#$NUM</b></a></td>
  <td class="type-cell"><span class="type-issue">🐛 Issue</span></td>
  <td>$TITLE $NEW_BADGE</td>
  <td class="age"><span class="$AGE_CLASS">$AGE_ICON ${DAYS_OLD}d</span></td>
  <td class="status">$PRI_DISPLAY</td>
  <td class="labels">$LABELS_HTML</td>
  <td class="assignee">$ASSIGNEES_HTML</td>
  <td class="milestone">$MILESTONE_DISPLAY</td>
  <td class="date">$CREATED</td>
  <td class="date">$UPDATED</td>
</tr>
ISSUE_ROW
  done
}

emit_pr_rows() {
  local prs="$1" repo_name="$2" prev_nums="$3"
  echo "$prs" | jq -r 'sort_by(.createdAt) | reverse | .[] | @json' | while read -r pj; do
    local NUM TITLE URL CREATED UPDATED CREATED_TS DAYS_OLD IS_DRAFT REVIEW_DECISION BRANCH
    NUM=$(echo "$pj" | jq -r '.number')
    TITLE=$(echo "$pj" | jq -r '.title' | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    URL=$(echo "$pj" | jq -r '.url')
    CREATED=$(echo "$pj" | jq -r '.createdAt | fromdate | strftime("%Y-%m-%d")')
    UPDATED=$(echo "$pj" | jq -r '.updatedAt | fromdate | strftime("%Y-%m-%d")')
    CREATED_TS=$(echo "$pj" | jq -r '.createdAt | fromdate')
    DAYS_OLD=$(( ($(date +%s) - CREATED_TS) / 86400 ))
    IS_DRAFT=$(echo "$pj" | jq -r '.isDraft')
    REVIEW_DECISION=$(echo "$pj" | jq -r '.reviewDecision // "null"')
    BRANCH=$(echo "$pj" | jq -r '.headRefName' | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

    read -r AGE_CLASS AGE_ICON <<< "$(age_class_icon "$DAYS_OLD")"

    local CI_STATUS CI_BADGE
    CI_STATUS=$(ci_status_from_rollup "$pj")
    case "$CI_STATUS" in
      success) CI_BADGE='<span class="ci-pass" title="CI passing">✅</span>'   ;;
      failure) CI_BADGE='<span class="ci-fail" title="CI failing">❌</span>'   ;;
      pending) CI_BADGE='<span class="ci-pend" title="CI pending">⏳</span>'   ;;
      *)       CI_BADGE=''                                                        ;;
    esac

    local TYPE_BADGE STATUS_DISPLAY WAITING_TAG
    if [ "$IS_DRAFT" = "true" ]; then
      TYPE_BADGE='<span class="type-pr draft">📝 Draft</span>'
      STATUS_DISPLAY="<span class=\"rv-none\">Draft</span> $CI_BADGE"
      WAITING_TAG=''
    else
      TYPE_BADGE='<span class="type-pr">🔀 PR</span>'
      case "$REVIEW_DECISION" in
        APPROVED)          STATUS_DISPLAY="<span class=\"rv-approved\">✓ Approved</span> $CI_BADGE"
                           WAITING_TAG='<span class="waiting-tag waiting-merge">✅ Ready</span>'    ;;
        CHANGES_REQUESTED) STATUS_DISPLAY="<span class=\"rv-changes\">✗ Changes</span> $CI_BADGE"
                           WAITING_TAG='<span class="waiting-tag waiting-you">⚡ Your turn</span>'  ;;
        REVIEW_REQUIRED)   STATUS_DISPLAY="<span class=\"rv-review\">⧖ Review</span> $CI_BADGE"
                           WAITING_TAG='<span class="waiting-tag waiting-them">⏳ Their turn</span>' ;;
        *)                 STATUS_DISPLAY="<span class=\"rv-none\">—</span> $CI_BADGE"
                           WAITING_TAG='<span class="waiting-tag waiting-them">⏳ Their turn</span>' ;;
      esac
    fi

    local LABELS_HTML ASSIGNEES_HTML HAS_ASSIGNEE MILESTONE_TITLE HAS_MILESTONE MILESTONE_DISPLAY
    LABELS_HTML=$(echo "$pj" | jq -r '.labels | if length==0 then "—" else map("<span class=\"label-tag\">\(.name)</span>") | join(" ") end')
    ASSIGNEES_HTML=$(echo "$pj" | jq -r '.assignees | if length==0 then "—" else map("<a href=\"https://github.com/\(.login)\">\(.login)</a>") | join(", ") end')
    HAS_ASSIGNEE=$(echo "$pj" | jq -r 'if (.assignees|length)>0 then "true" else "false" end')
    MILESTONE_TITLE=$(echo "$pj" | jq -r '.milestone | if .==null then "" else .title | gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;") end')
    HAS_MILESTONE=$(echo "$pj" | jq -r 'if .milestone!=null then "true" else "false" end')
    [ "$HAS_MILESTONE" = "true" ] \
      && MILESTONE_DISPLAY="<span class=\"milestone-tag\">🏁 $MILESTONE_TITLE</span>" \
      || MILESTONE_DISPLAY="—"

    local IS_NEW NEW_BADGE ROW_CLASS
    IS_NEW=$(is_new "$NUM" "$prev_nums")
    [ "$IS_NEW" = "true" ] && NEW_BADGE='<span class="new-badge">NEW</span>' && ROW_CLASS="issue-row pr-row new-item" || NEW_BADGE="" && ROW_CLASS="issue-row pr-row"

    cat >> "$OUTPUT_FILE" << PR_ROW
<tr class="$ROW_CLASS" data-type="pr" data-age="$DAYS_OLD" data-priority="none" data-assigned="$HAS_ASSIGNEE" data-milestone="$HAS_MILESTONE" data-repo="$repo_name" data-ci="$CI_STATUS">
  <td class="num"><a href="$URL"><b>#$NUM</b></a></td>
  <td class="type-cell"><span style="font-size:0.7em;color:#8b949e;display:block">$BRANCH</span>$TYPE_BADGE $WAITING_TAG</td>
  <td>$TITLE $NEW_BADGE</td>
  <td class="age"><span class="$AGE_CLASS">$AGE_ICON ${DAYS_OLD}d</span></td>
  <td class="status">$STATUS_DISPLAY</td>
  <td class="labels">$LABELS_HTML</td>
  <td class="assignee">$ASSIGNEES_HTML</td>
  <td class="milestone">$MILESTONE_DISPLAY</td>
  <td class="date">$CREATED</td>
  <td class="date">$UPDATED</td>
</tr>
PR_ROW
  done
}

TABLE_HEADER='<table>
<thead><tr>
  <th class="center">#</th>
  <th style="width:110px">Type / Branch</th>
  <th>Title</th>
  <th class="center">Age</th>
  <th class="center">Pri / Status</th>
  <th>Labels</th>
  <th>Assignees</th>
  <th>Milestone</th>
  <th class="center">Created</th>
  <th class="center">Updated</th>
</tr></thead>
<tbody>'

# ── HTML head ─────────────────────────────────────────────────────────────────

cat > "$OUTPUT_FILE" << HTML_HEAD
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>GitHub Issue Dashboard</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
    background: #0d1117; color: #c9d1d9; padding: 0 24px 32px; font-size: 14px;
  }
  a { color: #58a6ff; text-decoration: none; }
  a:hover { text-decoration: underline; }

  header { text-align: center; padding: 32px 0 24px; }
  header h1 { font-size: 2em; color: #e6edf3; margin-bottom: 8px; }
  header p { color: #8b949e; }
  .updated { font-size: 0.85em; color: #8b949e; margin-top: 8px; }
  .updated code { background: #161b22; padding: 2px 6px; border-radius: 4px; }

  .stats { display: flex; gap: 12px; flex-wrap: wrap; justify-content: center; margin-bottom: 28px; }
  .stat {
    background: #161b22; border: 1px solid #30363d; border-radius: 8px;
    padding: 14px 20px; text-align: center; min-width: 110px;
  }
  .stat-number        { font-size: 1.8em; font-weight: 700; color: #58a6ff; }
  .stat-number.green  { color: #3fb950; }
  .stat-number.muted  { color: #484f58; }
  .stat-label { font-size: 0.75em; color: #8b949e; margin-top: 4px; }
  .stat-section-label {
    flex-basis: 100%; text-align: center; font-size: 0.7em; font-weight: 600;
    color: #8b949e; text-transform: uppercase; letter-spacing: 0.08em; margin-bottom: -4px;
  }

  h2 { font-size: 1.2em; color: #e6edf3; margin-bottom: 16px; padding-bottom: 8px; border-bottom: 1px solid #21262d; }

  /* Sticky controls */
  .controls {
    position: sticky; top: 0; z-index: 100;
    background: #0d1117; border-bottom: 1px solid #21262d;
    padding: 12px 0; margin-bottom: 24px;
  }
  .controls-inner {
    background: #161b22; border: 1px solid #30363d; border-radius: 8px;
    padding: 12px 16px; display: flex; flex-wrap: wrap; gap: 12px; align-items: flex-start;
  }
  .ctrl-group { display: flex; flex-direction: column; gap: 5px; }
  .ctrl-label { font-size: 0.68em; font-weight: 600; color: #8b949e; text-transform: uppercase; letter-spacing: 0.05em; }
  .ctrl-buttons { display: flex; gap: 4px; flex-wrap: wrap; align-items: center; }
  .ctrl-btn {
    font-size: 0.76em; padding: 2px 9px; border-radius: 12px; border: 1px solid #30363d;
    background: #21262d; color: #c9d1d9; cursor: pointer; transition: all 0.1s;
  }
  .ctrl-btn:hover { border-color: #58a6ff; color: #58a6ff; }
  .ctrl-btn.active { background: #1f6feb; border-color: #1f6feb; color: #fff; }
  .search-input {
    font-size: 0.76em; padding: 2px 10px; border-radius: 12px; border: 1px solid #30363d;
    background: #21262d; color: #c9d1d9; width: 160px; outline: none;
  }
  .search-input:focus { border-color: #58a6ff; }
  .ctrl-sep { width: 1px; background: #30363d; align-self: stretch; margin: 0 4px; }
  .export-btn {
    font-size: 0.76em; padding: 2px 9px; border-radius: 12px; border: 1px solid #30363d;
    background: #21262d; color: #8b949e; cursor: pointer;
  }
  .export-btn:hover { border-color: #3fb950; color: #3fb950; }
  .refresh-btn:hover { border-color: #58a6ff; color: #58a6ff; }
  .refresh-btn:disabled { opacity: 0.6; cursor: default; }
  .filter-count { font-size: 0.78em; color: #8b949e; align-self: center; margin-left: auto; white-space: nowrap; }

  details { margin-bottom: 14px; border: 1px solid #30363d; border-radius: 8px; overflow: hidden; }
  details[open] summary { border-bottom: 1px solid #30363d; }
  summary {
    padding: 10px 14px; cursor: pointer; background: #161b22;
    display: flex; align-items: center; gap: 10px; list-style: none;
  }
  summary::-webkit-details-marker { display: none; }
  summary::before { content: "▶"; font-size: 0.7em; color: #8b949e; transition: transform 0.15s; }
  details[open] summary::before { transform: rotate(90deg); }
  summary h3 { font-size: 1em; color: #58a6ff; }
  summary h3.upstream-pr-title  { color: #3fb950; }
  summary h3.upstream-iss-title { color: #484f58; }
  summary .fork-of { font-size: 0.72em; color: #8b949e; margin-left: 6px; }
  summary .badge {
    margin-left: auto; font-size: 0.72em; font-weight: 600;
    padding: 2px 8px; border-radius: 12px; background: #21262d; color: #c9d1d9;
  }
  summary .badge.red    { background: #5d1a1a; color: #f97583; }
  summary .badge.orange { background: #3d2000; color: #e3a63a; }
  summary .badge.yellow { background: #2e2000; color: #d29922; }
  summary .badge.green  { background: #0f2d1a; color: #3fb950; }
  summary .badge.upr-red  { background: #0f2d1a; color: #3fb950; }
  summary .badge.upr-orng { background: #0f2d1a; color: #56d364; }
  summary .badge.upr-yelw { background: #0f2d1a; color: #7ee787; }
  summary .badge.upr-grn  { background: #0f2d1a; color: #aff5b4; }
  summary .badge.uis { background: #161b22; color: #484f58; border: 1px solid #21262d; }

  .section-divider { margin: 36px 0 20px; padding-top: 20px; border-top: 2px solid #21262d; }
  .section-note { font-size: 0.7em; color: #484f58; font-weight: 400; margin-left: 10px; }

  table { width: 100%; border-collapse: collapse; }
  th {
    background: #161b22; padding: 7px 10px; text-align: left;
    font-size: 0.78em; color: #8b949e; font-weight: 600;
    border-bottom: 1px solid #30363d; white-space: nowrap;
  }
  th.center { text-align: center; }
  td { padding: 7px 10px; border-bottom: 1px solid #21262d; vertical-align: middle; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: #1c2128; }
  tr.hidden { display: none; }
  tr.pr-row td { background: rgba(63,185,80,0.025); }
  tr.pr-row:hover td { background: rgba(63,185,80,0.06); }
  tr.new-item > td:first-child { border-left: 3px solid #3fb950; }
  .new-badge {
    display: inline-block; font-size: 0.65em; padding: 0 5px; border-radius: 4px;
    background: #0f2d1a; color: #3fb950; font-weight: 700; letter-spacing: 0.05em;
    vertical-align: middle; margin-left: 4px;
  }
  td.num       { text-align: center; white-space: nowrap; width: 52px; }
  td.type-cell { white-space: nowrap; width: 110px; }
  td.age       { text-align: center; white-space: nowrap; width: 72px; font-size: 0.9em; }
  td.status    { text-align: center; white-space: nowrap; width: 100px; }
  td.labels    { width: 16%; font-size: 0.8em; color: #8b949e; }
  td.assignee  { width: 9%;  font-size: 0.8em; }
  td.milestone { width: 9%;  font-size: 0.8em; }
  td.date      { text-align: center; white-space: nowrap; width: 90px; font-size: 0.8em; color: #8b949e; }

  .type-issue { font-size: 0.75em; padding: 1px 6px; border-radius: 4px; background: #21262d; color: #8b949e; }
  .type-pr    { font-size: 0.75em; padding: 1px 6px; border-radius: 4px; background: #0f2d1a; color: #3fb950; }
  .type-pr.draft { background: #21262d; color: #8b949e; }

  .label-tag { display: inline-block; padding: 1px 5px; border-radius: 12px; background: #21262d; font-size: 0.8em; margin: 1px 2px; }

  .age-new   { color: #3fb950; }
  .age-week  { color: #58a6ff; }
  .age-month { color: #d29922; }
  .age-old   { color: #f97583; }

  .pri-critical { color: #f97583; font-weight: 700; font-size: 0.8em; }
  .pri-high     { color: #e3a63a; font-weight: 600; font-size: 0.8em; }
  .pri-medium   { color: #d29922; font-size: 0.8em; }
  .pri-low      { color: #8b949e; font-size: 0.8em; }
  .pri-none     { color: #484f58; font-size: 0.8em; }

  .rv-approved { color: #3fb950; font-size: 0.8em; font-weight: 600; }
  .rv-changes  { color: #f97583; font-size: 0.8em; font-weight: 600; }
  .rv-review   { color: #d29922; font-size: 0.8em; }
  .rv-none     { color: #484f58; font-size: 0.8em; }
  .ci-pass, .ci-fail, .ci-pend { font-size: 0.85em; }

  .waiting-tag      { display: inline-block; font-size: 0.68em; font-weight: 600; padding: 1px 5px; border-radius: 10px; margin-top: 2px; white-space: nowrap; }
  .waiting-you      { background: #3d1010; color: #f97583; }
  .waiting-them     { background: #1c2333; color: #8b949e; }
  .waiting-merge    { background: #0f2d1a; color: #3fb950; }

  .milestone-tag { display: inline-block; padding: 1px 6px; border-radius: 4px; background: #1f3a5f; color: #79c0ff; font-size: 0.8em; }

  .toc { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 8px; padding: 10px 16px; background: #161b22; border: 1px solid #30363d; border-radius: 8px; align-items: center; }
  .toc:last-of-type { margin-bottom: 24px; }
  .toc a { text-decoration: none; }
  .toc-label { font-size: 0.68em; font-weight: 600; color: #8b949e; text-transform: uppercase; letter-spacing: 0.06em; white-space: nowrap; margin-right: 6px; flex-shrink: 0; }
  .toc .badge { font-size: 0.78em; font-weight: 600; padding: 2px 9px; border-radius: 12px; background: #21262d; color: #c9d1d9; }
  .toc .badge.red    { background: #5d1a1a; color: #f97583; }
  .toc .badge.orange { background: #3d2000; color: #e3a63a; }
  .toc .badge.yellow { background: #2e2000; color: #d29922; }
  .toc .badge.green  { background: #0f2d1a; color: #3fb950; }

  .legend { display: flex; gap: 28px; flex-wrap: wrap; justify-content: center; margin-bottom: 28px; padding: 12px 16px; background: #161b22; border: 1px solid #30363d; border-radius: 8px; }
  .legend-group { display: flex; flex-direction: column; gap: 6px; }
  .legend-title { font-size: 0.7em; font-weight: 600; color: #8b949e; text-transform: uppercase; letter-spacing: 0.05em; }
  .legend-items { display: flex; gap: 14px; flex-wrap: wrap; align-items: center; font-size: 0.82em; }

  footer { margin-top: 48px; text-align: center; font-size: 0.8em; color: #8b949e; border-top: 1px solid #21262d; padding-top: 24px; }
</style>
</head>
<body>
<header>
  <h1>📊 GitHub Issue Dashboard</h1>
  <p>Open issues &amp; PRs across own repos and upstream contributions</p>
  <p class="updated">Last updated: <code>$LAST_UPDATED</code></p>
</header>

<div class="stats">
  <div class="stat-section-label">Own Repositories</div>
  <div class="stat"><div class="stat-number">$TOTAL_REPOS</div><div class="stat-label">Repos Monitored</div></div>
  <div class="stat"><div class="stat-number">$REPOS_WITH_ACTIVITY</div><div class="stat-label">Active Repos</div></div>
  <div class="stat"><div class="stat-number">$TOTAL_ISSUES</div><div class="stat-label">Open Issues</div></div>
  <div class="stat"><div class="stat-number green">$TOTAL_PRS</div><div class="stat-label">Open PRs</div></div>
  <div class="stat"><div class="stat-number">$TOTAL_ASSIGNED</div><div class="stat-label">Assigned</div></div>
  <div class="stat"><div class="stat-number">$EOL_REPOS</div><div class="stat-label">EOL Excluded</div></div>
  <div class="stat-section-label" style="margin-top:8px">Upstream (${FORK_COUNT} forks)</div>
  <div class="stat"><div class="stat-number green">$UPSTREAM_MY_PRS</div><div class="stat-label">My PRs on ↑</div></div>
  <div class="stat"><div class="stat-number muted">$UPSTREAM_ISSUES_TOTAL</div><div class="stat-label">↑ Issues</div></div>
</div>

<h2>🗗 Legend</h2>
<div class="legend">
  <div class="legend-group">
    <div class="legend-title">Age</div>
    <div class="legend-items">
      <span class="age-new">🆕 &lt;7d</span>
      <span class="age-week">🗓️ 7–29d</span>
      <span class="age-month">📅 30–89d</span>
      <span class="age-old">🕰️ 90+d</span>
    </div>
  </div>
  <div class="legend-group">
    <div class="legend-title">Priority</div>
    <div class="legend-items">
      <span class="pri-critical">● Critical/P0</span>
      <span class="pri-high">● High/P1</span>
      <span class="pri-medium">● Medium/P2</span>
      <span class="pri-low">● Low/P3</span>
    </div>
  </div>
  <div class="legend-group">
    <div class="legend-title">PR Status</div>
    <div class="legend-items">
      <span class="rv-approved">✓ Approved</span>
      <span class="rv-changes">✗ Changes</span>
      <span class="rv-review">⧖ Review</span>
      <span>✅ CI Pass &nbsp;❌ CI Fail &nbsp;⏳ CI Pending</span>
    </div>
  </div>
  <div class="legend-group">
    <div class="legend-title">Other</div>
    <div class="legend-items">
      <span class="new-badge">NEW</span> new since last run
    </div>
  </div>
</div>

<h2>🗂️ My Repositories</h2>
HTML_HEAD

# ── filter/sort/export controls (sticky) ─────────────────────────────────────
cat >> "$OUTPUT_FILE" << 'CONTROLS'
<div class="controls">
<div class="controls-inner">
  <div class="ctrl-group">
    <div class="ctrl-label">Search</div>
    <div class="ctrl-buttons">
      <input type="search" id="search-input" class="search-input" placeholder="Filter titles…" oninput="applyFilters()">
    </div>
  </div>
  <div class="ctrl-group">
    <div class="ctrl-label">Type</div>
    <div class="ctrl-buttons">
      <button class="ctrl-btn active" onclick="setFilter('type','all',this)">All</button>
      <button class="ctrl-btn" onclick="setFilter('type','issue',this)">🐛 Issues</button>
      <button class="ctrl-btn" onclick="setFilter('type','pr',this)">🔀 PRs</button>
    </div>
  </div>
  <div class="ctrl-group">
    <div class="ctrl-label">Age</div>
    <div class="ctrl-buttons">
      <button class="ctrl-btn active" onclick="setFilter('age','all',this)">All</button>
      <button class="ctrl-btn" onclick="setFilter('age','new',this)">🆕 &lt;7d</button>
      <button class="ctrl-btn" onclick="setFilter('age','week',this)">🗓️ 7–30d</button>
      <button class="ctrl-btn" onclick="setFilter('age','month',this)">📅 30–90d</button>
      <button class="ctrl-btn" onclick="setFilter('age','stale',this)">🕰️ 90+d</button>
    </div>
  </div>
  <div class="ctrl-group">
    <div class="ctrl-label">Priority</div>
    <div class="ctrl-buttons">
      <button class="ctrl-btn active" onclick="setFilter('priority','all',this)">All</button>
      <button class="ctrl-btn" onclick="setFilter('priority','critical',this)">Critical</button>
      <button class="ctrl-btn" onclick="setFilter('priority','high',this)">High</button>
      <button class="ctrl-btn" onclick="setFilter('priority','medium',this)">Medium</button>
      <button class="ctrl-btn" onclick="setFilter('priority','low',this)">Low</button>
    </div>
  </div>
  <div class="ctrl-group">
    <div class="ctrl-label">Source</div>
    <div class="ctrl-buttons">
      <button class="ctrl-btn active" onclick="setFilter('source','all',this)">All</button>
      <button class="ctrl-btn" onclick="setFilter('source','own',this)">Own</button>
      <button class="ctrl-btn" onclick="setFilter('source','upstream-pr',this)">My ↑ PRs</button>
      <button class="ctrl-btn" onclick="setFilter('source','upstream-issue',this)">↑ Issues</button>
    </div>
  </div>
  <div class="ctrl-group">
    <div class="ctrl-label">CI</div>
    <div class="ctrl-buttons">
      <button class="ctrl-btn active" onclick="setFilter('ci','all',this)">All</button>
      <button class="ctrl-btn" onclick="setFilter('ci','failure',this)">❌ Failing</button>
      <button class="ctrl-btn" onclick="setFilter('ci','pending',this)">⏳ Pending</button>
      <button class="ctrl-btn" onclick="setFilter('ci','success',this)">✅ Passing</button>
    </div>
  </div>
  <div class="ctrl-group">
    <div class="ctrl-label">Sort</div>
    <div class="ctrl-buttons">
      <button class="ctrl-btn active" onclick="sortIssues('newest',this)">Newest</button>
      <button class="ctrl-btn" onclick="sortIssues('oldest',this)">Oldest</button>
      <button class="ctrl-btn" onclick="sortIssues('priority',this)">Priority</button>
    </div>
  </div>
  <div class="ctrl-group">
    <div class="ctrl-label">View</div>
    <div class="ctrl-buttons">
      <button class="ctrl-btn" onclick="toggleAll(true)">Expand All</button>
      <button class="ctrl-btn" onclick="toggleAll(false)">Collapse All</button>
    </div>
  </div>
  <div class="ctrl-sep"></div>
  <div class="ctrl-group">
    <div class="ctrl-label">Export</div>
    <div class="ctrl-buttons">
      <button class="export-btn" onclick="exportData('csv')">⬇ CSV</button>
      <button class="export-btn" onclick="exportData('json')">⬇ JSON</button>
    </div>
  </div>
  <div class="filter-count" id="filter-count"></div>
  <div class="ctrl-sep"></div>
  <div class="ctrl-group">
    <div class="ctrl-label">Actions</div>
    <div class="ctrl-buttons">
      <button class="export-btn refresh-btn" id="refresh-btn" onclick="triggerRefresh()">↺ Refresh</button>
    </div>
  </div>
</div>
</div>

<!-- token modal — iframe sandboxed so LP content scripts cannot inject -->
<div id="token-modal" style="display:none;position:fixed;inset:0;background:rgba(0,0,0,0.7);z-index:999;align-items:center;justify-content:center;">
  <iframe id="token-frame" sandbox="allow-scripts" style="border:none;border-radius:10px;width:460px;max-width:92vw;height:230px;" scrolling="no"></iframe>
</div>
CONTROLS

# ── own repos ─────────────────────────────────────────────────────────────────
if [ "$REPOS_WITH_ACTIVITY" -gt 0 ]; then
  echo '<div class="toc"><span class="toc-label">My Repos</span>' >> "$OUTPUT_FILE"
  for f in $(ls -t "$WORK_DIR"/own_*.json 2>/dev/null | xargs -I{} bash -c 'echo "$(jq -r .newest_ts "{}"):{}"' | sort -rn | cut -d: -f2-); do
    [ -f "$f" ] || continue
    repo=$(jq -r '.repo' "$f"); REPO_NAME=$(echo "$repo" | cut -d'/' -f2)
    ic=$(jq -r '.issue_count' "$f"); pc=$(jq -r '.pr_count' "$f"); TOTAL=$((ic+pc))
    if   [ "$TOTAL" -ge 10 ]; then BADGE_CLASS="red";    COUNT_ICON="🔴"
    elif [ "$TOTAL" -ge 5  ]; then BADGE_CLASS="orange"; COUNT_ICON="🟠"
    elif [ "$TOTAL" -ge 3  ]; then BADGE_CLASS="yellow"; COUNT_ICON="🟡"
    else                           BADGE_CLASS="green";  COUNT_ICON="🟢"; fi
    printf '<a href="#%s"><span class="badge %s">%s %s (%s)</span></a>\n' \
      "$REPO_NAME" "$BADGE_CLASS" "$COUNT_ICON" "$REPO_NAME" "$TOTAL" >> "$OUTPUT_FILE"
  done
  echo '</div>' >> "$OUTPUT_FILE"

  # Upstream PRs dot-list — shown right below own-repos dots before the tables
  if [ "$UPSTREAM_REPOS_WITH_MY_PRS" -gt 0 ]; then
    echo '<div class="toc"><span class="toc-label">Upstream PRs</span>' >> "$OUTPUT_FILE"
    for f in $(for ff in "$WORK_DIR"/upstream_*.json; do [ -f "$ff" ] && echo "$(jq -r .newest_ts "$ff") $ff"; done | sort -rn | awk '{print $2}'); do
      [ -f "$f" ] || continue
      mpc=$(jq -r '.my_pr_count' "$f"); [ "$mpc" -eq 0 ] && continue
      upstream_repo=$(jq -r '.upstream_repo' "$f")
      UPSTREAM_SLUG=$(echo "$upstream_repo" | tr '/' '-')
      if   [ "$mpc" -ge 10 ]; then BADGE_CLASS="red";    COUNT_ICON="🔴"
      elif [ "$mpc" -ge 5  ]; then BADGE_CLASS="orange"; COUNT_ICON="🟠"
      elif [ "$mpc" -ge 3  ]; then BADGE_CLASS="yellow"; COUNT_ICON="🟡"
      else                          BADGE_CLASS="green";  COUNT_ICON="🟢"; fi
      printf '<a href="#uppr-%s"><span class="badge %s">%s %s (%s)</span></a>\n' \
        "$UPSTREAM_SLUG" "$BADGE_CLASS" "$COUNT_ICON" "$upstream_repo" "$mpc" >> "$OUTPUT_FILE"
    done
    echo '</div>' >> "$OUTPUT_FILE"
  fi

  # Sort by newest_ts desc using temp sorted list
  for f in $(for ff in "$WORK_DIR"/own_*.json; do [ -f "$ff" ] && echo "$(jq -r .newest_ts "$ff") $ff"; done | sort -rn | awk '{print $2}'); do
    [ -f "$f" ] || continue
    repo=$(jq -r '.repo' "$f"); REPO_NAME=$(echo "$repo" | cut -d'/' -f2)
    ic=$(jq -r '.issue_count' "$f"); pc=$(jq -r '.pr_count' "$f"); TOTAL=$((ic+pc))
    issues=$(jq -c '.issues' "$f"); prs=$(jq -c '.prs' "$f")

    if   [ "$TOTAL" -ge 10 ]; then BADGE_CLASS="red";    COUNT_ICON="🔴"
    elif [ "$TOTAL" -ge 5  ]; then BADGE_CLASS="orange"; COUNT_ICON="🟠"
    elif [ "$TOTAL" -ge 3  ]; then BADGE_CLASS="yellow"; COUNT_ICON="🟡"
    else                           BADGE_CLASS="green";  COUNT_ICON="🟢"; fi

    PREV_ISSUE_NUMS=$(echo "$PREV_STATE" | jq -r ".own_issues[\"$repo\"] // [] | .[]" 2>/dev/null | tr '\n' ' ')
    PREV_PR_NUMS=$(echo "$PREV_STATE"    | jq -r ".own_prs[\"$repo\"] // [] | .[]"    2>/dev/null | tr '\n' ' ')

    cat >> "$OUTPUT_FILE" << REPO_HDR
<details id="$REPO_NAME" data-repo="$REPO_NAME" data-source="own" open>
<summary>
  <h3>$COUNT_ICON <a href="https://github.com/$repo">$REPO_NAME</a></h3>
  <span class="badge $BADGE_CLASS">$ic issues · $pc PRs</span>
</summary>
$TABLE_HEADER
REPO_HDR
    [ "$ic" -gt 0 ] && emit_issue_rows "$issues" "$REPO_NAME" "$PREV_ISSUE_NUMS"
    [ "$pc" -gt 0 ] && emit_pr_rows    "$prs"    "$REPO_NAME" "$PREV_PR_NUMS"
    printf '</tbody>\n</table>\n</details>\n\n' >> "$OUTPUT_FILE"
  done
else
  echo '<p style="text-align:center;padding:48px;color:#3fb950;font-size:1.2em">🎉 No open issues or PRs!</p>' >> "$OUTPUT_FILE"
fi

# ── upstream: my PRs ──────────────────────────────────────────────────────────
if [ "$UPSTREAM_REPOS_WITH_MY_PRS" -gt 0 ]; then
  cat >> "$OUTPUT_FILE" << UP_PR_HDR
<div class="section-divider">
  <h2>🔀 My PRs on Upstream Repositories</h2>
</div>
UP_PR_HDR

  for f in $(for ff in "$WORK_DIR"/upstream_*.json; do [ -f "$ff" ] && echo "$(jq -r .newest_ts "$ff") $ff"; done | sort -rn | awk '{print $2}'); do
    [ -f "$f" ] || continue
    mpc=$(jq -r '.my_pr_count' "$f"); [ "$mpc" -eq 0 ] && continue
    upstream_repo=$(jq -r '.upstream_repo' "$f"); fork_name=$(jq -r '.fork_name' "$f")
    my_prs=$(jq -c '.my_prs' "$f")
    UPSTREAM_SLUG=$(echo "$upstream_repo" | tr '/' '-')

    if   [ "$mpc" -ge 10 ]; then BADGE_CLASS="red";    COUNT_ICON="🔴"
    elif [ "$mpc" -ge 5  ]; then BADGE_CLASS="orange"; COUNT_ICON="🟠"
    elif [ "$mpc" -ge 3  ]; then BADGE_CLASS="yellow"; COUNT_ICON="🟡"
    else                          BADGE_CLASS="green";  COUNT_ICON="🟢"; fi

    PREV_PR_NUMS=$(echo "$PREV_STATE" | jq -r ".upstream_prs[\"$upstream_repo\"] // [] | .[]" 2>/dev/null | tr '\n' ' ')

    cat >> "$OUTPUT_FILE" << UPR_HDR
<details id="uppr-$UPSTREAM_SLUG" data-repo="uppr-$UPSTREAM_SLUG" data-source="upstream-pr" open>
<summary>
  <h3 class="upstream-pr-title">$COUNT_ICON <a href="https://github.com/$upstream_repo">$upstream_repo</a>
    <span class="fork-of">← fork: $fork_name</span>
  </h3>
  <span class="badge $BADGE_CLASS">$mpc my PRs</span>
</summary>
$TABLE_HEADER
UPR_HDR
    emit_pr_rows "$my_prs" "uppr-$UPSTREAM_SLUG" "$PREV_PR_NUMS"
    printf '</tbody>\n</table>\n</details>\n\n' >> "$OUTPUT_FILE"
  done
fi

# ── upstream: issues (collapsed) ─────────────────────────────────────────────
if [ "$UPSTREAM_REPOS_WITH_ISSUES" -gt 0 ]; then
  cat >> "$OUTPUT_FILE" << UP_ISS_HDR
<div class="section-divider">
  <h2 style="color:#484f58">📋 Upstream Issues <span class="section-note">(top 30 per repo · collapsed)</span></h2>
</div>
UP_ISS_HDR

  for f in $(for ff in "$WORK_DIR"/upstream_*.json; do [ -f "$ff" ] && echo "$(jq -r .newest_ts "$ff") $ff"; done | sort -rn | awk '{print $2}'); do
    [ -f "$f" ] || continue
    uic=$(jq -r '.up_issue_count' "$f"); [ "$uic" -eq 0 ] && continue
    upstream_repo=$(jq -r '.upstream_repo' "$f"); fork_name=$(jq -r '.fork_name' "$f")
    up_issues=$(jq -c '.up_issues' "$f")
    UPSTREAM_SLUG=$(echo "$upstream_repo" | tr '/' '-')

    cat >> "$OUTPUT_FILE" << UIS_HDR
<details id="upis-$UPSTREAM_SLUG" data-repo="upis-$UPSTREAM_SLUG" data-source="upstream-issue">
<summary>
  <h3 class="upstream-iss-title"><a href="https://github.com/$upstream_repo" style="color:#484f58">$upstream_repo</a>
    <span class="fork-of">← fork: $fork_name</span>
  </h3>
  <span class="badge uis">$uic issues</span>
</summary>
$TABLE_HEADER
UIS_HDR
    emit_issue_rows "$up_issues" "upis-$UPSTREAM_SLUG" ""
    printf '</tbody>\n</table>\n</details>\n\n' >> "$OUTPUT_FILE"
  done
fi

# ── footer + JS ───────────────────────────────────────────────────────────────
cat >> "$OUTPUT_FILE" << 'HTML_FOOT'
<footer>
  Powered by GitHub Actions &mdash; updates hourly &mdash;
  <a href="https://github.com/slmingol/github-issue-dashboard">View Repository</a>
</footer>

<script>
const filters = { type:'all', age:'all', priority:'all', source:'all', ci:'all' };

function setFilter(f, val, btn) {
  filters[f] = val;
  btn.closest('.ctrl-buttons').querySelectorAll('.ctrl-btn').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  applyFilters();
}

function applyFilters() {
  const search = (document.getElementById('search-input')?.value || '').toLowerCase();
  let visible = 0;

  document.querySelectorAll('tr.issue-row').forEach(row => {
    const age  = parseInt(row.dataset.age, 10);
    const pri  = row.dataset.priority;
    const asgn = row.dataset.assigned === 'true';
    const ms   = row.dataset.milestone === 'true';
    const typ  = row.dataset.type;
    const ci   = row.dataset.ci || 'none';
    const src  = row.closest('details')?.dataset.source || 'own';
    const title = row.querySelector('td:nth-child(3)')?.textContent.toLowerCase() || '';

    let show = true;
    if (filters.type     !== 'all' && typ !== filters.type)     show = false;
    if (filters.source   !== 'all' && src !== filters.source)   show = false;
    if (filters.priority !== 'all' && pri !== filters.priority) show = false;
    if (filters.ci       !== 'all' && ci  !== filters.ci)       show = false;
    if (filters.age !== 'all') {
      if (filters.age === 'new'   && age >= 7)                show = false;
      if (filters.age === 'week'  && (age < 7  || age >= 30)) show = false;
      if (filters.age === 'month' && (age < 30 || age >= 90)) show = false;
      if (filters.age === 'stale' && age < 90)                show = false;
    }
    if (search && !title.includes(search)) show = false;

    row.classList.toggle('hidden', !show);
    if (show) visible++;
  });

  document.querySelectorAll('details[data-repo]').forEach(det => {
    det.style.display = det.querySelectorAll('tr.issue-row:not(.hidden)').length > 0 ? '' : 'none';
  });

  const total = document.querySelectorAll('tr.issue-row').length;
  const el = document.getElementById('filter-count');
  if (el) el.textContent = visible === total ? `${total} items` : `${visible} / ${total} items`;
}

function sortIssues(by, btn) {
  btn.closest('.ctrl-buttons').querySelectorAll('.ctrl-btn').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  const priOrder = { critical:0, high:1, medium:2, low:3, none:4 };
  document.querySelectorAll('details[data-repo] tbody').forEach(tbody => {
    Array.from(tbody.querySelectorAll('tr.issue-row'))
      .sort((a, b) => {
        if (by === 'oldest')   return parseInt(a.dataset.age,10) - parseInt(b.dataset.age,10);
        if (by === 'newest')   return parseInt(b.dataset.age,10) - parseInt(a.dataset.age,10);
        if (by === 'priority') return (priOrder[a.dataset.priority]??4) - (priOrder[b.dataset.priority]??4);
        return 0;
      })
      .forEach(r => tbody.appendChild(r));
  });
}

function toggleAll(open) {
  document.querySelectorAll('details[data-repo]').forEach(d => {
    if (d.style.display !== 'none') d.open = open;
  });
}

function exportData(fmt) {
  const rows = Array.from(document.querySelectorAll('tr.issue-row:not(.hidden)'));
  const data = rows.map(row => {
    const cells = row.querySelectorAll('td');
    const det   = row.closest('details');
    return {
      source:    det?.dataset.source || 'own',
      repo:      row.dataset.repo,
      type:      row.dataset.type,
      number:    cells[0].textContent.trim().replace('#',''),
      url:       cells[0].querySelector('a')?.href || '',
      title:     cells[2].textContent.trim(),
      age_days:  parseInt(row.dataset.age,10),
      priority:  row.dataset.priority,
      ci:        row.dataset.ci || 'none',
      labels:    Array.from(cells[5].querySelectorAll('.label-tag')).map(t=>t.textContent).join(', '),
      assignees: cells[6].textContent.trim().replace('—',''),
      milestone: cells[7].textContent.trim().replace('—',''),
      created:   cells[8].textContent.trim(),
      updated:   cells[9].textContent.trim()
    };
  });
  if (fmt === 'json') {
    dlBlob('dashboard.json', JSON.stringify(data,null,2), 'application/json');
  } else {
    const h = ['source','repo','type','number','title','age_days','priority','ci','labels','assignees','milestone','created','updated','url'];
    dlBlob('dashboard.csv',
      [h.join(','), ...data.map(d => h.map(k=>JSON.stringify(String(d[k]??''))).join(','))].join('\n'),
      'text/csv');
  }
}

function dlBlob(name, content, type) {
  const a = Object.assign(document.createElement('a'), {
    href: URL.createObjectURL(new Blob([content],{type})), download: name
  });
  a.click(); setTimeout(()=>URL.revokeObjectURL(a.href),1000);
}

applyFilters();

// ── refresh button ────────────────────────────────────────────────────────────
const REPO = 'slmingol/github-issue-dashboard';
const WORKFLOW = 'update-dashboard.yml';
const TOKEN_KEY = 'gh_dashboard_token';

function showTokenModal() {
  const modal = document.getElementById('token-modal');
  const frame = document.getElementById('token-frame');
  frame.srcdoc = `<!doctype html><html><head><style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:24px 28px;font-family:system-ui,sans-serif;color:#e6edf3;overflow:hidden;}
    h3{font-size:1em;margin-bottom:8px;}
    p{color:#8b949e;font-size:0.81em;margin-bottom:12px;line-height:1.4;}
    code{background:#21262d;padding:1px 4px;border-radius:4px;}
    a{color:#58a6ff;}
    #ti{width:100%;background:#0d1117;border:1px solid #30363d;border-radius:6px;color:#e6edf3;padding:6px 10px;font-size:0.85em;font-family:monospace;outline:none;margin-bottom:10px;}
    .btns{display:flex;gap:8px;justify-content:flex-end;}
    .cancel{background:#21262d;border:1px solid #30363d;border-radius:6px;color:#8b949e;padding:5px 14px;cursor:pointer;font-size:0.82em;}
    .save{background:#238636;border:1px solid #2ea043;border-radius:6px;color:#fff;padding:5px 14px;cursor:pointer;font-size:0.82em;}
  </style></head><body>
    <h3>GitHub Token Required</h3>
    <p>Enter a classic PAT with <code>repo</code> scope. <a href="https://github.com/settings/tokens/new?scopes=repo&description=github-issue-dashboard-refresh" target="_blank">Create one here</a>. Stored in localStorage, never sent anywhere except api.github.com.</p>
    <input id="ti" type="text" placeholder="ghp_..." autocomplete="off" spellcheck="false">
    <div class="btns">
      <button class="cancel" onclick="parent.postMessage({type:'cancel'},'*')">Cancel</button>
      <button class="save" onclick="go()">Save &amp; Trigger</button>
    </div>
    <script>
      document.getElementById('ti').focus();
      document.getElementById('ti').addEventListener('keydown',function(e){if(e.key==='Enter'){e.preventDefault();go();}});
      function go(){var t=document.getElementById('ti').value.trim();if(t)parent.postMessage({type:'token',value:t},'*');}
    <\/script>
  </body></html>`;
  modal.style.display = 'flex';
}

function triggerRefresh() {
  const token = localStorage.getItem(TOKEN_KEY);
  if (!token) { showTokenModal(); return; }
  dispatchWorkflow(token);
}

window.addEventListener('message', function(e) {
  if (e.data.type === 'cancel') {
    document.getElementById('token-modal').style.display = 'none';
  } else if (e.data.type === 'token') {
    document.getElementById('token-modal').style.display = 'none';
    localStorage.setItem(TOKEN_KEY, e.data.value);
    dispatchWorkflow(e.data.value);
  }
});

function dispatchWorkflow(token) {
  const btn = document.getElementById('refresh-btn');
  btn.disabled = true;
  btn.textContent = '↺ Triggering…';
  fetch('https://api.github.com/repos/' + REPO + '/actions/workflows/' + WORKFLOW + '/dispatches', {
    method: 'POST',
    headers: {
      'Authorization': 'token ' + token,
      'Accept': 'application/vnd.github.v3+json',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ ref: 'main' }),
  }).then(r => {
    if (r.status === 204) {
      btn.textContent = '✓ Triggered';
      btn.style.borderColor = '#2ea043';
      btn.style.color = '#3fb950';
      setTimeout(() => { btn.textContent = '↺ Refresh'; btn.style.borderColor=''; btn.style.color=''; btn.disabled=false; }, 4000);
    } else if (r.status === 401 || r.status === 403) {
      localStorage.removeItem(TOKEN_KEY);
      btn.textContent = '↺ Refresh';
      btn.disabled = false;
      alert('Token rejected (401/403). Ensure it is a classic PAT with repo scope. Please re-enter.');
      showTokenModal();
    } else {
      btn.textContent = '✗ Error ' + r.status;
      btn.style.color = '#f97583';
      setTimeout(() => { btn.textContent = '↺ Refresh'; btn.style.color=''; btn.disabled=false; }, 4000);
    }
  }).catch(() => {
    btn.textContent = '✗ Network error';
    btn.style.color = '#f97583';
    setTimeout(() => { btn.textContent = '↺ Refresh'; btn.style.color=''; btn.disabled=false; }, 4000);
  });
}

// close modal on backdrop click
document.getElementById('token-modal').addEventListener('click', function(e) {
  if (e.target === this) this.style.display = 'none';
});
</script>
</body>
</html>
HTML_FOOT

# ── persist state for next run ────────────────────────────────────────────────
echo "$NEW_STATE" > "$STATE_FILE"

echo "✅ Dashboard generated: $OUTPUT_FILE"
echo "📊 Own: $REPOS_WITH_ACTIVITY active repos, $TOTAL_ISSUES issues, $TOTAL_PRS PRs"
echo "⬆️  Upstream: $UPSTREAM_MY_PRS my PRs ($UPSTREAM_REPOS_WITH_MY_PRS repos); $UPSTREAM_ISSUES_TOTAL issues"
echo "📦 Excluded: $EOL_REPOS EOL repos"
