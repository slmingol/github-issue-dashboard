#!/bin/bash

# GitHub Issue Dashboard Generator
# Fetches all repos and open issues/PRs, generates HTML dashboard for GitHub Pages

OUTPUT_FILE="docs/index.html"
USERNAME="slmingol"

mkdir -p docs

echo "🔍 Fetching repositories..."

ALL_REPO_DATA=$(gh repo list "$USERNAME" --limit 200 \
  --json name,owner,hasIssuesEnabled,isArchived,repositoryTopics,isFork,parent)

REPOS=$(echo "$ALL_REPO_DATA" | jq -r \
  '.[] | select(.hasIssuesEnabled and (.isArchived | not)) |
   if ((.repositoryTopics // []) | map(.name) | any(. == "eol" or . == "end-of-life"))
   then empty
   else "\(.owner.login)/\(.name)" end')

EOL_REPOS=$(echo "$ALL_REPO_DATA" | \
  jq '[.[] | select((.repositoryTopics // []) | map(.name) | any(. == "eol" or . == "end-of-life"))] | length')

FORK_COUNT=$(echo "$ALL_REPO_DATA" | jq '[.[] | select(.isFork)] | length')

# upstream_full_name|fork_name pairs, deduped
UPSTREAM_PAIRS=$(echo "$ALL_REPO_DATA" | \
  jq -r '.[] | select(.isFork and (.parent != null)) | "\(.parent.nameWithOwner)|\(.name)"' | sort -u)

TOTAL_REPOS=0
TOTAL_ISSUES=0
TOTAL_PRS=0
REPOS_WITH_ACTIVITY=0
TOTAL_ASSIGNED=0
TOTAL_WITH_MILESTONE=0
TEMP_DATA=$(mktemp)
TEMP_PR_DATA=$(mktemp)

UPSTREAM_MY_PRS=0
UPSTREAM_ISSUES_TOTAL=0
UPSTREAM_REPOS_WITH_MY_PRS=0
UPSTREAM_REPOS_WITH_ISSUES=0
TEMP_UPSTREAM_PRS=$(mktemp)
TEMP_UPSTREAM_ISSUES=$(mktemp)

echo "📝 Analyzing own repo issues + PRs..."

while IFS= read -r repo; do
  ((TOTAL_REPOS++))
  echo "   Checking $repo..."

  ISSUES=$(gh issue list --repo "$repo" --state open \
    --json number,title,labels,createdAt,updatedAt,url,milestone,assignees 2>/dev/null || echo "[]")
  ISSUE_COUNT=$(echo "$ISSUES" | jq '. | length')

  PRS=$(gh pr list --repo "$repo" --state open \
    --json number,title,labels,createdAt,updatedAt,url,milestone,assignees,isDraft,reviewDecision,headRefName \
    2>/dev/null || echo "[]")
  PR_COUNT=$(echo "$PRS" | jq '. | length')

  TOTAL_ISSUES=$((TOTAL_ISSUES + ISSUE_COUNT))
  TOTAL_PRS=$((TOTAL_PRS + PR_COUNT))

  if [ "$ISSUE_COUNT" -gt 0 ] || [ "$PR_COUNT" -gt 0 ]; then
    ((REPOS_WITH_ACTIVITY++))
    ASSIGNED=$(echo "$ISSUES" | jq '[.[] | select(.assignees | length > 0)] | length')
    ((TOTAL_ASSIGNED += ASSIGNED))
    WITH_MILESTONE=$(echo "$ISSUES" | jq '[.[] | select(.milestone != null)] | length')
    ((TOTAL_WITH_MILESTONE += WITH_MILESTONE))

    NEWEST_ISSUE_TS=$(echo "$ISSUES" | jq -r 'if length > 0 then [.[].createdAt] | max | fromdate else 0 end')
    NEWEST_PR_TS=$(echo "$PRS"    | jq -r 'if length > 0 then [.[].createdAt] | max | fromdate else 0 end')
    NEWEST_TS=$(( NEWEST_ISSUE_TS > NEWEST_PR_TS ? NEWEST_ISSUE_TS : NEWEST_PR_TS ))

    echo "$NEWEST_TS|$repo|$ISSUE_COUNT|$ISSUES" >> "$TEMP_DATA"
    echo "$repo|$PR_COUNT|$PRS"                  >> "$TEMP_PR_DATA"
  fi
done <<< "$REPOS"

echo "⬆️  Analyzing upstream PRs + issues..."

while IFS='|' read -r upstream_repo fork_name; do
  [ -z "$upstream_repo" ] && continue
  echo "   Upstream $upstream_repo (fork: $fork_name)..."

  # My PRs on this upstream (primary)
  MY_PRS=$(gh pr list --repo "$upstream_repo" --state open --author "$USERNAME" \
    --json number,title,labels,createdAt,updatedAt,url,milestone,assignees,isDraft,reviewDecision,headRefName \
    2>/dev/null || echo "[]")
  MY_PR_COUNT=$(echo "$MY_PRS" | jq '. | length')

  # Upstream issues (secondary, top 30)
  UP_ISSUES=$(gh issue list --repo "$upstream_repo" --state open --limit 30 \
    --json number,title,labels,createdAt,updatedAt,url,milestone,assignees 2>/dev/null || echo "[]")
  UP_ISSUE_COUNT=$(echo "$UP_ISSUES" | jq '. | length')

  UPSTREAM_MY_PRS=$((UPSTREAM_MY_PRS + MY_PR_COUNT))
  UPSTREAM_ISSUES_TOTAL=$((UPSTREAM_ISSUES_TOTAL + UP_ISSUE_COUNT))

  if [ "$MY_PR_COUNT" -gt 0 ]; then
    ((UPSTREAM_REPOS_WITH_MY_PRS++))
    NEWEST_TS=$(echo "$MY_PRS" | jq -r '[.[].createdAt] | max | fromdate')
    echo "$NEWEST_TS|$upstream_repo|$fork_name|$MY_PR_COUNT|$MY_PRS" >> "$TEMP_UPSTREAM_PRS"
  fi
  if [ "$UP_ISSUE_COUNT" -gt 0 ]; then
    ((UPSTREAM_REPOS_WITH_ISSUES++))
    NEWEST_TS=$(echo "$UP_ISSUES" | jq -r '[.[].createdAt] | max | fromdate')
    echo "$NEWEST_TS|$upstream_repo|$fork_name|$UP_ISSUE_COUNT|$UP_ISSUES" >> "$TEMP_UPSTREAM_ISSUES"
  fi
done <<< "$UPSTREAM_PAIRS"

LAST_UPDATED=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

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
    background: #0d1117; color: #c9d1d9; padding: 32px 24px; font-size: 14px;
  }
  a { color: #58a6ff; text-decoration: none; }
  a:hover { text-decoration: underline; }
  header { text-align: center; margin-bottom: 32px; }
  header h1 { font-size: 2em; color: #e6edf3; margin-bottom: 8px; }
  header p { color: #8b949e; }
  .updated { font-size: 0.85em; color: #8b949e; margin-top: 8px; }
  .updated code { background: #161b22; padding: 2px 6px; border-radius: 4px; }

  .stats { display: flex; gap: 16px; flex-wrap: wrap; justify-content: center; margin-bottom: 32px; }
  .stat {
    background: #161b22; border: 1px solid #30363d; border-radius: 8px;
    padding: 16px 24px; text-align: center; min-width: 120px;
  }
  .stat-number          { font-size: 2em; font-weight: 700; color: #58a6ff; }
  .stat-number.purple   { color: #bc8cff; }
  .stat-number.green    { color: #3fb950; }
  .stat-label { font-size: 0.78em; color: #8b949e; margin-top: 4px; }
  .stat-group-label {
    width: 100%; text-align: center; font-size: 0.7em; font-weight: 600;
    color: #8b949e; text-transform: uppercase; letter-spacing: 0.08em;
    margin-bottom: -8px;
  }

  h2 { font-size: 1.3em; color: #e6edf3; margin-bottom: 16px; padding-bottom: 8px; border-bottom: 1px solid #21262d; }

  .controls {
    background: #161b22; border: 1px solid #30363d; border-radius: 8px;
    padding: 16px 20px; margin-bottom: 24px; display: flex; flex-wrap: wrap; gap: 16px; align-items: flex-start;
  }
  .ctrl-group { display: flex; flex-direction: column; gap: 6px; }
  .ctrl-label { font-size: 0.7em; font-weight: 600; color: #8b949e; text-transform: uppercase; letter-spacing: 0.05em; }
  .ctrl-buttons { display: flex; gap: 4px; flex-wrap: wrap; }
  .ctrl-btn {
    font-size: 0.78em; padding: 3px 10px; border-radius: 12px; border: 1px solid #30363d;
    background: #21262d; color: #c9d1d9; cursor: pointer; transition: all 0.1s;
  }
  .ctrl-btn:hover { border-color: #58a6ff; color: #58a6ff; }
  .ctrl-btn.active { background: #1f6feb; border-color: #1f6feb; color: #fff; }
  .ctrl-sep { width: 1px; background: #30363d; align-self: stretch; margin: 0 4px; }
  .export-btn {
    font-size: 0.78em; padding: 3px 10px; border-radius: 12px; border: 1px solid #30363d;
    background: #21262d; color: #8b949e; cursor: pointer;
  }
  .export-btn:hover { border-color: #3fb950; color: #3fb950; }
  .filter-count { font-size: 0.8em; color: #8b949e; align-self: center; margin-left: auto; }

  details { margin-bottom: 16px; border: 1px solid #30363d; border-radius: 8px; overflow: hidden; }
  details[open] summary { border-bottom: 1px solid #30363d; }
  summary {
    padding: 12px 16px; cursor: pointer; background: #161b22;
    display: flex; align-items: center; gap: 10px; list-style: none;
  }
  summary::-webkit-details-marker { display: none; }
  summary::before { content: "▶"; font-size: 0.7em; color: #8b949e; transition: transform 0.15s; }
  details[open] summary::before { transform: rotate(90deg); }
  summary h3 { font-size: 1em; color: #58a6ff; }
  summary h3.upstream-pr-title   { color: #3fb950; }
  summary h3.upstream-iss-title  { color: #484f58; }
  summary .fork-of { font-size: 0.75em; color: #8b949e; margin-left: 6px; }
  summary .badge {
    margin-left: auto; font-size: 0.75em; font-weight: 600;
    padding: 2px 8px; border-radius: 12px; background: #21262d; color: #c9d1d9;
  }
  summary .badge.red    { background: #5d1a1a; color: #f97583; }
  summary .badge.orange { background: #3d2000; color: #e3a63a; }
  summary .badge.yellow { background: #2e2000; color: #d29922; }
  summary .badge.green  { background: #0f2d1a; color: #3fb950; }
  /* upstream PR badges: green tones */
  summary .badge.upr-red  { background: #0f2d1a; color: #3fb950; }
  summary .badge.upr-orng { background: #0f2d1a; color: #56d364; }
  summary .badge.upr-yelw { background: #0f2d1a; color: #7ee787; }
  summary .badge.upr-grn  { background: #0f2d1a; color: #aff5b4; }
  /* upstream issue badges: muted */
  summary .badge.uis { background: #161b22; color: #484f58; border: 1px solid #30363d; }

  .section-divider { margin: 40px 0 24px; padding-top: 24px; border-top: 2px solid #21262d; }
  .section-note { font-size: 0.75em; color: #484f58; font-weight: 400; margin-left: 12px; }

  table { width: 100%; border-collapse: collapse; }
  th {
    background: #161b22; padding: 8px 12px; text-align: left;
    font-size: 0.8em; color: #8b949e; font-weight: 600;
    border-bottom: 1px solid #30363d; white-space: nowrap;
  }
  th.center { text-align: center; }
  td { padding: 8px 12px; border-bottom: 1px solid #21262d; vertical-align: middle; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: #1c2128; }
  tr.hidden { display: none; }
  tr.pr-row td { background: rgba(63,185,80,0.03); }
  tr.pr-row:hover td { background: rgba(63,185,80,0.07); }
  td.num      { text-align: center; white-space: nowrap; width: 55px; }
  td.type     { text-align: center; white-space: nowrap; width: 85px; }
  td.age      { text-align: center; white-space: nowrap; width: 75px; font-size: 0.9em; }
  td.status   { text-align: center; white-space: nowrap; width: 90px; }
  td.labels   { width: 16%; font-size: 0.8em; color: #8b949e; }
  td.assignee { width: 10%; font-size: 0.8em; }
  td.milestone{ width: 10%; font-size: 0.8em; }
  td.date     { text-align: center; white-space: nowrap; width: 95px; font-size: 0.8em; color: #8b949e; }

  .type-issue { font-size: 0.75em; padding: 1px 6px; border-radius: 4px; background: #21262d; color: #8b949e; }
  .type-pr    { font-size: 0.75em; padding: 1px 6px; border-radius: 4px; background: #0f2d1a; color: #3fb950; }
  .type-pr.draft { background: #21262d; color: #8b949e; }

  .label-tag {
    display: inline-block; padding: 1px 6px; border-radius: 12px;
    background: #21262d; font-size: 0.8em; margin: 1px 2px;
  }
  .age-new    { color: #3fb950; }
  .age-week   { color: #58a6ff; }
  .age-month  { color: #d29922; }
  .age-old    { color: #f97583; }

  .pri-critical { color: #f97583; font-weight: 700; font-size: 0.8em; }
  .pri-high     { color: #e3a63a; font-weight: 600; font-size: 0.8em; }
  .pri-medium   { color: #d29922; font-size: 0.8em; }
  .pri-low      { color: #8b949e; font-size: 0.8em; }
  .pri-none     { color: #484f58; font-size: 0.8em; }

  .rv-approved  { color: #3fb950; font-size: 0.8em; font-weight: 600; }
  .rv-changes   { color: #f97583; font-size: 0.8em; font-weight: 600; }
  .rv-review    { color: #d29922; font-size: 0.8em; }
  .rv-none      { color: #484f58; font-size: 0.8em; }

  .milestone-tag {
    display: inline-block; padding: 1px 6px; border-radius: 4px;
    background: #1f3a5f; color: #79c0ff; font-size: 0.8em;
  }

  .toc { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 32px; padding: 16px 20px; background: #161b22; border: 1px solid #30363d; border-radius: 8px; }
  .toc a { text-decoration: none; }

  .legend { display: flex; gap: 32px; flex-wrap: wrap; justify-content: center; margin-bottom: 32px; padding: 16px 20px; background: #161b22; border: 1px solid #30363d; border-radius: 8px; }
  .legend-group { display: flex; flex-direction: column; gap: 8px; }
  .legend-title { font-size: 0.75em; font-weight: 600; color: #8b949e; text-transform: uppercase; letter-spacing: 0.05em; }
  .legend-items { display: flex; gap: 16px; flex-wrap: wrap; align-items: center; font-size: 0.85em; }

  footer { margin-top: 48px; text-align: center; font-size: 0.8em; color: #8b949e; border-top: 1px solid #21262d; padding-top: 24px; }
</style>
</head>
<body>
<header>
  <h1>📊 GitHub Issue Dashboard</h1>
  <p>Real-time overview of open issues &amp; PRs across all repositories</p>
  <p class="updated">Last updated: <code>$LAST_UPDATED</code></p>
</header>

<div class="stats">
  <div class="stat-group-label" style="flex-basis:100%">Own Repos</div>
  <div class="stat"><div class="stat-number">$TOTAL_REPOS</div><div class="stat-label">Repos Monitored</div></div>
  <div class="stat"><div class="stat-number">$REPOS_WITH_ACTIVITY</div><div class="stat-label">Repos with Activity</div></div>
  <div class="stat"><div class="stat-number">$TOTAL_ISSUES</div><div class="stat-label">Open Issues</div></div>
  <div class="stat"><div class="stat-number green">$TOTAL_PRS</div><div class="stat-label">Open PRs</div></div>
  <div class="stat"><div class="stat-number">$TOTAL_ASSIGNED</div><div class="stat-label">Assigned Issues</div></div>
  <div class="stat"><div class="stat-number">$EOL_REPOS</div><div class="stat-label">EOL (excluded)</div></div>
  <div class="stat-group-label" style="flex-basis:100%; margin-top:8px;">Upstream (${FORK_COUNT} forks)</div>
  <div class="stat"><div class="stat-number green">$UPSTREAM_MY_PRS</div><div class="stat-label">My PRs on Upstream</div></div>
  <div class="stat"><div class="stat-number" style="color:#484f58">$UPSTREAM_ISSUES_TOTAL</div><div class="stat-label">Upstream Issues</div></div>
</div>

<h2>🗗 Legend</h2>
<div class="legend">
  <div class="legend-group">
    <div class="legend-title">Issue Count</div>
    <div class="legend-items">
      <span class="badge red">🔴 10+</span>
      <span class="badge orange">🟠 5–9</span>
      <span class="badge yellow">🟡 3–4</span>
      <span class="badge green">🟢 1–2</span>
    </div>
  </div>
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
    <div class="legend-title">Priority / PR Status</div>
    <div class="legend-items">
      <span class="pri-critical">● Crit</span>
      <span class="pri-high">● High</span>
      <span class="pri-medium">● Med</span>
      <span class="pri-low">● Low</span>
      <span class="rv-approved">✓ Approved</span>
      <span class="rv-changes">✗ Changes</span>
      <span class="rv-review">⧖ Review</span>
    </div>
  </div>
</div>

<h2>🗂️ My Repositories</h2>
HTML_HEAD

# ── helpers ──────────────────────────────────────────────────────────────────

age_class_icon() {
  local days=$1
  if   [ "$days" -ge 90 ]; then echo "age-old   🕰️"
  elif [ "$days" -ge 30 ]; then echo "age-month 📅"
  elif [ "$days" -ge 7  ]; then echo "age-week  🗓️"
  else                          echo "age-new   🆕"
  fi
}

priority_from_labels() {
  local issue_json=$1
  echo "$issue_json" | jq -r '
    .labels | map(.name | ascii_downcase) |
    if   any(. == "critical" or . == "p0" or . == "blocker" or . == "urgent") then "critical"
    elif any(. == "high"     or . == "p1" or . == "high-priority" or . == "priority: high") then "high"
    elif any(. == "medium"   or . == "p2" or . == "medium-priority" or . == "priority: medium") then "medium"
    elif any(. == "low"      or . == "p3" or . == "low-priority" or . == "priority: low" or . == "minor") then "low"
    else "none" end'
}

emit_issue_rows() {
  local issues="$1"
  local repo_name="$2"
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

    read AGE_CLASS AGE_ICON <<< "$(age_class_icon $DAYS_OLD)"
    PRIORITY=$(priority_from_labels "$ij")
    case "$PRIORITY" in
      critical) PRI_DISPLAY='<span class="pri-critical">🔴 Critical</span>' ;;
      high)     PRI_DISPLAY='<span class="pri-high">🟠 High</span>' ;;
      medium)   PRI_DISPLAY='<span class="pri-medium">🟡 Medium</span>' ;;
      low)      PRI_DISPLAY='<span class="pri-low">🔵 Low</span>' ;;
      *)        PRI_DISPLAY='<span class="pri-none">—</span>' ;;
    esac

    ASSIGNEES_HTML=$(echo "$ij" | jq -r '.assignees | if length==0 then "—" else map("<a href=\"https://github.com/\(.login)\">\(.login)</a>") | join(", ") end')
    HAS_ASSIGNEE=$(echo "$ij" | jq -r 'if (.assignees|length)>0 then "true" else "false" end')
    MILESTONE_TITLE=$(echo "$ij" | jq -r '.milestone | if .==null then "" else .title | gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;") end')
    HAS_MILESTONE=$(echo "$ij" | jq -r 'if .milestone!=null then "true" else "false" end')
    [ "$HAS_MILESTONE" = "true" ] && MILESTONE_DISPLAY="<span class=\"milestone-tag\">🏁 $MILESTONE_TITLE</span>" || MILESTONE_DISPLAY="—"

    cat >> "$OUTPUT_FILE" << ISSUE_ROW
<tr class="issue-row" data-type="issue" data-age="$DAYS_OLD" data-priority="$PRIORITY" data-assigned="$HAS_ASSIGNEE" data-milestone="$HAS_MILESTONE" data-repo="$repo_name">
  <td class="num"><a href="$URL"><b>#$NUM</b></a></td>
  <td><span class="type-issue">🐛 Issue</span></td>
  <td>$TITLE</td>
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
  local prs="$1"
  local repo_name="$2"
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

    read AGE_CLASS AGE_ICON <<< "$(age_class_icon $DAYS_OLD)"
    LABELS_HTML=$(echo "$pj" | jq -r '.labels | if length==0 then "—" else map("<span class=\"label-tag\">\(.name)</span>") | join(" ") end')
    ASSIGNEES_HTML=$(echo "$pj" | jq -r '.assignees | if length==0 then "—" else map("<a href=\"https://github.com/\(.login)\">\(.login)</a>") | join(", ") end')
    HAS_ASSIGNEE=$(echo "$pj" | jq -r 'if (.assignees|length)>0 then "true" else "false" end')
    MILESTONE_TITLE=$(echo "$pj" | jq -r '.milestone | if .==null then "" else .title | gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;") end')
    HAS_MILESTONE=$(echo "$pj" | jq -r 'if .milestone!=null then "true" else "false" end')
    [ "$HAS_MILESTONE" = "true" ] && MILESTONE_DISPLAY="<span class=\"milestone-tag\">🏁 $MILESTONE_TITLE</span>" || MILESTONE_DISPLAY="—"

    if [ "$IS_DRAFT" = "true" ]; then
      TYPE_BADGE='<span class="type-pr draft">📝 Draft PR</span>'
      STATUS_DISPLAY='<span class="rv-none">Draft</span>'
    else
      TYPE_BADGE='<span class="type-pr">🔀 PR</span>'
      case "$REVIEW_DECISION" in
        APPROVED)          STATUS_DISPLAY='<span class="rv-approved">✓ Approved</span>'  ;;
        CHANGES_REQUESTED) STATUS_DISPLAY='<span class="rv-changes">✗ Changes</span>'   ;;
        REVIEW_REQUIRED)   STATUS_DISPLAY='<span class="rv-review">⧖ Review</span>'     ;;
        *)                 STATUS_DISPLAY='<span class="rv-none">—</span>'               ;;
      esac
    fi

    cat >> "$OUTPUT_FILE" << PR_ROW
<tr class="issue-row pr-row" data-type="pr" data-age="$DAYS_OLD" data-priority="none" data-assigned="$HAS_ASSIGNEE" data-milestone="$HAS_MILESTONE" data-repo="$repo_name">
  <td class="num"><a href="$URL"><b>#$NUM</b></a></td>
  <td><span style="font-size:0.75em;color:#8b949e">$BRANCH</span> $TYPE_BADGE</td>
  <td>$TITLE</td>
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
  <th class="center">#</th><th class="center" style="width:110px">Type</th><th>Title</th>
  <th class="center">Age</th><th class="center">Pri/Status</th>
  <th>Labels</th><th>Assignees</th><th>Milestone</th>
  <th class="center">Created</th><th class="center">Updated</th>
</tr></thead>
<tbody>'

# ── filter/sort/export controls ──────────────────────────────────────────────
cat >> "$OUTPUT_FILE" << 'CONTROLS'
<div class="controls">
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
    <div class="ctrl-label">Assignee</div>
    <div class="ctrl-buttons">
      <button class="ctrl-btn active" onclick="setFilter('assignee','all',this)">All</button>
      <button class="ctrl-btn" onclick="setFilter('assignee','assigned',this)">Assigned</button>
      <button class="ctrl-btn" onclick="setFilter('assignee','unassigned',this)">Unassigned</button>
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
    <div class="ctrl-label">Sort By</div>
    <div class="ctrl-buttons">
      <button class="ctrl-btn active" onclick="sortIssues('newest',this)">Newest</button>
      <button class="ctrl-btn" onclick="sortIssues('oldest',this)">Oldest</button>
      <button class="ctrl-btn" onclick="sortIssues('priority',this)">Priority</button>
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
</div>
CONTROLS

# ── own repos ────────────────────────────────────────────────────────────────
if [ "$REPOS_WITH_ACTIVITY" -gt 0 ]; then
  echo '<div class="toc">' >> "$OUTPUT_FILE"
  sort -t'|' -k1 -rn "$TEMP_DATA" | while IFS='|' read -r newest_ts repo issue_count issues; do
    REPO_NAME=$(echo "$repo" | cut -d'/' -f2)
    PR_LINE=$(grep "^$repo|" "$TEMP_PR_DATA" 2>/dev/null || echo "")
    PR_COUNT=$(echo "$PR_LINE" | cut -d'|' -f2)
    PR_COUNT=${PR_COUNT:-0}
    TOTAL=$((issue_count + PR_COUNT))
    if   [ "$TOTAL" -ge 10 ]; then BADGE_CLASS="red";    COUNT_ICON="🔴"
    elif [ "$TOTAL" -ge 5  ]; then BADGE_CLASS="orange"; COUNT_ICON="🟠"
    elif [ "$TOTAL" -ge 3  ]; then BADGE_CLASS="yellow"; COUNT_ICON="🟡"
    else                           BADGE_CLASS="green";  COUNT_ICON="🟢"; fi
    printf '<a href="#%s"><span class="badge %s">%s %s (%s)</span></a>\n' \
      "$REPO_NAME" "$BADGE_CLASS" "$COUNT_ICON" "$REPO_NAME" "$TOTAL" >> "$OUTPUT_FILE"
  done
  echo '</div>' >> "$OUTPUT_FILE"

  sort -t'|' -k1 -rn "$TEMP_DATA" | while IFS='|' read -r newest_ts repo issue_count issues; do
    REPO_NAME=$(echo "$repo" | cut -d'/' -f2)
    PR_LINE=$(grep "^$repo|" "$TEMP_PR_DATA" 2>/dev/null || echo "")
    PR_COUNT=$(echo "$PR_LINE" | cut -d'|' -f2); PR_COUNT=${PR_COUNT:-0}
    PRS=$(echo "$PR_LINE" | cut -d'|' -f3-)
    TOTAL=$((issue_count + PR_COUNT))
    if   [ "$TOTAL" -ge 10 ]; then BADGE_CLASS="red";    COUNT_ICON="🔴"
    elif [ "$TOTAL" -ge 5  ]; then BADGE_CLASS="orange"; COUNT_ICON="🟠"
    elif [ "$TOTAL" -ge 3  ]; then BADGE_CLASS="yellow"; COUNT_ICON="🟡"
    else                           BADGE_CLASS="green";  COUNT_ICON="🟢"; fi

    cat >> "$OUTPUT_FILE" << REPO_HDR
<details id="$REPO_NAME" data-repo="$REPO_NAME" data-source="own" open>
<summary>
  <h3>$COUNT_ICON <a href="https://github.com/$repo">$REPO_NAME</a></h3>
  <span class="badge $BADGE_CLASS">$issue_count issues · $PR_COUNT PRs</span>
</summary>
$TABLE_HEADER
REPO_HDR

    [ "$issue_count" -gt 0 ] && emit_issue_rows "$issues" "$REPO_NAME"
    [ "$PR_COUNT"    -gt 0 ] && [ -n "$PRS" ] && emit_pr_rows "$PRS" "$REPO_NAME"
    printf '</tbody>\n</table>\n</details>\n\n' >> "$OUTPUT_FILE"
  done
else
  echo '<p style="text-align:center;padding:48px;color:#3fb950;font-size:1.2em">🎉 No open issues or PRs!</p>' >> "$OUTPUT_FILE"
fi

# ── upstream: my PRs (primary) ───────────────────────────────────────────────
if [ "$UPSTREAM_REPOS_WITH_MY_PRS" -gt 0 ]; then
  cat >> "$OUTPUT_FILE" << UP_PR_HDR
<div class="section-divider">
  <h2>🔀 My PRs on Upstream Repositories</h2>
</div>
UP_PR_HDR

  echo '<div class="toc">' >> "$OUTPUT_FILE"
  sort -t'|' -k1 -rn "$TEMP_UPSTREAM_PRS" | while IFS='|' read -r newest_ts upstream_repo fork_name pr_count prs; do
    UPSTREAM_SLUG=$(echo "$upstream_repo" | tr '/' '-')
    if   [ "$pr_count" -ge 10 ]; then BADGE_CLASS="upr-red";  COUNT_ICON="🔴"
    elif [ "$pr_count" -ge 5  ]; then BADGE_CLASS="upr-orng"; COUNT_ICON="🟠"
    elif [ "$pr_count" -ge 3  ]; then BADGE_CLASS="upr-yelw"; COUNT_ICON="🟡"
    else                               BADGE_CLASS="upr-grn";  COUNT_ICON="🟢"; fi
    printf '<a href="#uppr-%s"><span class="badge %s">%s %s (%s)</span></a>\n' \
      "$UPSTREAM_SLUG" "$BADGE_CLASS" "$COUNT_ICON" "$upstream_repo" "$pr_count" >> "$OUTPUT_FILE"
  done
  echo '</div>' >> "$OUTPUT_FILE"

  sort -t'|' -k1 -rn "$TEMP_UPSTREAM_PRS" | while IFS='|' read -r newest_ts upstream_repo fork_name pr_count prs; do
    UPSTREAM_SLUG=$(echo "$upstream_repo" | tr '/' '-')
    if   [ "$pr_count" -ge 10 ]; then BADGE_CLASS="upr-red";  COUNT_ICON="🔴"
    elif [ "$pr_count" -ge 5  ]; then BADGE_CLASS="upr-orng"; COUNT_ICON="🟠"
    elif [ "$pr_count" -ge 3  ]; then BADGE_CLASS="upr-yelw"; COUNT_ICON="🟡"
    else                               BADGE_CLASS="upr-grn";  COUNT_ICON="🟢"; fi

    cat >> "$OUTPUT_FILE" << UPR_HDR
<details id="uppr-$UPSTREAM_SLUG" data-repo="uppr-$UPSTREAM_SLUG" data-source="upstream-pr" open>
<summary>
  <h3 class="upstream-pr-title">$COUNT_ICON <a href="https://github.com/$upstream_repo">$upstream_repo</a>
    <span class="fork-of">← fork: $fork_name</span>
  </h3>
  <span class="badge $BADGE_CLASS">$pr_count my PRs</span>
</summary>
$TABLE_HEADER
UPR_HDR

    emit_pr_rows "$prs" "uppr-$UPSTREAM_SLUG"
    printf '</tbody>\n</table>\n</details>\n\n' >> "$OUTPUT_FILE"
  done
fi

# ── upstream: issues (secondary, collapsed) ───────────────────────────────────
if [ "$UPSTREAM_REPOS_WITH_ISSUES" -gt 0 ]; then
  cat >> "$OUTPUT_FILE" << UP_ISS_HDR
<div class="section-divider">
  <h2 style="color:#484f58">📋 Upstream Issues <span class="section-note">(top 30 per repo · collapsed)</span></h2>
</div>
UP_ISS_HDR

  sort -t'|' -k1 -rn "$TEMP_UPSTREAM_ISSUES" | while IFS='|' read -r newest_ts upstream_repo fork_name issue_count issues; do
    UPSTREAM_SLUG=$(echo "$upstream_repo" | tr '/' '-')

    cat >> "$OUTPUT_FILE" << UIS_HDR
<details id="upis-$UPSTREAM_SLUG" data-repo="upis-$UPSTREAM_SLUG" data-source="upstream-issue">
<summary>
  <h3 class="upstream-iss-title"><a href="https://github.com/$upstream_repo" style="color:#484f58">$upstream_repo</a>
    <span class="fork-of">← fork: $fork_name</span>
  </h3>
  <span class="badge uis">$issue_count issues</span>
</summary>
$TABLE_HEADER
UIS_HDR

    emit_issue_rows "$issues" "upis-$UPSTREAM_SLUG"
    printf '</tbody>\n</table>\n</details>\n\n' >> "$OUTPUT_FILE"
  done
fi

cat >> "$OUTPUT_FILE" << 'HTML_FOOT'
<footer>
  Powered by GitHub Actions &mdash; updates hourly &mdash;
  <a href="https://github.com/slmingol/github-issue-dashboard">View Repository</a>
</footer>

<script>
const filters = { type: 'all', age: 'all', priority: 'all', assignee: 'all', source: 'all' };

function setFilter(f, val, btn) {
  filters[f] = val;
  btn.closest('.ctrl-buttons').querySelectorAll('.ctrl-btn').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  applyFilters();
}

function applyFilters() {
  let visible = 0;
  document.querySelectorAll('tr.issue-row').forEach(row => {
    const age    = parseInt(row.dataset.age, 10);
    const pri    = row.dataset.priority;
    const asgn   = row.dataset.assigned === 'true';
    const ms     = row.dataset.milestone === 'true';
    const typ    = row.dataset.type;
    const src    = row.closest('details') ? row.closest('details').dataset.source : 'own';

    let show = true;
    if (filters.type !== 'all'     && typ !== filters.type)          show = false;
    if (filters.source !== 'all'   && src !== filters.source)        show = false;
    if (filters.priority !== 'all' && pri !== filters.priority)      show = false;
    if (filters.assignee === 'assigned'   && !asgn)                  show = false;
    if (filters.assignee === 'unassigned' && asgn)                   show = false;
    if (filters.age !== 'all') {
      if (filters.age === 'new'   && age >= 7)                show = false;
      if (filters.age === 'week'  && (age < 7  || age >= 30)) show = false;
      if (filters.age === 'month' && (age < 30 || age >= 90)) show = false;
      if (filters.age === 'stale' && age < 90)                show = false;
    }
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
  const priOrder = { critical: 0, high: 1, medium: 2, low: 3, none: 4 };
  document.querySelectorAll('details[data-repo] tbody').forEach(tbody => {
    const rows = Array.from(tbody.querySelectorAll('tr.issue-row'));
    rows.sort((a, b) => {
      if (by === 'oldest')   return parseInt(a.dataset.age, 10) - parseInt(b.dataset.age, 10);
      if (by === 'newest')   return parseInt(b.dataset.age, 10) - parseInt(a.dataset.age, 10);
      if (by === 'priority') return (priOrder[a.dataset.priority] ?? 4) - (priOrder[b.dataset.priority] ?? 4);
      return 0;
    });
    rows.forEach(r => tbody.appendChild(r));
  });
}

function exportData(fmt) {
  const rows = Array.from(document.querySelectorAll('tr.issue-row:not(.hidden)'));
  const data = rows.map(row => {
    const cells = row.querySelectorAll('td');
    const det   = row.closest('details');
    return {
      source:    det ? det.dataset.source : 'own',
      repo:      row.dataset.repo,
      type:      row.dataset.type,
      number:    cells[0].textContent.trim().replace('#', ''),
      url:       cells[0].querySelector('a') ? cells[0].querySelector('a').href : '',
      title:     cells[2].textContent.trim(),
      age_days:  parseInt(row.dataset.age, 10),
      priority:  row.dataset.priority,
      labels:    Array.from(cells[5].querySelectorAll('.label-tag')).map(t => t.textContent).join(', '),
      assignees: cells[6].textContent.trim().replace('—', ''),
      milestone: cells[7].textContent.trim().replace('—', ''),
      created:   cells[8].textContent.trim(),
      updated:   cells[9].textContent.trim()
    };
  });

  if (fmt === 'json') {
    dlBlob('dashboard.json', JSON.stringify(data, null, 2), 'application/json');
  } else {
    const headers = ['source','repo','type','number','title','age_days','priority','labels','assignees','milestone','created','updated','url'];
    const csv = [
      headers.join(','),
      ...data.map(d => headers.map(h => JSON.stringify(String(d[h] ?? ''))).join(','))
    ].join('\n');
    dlBlob('dashboard.csv', csv, 'text/csv');
  }
}

function dlBlob(filename, content, type) {
  const blob = new Blob([content], { type });
  const url  = URL.createObjectURL(blob);
  const a    = document.createElement('a');
  a.href = url; a.download = filename; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

applyFilters();
</script>
</body>
</html>
HTML_FOOT

rm -f "$TEMP_DATA" "$TEMP_PR_DATA" "$TEMP_UPSTREAM_PRS" "$TEMP_UPSTREAM_ISSUES"

echo "✅ Dashboard generated: $OUTPUT_FILE"
echo "📊 Own repos: $REPOS_WITH_ACTIVITY active, $TOTAL_ISSUES issues, $TOTAL_PRS PRs"
echo "⬆️  Upstream: $UPSTREAM_MY_PRS my PRs across $UPSTREAM_REPOS_WITH_MY_PRS repos; $UPSTREAM_ISSUES_TOTAL issues (collapsed)"
echo "📦 Excluded: $EOL_REPOS EOL repositories"
