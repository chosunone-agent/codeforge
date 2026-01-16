#!/bin/bash
# Manual test for suggestion-manager plugin
# Run this from a directory where OpenCode is running with the plugin loaded

set -e

PORT=${SUGGESTION_MANAGER_PORT:-4097}
BASE_URL="http://127.0.0.1:$PORT"

echo "=== Testing Suggestion Manager ==="
echo "Server: $BASE_URL"
echo

# 1. Health check
echo "1. Health check..."
curl -s "$BASE_URL/health" | jq .
echo

# 2. List suggestions (should be empty or have existing ones)
echo "2. List suggestions..."
curl -s "$BASE_URL/suggestions" | jq .
echo

# 3. If there are suggestions, get details of the first one
echo "3. Getting first suggestion (if any)..."
FIRST_ID=$(curl -s "$BASE_URL/suggestions" | jq -r '.suggestions[0].id // empty')
if [ -n "$FIRST_ID" ]; then
    echo "   Found suggestion: $FIRST_ID"
    curl -s "$BASE_URL/suggestions/$FIRST_ID" | jq .
else
    echo "   No suggestions found. Ask the AI to publish one!"
    echo
    echo "   Try telling the AI:"
    echo "   'Make a small change to a file and publish it as a suggestion for me to review'"
fi
echo

echo "=== Done ==="
