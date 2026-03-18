#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MEMBERS_JSON="${SCRIPT_DIR}/members.json"

ORG_ID="org_swbgSzieLIzJ9xLY"
API_BASE="https://api.devin.ai/v3/organizations/${ORG_ID}/sessions"

usage() {
  echo "Usage: $0 <days>" >&2
  echo "  days: Number of past days to report (positive integer)" >&2
  echo "  Example: $0 5  (report sessions from the past 5 days)" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

DAYS="$1"

if ! [[ "$DAYS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: days must be a positive integer." >&2
  usage
fi

for cmd in jq curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: ${cmd} is required." >&2
    exit 1
  fi
done

if [[ -z "${DEVIN_API_KEY:-}" ]]; then
  echo "Error: DEVIN_API_KEY environment variable is not set." >&2
  exit 1
fi

if [[ ! -f "$MEMBERS_JSON" ]]; then
  echo "Error: File not found: $MEMBERS_JSON" >&2
  exit 1
fi

# Calculate the epoch timestamp for N days ago at 00:00:00 JST
calc_start_epoch() {
  local days="$1"
  if date -j -f "%Y-%m-%d %H:%M:%S" "2000-01-01 00:00:00" "+%s" &>/dev/null; then
    # macOS BSD date
    local target_date
    target_date=$(TZ=Asia/Tokyo date -j -v "-${days}d" "+%Y-%m-%d")
    TZ=Asia/Tokyo date -j -f "%Y-%m-%d %H:%M:%S" "${target_date} 00:00:00" "+%s"
  else
    # GNU date
    local target_date
    target_date=$(TZ=Asia/Tokyo date -d "${days} days ago" "+%Y-%m-%d")
    TZ=Asia/Tokyo date -d "${target_date} 00:00:00" "+%s"
  fi
}

START_EPOCH=$(calc_start_epoch "$DAYS")

if date -j -f "%Y-%m-%d %H:%M:%S" "2000-01-01 00:00:00" "+%s" &>/dev/null; then
  START_DATE=$(TZ=Asia/Tokyo date -j -v "-${DAYS}d" "+%Y-%m-%d")
  END_DATE=$(TZ=Asia/Tokyo date -j "+%Y-%m-%d")
else
  START_DATE=$(TZ=Asia/Tokyo date -d "${DAYS} days ago" "+%Y-%m-%d")
  END_DATE=$(TZ=Asia/Tokyo date "+%Y-%m-%d")
fi
OUTPUT_FILE="/tmp/devin-usage-${START_DATE}-${END_DATE}.csv"

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

INSIGHTS_JSON="${TMPDIR_WORK}/insights.json"

ALL_ITEMS="${TMPDIR_WORK}/all_items.json"
echo '[]' > "$ALL_ITEMS"

cursor=""
page=1
MAX_PAGES=100

while true; do
  url="${API_BASE}?first=200&created_after=${START_EPOCH}"
  if [[ -n "$cursor" ]]; then
    encoded_cursor=$(echo -n "$cursor" | jq -sRr @uri)
    url="${url}&after=${encoded_cursor}"
  fi

  echo "Fetching page ${page}..." >&2

  http_code=$(curl --silent --output "${TMPDIR_WORK}/response.json" \
    --write-out "%{http_code}" \
    --max-time 30 --connect-timeout 10 \
    --request GET \
    --url "$url" \
    --header "Authorization: Bearer ${DEVIN_API_KEY}")

  if [[ "$http_code" -ne 200 ]]; then
    echo "Error: API returned HTTP ${http_code}" >&2
    cat "${TMPDIR_WORK}/response.json" >&2
    echo >&2
    exit 1
  fi

  response=$(<"${TMPDIR_WORK}/response.json")

  items=$(echo "$response" | jq '.items // []')
  if [[ $(echo "$items" | jq 'type') != '"array"' ]]; then
    echo "Error: Unexpected API response (items is not an array)" >&2
    exit 1
  fi

  has_next=$(echo "$response" | jq -r '.has_next_page')
  end_cursor=$(echo "$response" | jq -r '.end_cursor // empty')

  merged=$(jq -s '.[0] + .[1]' "$ALL_ITEMS" <(echo "$items"))
  echo "$merged" > "$ALL_ITEMS"

  count=$(echo "$items" | jq 'length')
  total=$(jq 'length' "$ALL_ITEMS")
  echo "  Got ${count} sessions (total: ${total})" >&2

  if [[ "$has_next" != "true" ]]; then
    break
  fi

  if [[ "$page" -ge "$MAX_PAGES" ]]; then
    echo "Warning: Reached maximum page limit (${MAX_PAGES}). Results may be incomplete." >&2
    break
  fi

  cursor="$end_cursor"
  page=$((page + 1))
done

total=$(jq 'length' "$ALL_ITEMS")
echo "Fetched ${total} sessions total." >&2

# --- Phase 2: Fetch insights for each session ---
echo "Fetching insights for each session..." >&2

session_ids=$(jq -r '.[].session_id' "$ALL_ITEMS")

if [[ -z "$session_ids" ]]; then
  echo "No sessions found, skipping insights fetch." >&2
  echo '[]' > "$INSIGHTS_JSON"
else
  insights_count=0
  insights_total=$(echo "$session_ids" | wc -l | tr -d ' ')
  : > "${TMPDIR_WORK}/insights_lines.jsonl"

  while IFS= read -r sid; do
    insights_count=$((insights_count + 1))
    devin_id="devin-${sid}"
    echo "  Fetching insights ${insights_count}/${insights_total}: ${devin_id}..." >&2

    insights_http_code=$(curl --silent --output "${TMPDIR_WORK}/insight_response.json" \
      --write-out "%{http_code}" \
      --max-time 60 --connect-timeout 10 \
      --retry 2 --retry-delay 2 \
      --request GET \
      --url "${API_BASE}/${devin_id}/insights" \
      --header "Authorization: Bearer ${DEVIN_API_KEY}") || true

    if [[ "$insights_http_code" -ne 200 ]]; then
      echo "  Warning: Insights API returned HTTP ${insights_http_code} for ${devin_id}, skipping." >&2
      jq -nc --arg sid "$sid" '{session_id: $sid, original_prompt: null}' \
        >> "${TMPDIR_WORK}/insights_lines.jsonl"
      continue
    fi

    jq -c --arg sid "$sid" \
      '{session_id: $sid, original_prompt: (.analysis.suggested_prompt.original_prompt // null)}' \
      "${TMPDIR_WORK}/insight_response.json" \
      >> "${TMPDIR_WORK}/insights_lines.jsonl"

    sleep 0.3
  done <<< "$session_ids"

  jq -s '.' "${TMPDIR_WORK}/insights_lines.jsonl" > "$INSIGHTS_JSON"
  echo "Insights fetched for ${insights_total} sessions." >&2
fi

# --- Phase 3: Generate CSV output ---
jq -r --slurpfile members "$MEMBERS_JSON" --slurpfile insights "$INSIGHTS_JSON" \
'
  # Build user_id -> name lookup from members array
  ($members[0] | map({(.user_id): .name}) | add // {}) as $user_map |
  # Build session_id -> original_prompt lookup from insights array
  ($insights[0] | map({(.session_id): (.original_prompt // "")}) | add // {}) as $prompt_map |

  .[]
  | {
      session_id,
      title,
      created_at,
      acus_consumed,
      user_id,
      url,
      pull_requests
    }
  | .user_name = ($user_map[.user_id // ""] // .user_id // "unknown")
  | .created_at_jst = (.created_at + 9*3600
      | strftime("%Y-%m-%d %H:%M:%S"))
  | .pr_info = (
      if (.pull_requests // [] | length) == 0 then ""
      else
        [(.pull_requests // [])[] | "\(.pr_url)(\(.pr_state))"] | join(" | ")
      end
    )
  | .prompt = ($prompt_map[.session_id] // "" | gsub("\n"; " ") | gsub("\r"; ""))
  | [
      .title,
      .created_at_jst,
      (.acus_consumed | tostring),
      .user_name,
      .url,
      .pr_info,
      .prompt
    ]
  | @csv
' "$ALL_ITEMS" \
| sort -t',' -k2,2 \
| {
  printf '\xEF\xBB\xBF'
  echo '"セッション名","開始日時(JST)","消費ACU","ユーザー名","セッションURL","PR情報","プロンプト"'
  cat
} > "$OUTPUT_FILE"

echo "Report written to: ${OUTPUT_FILE}" >&2
