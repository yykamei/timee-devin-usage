#!/bin/bash

set -uxo -o pipefail
curl \
  --request GET \
  --url "https://api.devin.ai/v3/organizations/org_swbgSzieLIzJ9xLY/sessions/devin-${1}/insights" \
  --header "Authorization: Bearer ${DEVIN_API_KEY}" \
  | jq .

