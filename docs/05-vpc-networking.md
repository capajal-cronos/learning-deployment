# Chapter 05 — VPC networking

This is the chapter most cloud tutorials skip and most career-long professionals wish they'd read sooner. Take your time. Networking is the *foundation* — once you understand it, the rest of the cloud is just things plugged into it.

By the end of this chapter you'll be able to answer:

- What is a **VPC**?
- What is a **subnet** and why are there ranges of IP addresses?
- What is the difference between an **internal** and an **external** IP?
- What is a **route** and a **firewall rule**?
- How does a request from the internet actually reach my VM?

---

## 1. Why a "private network" exists

Imagine renting a server room in a warehouse. Other tenants are next to you. You wouldn't want their cables plugged into your machines, and you wouldn't want every internet stranger able to ping your DB.

A **VPC (Virtual Private Cloud)** is *your own software-defined network* inside Google's data centers. Only the resources you put inside it can use its private IPs to talk to each other. The internet is *outside* by default.

Visually:

```
                       ┌────────────────────────────────────────┐
                       │            VPC: taskboard-vpc          │
                       │                                        │
   internet            │   ┌─────────────────────────────────┐  │
       │               │   │  Subnet: app-subnet (10.10.0/24)│  │
       ▼               │   │   ┌──────────┐   ┌──────────┐   │  │
  ┌─────────┐  HTTPS   │   │   │  app VM  │◄─►│  db VM   │   │  │
  │firewall ├──────────┼──►│   │ 10.10.0.5│   │10.10.0.6 │   │  │
  └─────────┘ 443 only │   │   └──────────┘   └──────────┘   │  │
                       │   └─────────────────────────────────┘  │
                       └────────────────────────────────────────┘
```

Inside the VPC, the two VMs reach each other via `10.10.0.x` — fast, private, free. Outside traffic can only enter via specific firewall rules.

---

## 2. IP addresses in two minutes

An IPv4 address is 4 numbers, each 0–255: `10.10.0.5`. Some ranges are reserved as **private** (RFC 1918):

- `10.0.0.0 – 10.255.255.255`
- `172.16.0.0 – 172.31.255.255`
- `192.168.0.0 – 192.168.255.255`

These addresses are **not routable on the public internet**. Your home router uses them. So does every VPC.

A **subnet** carves out a *contiguous range*. We write ranges in **CIDR** notation: `10.10.0.0/24`.

```
10.10.0.0/24     →  256 addresses (10.10.0.0 to 10.10.0.255)
10.10.0.0/16     →  65,536 addresses
10.10.0.0/28     →  16 addresses
```

The number after the slash is how many bits are **fixed**. Higher number = smaller range.

> 💡 **Rule of thumb**: a `/24` subnet (256 IPs) is plenty for a learning project. Pick non-overlapping ranges if you ever connect VPCs together later.

---

## 3. What "internal" vs "external" IP means

Every VM gets at least one **internal IP** — the one inside the VPC. Optionally, GCP can also attach an **external IP** — a public, internet-routable address.

