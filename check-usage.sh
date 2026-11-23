#!/usr/bin/env bash
# Checks this month's GitHub Actions minutes for an org and alerts (Slack and/or
# email) once per threshold per month. Alerts are recorded as issues in this repo.
#
# This repo is public, so logs show only computed totals: never raw API
# responses, never repository names, never secrets.
set -euo pipefail

: "${ORG:?ORG is required}"
: "${BILLING_TOKEN:?BILLING_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
THRESHOLD="${THRESHOLD:-1000}"
THRESHOLD_HIGH="${THRESHOLD_HIGH:-}"
INCLUDED_MINUTES="${INCLUDED_MINUTES:-2000}"
DRY_RUN="${DRY_RUN:-false}"
TEST_ALERT="${TEST_ALERT:-false}"
LABEL="usage-alert"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

year="$(date -u +%Y)"
month="$(date -u +%m)"
period="$year-$month"
billing_url="https://github.com/organizations/$ORG/settings/billing/usage"
run_url="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/${GITHUB_RUN_ID:-0}"

# --- Fetch usage (response goes to a file, never to the log) ----------------
if ! GH_TOKEN="$BILLING_TOKEN" gh api \
  "/organizations/$ORG/settings/billing/usage?year=$year&month=$((10#$month))" \
  >"$tmp/usage.json" 2>"$tmp/err"; then
  # gh's error line is the API message (e.g. "HTTP 403: ..."), not the body.
  echo "::error::Billing usage request failed: $(head -c 300 "$tmp/err")"
  exit 1
fi

