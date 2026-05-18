# Learning Deployment — A Hands-On GCP Tutorial

Welcome! This repository is a **guided learning project** that teaches you how to take a real fullstack web app from your laptop all the way to a production-style deployment on **Google Cloud Platform (GCP)**, with a real **CI/CD pipeline** powered by **GitHub Actions**.

> You will not just copy commands. You will understand **why** every piece of infrastructure exists.

---

## What you will build

A small but realistic fullstack app called **"TaskBoard"** — a personal task list with login.

| Layer            | Technology                                       |
| ---------------- | ------------------------------------------------ |
| Frontend (UI)    | React (built with Vite)                          |
| Frontend server  | Express.js (serves the built React + proxies API)|
| Backend API      | Python + FastAPI                                 |
| Database         | PostgreSQL                                       |
| Container runtime| Docker                                           |
| Cloud provider   | Google Cloud Platform                            |
| CI/CD            | GitHub + GitHub Actions                          |
| Registry         | Google Artifact Registry                         |
| Compute          | Compute Engine VMs in a custom VPC               |

---

## What you will learn

1. How to run a fullstack app locally with Docker Compose
2. What Docker actually does and why production uses it
3. What a **VPC** is, what **subnets** are, and how **firewall rules** work
4. The difference between **internal** and **external** IP addresses
5. How a **service account** authenticates a pipeline to a cloud
6. How a real **CI/CD pipeline** flows from `git push` to production
7. How frontend / backend / database talk to each other in a private network
8. Basic monitoring, logging, troubleshooting, and **cost control**

---

## How to use this repo

Follow the docs in order. Each chapter has **checkpoints**, **exercises**, and **"what just happened?"** explanations.

```
docs/
├── 00-introduction.md             ← Start here
├── 01-project-overview.md
├── 02-local-development.md
├── 03-docker-basics.md
├── 04-gcp-introduction.md
├── 05-vpc-networking.md
├── 06-compute-engine-deployment.md
├── 07-database-setup.md
├── 08-firewalls-and-security.md
├── 09-ci-cd-with-github-actions.md
├── 10-monitoring-and-logging.md
├── 11-troubleshooting.md
├── 12-cleanup-and-cost-management.md
└── 13-next-steps.md
```

The architecture diagram lives in `architecture.drawio`. To view or export:

1. Open https://app.diagrams.net (or install the VS Code **Draw.io Integration** extension).
2. **File → Open from → Device**, pick `architecture.drawio`.
3. To create `architecture.png`: **File → Export as → PNG…** — accept the defaults and save next to the `.drawio` file. The PNG is intentionally tracked by git so reviewers can preview the diagram inline.

---

## Prerequisites

Before you start chapter `00`, install:

- **Git** — https://git-scm.com/
- **Docker Desktop** — https://www.docker.com/products/docker-desktop/
- **Node.js 20+** — https://nodejs.org/
- **Python 3.11+** — https://www.python.org/
- A **Google Cloud account** with billing enabled (the free tier covers most of this tutorial)
- The **`gcloud` CLI** — https://cloud.google.com/sdk/docs/install

You do **not** need any prior cloud experience.

---

## Repository layout

```
.
├── README.md
├── docs/                        ← the tutorial (start here)
├── architecture.drawio          ← system architecture diagram
├── backend/                     ← FastAPI service
├── frontend/                    ← React app + Express server
├── docker-compose.yml           ← runs everything locally
├── .env.example                 ← copy to .env and fill in
├── .gitignore
└── .github/workflows/ci-cd.yml  ← the CI/CD pipeline
```

---

## A note on cost

Following this tutorial inside GCP's free tier should cost **less than $5** if you remember to run the cleanup script in chapter `12`. We tell you exactly which resources cost money and how to delete them.

> **Rule #1 of cloud**: if you stop following this tutorial, go to chapter `12` and clean up. Cloud resources keep billing you even when you're not looking.

---

## License

MIT — use this freely for learning, teaching, or as a base for your own projects.
