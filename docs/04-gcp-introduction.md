# Chapter 04 — GCP introduction

Time to leave your laptop. This chapter is about the **vocabulary and structure** of Google Cloud — the mental map you'll use for the rest of the tutorial. You won't deploy anything yet; you'll set up your account, your project, your billing, and your CLI.

If you're impatient, resist. Half of cloud confusion is people skipping the part where they learn what a "project" is.

---

## 1. The GCP mental map

GCP is organized as a tree:

```
Organization (optional, for companies)
└── Folder (optional)
    └── Project ← almost everything lives inside one
        ├── APIs/Services (Compute, Networking, Logging, …)
        ├── IAM (who can do what)
        ├── Resources (VMs, networks, buckets, …)
        └── Billing account (attached separately)
```

Key term: **Project**. Think of it as a Visual Studio Code workspace. Every resource you create (VM, network, image, etc.) is *inside* a project. Two different projects are firewalled from each other by default.

Each project has:

- A **Project ID** — globally unique, you choose at creation. *Lowercase, hyphens.* Example: `taskboard-learning-1`.
- A **Project Number** — auto-generated, all digits.
- A **Project Name** — display only, can be anything.

We'll use the ID everywhere.

---

## 2. APIs

In GCP, every service is exposed as an **API**. You "enable" the APIs you want to use. This sounds bureaucratic but it's actually nice:

- You only pay for what you enable.
- Disabling an API turns off a whole class of attack surface.
- The CLI verbs map 1:1 onto API endpoints.

We will enable a handful of APIs as we need them. There is no penalty for enabling one and not using it (other than slightly noisier logs).

---

## 3. Regions and zones

When you create resources, you choose **where** they live geographically.

- **Region** — a geographic area, e.g. `europe-west4` (Netherlands), `us-central1` (Iowa).
- **Zone** — a single data center inside a region, e.g. `europe-west4-a`.

```
europe-west4   (region)
├── europe-west4-a   (zone)
├── europe-west4-b   (zone)
└── europe-west4-c   (zone)
```

Two zones in the same region can fail independently but have very low latency between them. Multiple regions are for global resilience but expensive bandwidth between them.

> 💡 **Pick a region close to you** for this tutorial. We'll use `<your-region>` as a placeholder. Common choices: `europe-west4`, `us-central1`, `asia-southeast1`.

---

## 4. Install the gcloud CLI

If you haven't already, install Google Cloud SDK:

- https://cloud.google.com/sdk/docs/install

Verify:

```bash
gcloud --version
```

Then log in. This pops a browser:

```bash
gcloud auth login
```

This authenticates you, the human. Later we'll also create a **service account** — a "robot user" — for our CI/CD pipeline. Don't confuse the two.

---

## 5. Create a project

You can do this from the web console (cloud.google.com → top bar → "New Project") or the CLI:

```bash
gcloud projects create taskboard-learning-1 \
  --name="TaskBoard Learning"
```

Make sure to substitute a unique ID. If you see `Project ID already exists`, append a number.

Set it as your active project:

```bash
gcloud config set project taskboard-learning-1
```

Confirm:

```bash
gcloud config list
```

You should see your account and project printed.

---

## 6. Link a billing account

A new project has no billing account, so GCP will refuse to create paid resources.

1. Open the Google Cloud Console.
2. Top-left menu → **Billing**.
3. If you have no billing account yet, create one (you'll add a card; first-time accounts get $300 free credit).
4. Link your project to the billing account.

> ⚠️ **Pitfall**
> Many tutorials forget this and then say "huh, my command works locally but the cloud says PERMISSION_DENIED". This is the first place to check.

---

## 7. Enable the APIs we'll need

You can enable APIs as you go, but doing them up front avoids context-switching. Run:

```bash
gcloud services enable \
  compute.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  secretmanager.googleapis.com
```

Each line is a service:

| API                                  | What we'll use it for                            |
| ------------------------------------ | ------------------------------------------------ |
| `compute.googleapis.com`             | VMs, VPC, firewall (Compute Engine)              |
| `artifactregistry.googleapis.com`    | Storing our Docker images                        |
| `iam.googleapis.com`                 | Creating the CI/CD service account               |
| `iamcredentials.googleapis.com`      | Workload Identity Federation (no static keys)    |
| `logging.googleapis.com`             | Centralized logs in chapter 10                   |
| `monitoring.googleapis.com`          | Metrics and dashboards in chapter 10             |
| `secretmanager.googleapis.com`       | Storing JWT_SECRET safely in chapter 09          |

It's fine if the command takes a minute.

---

## 8. Set a default region and zone

So you don't have to type `--region` every time:

```bash
gcloud config set compute/region <your-region>
gcloud config set compute/zone <your-region>-a
```

For example: `europe-west4` and `europe-west4-a`.

---

## 9. The free tier

GCP's "Always Free" tier includes a small VM ("e2-micro" in one of the US regions) and a generous slice of network egress. For the *real* deployment we use `e2-small`, which costs around $13/month if left running 24/7. Cleanup matters.

Here's a survival rule that has saved more wallets than any other:

> Whenever you create a resource, also write the **delete** command into a notepad. When you're done learning, run them. Chapter 12 will give you a single script that does all of it.

---

## 10. Two ways to interact with GCP

You'll see all three of these in the tutorial:

1. **`gcloud` CLI** — what we mostly use. Scriptable, reproducible.
2. **Cloud Console** (the web UI at console.cloud.google.com) — great for *seeing* what you created.
3. **Infrastructure-as-Code** (Terraform, Pulumi) — what you'd use in real production teams. We mention it in chapter 13.

Beginners often only learn the console and then can't reproduce anything. We invert that: CLI first, console for inspection.

---

## 11. Quick sanity check

```bash
gcloud projects describe taskboard-learning-1
gcloud config list
gcloud services list --enabled
```

You should see your project, your account, and the APIs you enabled. If anything is missing, fix it before moving on. Cloud problems compound.

---

## 12. Checkpoint ✅

1. What's the difference between a **region** and a **zone**?
2. What is a GCP **project**, in one sentence?
3. Why do we enable APIs explicitly?
4. What's the difference between you logging in with `gcloud auth login` and a **service account**?

> Answers
> 1. Region = geographic area; zone = a data center inside that area. Zones in the same region fail independently and have low inter-zone latency.
> 2. A boundary that owns a set of resources, has its own IAM, and is billed independently.
> 3. To restrict attack surface, control cost, and make permissions explicit.
> 4. `gcloud auth login` authenticates a **human**. A service account is a **robot** identity for automation (CI/CD, apps) — no password, only keys or federation.

---

## 13. Optional exercise 🧪

Run `gcloud iam roles list --filter="name:roles/compute*"` and skim the list. You'll see things like `roles/compute.admin`, `roles/compute.viewer`. We won't grant any yet, but it's good to glimpse the surface. We'll come back to "least privilege" in chapter 09.

---

➡️ Next: [Chapter 05 — VPC networking](./05-vpc-networking.md)
