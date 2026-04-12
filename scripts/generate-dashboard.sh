#!/bin/bash

# GitHub Issue Dashboard Generator
# Fetches all repos and open issues, generates markdown dashboard

DASHBOARD_FILE="DASHBOARD.md"
USERNAME="slmingol"

echo "🔍 Fetching repositories..."

# Get all repos for user (including topics to check for EOL)
REPOS=$(gh repo list "$USERNAME" --limit 200 --json name,owner,hasIssuesEnabled,isArchived,repositoryTopics | \
  jq -r '.[] | select(.hasIssuesEnabled and (.isArchived | not)) | 
    if ((.repositoryTopics // []) | map(.name) | any(. == "eol" or . == "end-of-life")) then empty else "\(.owner.login)/\(.name)" end')

# Start building dashboard  
cat > "$DASHBOARD_FILE" << 'HEADER'
<div align="center">

# 📊 GitHub Issue Dashboard

### 🔍 Real-time overview of open issues across all repositories

<img src="https://img.shields.io/badge/Auto--Updated-Daily-blue?style=for-the-badge" alt="Auto Updated"/>

</div>

---

HEADER

echo "> 🕐 **Last Updated**: \`$(date -u '+%Y-%m-%d %H:%M:%S UTC')\`" >> "$DASHBOARD_FILE"
echo "" >> "$DASHBOARD_FILE"

# Summary vars
TOTAL_REPOS=0
TOTAL_ISSUES=0
REPOS_WITH_ISSUES=0
TEMP_DATA=$(mktemp)

# Get count of EOL repos for stats
EOL_REPOS=$(gh repo list "$USERNAME" --limit 200 --json name,repositoryTopics | \
  jq '[.[] | select((.repositoryTopics // []) | map(.name) | any(. == "eol" or . == "end-of-life"))] | length')

echo "📝 Analyzing issues..."

# Collect repo data
while IFS= read -r repo; do
  ((TOTAL_REPOS++))
  echo "   Checking $repo..."
  
  ISSUES=$(gh issue list --repo "$repo" --state open --json number,title,labels,createdAt,updatedAt,url 2>/dev/null || echo "[]")
  ISSUE_COUNT=$(echo "$ISSUES" | jq '. | length')
  
  if [ "$ISSUE_COUNT" -gt 0 ]; then
    ((REPOS_WITH_ISSUES++))
    ((TOTAL_ISSUES += ISSUE_COUNT))
    echo "$repo|$ISSUE_COUNT|$ISSUES" >> "$TEMP_DATA"
  fi
done <<< "$REPOS"

# Add summary stats
cat >> "$DASHBOARD_FILE" << STATS
<div align="center">

## 📈 Quick Stats

<table>
<tr>
<td align="center" width="25%">
<img src="https://img.shields.io/badge/Active_Repos-$TOTAL_REPOS-blue?style=for-the-badge&logo=github" alt="Active Repos"/>
<br/>
<sub>📚 Repositories Monitored</sub>
</td>
<td align="center" width="25%">
<img src="https://img.shields.io/badge/Repos_with_Issues-$REPOS_WITH_ISSUES-orange?style=for-the-badge&logo=github" alt="Repos with Issues"/>
<br/>
<sub>⚠️ Needs Attention</sub>
</td>
<td align="center" width="25%">
<img src="https://img.shields.io/badge/Open_Issues-$TOTAL_ISSUES-red?style=for-the-badge&logo=target" alt="Total Issues"/>
<br/>
<sub>🎯 Total Open Issues</sub>
</td>
<td align="center" width="25%">
<img src="https://img.shields.io/badge/EOL_Repos-$EOL_REPOS-gray?style=for-the-badge&logo=archive" alt="EOL Repos"/>
<br/>
<sub>📦 End of Life</sub>
</td>
</tr>
</table>

</div>

---

STATS

# Add detailed sections
if [ "$REPOS_WITH_ISSUES" -gt 0 ]; then
  echo "## 🗂️ Issues by Repository" >> "$DASHBOARD_FILE"
  echo "" >> "$DASHBOARD_FILE"
  
  sort -t'|' -k2 -rn "$TEMP_DATA" | while IFS='|' read -r repo issue_count issues; do
    REPO_NAME=$(echo "$repo" | cut -d'/' -f2)
    
    # Color code by issue count
    if [ "$issue_count" -ge 10 ]; then
      COUNT_COLOR="critical"; COUNT_ICON="🔴"
    elif [ "$issue_count" -ge 5 ]; then
      COUNT_COLOR="important"; COUNT_ICON="🟠"
    elif [ "$issue_count" -ge 3 ]; then
      COUNT_COLOR="yellow"; COUNT_ICON="🟡"
    else
      COUNT_COLOR="success"; COUNT_ICON="🟢"
    fi
    
    # Repo header
    cat >> "$DASHBOARD_FILE" << REPO_HDR
<details open>
<summary>

### $COUNT_ICON [\`$REPO_NAME\`](https://github.com/$repo) 
<img src="https://img.shields.io/badge/Issues-$issue_count-$COUNT_COLOR?style=flat-square" alt="$issue_count issues"/>

</summary>

<br/>

REPO_HDR
    
    # Process each issue
    echo "$issues" | jq -r '.[] | @json' | while read -r issue_json; do
      NUM=$(echo "$issue_json" | jq -r '.number')
      TITLE=$(echo "$issue_json" | jq -r '.title')
      URL=$(echo "$issue_json" | jq -r '.url')
      LABELS=$(echo "$issue_json" | jq -r '.labels | map(.name) | join(", ")')
      CREATED=$(echo "$issue_json" | jq -r '.createdAt | fromdate | strftime("%Y-%m-%d")')
      UPDATED=$(echo "$issue_json" | jq -r '.updatedAt | fromdate | strftime("%Y-%m-%d")')
      
      # Age calculation
      CREATED_TS=$(echo "$issue_json" | jq -r '.createdAt | fromdate')
      DAYS_OLD=$(( ($(date +%s) - CREATED_TS) / 86400 ))
      
      if [ "$DAYS_OLD" -ge 90 ]; then
        AGE_EMOJI="🕰️"; AGE_COLOR="inactive"
      elif [ "$DAYS_OLD" -ge 30 ]; then
        AGE_EMOJI="📅"; AGE_COLOR="yellow"
      elif [ "$DAYS_OLD" -ge 7 ]; then
        AGE_EMOJI="🗓️"; AGE_COLOR="green"
      else
        AGE_EMOJI="🆕"; AGE_COLOR="brightgreen"
      fi
      
      LABEL_TEXT=""
      [ -n "$LABELS" ] && LABEL_TEXT="  |  🏷️ $LABELS"
      
      # Issue card
      cat >> "$DASHBOARD_FILE" << ISSUE_CARD
<table>
<tr>
<td width="60" align="center">

**[#$NUM]($URL)**

</td>
<td>

**$TITLE**

$AGE_EMOJI <img src="https://img.shields.io/badge/Age-${DAYS_OLD}_days-$AGE_COLOR?style=flat-square" alt="$DAYS_OLD days old"/>$LABEL_TEXT

<sub>📅 Created: $CREATED  |  🔄 Updated: $UPDATED</sub>

</td>
</tr>
</table>

ISSUE_CARD
      
    done
    
    echo "</details>" >> "$DASHBOARD_FILE"
    echo "" >> "$DASHBOARD_FILE"
  done
else
  cat >> "$DASHBOARD_FILE" << 'NOCLEAR'
<div align="center">

## 🎉 All Clear!

<img width="400" src="https://media.giphy.com/media/3o7abKhOpu0NwenH3O/giphy.gif" alt="Success"/>

### No open issues found! 

All repositories are in great shape! ✨

</div>

NOCLEAR
fi

# Footer
cat >> "$DASHBOARD_FILE" << 'FOOTER'

---

<div align="center">

### 🤖 Automation Info

<img src="https://img.shields.io/badge/Powered_by-GitHub_Actions-2088FF?style=for-the-badge&logo=github-actions&logoColor=white" alt="GitHub Actions"/>
<img src="https://img.shields.io/badge/Updates-Daily_at_6AM_UTC-Success?style=for-the-badge&logo=clockify&logoColor=white" alt="Schedule"/>

<sub>📊 Dashboard automatically generated and updated daily</sub>  
<sub>🔗 [View Repository](https://github.com/slmingol/github-issue-dashboard) | [Manual Update](https://github.com/slmingol/github-issue-dashboard/actions/workflows/update-dashboard.yml)</sub>

</div>
FOOTER

rm -f "$TEMP_DATA"

echo "✅ Dashboard generated: $DASHBOARD_FILE"
echo "📊 Summary: $REPOS_WITH_ISSUES repos with $TOTAL_ISSUES total issues"
echo "📦 Excluded: $EOL_REPOS EOL repositories"
