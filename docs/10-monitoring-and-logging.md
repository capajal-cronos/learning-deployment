# Chapter 10 — Monitoring and logging

A deployment that "works" is only the start. Real systems break, and the only difference between a healthy and a chaotic on-call is **observability** — knowing *what* the system is doing right now.

This chapter gives you the basics:

- Where logs live in GCP.
- How to find a specific error.
- Three metrics worth dashboarding.
- An uptime check and an alert.

---

## 1. What we mean by "observability"

A useful mental model: three pillars.

| Pillar     | Answers                                  | Tools in GCP                            |
| ---------- | ---------------------------------------- | --------------------------------------- |
| **Logs**   | "What happened, exactly?"                | Cloud Logging                           |
| **Metrics**| "Is the system healthy in aggregate?"    | Cloud Monitoring (Prometheus-compatible) |
| **Traces** | "Where did a single request spend time?" | Cloud Trace / OpenTelemetry             |

We focus on logs and metrics — they're 90% of the value for the first deploy.

---

## 2. Where the logs live

The Cloud Logging Agent is preinstalled on modern Compute Engine VMs. **Anything written to stdout/stderr by your container is automatically shipped to Cloud Logging.** That's why we made FastAPI use `PYTHONUNBUFFERED=1` and Express use `morgan` — those logs flow straight up to GCP.

To see them:

- Console: **Logging → Logs Explorer**.
- CLI:

```bash
# Last 10 backend log lines.
gcloud logging read \
  'resource.type="gce_instance" AND resource.labels.instance_id="<APP_VM_ID>" AND jsonPayload.message=~"uvicorn"' \
  --limit=10 --format=json
```

You can also tail in near-real-time:

```bash
gcloud logging tail \
  'resource.type="gce_instance" AND resource.labels.instance_id="<APP_VM_ID>"'
```

> 💡 The Logs Explorer UI has a query bar with autocomplete. Spend ten minutes there. It is the single most useful incident-response surface you have.

---

## 3. Structured logging beats string logging

Right now FastAPI logs plain text. The next upgrade — for a real product — is **structured JSON logs**:

```python
import logging, json, sys

class JsonFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({
            "severity": record.levelname,
            "message":  record.getMessage(),
            "logger":   record.name,
            "module":   record.module,
        })

handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
```

GCP recognizes the `severity` field and colors the log entry in the UI. You can also `gcloud logging read ... severity>=ERROR` to filter cleanly. Try this as an exercise.

---

## 4. Metrics that actually matter

For a web service, start with the **golden four**:

| Metric         | Why                                                   |
| -------------- | ----------------------------------------------------- |
| Latency        | Slow users churn faster than broken users complain.   |
| Traffic        | Spikes correlate with most outages.                   |
| Errors         | The first signal that something's wrong.              |
| Saturation     | CPU / memory / disk pressure → coming failure.        |

GCP gives you CPU, disk, and network utilization for free per VM. To get **HTTP-level** latency and errors, you have two options:

- **Cheap path**: parse the Express access logs into log-based metrics. Free.
- **Better path**: install the OpenTelemetry collector inside your containers and export to Cloud Monitoring. Out of scope for this chapter, recommended in chapter 13.

---

## 5. Set up an uptime check

This is the single most valuable 60 seconds you'll spend on monitoring.

```bash
PROJECT_ID=$(gcloud config get-value project)
EXT_IP=$(gcloud compute instances describe taskboard-app --format='get(networkInterfaces[0].accessConfigs[0].natIP)')

gcloud monitoring uptime create taskboard-healthz \
  --resource-type=uptime-url \
  --resource-labels=host=${EXT_IP},project_id=${PROJECT_ID} \
  --path="/healthz" \
  --period=1
```

GCP will now hit `/healthz` every minute from multiple regions. Look in **Monitoring → Uptime checks**.

To get a paging alert when it fails, create an **alerting policy** and attach a notification channel (email is the simplest):

1. **Monitoring → Alerting → Create policy**.
2. Add condition: "Uptime check failure" for `taskboard-healthz`.
3. Add notification: your email.

You can do this from the CLI too, but the UI is honestly clearer here.

---

## 6. Reading a real error

Here's a typical incident shape:

1. Pager fires: "uptime check failing for 2 minutes".
2. You open Logs Explorer, filter by the app VM.
3. The last few lines are backend tracebacks: `OperationalError: connection refused`.
4. You check the DB VM uptime check — also failing.
5. The DB VM disk is full (`df -h` reveals 100%).
6. Postgres has shut itself down.

That whole flow is a **15-minute fix** once you know where to look. Without observability, it's a 3-hour outage of "I don't know what's wrong."

> 💡 The single sharpest skill in operations isn't writing code. It's **fast triage**. Practice it in a non-emergency by triggering small failures on purpose.

---

## 7. Audit logs — who did what

Separate from app logs, GCP records every API call (who called it, on which resource, when). To peek:

```bash
gcloud logging read 'protoPayload.@type="type.googleapis.com/google.cloud.audit.AuditLog"' --limit 5
```

You'll see things like "github-deployer pulled image X at T". This is gold for forensics. Pay attention especially when it shows actions you didn't do — that's how you spot a leaked credential.

---

## 8. Cost monitoring

You can also alert on **money**. From the Cloud Console:

1. **Billing → Budgets & alerts → Create budget**.
2. Set a monthly amount (e.g. $10).
3. Choose thresholds (e.g. 50%, 90%, 100%) and notification emails.

This is the cheapest insurance against the "I forgot to clean up" story. Do it now. Seriously, pause the tutorial, set the budget, come back.

---

## 9. Checkpoint ✅

1. Where do `print()` and `console.log()` outputs end up after deployment?
2. What are the four "golden signals" of monitoring?
3. Why is an uptime check more valuable than CPU graphs alone?
4. What does the audit log tell you that app logs don't?

> Answers
> 1. Cloud Logging — automatically, via the logging agent that ships container stdout/stderr.
> 2. Latency, Traffic, Errors, Saturation.
> 3. Because an uptime check is the user's perspective; CPU might be fine while the app returns 500.
> 4. Every API action taken by every identity — who deployed, who changed firewall rules, who accessed secrets.

---

## 10. Optional exercise 🧪

Trigger a synthetic error and find it:

1. On the app VM, do `sudo docker stop taskboard-backend`.
2. Wait 90 seconds.
3. Open Logs Explorer and find the moment the frontend started returning 502/504s.
4. Restart the backend.

If you couldn't find the error window in under two minutes, your filters need refining — try filtering by `severity>=ERROR` and the VM instance ID.

---

➡️ Next: [Chapter 11 — Troubleshooting](./11-troubleshooting.md)
