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

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

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

jq -r --slurpfile members "$MEMBERS_JSON" \
'
  # Build user_id -> name lookup from members array
  ($members[0] | map({(.user_id): .name}) | add // {}) as $user_map |

  .[]
  | {
      title,
      created_at,
      acus_consumed,
      user_id,
      url,
      status,
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
  | [
      .title,
      .created_at_jst,
      (.acus_consumed | tostring),
      .user_name,
      .url,
      .status,
      .pr_info
    ]
  | @csv
' "$ALL_ITEMS" \
| sort -t',' -k2,2 \
| {
  printf '\xEF\xBB\xBF'
  echo '"セッション名","開始日時(JST)","消費ACU","ユーザー名","セッションURL","ステータス","PR情報"'
  cat
}
