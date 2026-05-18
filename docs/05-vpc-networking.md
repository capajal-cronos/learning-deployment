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

By default, no — packets can leave (via the internal route → … → internet gateway) but the response needs a way back. Without an external IP, packets from the internet can't return to it. The standard fix is **Cloud NAT**: a managed NAT gateway that gives internal-only VMs outbound internet without giving them an inbound public address. We mention this again in chapter 13.

For this tutorial, we'll keep the DB simple by installing Postgres at VM creation time and not relying on outbound internet later.

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

### What just happened?

You created an *empty* private network. No VMs in it yet. Behind the scenes, GCP also added:

- A route `10.10.0.0/24 → local` for the subnet.
- A route `0.0.0.0/0 → default internet gateway`.
- Default-deny ingress on everything.

You can confirm:

```bash
gcloud compute routes list --filter="network=taskboard-vpc"
gcloud compute firewall-rules list --filter="network=taskboard-vpc"
```

Routes: two. Firewall rules: zero (we'll add ours in chapter 08).

---

## 8. The end-to-end picture

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

## 9. Common beginner mistakes

| Mistake                                              | Fix / explanation                                                          |
| ---------------------------------------------------- | -------------------------------------------------------------------------- |
| Using a giant `/16` "to be safe"                     | Wastes IP space and increases blast radius. `/24` is plenty here.          |
| Opening 5432/tcp to `0.0.0.0/0`                      | Now anyone on the internet can probe your DB. Use source `10.10.0.0/24`.   |
| Giving the DB an external IP                        | Same problem at the network layer. Don't.                                  |
| Confusing the VPC's CIDR with the subnet's CIDR      | The VPC has no CIDR. Only subnets do. The VPC is just a logical container. |
| Forgetting that the default action is **deny ingress** | If your VM is unreachable, you probably just forgot a firewall rule.     |

---

## 10. Checkpoint ✅

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

## 11. Optional exercise 🧪

Run:

```bash
gcloud compute routes list --filter="network=taskboard-vpc"
```

You'll see two routes. Pick the `0.0.0.0/0` route and look at the next-hop field. What does the value mean?

(Answer: it's the default internet gateway, which is the doorway out of your VPC to the rest of the internet.)

---

➡️ Next: [Chapter 06 — Compute Engine deployment](./06-compute-engine-deployment.md)
