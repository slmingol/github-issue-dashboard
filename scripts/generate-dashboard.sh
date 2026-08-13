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
TOTAL_ASSIGNED=0
TOTAL_WITH_MILESTONE=0
TEMP_DATA=$(mktemp)

EOL_REPOS=$(gh repo list "$USERNAME" --limit 200 --json name,repositoryTopics | \
  jq '[.[] | select((.repositoryTopics // []) | map(.name) | any(. == "eol" or . == "end-of-life"))] | length')

echo "📝 Analyzing issues..."

while IFS= read -r repo; do
  ((TOTAL_REPOS++))
  echo "   Checking $repo..."
  ISSUES=$(gh issue list --repo "$repo" --state open \
    --json number,title,labels,createdAt,updatedAt,url,milestone,assignees 2>/dev/null || echo "[]")
  ISSUE_COUNT=$(echo "$ISSUES" | jq '. | length')
  if [ "$ISSUE_COUNT" -gt 0 ]; then
    ((REPOS_WITH_ISSUES++))
    ((TOTAL_ISSUES += ISSUE_COUNT))
    ASSIGNED=$(echo "$ISSUES" | jq '[.[] | select(.assignees | length > 0)] | length')
    ((TOTAL_ASSIGNED += ASSIGNED))
    WITH_MILESTONE=$(echo "$ISSUES" | jq '[.[] | select(.milestone != null)] | length')
    ((TOTAL_WITH_MILESTONE += WITH_MILESTONE))
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
    padding: 20px 32px; text-align: center; min-width: 140px;
  }
  .stat-number { font-size: 2em; font-weight: 700; color: #58a6ff; }
  .stat-label { font-size: 0.8em; color: #8b949e; margin-top: 4px; }

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
  tr.hidden { display: none; }
  td.num      { text-align: center; white-space: nowrap; width: 60px; }
  td.age      { text-align: center; white-space: nowrap; width: 80px; font-size: 0.9em; }
  td.priority { text-align: center; white-space: nowrap; width: 80px; }
  td.labels   { width: 18%; font-size: 0.8em; color: #8b949e; }
  td.assignee { width: 10%; font-size: 0.8em; }
  td.milestone{ width: 10%; font-size: 0.8em; }
  td.date     { text-align: center; white-space: nowrap; width: 100px; font-size: 0.8em; color: #8b949e; }

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

  .milestone-tag {
    display: inline-block; padding: 1px 6px; border-radius: 4px;
    background: #1f3a5f; color: #79c0ff; font-size: 0.8em;
  }

  .toc { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 32px; padding: 16px 20px; background: #161b22; border: 1px solid #30363d; border-radius: 8px; }
  .toc a { text-decoration: none; }
  .toc a:hover .badge { opacity: 0.8; outline: 1px solid #58a6ff; }

  .legend { display: flex; gap: 32px; flex-wrap: wrap; justify-content: center; margin-bottom: 32px; padding: 16px 20px; background: #161b22; border: 1px solid #30363d; border-radius: 8px; }
  .legend-group { display: flex; flex-direction: column; gap: 8px; }
  .legend-title { font-size: 0.75em; font-weight: 600; color: #8b949e; text-transform: uppercase; letter-spacing: 0.05em; }
  .legend-items { display: flex; gap: 16px; flex-wrap: wrap; align-items: center; font-size: 0.85em; }
  .legend-items .badge { margin: 0; }

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
  <div class="stat"><div class="stat-number">$TOTAL_ASSIGNED</div><div class="stat-label">Assigned Issues</div></div>
  <div class="stat"><div class="stat-number">$TOTAL_WITH_MILESTONE</div><div class="stat-label">Milestoned Issues</div></div>
  <div class="stat"><div class="stat-number">$EOL_REPOS</div><div class="stat-label">EOL Repos (excluded)</div></div>
</div>

<h2>🗗 Legend</h2>
<div class="legend">
  <div class="legend-group">
    <div class="legend-title">Repo Issue Count</div>
    <div class="legend-items">
      <span class="badge red">🔴 10+ issues</span>
      <span class="badge orange">🟠 5–9 issues</span>
      <span class="badge yellow">🟡 3–4 issues</span>
      <span class="badge green">🟢 1–2 issues</span>
    </div>
  </div>
  <div class="legend-group">
    <div class="legend-title">Issue Age</div>
    <div class="legend-items">
      <span class="age-new">🆕 &lt; 7 days</span>
      <span class="age-week">🗓️ 7–29 days</span>
      <span class="age-month">📅 30–89 days</span>
      <span class="age-old">🕰️ 90+ days</span>
    </div>
  </div>
  <div class="legend-group">
    <div class="legend-title">Priority (from labels)</div>
    <div class="legend-items">
      <span class="pri-critical">● Critical/P0</span>
      <span class="pri-high">● High/P1</span>
      <span class="pri-medium">● Medium/P2</span>
      <span class="pri-low">● Low/P3</span>
      <span class="pri-none">● None</span>
    </div>
  </div>
</div>

<h2>🗂️ Issues by Repository</h2>
HTML_HEAD

if [ "$REPOS_WITH_ISSUES" -gt 0 ]; then
  # Filter/sort/export controls
  cat >> "$OUTPUT_FILE" << 'CONTROLS'
<div class="controls">
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
      <button class="ctrl-btn" onclick="setFilter('priority','none',this)">None</button>
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
    <div class="ctrl-label">Milestone</div>
    <div class="ctrl-buttons">
      <button class="ctrl-btn active" onclick="setFilter('milestone','all',this)">All</button>
      <button class="ctrl-btn" onclick="setFilter('milestone','yes',this)">Has Milestone</button>
      <button class="ctrl-btn" onclick="setFilter('milestone','no',this)">No Milestone</button>
    </div>
  </div>
  <div class="ctrl-group">
    <div class="ctrl-label">Sort Issues By</div>
    <div class="ctrl-buttons">
      <button class="ctrl-btn active" onclick="sortIssues('newest',this)">Newest First</button>
      <button class="ctrl-btn" onclick="sortIssues('oldest',this)">Oldest First</button>
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

  # Table of contents
  echo '<div class="toc">' >> "$OUTPUT_FILE"
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
    printf '<a href="#%s"><span class="badge %s">%s %s (%s)</span></a>\n' \
      "$REPO_NAME" "$BADGE_CLASS" "$COUNT_ICON" "$REPO_NAME" "$issue_count" >> "$OUTPUT_FILE"
  done
  echo '</div>' >> "$OUTPUT_FILE"

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
<details id="$REPO_NAME" data-repo="$REPO_NAME" open>
<summary>
  <h3>$COUNT_ICON <a href="https://github.com/$repo">$REPO_NAME</a></h3>
  <span class="badge $BADGE_CLASS">$issue_count issues</span>
</summary>
<table>
<thead>
<tr>
  <th class="center">#</th>
  <th>Title</th>
  <th class="center">Age</th>
  <th class="center">Priority</th>
  <th>Labels</th>
  <th>Assignees</th>
  <th>Milestone</th>
  <th class="center">Created</th>
  <th class="center">Updated</th>
</tr>
</thead>
<tbody>
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

      # Priority detection from labels (#3)
      PRIORITY=$(echo "$issue_json" | jq -r '
        .labels | map(.name | ascii_downcase) |
        if any(. == "critical" or . == "p0" or . == "blocker" or . == "urgent") then "critical"
        elif any(. == "high" or . == "p1" or . == "high-priority" or . == "priority: high") then "high"
        elif any(. == "medium" or . == "p2" or . == "medium-priority" or . == "priority: medium") then "medium"
        elif any(. == "low" or . == "p3" or . == "low-priority" or . == "priority: low" or . == "minor") then "low"
        else "none" end')

      case "$PRIORITY" in
        critical) PRI_DISPLAY='<span class="pri-critical">🔴 Critical</span>' ;;
        high)     PRI_DISPLAY='<span class="pri-high">🟠 High</span>' ;;
        medium)   PRI_DISPLAY='<span class="pri-medium">🟡 Medium</span>' ;;
        low)      PRI_DISPLAY='<span class="pri-low">🔵 Low</span>' ;;
        *)        PRI_DISPLAY='<span class="pri-none">—</span>' ;;
      esac

      # Assignees (#5)
      ASSIGNEES_HTML=$(echo "$issue_json" | jq -r \
        '.assignees | if length == 0 then "—" else map("<a href=\"https://github.com/\(.login)\">\(.login)</a>") | join(", ") end')
      HAS_ASSIGNEE=$(echo "$issue_json" | jq -r 'if (.assignees | length) > 0 then "true" else "false" end')

      # Milestone (#2)
      MILESTONE_TITLE=$(echo "$issue_json" | jq -r \
        '.milestone | if . == null then "" else .title | gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;") end')
      HAS_MILESTONE=$(echo "$issue_json" | jq -r 'if .milestone != null then "true" else "false" end')
      if [ "$HAS_MILESTONE" = "true" ]; then
        MILESTONE_DISPLAY="<span class=\"milestone-tag\">🏁 $MILESTONE_TITLE</span>"
      else
        MILESTONE_DISPLAY="—"
      fi

      cat >> "$OUTPUT_FILE" << ISSUE_ROW
<tr class="issue-row" data-age="$DAYS_OLD" data-priority="$PRIORITY" data-assigned="$HAS_ASSIGNEE" data-milestone="$HAS_MILESTONE" data-repo="$REPO_NAME">
  <td class="num"><a href="$URL"><b>#$NUM</b></a></td>
  <td>$TITLE</td>
  <td class="age"><span class="$AGE_CLASS">$AGE_ICON ${DAYS_OLD}d</span></td>
  <td class="priority">$PRI_DISPLAY</td>
  <td class="labels">$LABELS_HTML</td>
  <td class="assignee">$ASSIGNEES_HTML</td>
  <td class="milestone">$MILESTONE_DISPLAY</td>
  <td class="date">$CREATED</td>
  <td class="date">$UPDATED</td>
</tr>
ISSUE_ROW
    done

    printf '</tbody>\n</table>\n</details>\n\n' >> "$OUTPUT_FILE"
  done
else
  echo '<p style="text-align:center;padding:48px;color:#3fb950;font-size:1.2em">🎉 No open issues — all repositories are in great shape!</p>' >> "$OUTPUT_FILE"
fi

cat >> "$OUTPUT_FILE" << 'HTML_FOOT'
<footer>
  Powered by GitHub Actions &mdash; updates hourly &mdash;
  <a href="https://github.com/slmingol/github-issue-dashboard">View Repository</a>
</footer>

<script>
const filters = { age: 'all', priority: 'all', assignee: 'all', milestone: 'all' };

function setFilter(type, val, btn) {
  filters[type] = val;
  btn.closest('.ctrl-buttons').querySelectorAll('.ctrl-btn').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  applyFilters();
}

function applyFilters() {
  let visible = 0;
  document.querySelectorAll('tr.issue-row').forEach(row => {
    const age      = parseInt(row.dataset.age, 10);
    const pri      = row.dataset.priority;
    const assigned = row.dataset.assigned === 'true';
    const ms       = row.dataset.milestone === 'true';

    let show = true;
    if (filters.age !== 'all') {
      if (filters.age === 'new'   && age >= 7)               show = false;
      if (filters.age === 'week'  && (age < 7 || age >= 30)) show = false;
      if (filters.age === 'month' && (age < 30 || age >= 90))show = false;
      if (filters.age === 'stale' && age < 90)               show = false;
    }
    if (filters.priority !== 'all' && pri !== filters.priority) show = false;
    if (filters.assignee === 'assigned'   && !assigned)         show = false;
    if (filters.assignee === 'unassigned' && assigned)          show = false;
    if (filters.milestone === 'yes' && !ms)                     show = false;
    if (filters.milestone === 'no'  && ms)                      show = false;

    row.classList.toggle('hidden', !show);
    if (show) visible++;
  });

  document.querySelectorAll('details[data-repo]').forEach(det => {
    const hasVisible = det.querySelectorAll('tr.issue-row:not(.hidden)').length > 0;
    det.style.display = hasVisible ? '' : 'none';
  });

  const total = document.querySelectorAll('tr.issue-row').length;
  const el = document.getElementById('filter-count');
  if (el) el.textContent = visible === total ? `${total} issues` : `${visible} / ${total} issues`;
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
  const rows = Array.from(document.querySelectorAll('tr.issue-row'));
  const data = rows.map(row => {
    const cells = row.querySelectorAll('td');
    return {
      repo:      row.dataset.repo,
      number:    cells[0].textContent.trim().replace('#', ''),
      url:       cells[0].querySelector('a') ? cells[0].querySelector('a').href : '',
      title:     cells[1].textContent.trim(),
      age_days:  parseInt(row.dataset.age, 10),
      priority:  row.dataset.priority,
      labels:    Array.from(cells[4].querySelectorAll('.label-tag')).map(t => t.textContent).join(', ') || '',
      assignees: cells[5].textContent.trim().replace('—', ''),
      milestone: cells[6].textContent.trim().replace('—', ''),
      created:   cells[7].textContent.trim(),
      updated:   cells[8].textContent.trim()
    };
  });

  if (fmt === 'json') {
    dlBlob('dashboard.json', JSON.stringify(data, null, 2), 'application/json');
  } else {
    const headers = ['repo','number','title','age_days','priority','labels','assignees','milestone','created','updated','url'];
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

rm -f "$TEMP_DATA"

echo "✅ Dashboard generated: $OUTPUT_FILE"
echo "📊 Summary: $REPOS_WITH_ISSUES repos with $TOTAL_ISSUES total issues (assigned: $TOTAL_ASSIGNED, milestoned: $TOTAL_WITH_MILESTONE)"
echo "📦 Excluded: $EOL_REPOS EOL repositories"
