# actions-usage-alert

Sends an alert when the org's GitHub Actions minutes for the month cross a threshold. The check runs twice a day.

GitHub's Free plan includes 2,000 Actions minutes a month, shared by every private repo in the org. GitHub has no built-in alert for free minutes: budgets only cover paid usage. This workflow fills that gap.

## How it works

1. `check-usage.sh` calls `GET /organizations/{org}/settings/billing/usage` for the current month (UTC). It sums the items where `product == "actions"` and `unitType == "Minutes"`, and groups them by repository.
2. It compares the total with `ALERT_THRESHOLD_MINUTES` and, if set, `ALERT_THRESHOLD_MINUTES_HIGH`.
3. For each threshold crossed for the first time this month, it sends one alert to every configured channel (Slack and/or email). The alert includes the total, the threshold, the included minutes, minutes per repo (highest first) and a link to the billing usage page.
4. It records each alert as an issue labelled `usage-alert`, titled `Actions usage YYYY-MM: crossed N minutes`. The next run sees that issue and doesn't alert again for the same threshold that month. The issues also serve as a history.

The repo is public on purpose: Actions minutes in public repos are free and don't count toward the quota, so the check keeps running after the quota is used up. For the same reason, **logs and issues show only totals**. Repository names and the per-repo breakdown go only to Slack/email, and secrets and raw API responses are never printed.

If a channel fails to send, the run fails and records nothing, so the next run tries again.

## Configuration

Settings → Secrets and variables → Actions.

### Secrets

| Name | Required | Purpose |
| --- | --- | --- |
| `BILLING_TOKEN` | yes | Fine-grained PAT that can read the org's billing usage (see below). |
| `SLACK_WEBHOOK_URL` | no | Slack incoming webhook. Turns on Slack alerts. |
| `RESEND_API_KEY` | no | [Resend](https://resend.com) API key. Turns on email alerts. |

### Variables

| Name | Default | Purpose |
| --- | --- | --- |
| `ALERT_THRESHOLD_MINUTES` | `1000` | First alert threshold, in minutes. |
| `ALERT_THRESHOLD_MINUTES_HIGH` | unset | Optional second threshold, e.g. `1600`. |
| `INCLUDED_MINUTES` | `2000` | Minutes included in the plan, used in the message. |
| `EMAIL_TO` | | Comma-separated recipients. Required for email. |
| `EMAIL_FROM` | | Sender, e.g. `Actions Alerts <alerts@example.com>`. Must be on a domain verified in Resend. Required for email. |
| `ORG` | repo owner | Org to check. |

Each channel turns on only when its secret is set. To switch channels, add or remove the secret.

### Creating `BILLING_TOKEN`

You need to be an owner of the org.

1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → **Generate new token**.
2. **Resource owner**: the org.
3. **Expiration**: as long as the org's policy allows. Put the renewal date in your calendar.
4. **Repository access**: *Public repositories* (it needs no repository access).
5. **Permissions → Organization permissions → Administration: Read-only**. Nothing else.
6. Generate the token. If the org requires approval for fine-grained tokens, approve it under Org settings → Personal access tokens → Pending requests.
7. Save it as the repo secret `BILLING_TOKEN`:
   ```sh
   gh secret set BILLING_TOKEN --repo <org>/actions-usage-alert
   ```

### Email via Resend

1. Create a Resend account, then add and verify a sending domain (DNS records).
2. Create an API key with *Sending access* only, and save it as `RESEND_API_KEY`.
3. Set the `EMAIL_FROM` and `EMAIL_TO` variables.

## Testing

Actions → *Actions usage alert* → **Run workflow**:

- **dry_run**: fetches usage and logs the total and which thresholds would alert. Sends and records nothing.
- **test_alert**: sends a `[TEST]` alert with the real numbers to every configured channel, whatever the thresholds. Records nothing.
- Both unchecked: a normal run, the same as the schedule.

From the CLI:

```sh
gh workflow run usage-alert.yml -f dry_run=true
gh workflow run usage-alert.yml -f test_alert=true
gh run watch
```

To make a threshold alert again this month, close and delete its issue, or rename it, then rerun.

## Changing the threshold

```sh
gh variable set ALERT_THRESHOLD_MINUTES --body 1200
gh variable set ALERT_THRESHOLD_MINUTES_HIGH --body 1600
gh variable delete ALERT_THRESHOLD_MINUTES_HIGH   # turn off the second threshold
```

To change the schedule, edit the `cron` line in `.github/workflows/usage-alert.yml`.

## Notes

- Usage data can lag by a few hours.
- GitHub disables scheduled workflows in repos with no activity for 60 days. Each scheduled run re-enables its own workflow to prevent that.
- The org's $0 Actions budget is separate. It stops paid usage once the free minutes are used up.
