#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_JSON="${SCRIPT_DIR}/result.json"
MEMBERS_JSON="${SCRIPT_DIR}/members.json"

usage() {
  echo "Usage: $0 <start_date> <end_date>" >&2
  echo "  Dates in YYYY-MM-DD format (JST)" >&2
  echo "  Example: $0 2025-03-10 2025-03-14" >&2
  exit 1
}

if [[ $# -ne 2 ]]; then
  usage
fi

START_DATE="$1"
END_DATE="$2"

if ! [[ "$START_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! [[ "$END_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "Error: Dates must be in YYYY-MM-DD format." >&2
  usage
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required. Install it with: brew install jq" >&2
  exit 1
fi

# Convert YYYY-MM-DD to epoch (supports both macOS BSD date and GNU date)
to_epoch() {
  local datetime="$1"
  if date -j -f "%Y-%m-%d %H:%M:%S" "$datetime" "+%s" 2>/dev/null; then
    return
  fi
  date -d "$datetime" "+%s" 2>/dev/null && return
  echo "Error: Cannot parse date: $datetime" >&2
  exit 1
}

START_EPOCH=$(TZ=Asia/Tokyo to_epoch "${START_DATE} 00:00:00")
END_EPOCH=$(TZ=Asia/Tokyo to_epoch "${END_DATE} 23:59:59")

if [[ "$START_EPOCH" -gt "$END_EPOCH" ]]; then
  echo "Error: start_date must be before or equal to end_date." >&2
  exit 1
fi

for f in "$RESULT_JSON" "$MEMBERS_JSON"; do
  if [[ ! -f "$f" ]]; then
    echo "Error: File not found: $f" >&2
    exit 1
  fi
done

jq -r --argjson start "$START_EPOCH" \
      --argjson end "$END_EPOCH" \
      --slurpfile members "$MEMBERS_JSON" \
'
  # Build user_id -> name lookup from members array
  ($members[0] | map({(.user_id): .name}) | add // {}) as $user_map |

  .items[]
  | select(.created_at >= $start and .created_at <= $end)
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
' "$RESULT_JSON" \
| sort -t',' -k2,2 \
| {
  printf '\xEF\xBB\xBF'
  echo '"セッション名","開始日時(JST)","消費ACU","ユーザー名","セッションURL","ステータス","PR情報"'
  cat
}
