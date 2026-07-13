#!/bin/bash

# GitHub Issue Dashboard Generator
# Fetches all repos and open issues, generates HTML dashboard for GitHub Pages

OUTPUT_FILE="docs/index.html"
USERNAME="slmingol"

mkdir -p docs

echo "🔍 Fetching repositories..."

REPOS=$(gh repo list "$USERNAME" --limit 200 --json name,owner,hasIssuesEnabled,isArchived,repositoryTopics | \
  jq -r '.[] | select(.hasIssuesEnabled and (.isArchived | not)) |
    if ((.repositoryTopics // []) | map(.name) | any(. == "eol" or . == "end-of-life")) then empty else "\(.owner.login)/\(.name)" end')

TOTAL_REPOS=0
TOTAL_ISSUES=0
REPOS_WITH_ISSUES=0
TEMP_DATA=$(mktemp)

EOL_REPOS=$(gh repo list "$USERNAME" --limit 200 --json name,repositoryTopics | \
  jq '[.[] | select((.repositoryTopics // []) | map(.name) | any(. == "eol" or . == "end-of-life"))] | length')

echo "📝 Analyzing issues..."

while IFS= read -r repo; do
  ((TOTAL_REPOS++))
  echo "   Checking $repo..."
  ISSUES=$(gh issue list --repo "$repo" --state open --json number,title,labels,createdAt,updatedAt,url 2>/dev/null || echo "[]")
  ISSUE_COUNT=$(echo "$ISSUES" | jq '. | length')
  if [ "$ISSUE_COUNT" -gt 0 ]; then
    ((REPOS_WITH_ISSUES++))
    ((TOTAL_ISSUES += ISSUE_COUNT))
    NEWEST_TS=$(echo "$ISSUES" | jq -r '[.[].createdAt] | max | fromdate')
    echo "$NEWEST_TS|$repo|$ISSUE_COUNT|$ISSUES" >> "$TEMP_DATA"
  fi
done <<< "$REPOS"

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
    padding: 20px 32px; text-align: center; min-width: 160px;
  }
  .stat-number { font-size: 2em; font-weight: 700; color: #58a6ff; }
  .stat-label { font-size: 0.8em; color: #8b949e; margin-top: 4px; }

  h2 { font-size: 1.3em; color: #e6edf3; margin-bottom: 16px; padding-bottom: 8px; border-bottom: 1px solid #21262d; }

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
  summary .badge {
    margin-left: auto; font-size: 0.75em; font-weight: 600;
    padding: 2px 8px; border-radius: 12px; background: #21262d; color: #c9d1d9;
  }
  summary .badge.red    { background: #5d1a1a; color: #f97583; }
  summary .badge.orange { background: #3d2000; color: #e3a63a; }
  summary .badge.yellow { background: #2e2000; color: #d29922; }
  summary .badge.green  { background: #0f2d1a; color: #3fb950; }

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
  td.num { text-align: center; white-space: nowrap; width: 60px; }
  td.age { text-align: center; white-space: nowrap; width: 80px; font-size: 0.9em; }
  td.labels { width: 20%; font-size: 0.8em; color: #8b949e; }
  td.date { text-align: center; white-space: nowrap; width: 100px; font-size: 0.8em; color: #8b949e; }

  .label-tag {
    display: inline-block; padding: 1px 6px; border-radius: 12px;
    background: #21262d; font-size: 0.8em; margin: 1px 2px;
  }
  .age-new    { color: #3fb950; }
  .age-week   { color: #58a6ff; }
  .age-month  { color: #d29922; }
  .age-old    { color: #f97583; }

  footer { margin-top: 48px; text-align: center; font-size: 0.8em; color: #8b949e; border-top: 1px solid #21262d; padding-top: 24px; }
</style>
</head>
<body>
<header>
  <h1>📊 GitHub Issue Dashboard</h1>
  <p>Real-time overview of open issues across all repositories</p>
  <p class="updated">Last updated: <code>$LAST_UPDATED</code></p>
</header>

<div class="stats">
  <div class="stat"><div class="stat-number">$TOTAL_REPOS</div><div class="stat-label">Repositories Monitored</div></div>
  <div class="stat"><div class="stat-number">$REPOS_WITH_ISSUES</div><div class="stat-label">Repos with Issues</div></div>
  <div class="stat"><div class="stat-number">$TOTAL_ISSUES</div><div class="stat-label">Total Open Issues</div></div>
  <div class="stat"><div class="stat-number">$EOL_REPOS</div><div class="stat-label">EOL Repos (excluded)</div></div>
</div>

<h2>🗂️ Issues by Repository</h2>
HTML_HEAD

if [ "$REPOS_WITH_ISSUES" -gt 0 ]; then
  sort -t'|' -k1 -rn "$TEMP_DATA" | while IFS='|' read -r newest_ts repo issue_count issues; do
    REPO_NAME=$(echo "$repo" | cut -d'/' -f2)

    if [ "$issue_count" -ge 10 ]; then
      BADGE_CLASS="red";    COUNT_ICON="🔴"
    elif [ "$issue_count" -ge 5 ]; then
      BADGE_CLASS="orange"; COUNT_ICON="🟠"
    elif [ "$issue_count" -ge 3 ]; then
      BADGE_CLASS="yellow"; COUNT_ICON="🟡"
    else
      BADGE_CLASS="green";  COUNT_ICON="🟢"
    fi

    cat >> "$OUTPUT_FILE" << REPO_HDR
<details open>
<summary>
  <h3>$COUNT_ICON <a href="https://github.com/$repo">$REPO_NAME</a></h3>
  <span class="badge $BADGE_CLASS">$issue_count issues</span>
</summary>
<table>
<tr>
  <th class="center">#</th>
  <th>Title</th>
  <th class="center">Age</th>
  <th>Labels</th>
  <th class="center">Created</th>
  <th class="center">Updated</th>
</tr>
REPO_HDR

    echo "$issues" | jq -r 'sort_by(.createdAt) | reverse | .[] | @json' | while read -r issue_json; do
      NUM=$(echo "$issue_json" | jq -r '.number')
      TITLE=$(echo "$issue_json" | jq -r '.title' | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
      URL=$(echo "$issue_json" | jq -r '.url')
      LABELS_HTML=$(echo "$issue_json" | jq -r '.labels | if length == 0 then "—" else map("<span class=\"label-tag\">\(.name)</span>") | join(" ") end')
      CREATED=$(echo "$issue_json" | jq -r '.createdAt | fromdate | strftime("%Y-%m-%d")')
      UPDATED=$(echo "$issue_json" | jq -r '.updatedAt | fromdate | strftime("%Y-%m-%d")')

      CREATED_TS=$(echo "$issue_json" | jq -r '.createdAt | fromdate')
      DAYS_OLD=$(( ($(date +%s) - CREATED_TS) / 86400 ))

      if [ "$DAYS_OLD" -ge 90 ]; then
        AGE_CLASS="age-old";   AGE_ICON="🕰️"
      elif [ "$DAYS_OLD" -ge 30 ]; then
        AGE_CLASS="age-month"; AGE_ICON="📅"
      elif [ "$DAYS_OLD" -ge 7 ]; then
        AGE_CLASS="age-week";  AGE_ICON="🗓️"
      else
        AGE_CLASS="age-new";   AGE_ICON="🆕"
      fi

      cat >> "$OUTPUT_FILE" << ISSUE_ROW
<tr>
  <td class="num"><a href="$URL"><b>#$NUM</b></a></td>
  <td>$TITLE</td>
  <td class="age"><span class="$AGE_CLASS">$AGE_ICON ${DAYS_OLD}d</span></td>
  <td class="labels">$LABELS_HTML</td>
  <td class="date">$CREATED</td>
  <td class="date">$UPDATED</td>
</tr>
ISSUE_ROW
    done

    printf '</table>\n</details>\n\n' >> "$OUTPUT_FILE"
  done
else
  echo '<p style="text-align:center;padding:48px;color:#3fb950;font-size:1.2em">🎉 No open issues — all repositories are in great shape!</p>' >> "$OUTPUT_FILE"
fi

cat >> "$OUTPUT_FILE" << 'HTML_FOOT'
<footer>
  Powered by GitHub Actions &mdash; updates hourly &mdash;
  <a href="https://github.com/slmingol/github-issue-dashboard">View Repository</a>
</footer>
</body>
</html>
HTML_FOOT

rm -f "$TEMP_DATA"

echo "✅ Dashboard generated: $OUTPUT_FILE"
echo "📊 Summary: $REPOS_WITH_ISSUES repos with $TOTAL_ISSUES total issues"
echo "📦 Excluded: $EOL_REPOS EOL repositories"
