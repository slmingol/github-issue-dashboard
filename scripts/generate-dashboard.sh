#!/bin/bash
set -e

# GitHub Issue Dashboard Generator
# Fetches all repos and open issues, generates markdown dashboard

DASHBOARD_FILE="DASHBOARD.md"
USERNAME="slmingol"

echo "🔍 Fetching repositories..."

# Get all repos for user
REPOS=$(gh repo list "$USERNAME" --limit 200 --json name,owner,hasIssuesEnabled,isArchived,updatedAt | \
  jq -r '.[] | select(.hasIssuesEnabled and (.isArchived | not)) | "\(.owner.login)/\(.name)"')

# Start building dashboard
cat > "$DASHBOARD_FILE" << 'EOF'
# 📊 GitHub Issue Dashboard

> Auto-generated dashboard of open issues across all repositories

EOF

echo "**Last Updated**: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$DASHBOARD_FILE"
echo "" >> "$DASHBOARD_FILE"

# Summary section
TOTAL_REPOS=0
TOTAL_ISSUES=0
REPOS_WITH_ISSUES=0

# Temporary file for repo data
TEMP_DATA=$(mktemp)

echo "📝 Analyzing issues..."

while IFS= read -r repo; do
  ((TOTAL_REPOS++))
  
  echo "   Checking $repo..."
  
  # Get issues for this repo
  ISSUES=$(gh issue list --repo "$repo" --state open --json number,title,labels,createdAt,updatedAt,url 2>/dev/null || echo "[]")
  ISSUE_COUNT=$(echo "$ISSUES" | jq '. | length')
  
  if [ "$ISSUE_COUNT" -gt 0 ]; then
    ((REPOS_WITH_ISSUES++))
    ((TOTAL_ISSUES += ISSUE_COUNT))
    
    # Store repo data for later
    echo "$repo|$ISSUE_COUNT|$ISSUES" >> "$TEMP_DATA"
  fi
done <<< "$REPOS"

# Add summary
cat >> "$DASHBOARD_FILE" << EOF
## 📈 Summary

- 🗂️ **Total Repositories**: $TOTAL_REPOS
- ⚠️ **Repositories with Open Issues**: $REPOS_WITH_ISSUES
- 🎯 **Total Open Issues**: $TOTAL_ISSUES

---

EOF

# Add detailed sections for each repo with issues
if [ "$REPOS_WITH_ISSUES" -gt 0 ]; then
  echo "## 📋 Open Issues by Repository" >> "$DASHBOARD_FILE"
  echo "" >> "$DASHBOARD_FILE"
  
  # Sort by issue count (descending)
  sort -t'|' -k2 -rn "$TEMP_DATA" | while IFS='|' read -r repo issue_count issues; do
    echo "### 🔹 [$repo](https://github.com/$repo)" >> "$DASHBOARD_FILE"
    echo "" >> "$DASHBOARD_FILE"
    echo "**Open Issues**: $issue_count" >> "$DASHBOARD_FILE"
    echo "" >> "$DASHBOARD_FILE"
    
    # Parse and display each issue
    echo "$issues" | jq -r '.[] | 
      "| [#\(.number)](\(.url)) | \(.title) | \(.labels | map(.name) | join(", ")) | \(.createdAt | fromdate | strftime("%Y-%m-%d")) |"' | \
    {
      echo "| Issue | Title | Labels | Created |"
      echo "|-------|-------|--------|---------|"
      cat
    } >> "$DASHBOARD_FILE"
    
    echo "" >> "$DASHBOARD_FILE"
  done
else
  echo "## 🎉 No Open Issues!" >> "$DASHBOARD_FILE"
  echo "" >> "$DASHBOARD_FILE"
  echo "All repositories are issue-free! ✨" >> "$DASHBOARD_FILE"
  echo "" >> "$DASHBOARD_FILE"
fi

# Add footer
cat >> "$DASHBOARD_FILE" << 'EOF'

---

<p align="center">
  <sub>Dashboard generated automatically by <a href="https://github.com/slmingol/github-issue-dashboard">GitHub Issue Dashboard</a></sub>
</p>
EOF

# Cleanup
rm -f "$TEMP_DATA"

echo "✅ Dashboard generated: $DASHBOARD_FILE"
echo "📊 Summary: $REPOS_WITH_ISSUES repos with $TOTAL_ISSUES total issues"