| Property             | Internal IP            | External IP                  |
| -------------------- | ---------------------- | ---------------------------- |
| Range                | private (10.x, etc.)   | public (any non-private IP)  |
| Reachable from       | only the VPC           | the entire internet          |
| Reachable to         | same                   | needs firewall rule          |
| Cost                 | free                   | small hourly fee             |
| Default             | yes                   | yes (we'll disable for the DB)|

For our deployment:

- **App VM** has an internal IP **and** a public IP (so users can reach it).
- **DB VM** has an internal IP **only**. Nobody on the internet can address it.

That's the security win we want.

---

## 4. Subnets and "regional vs global"

In GCP, a VPC is **global** but each subnet is **regional**. That means:

- You can have one VPC that spans the world.
- Each region inside it has its own subnet with its own IP range.
- Two VMs in different regions in the same VPC can still talk to each other privately, over Google's backbone.

For us, one VPC + one subnet in our chosen region is enough.

---

## 5. Routes and the default route

A **route** says: "to reach this destination IP range, send the packet to this next hop."

When you create a VPC, GCP automatically adds:

- An **internal route** for each subnet's CIDR → "deliver locally".
- A **default route** `0.0.0.0/0` → the **internet gateway**, used for all other destinations.

That's why a VM with an external IP can reach the internet without you doing anything. The route already exists.

> 🧠 **Think first**
> Our DB VM has *no* external IP. Can it install OS updates from the internet? Why or why not?

By default, no — packets can leave (via the internal route → … → internet gateway) but the response needs a way back. Without an external IP, packets from the internet can't return to it. The standard fix is **Cloud NAT**: a managed NAT gateway that gives internal-only VMs outbound internet without giving them an inbound public address.

This bites you immediately, by the way: the DB VM's startup script needs to `apt-get install postgresql-16` from `deb.debian.org` and `www.postgresql.org` — both public internet destinations. Without Cloud NAT in place, the DB VM's first boot will fail with a wall of `Network is unreachable` and `connection timed out` errors, no `postgres` user gets created, and step 7 of chapter 07 (the `pg_dump` exercise) breaks with `sudo: unknown user postgres`. **Set up Cloud NAT before you create the DB VM** — instructions are in section 8 below.

---

## 6. Firewall rules — the *real* gate

A firewall rule in GCP is a sentence:

> Allow / deny  traffic  on  these protocols/ports  to  these targets  from  these sources.

Default rules in a new auto-mode VPC are pretty permissive. We're creating a **custom-mode** VPC so we control every rule.

Examples we'll create later:

| Name                       | Direction | Source         | Target tag      | Protocol/Port | Why                                          |
| -------------------------- | --------- | -------------- | --------------- | ------------- | -------------------------------------------- |
| `allow-ssh-from-iap`       | ingress   | IAP CIDR       | `app`,`db`      | tcp:22        | SSH only via IAP (no public 22 open)         |
| `allow-http-public`        | ingress   | 0.0.0.0/0      | `app`           | tcp:80,443    | Users reach the app                          |
| `allow-internal-db`        | ingress   | 10.10.0.0/24   | `db`            | tcp:5432      | Backend → DB *only inside the VPC*           |
| `deny-everything-else`     | implicit  | —              | —               | —             | Implicit deny — GCP default                  |

The trick: **target tags**. Each VM is tagged (`--tags=app` or `--tags=db`) and rules apply to the tag. Adding a VM to the tag puts it under the rule — much cleaner than maintaining IP lists.

> 💡 GCP firewall rules are **stateful**. If you allow a TCP connection in one direction, the response is automatically allowed back.

---

## 7. Hands-on — create the VPC and subnet

Replace `<your-region>` with the region you set in chapter 04.

```bash
# 1. The VPC itself (custom mode → no auto subnets).
gcloud compute networks create taskboard-vpc \
  --subnet-mode=custom \
  --bgp-routing-mode=regional

# 2. A subnet inside it.
gcloud compute networks subnets create app-subnet \
  --network=taskboard-vpc \
  --region=<your-region> \
  --range=10.10.0.0/24
```

Verify:

```bash
gcloud compute networks list
gcloud compute networks subnets list --filter="network~taskboard-vpc"
```

You should see your VPC and the subnet with CIDR `10.10.0.0/24`.

> 🖥️ **See it in the UI:** Console → **VPC network → VPC networks** shows `taskboard-vpc`; click it to see its subnets, IP ranges, routes, and (later) firewall rules all on one page. It's the clearest way to *picture* the network you just built from the CLI.

### What just happened?

You created an *empty* private network. No VMs in it yet. Behind the scenes, GCP also added:

- A route `10.10.0.0/24 → local` for the subnet.
- A route `0.0.0.0/0 → default internet gateway`.
- Default-deny ingress on everything.

You can confirm:

```bash
gcloud compute routes list --filter="network~taskboard-vpc"
gcloud compute firewall-rules list --filter="network=taskboard-vpc" --format=json
```

Routes: two. Firewall rules: zero — printed as an empty list `[]` (we'll add ours in chapter 08).

> 💡 Without `--format=json`, `gcloud` prints a notice like *"To show all fields of the firewall, please show in JSON format"* instead of a result, because there are no rows to render in a table. Asking for JSON gives you a clean `[]`.

### "Why is everything empty?" — a sanity check

Right after creating the VPC, it's normal to run a few `list` commands and see nothing. Three things to know:

**1. Subnets list is empty until you create one.**
You used `--subnet-mode=custom`, which means *"don't auto-create subnets in every region, I'll define them myself"*. The opposite, `--subnet-mode=auto`, would have spawned a `/20` in every GCP region — convenient but wasteful and harder to reason about. Custom mode starts you with zero subnets on purpose. Run command 2 above (`networks subnets create app-subnet ...`) and re-run the list.

**2. Routes list looks empty with `=`, but routes do exist.**
Every VPC gets default routes automatically. The catch is the `network` field stores a full URL like `https://www.googleapis.com/compute/v1/projects/.../networks/taskboard-vpc`, not the short name. So `--filter="network=taskboard-vpc"` matches nothing. Use the substring operator instead:

```bash
gcloud compute routes list --filter="network~taskboard-vpc"
```

The `~` means "contains". You'll see the default `0.0.0.0/0` route (your doorway to the internet) plus a route per subnet once subnets exist.

**3. Firewall rules list is genuinely empty — and that's the point.**
A brand-new custom VPC has **zero** firewall rules. GCP's default policy is *deny all ingress, allow all egress*, so nothing can reach your VMs until you add allow rules (we do that in chapter 08). An empty list here is the secure default, not a bug.

---

## 8. Cloud NAT — outbound internet for private VMs

Our DB VM is created with `--no-address` (no external IP) so the internet can't reach it. But it still needs to *talk to* the internet for one critical thing: installing Postgres during first boot. Without a way out, the startup script's `apt-get install postgresql-16` hangs and times out, no `postgres` user is ever created, and the DB VM ends up broken.

### First: what is NAT?

**NAT** stands for **Network Address Translation**. It's the trick that lets a machine with a *private* IP address (one that's not reachable from the public internet) still *talk to* the internet by borrowing a public IP for the duration of each connection.

You already use NAT every day without thinking about it. Your laptop at home has a private IP like `192.168.1.42` — that address means nothing on the public internet. When you load a webpage, your home router does the translation:

```
   Laptop                  Router (your public IP: 84.12.5.99)              Internet
   192.168.1.42  ──────►   src 192.168.1.42 → rewritten to src 84.12.5.99   ──────►  google.com
                ◄──────    dst 84.12.5.99 → rewritten to dst 192.168.1.42   ◄──────
```

Two key properties of NAT:

1. **It rewrites the source IP on the way out**, so the destination server sees the *router's* public IP, not the laptop's private one.
2. **It remembers the mapping** so it can deliver the reply back to the right laptop. The router keeps a table: "this outgoing connection from 192.168.1.42 is using public port X — any reply on port X goes back to 192.168.1.42."

A side effect: NAT is naturally **one-way**. A random server on the internet *cannot* initiate a connection to your laptop, because the router has no entry for it in the translation table. The connection has to start from the inside. That's why NAT doubles as a basic firewall.

### Cloud NAT is the same idea, but managed by GCP

Your home router does NAT for your home network. **Cloud NAT** does NAT for your VPC: it gives private VMs (the ones created with `--no-address`) a borrowed public IP to use when they need to reach the internet, while keeping them un-reachable from the internet.

It's the same pattern as your home network, just GCP-managed and region-scoped instead of running on a physical box in your living room.

### Mental model

```
   DB VM (no external IP, 10.10.0.6)
            │
            │  outbound packet to www.postgresql.org
            ▼
   ┌──────────────────────────┐
   │  Cloud NAT in <region>   │   ← rewrites source IP to a public NAT IP
   └──────────┬───────────────┘
              │
              ▼
        internet
```

Inbound from the internet? Still blocked. The VM has no external IP and no firewall rule lets random sources in. Cloud NAT is **strictly outbound** — exactly like your home router doesn't let random people from the internet open connections to your laptop.

### Hands-on — create the NAT gateway

You need two resources: a **Cloud Router** (a logical control plane object — even though we're not actually routing BGP) and a **NAT config** attached to it.

```bash
REGION=<your-region>     # same region as your subnet

# 1. The Cloud Router — required scaffolding, even for NAT-only use.
gcloud compute routers create taskboard-router \
  --network=taskboard-vpc \
  --region=$REGION

# 2. The NAT config — applies to every subnet in this region, with
#    auto-allocated public NAT IPs (cheap and fine for a tutorial).
gcloud compute routers nats create taskboard-nat \
  --router=taskboard-router \
  --region=$REGION \
  --nat-all-subnet-ip-ranges \
  --auto-allocate-nat-external-ips
```

Verify:

```bash
gcloud compute routers nats list --router=taskboard-router --region=$REGION
```

You should see `taskboard-nat` with `--nat-all-subnet-ip-ranges` enabled.

> 🖥️ **See it in the UI:** Console → **Network services → Cloud NAT** shows your gateway, the auto-allocated NAT IP(s), and a per-VM usage breakdown once VMs start talking out.

### When to create it

**Before** you create the DB VM in chapter 06. Startup scripts run *once* at first boot; if the script fails because there's no internet, rebooting won't re-run it. You'd either have to delete and recreate the VM, or run the script manually over SSH (annoying — see chapter 11 for that recovery).

### Who actually uses Cloud NAT?

Once Cloud NAT exists in a region, it automatically covers every `--no-address` VM in that region — you don't attach it to specific VMs. But it's only relevant for VMs *without* an external IP. The split for our tutorial:

| VM              | External IP?        | How it reaches the internet                              |
| --------------- | ------------------- | -------------------------------------------------------- |
| `taskboard-app` | Yes                 | Directly, via its own external IP. **Bypasses Cloud NAT.** |
| `taskboard-db`  | No (`--no-address`) | Through Cloud NAT. **Required, or apt installs fail.**   |

A VM that already has an external IP is its own door to the internet — adding NAT to the path would be redundant. NAT is *only* a workaround for the missing public address on private VMs.

### Does every VM "need" NAT?

The better question is *"should every VM be `--no-address`?"*, and the answer is **yes for almost everything except VMs that must be directly reachable from the public internet**. The grown-up pattern:

- DB, internal services, workers, build runners → `--no-address`, outbound via Cloud NAT, reachable only inside the VPC.
- Public-facing front door → a **load balancer** with a public IP, with the actual VMs sitting behind it as `--no-address`. The LB is the only thing with a public address.

In this tutorial we cheat by giving the app VM its own external IP, because you don't have a load balancer set up yet. That's fine for learning; in production you'd put the app VM behind an HTTPS LB and drop its external IP — at which point Cloud NAT covers *every* VM in the project, not just the DB.

### Cost note

Cloud NAT has a small per-hour charge for the gateway plus per-GB egress. For a tutorial it's a few cents a day. When you tear everything down in chapter 12, also delete the NAT and router (we cover this in the cleanup script).

---

## 9. The end-to-end picture

Here's how a packet will eventually flow once everything is built:

```
   user (browser)
         │ TCP 443 (HTTPS)
         ▼
   ┌─────────────────────────┐
   │ External IP of app VM   │   ← attached only to the app VM
   └─────────┬───────────────┘
             │   firewall rule: allow-http-public on tag "app"
             ▼
   ┌─────────────────────────┐
   │  app VM                 │   Express:3000 → backend:8000 (containers)
   │  internal: 10.10.0.5    │
   └─────────┬───────────────┘
             │   firewall rule: allow-internal-db on tag "db"
             │   only sources in 10.10.0.0/24 allowed
             ▼
   ┌─────────────────────────┐
   │  db VM                  │   Postgres:5432
   │  internal: 10.10.0.6    │
   │  NO external IP         │
   └─────────────────────────┘
```

If you understand this picture, you understand cloud networking better than 80% of devs.

---

## 10. Common beginner mistakes

| Mistake                                              | Fix / explanation                                                          |
| ---------------------------------------------------- | -------------------------------------------------------------------------- |
| Using a giant `/16` "to be safe"                     | Wastes IP space and increases blast radius. `/24` is plenty here.          |
| Opening 5432/tcp to `0.0.0.0/0`                      | Now anyone on the internet can probe your DB. Use source `10.10.0.0/24`.   |
| Giving the DB an external IP                        | Same problem at the network layer. Don't.                                  |
| Confusing the VPC's CIDR with the subnet's CIDR      | The VPC has no CIDR. Only subnets do. The VPC is just a logical container. |
| Forgetting that the default action is **deny ingress** | If your VM is unreachable, you probably just forgot a firewall rule.     |

---

## 11. Checkpoint ✅

1. What's the difference between a VPC and a subnet?
2. Why is a private IP like `10.10.0.5` not reachable from the internet?
3. What does it mean that GCP firewall rules are **stateful**?
4. If a VM has no external IP, can the internet reach it?

> Answers
> 1. The VPC is the network-level container; subnets are regional CIDR slices inside it where VMs actually live.
> 2. Public routers refuse to forward private-range addresses. They're only meaningful inside one organization's network.
> 3. If an outbound packet is allowed, the return packet is allowed automatically. You don't need a reverse rule.
> 4. Not directly. With careful infra (NAT, load balancer, IAP), you can expose specific services, but the VM itself is not addressable from the public internet.

---

## 12. Optional exercise 🧪

Run:

```bash
gcloud compute routes list --filter="network~taskboard-vpc"
```

You'll see two routes. Pick the `0.0.0.0/0` route and look at the next-hop field. What does the value mean?

(Answer: it's the default internet gateway, which is the doorway out of your VPC to the rest of the internet.)

---

➡️ Next: [Chapter 06 — Compute Engine deployment](./06-compute-engine-deployment.md)