# Per-repo minutes, highest first: [{repo, minutes}]
jq '[.usageItems[]
     | select(.product == "actions" and .unitType == "Minutes")]
    | group_by(.repositoryName // "")
    | map({repo: (.[0].repositoryName // "" | if . == "" then "(no repository)" else . end),
           minutes: (map(.quantity) | add)})
    | sort_by(-.minutes)' "$tmp/usage.json" >"$tmp/repos.json"

total="$(jq '(map(.minutes) | add // 0) | round' "$tmp/repos.json")"
repo_count="$(jq 'length' "$tmp/repos.json")"
pct=$(( total * 100 / INCLUDED_MINUTES ))

echo "Period: $period (UTC)"
echo "Actions minutes used: $total of $INCLUDED_MINUTES included ($pct%) across $repo_count repositories"
{
  echo "### Actions usage $period"
  echo "**$total** of $INCLUDED_MINUTES included minutes used ($pct%)."
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"

# --- Which thresholds are crossed and not yet alerted? -----------------------
title_for() { echo "Actions usage $period: crossed $1 minutes"; }

thresholds=("$THRESHOLD")
[[ -n "$THRESHOLD_HIGH" ]] && thresholds+=("$THRESHOLD_HIGH")

GH_TOKEN="$GITHUB_TOKEN" gh issue list --repo "$GITHUB_REPOSITORY" --state all \
  --label "$LABEL" --limit 500 --json title --jq '.[].title' >"$tmp/titles"

new=()
for t in "${thresholds[@]}"; do
  [[ "$t" =~ ^[0-9]+$ ]] || { echo "::error::Threshold '$t' is not a whole number"; exit 1; }
  if (( total >= t )); then
    if grep -qxF "$(title_for "$t")" "$tmp/titles"; then
      echo "Threshold $t: crossed, already alerted this month"
    else
      echo "Threshold $t: crossed, alert due"
      new+=("$t")
    fi
  else
    echo "Threshold $t: not crossed"
  fi
done

if [[ "$TEST_ALERT" == "true" ]]; then
  echo "Test alert requested: sending regardless of thresholds; nothing will be recorded"
  prefix="[TEST] "
  shown_threshold="${thresholds[0]}"
elif (( ${#new[@]} == 0 )); then
  echo "No alert needed."
  exit 0
else
  prefix=""
  shown_threshold="${new[${#new[@]}-1]}"   # highest newly crossed
fi

# --- Build the message (only sent to private channels, never logged) --------
breakdown="$(jq -r '.[] | "\(.minutes | (. * 10 | round) / 10 | tostring | (" " * ([8 - length, 0] | max)) + .)  \(.repo)"' "$tmp/repos.json")"
subject="${prefix}GitHub Actions usage: $total of $INCLUDED_MINUTES minutes used in $period ($ORG)"
body="${prefix}GitHub Actions minutes for $ORG crossed $shown_threshold minutes in $period.

Used:      $total minutes ($pct% of $INCLUDED_MINUTES included)
Threshold: $shown_threshold minutes
Remaining: $(( INCLUDED_MINUTES - total )) minutes

Minutes by repository (highest first):
$breakdown

Billing usage: $billing_url
Alert run:     $run_url"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run: would alert for threshold $shown_threshold; nothing sent or recorded."
  exit 0
fi

# --- Send -------------------------------------------------------------------
sent=0
failed=0

if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
  slack_text="*${prefix}GitHub Actions usage alert: $ORG*
*$total* of $INCLUDED_MINUTES included minutes used in $period ($pct%). Threshold: $shown_threshold.
\`\`\`
$breakdown
\`\`\`
<$billing_url|Billing usage> · <$run_url|Alert run>"
  code="$(jq -n --arg text "$slack_text" '{text: $text}' |
    curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      --data-binary @- "$SLACK_WEBHOOK_URL" 2>/dev/null || echo "000")"
  if [[ "$code" == 2* ]]; then echo "Slack: sent"; sent=$((sent + 1))
  else echo "::error::Slack: failed (HTTP $code)"; failed=$((failed + 1)); fi
else
  echo "Slack: not configured"
fi

if [[ -n "${RESEND_API_KEY:-}" ]]; then
  : "${EMAIL_TO:?EMAIL_TO is required when RESEND_API_KEY is set}"
  : "${EMAIL_FROM:?EMAIL_FROM is required when RESEND_API_KEY is set}"
  code="$(jq -n --arg from "$EMAIL_FROM" --arg to "$EMAIL_TO" --arg subject "$subject" --arg text "$body" \
      '{from: $from, to: ($to | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))),
        subject: $subject, text: $text}' |
    curl -sS -o /dev/null -w '%{http_code}' -X POST https://api.resend.com/emails \
      -H "Authorization: Bearer $RESEND_API_KEY" -H 'Content-Type: application/json' \
      --data-binary @- 2>/dev/null || echo "000")"
  if [[ "$code" == 2* ]]; then echo "Email: sent"; sent=$((sent + 1))
  else echo "::error::Email: failed (HTTP $code)"; failed=$((failed + 1)); fi
else
  echo "Email: not configured"
fi

if (( failed > 0 )); then
  echo "::error::An alert channel failed; not recording, so the next run retries."
  exit 1
fi
(( sent == 0 )) && echo "::warning::No alert channel configured; the issue below is the only alert."

[[ "$TEST_ALERT" == "true" ]] && exit 0

# --- Record (public issue: totals only, no repository names) ----------------
GH_TOKEN="$GITHUB_TOKEN" gh label create "$LABEL" --repo "$GITHUB_REPOSITORY" \
  --color D93F0B --description "Monthly Actions usage threshold alerts" --force >/dev/null
for t in "${new[@]}"; do
  GH_TOKEN="$GITHUB_TOKEN" gh issue create --repo "$GITHUB_REPOSITORY" --label "$LABEL" \
    --title "$(title_for "$t")" \
    --body "Org Actions minutes reached **$total** of $INCLUDED_MINUTES included in $period (threshold: $t). Per-repository details were sent to the alert channels.

[Billing usage]($billing_url) · [Alert run]($run_url)" >/dev/null
  echo "Recorded threshold $t"
done
