# Chapter 00 — Introduction

> *"You don't deploy code. You deploy a **system**."*

Welcome. This is the first chapter of a guided tour that takes you from a laptop with an empty terminal to a real, internet-reachable web application running on Google Cloud, fronted by HTTPS, defended by a firewall, and redeployed automatically every time you push to GitHub.

Take your time. The goal is **understanding**, not speed.

---

## 1. Why this tutorial exists

Most "deploy to the cloud" tutorials look like this:

1. Click here.
2. Paste this command.
3. 🎉 You're done.

You get a green ✅ at the end. But two weeks later, something breaks and you have no idea where to look — because you never learned what the system actually is.

This tutorial is the opposite. Every command, file, and resource has a **why** attached. We will sometimes go slower than you want. That's the point.

---

## 2. What you will build

A small fullstack app called **TaskBoard**:

```
┌────────┐    HTTPS    ┌──────────────────────┐    HTTP     ┌─────────────┐
│Browser │ ──────────► │ Express  (frontend)  │ ──────────► │ FastAPI     │
└────────┘             │ + static React build │             │  backend    │
                       └──────────────────────┘             └──────┬──────┘
                                                                   │ SQL
                                                                   ▼
                                                            ┌────────────┐
                                                            │ PostgreSQL │
                                                            └────────────┘
```

A user can register, log in, and manage a personal task list. That's it. Small enough to ship, big enough to teach.

By the end of the tutorial, this exact diagram will be deployed on Google Cloud, inside your own private network, with a CI/CD pipeline doing the work for you.

---

## 3. What you will learn

| Topic                     | Why it matters                                         |
| ------------------------- | ------------------------------------------------------ |
| **Docker**                | "It runs on my machine" is not a deploy strategy.      |
| **Docker Compose**        | The cheapest way to think in multi-service systems.   |
| **VPCs**                  | A private network is the foundation of cloud security. |
| **Subnets & IP ranges**   | Where your services actually live.                     |
| **Firewall rules**        | The bouncer between the internet and your servers.     |
| **Compute Engine**        | Renting a server by the hour.                          |
| **Artifact Registry**     | Where your Docker images go to live.                   |
| **Service accounts**      | How a robot proves who it is to GCP.                   |
| **GitHub Actions**        | Turning `git push` into a deploy.                      |
| **Logs & monitoring**     | Finding out what your app did at 3am.                  |
| **Cleanup & cost**        | Avoiding a surprise bill.                              |

---

## 4. Mental model: code → system → service

When most beginners think about "deploying", they think about **moving files**. That's only one layer.

```
                ┌────────────────────────────────────┐
                │  Layer 4 — Service (what users see)│
                │   • a URL that returns your app    │
                │   • uptime, latency, error rate    │
                └────────────────────────────────────┘
                          ▲ depends on ▲
                ┌────────────────────────────────────┐
                │  Layer 3 — Infrastructure          │
                │   • VPC, subnets, firewalls        │
                │   • VMs, load balancer, DNS        │
                └────────────────────────────────────┘
                          ▲ depends on ▲
                ┌────────────────────────────────────┐
                │  Layer 2 — Packaging               │
                │   • Docker image                   │
                │   • image registry                 │
                └────────────────────────────────────┘
                          ▲ depends on ▲
                ┌────────────────────────────────────┐
                │  Layer 1 — Code                    │
                │   • your source                    │
                │   • your tests                     │
                └────────────────────────────────────┘
```

We will build this stack **from the bottom up**. Code first, then containers, then the cloud network, then the VM, then the pipeline that drives the whole thing.

If you ever feel lost, come back to this diagram and ask: *which layer am I in right now?*

---

## 5. How each chapter is structured

Each chapter follows the same rhythm:

1. **Concept** — the idea, in plain English.
2. **Why it exists** — what problem it solves.
3. **Hands-on** — a command, a file, or a click in the GCP console.
4. **What just happened?** — a short re-explanation of what you did.
5. **Checkpoint** — a tiny self-check before moving on.
6. **Common mistakes** — things that have burned everyone at least once.
7. **Exercises** *(optional)* — small experiments to deepen understanding.

When you see this box:

> 🧠 **Think first**
> A question. Try to answer before reading the next paragraph.

…take ten seconds to actually think. The tutorial is 10× more useful if you do.

---

## 6. What you need before chapter 01

Open a terminal and check each of these:

| Tool        | Command                  | Why                           |
| ----------- | ------------------------ | ----------------------------- |
| Git         | `git --version`          | Version control               |
| Docker      | `docker --version`       | Build / run containers        |
| Compose     | `docker compose version` | Multi-container orchestration |
| Node.js 20+ | `node --version`         | Frontend build                |
| Python 3.11+| `python --version`       | Backend                       |
| gcloud      | `gcloud --version`       | Talk to Google Cloud          |

If any of those fail, install the missing tool first (links in the [README](../README.md)).

You also need:

- A **GitHub account** (free).
- A **Google Cloud account** with **billing enabled**. New accounts get $300 in free credit. We design every step to stay under the free tier where possible.

---

## 7. A note on cost

Most resources in this tutorial are free or cost cents per hour. The risk is **forgetting to clean up**. A single `e2-small` VM left running 24/7 is about $13/month — small, but multiply that by a few half-finished tutorials and it adds up.

Chapter `12` is the cleanup chapter. **Bookmark it now.**

---

## 8. Conventions in the docs

- Commands you should run look like this:
  ```bash
  echo "hello"
  ```
- Things to fill in are in `<angle brackets>`:
  ```bash
  gcloud config set project <your-project-id>
  ```
- Output you should see is shown after the command:
  ```bash
  $ docker --version
  Docker version 27.3.1, build ce12230
  ```
- 💡 = tip
- ⚠️ = pitfall
- 🧪 = exercise
- ✅ = checkpoint

---

## 9. Checkpoint ✅

Before moving on, you should be able to answer:

1. What are the four layers of "deployment" as described in section 4?
2. What does this tutorial value more — understanding or speed?
3. What is the **one** thing you must do if you stop midway?

> Answers
> 1. Code, Packaging, Infrastructure, Service.
> 2. Understanding.
> 3. Run the cleanup in chapter 12, or you will be billed.

---

➡️ Next: [Chapter 01 — Project overview](./01-project-overview.md)
