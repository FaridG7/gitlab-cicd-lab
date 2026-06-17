# GitLab CI/CD Lab — Node.js Service Deployment

An end-to-end DevOps pipeline that provisions a virtual machine with Terraform, then builds and deploys a Node.js application to it through a **self-hosted GitLab CI/CD** pipeline running Ansible, behind a security-hardened Nginx reverse proxy.

> Built as a learning project following the [roadmap.sh **Node.js Service Deployment**](https://roadmap.sh/projects/nodejs-service-deployment) guide, with two deliberate substitutions to keep the entire stack running locally and free of charge:
>
> - **Local libvirt/KVM VM instead of DigitalOcean** — provisioned with Terraform, no public IP or cloud account required.
> - **Self-hosted GitLab instead of GitHub Actions** — no public IP means no inbound webhook for GitHub, so GitLab runs as a container on the host.
>
> The goal was to practice the full lifecycle — Infrastructure as Code, configuration management, CI/CD, reverse-proxy hardening — in a realistic, reproducible home lab.

---

## Table of Contents

- [Architecture](#architecture)
- [How the Pipeline Works](#how-the-pipeline-works)
- [Repository Layout](#repository-layout)
- [Tech Stack](#tech-stack)
- [Prerequisites](#prerequisites)
- [Getting Started](#getting-start)
- [Configuration Reference](#configuration-reference)
- [Key Engineering Decisions](#key-engineering-decisions)
- [Troubleshooting](#troubleshooting)
- [Project History](#project-history)
- [Sub-project READMEs](#sub-project-readmes)
- [License](#license)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              HOST MACHINE                               │
│                                                                         │
│  ┌───────────────────────┐        ┌──────────────────────────────────┐  │
│  │  Self-hosted GitLab   │        │  libvirt / KVM                   │  │
│  │  ┌─────────────────┐  │  push  │  ┌────────────────────────────┐  │  │
│  │  │  Git repo + CI  │◄─┼────────┤  │  Ubuntu 24.04 VM           │  │  │
│  │  └────────┬────────┘  │        │  │  (192.168.122.100)         │  │  │
│  │           │           │        │  │                            │  │  │
│  │  ┌────────▼────────┐  │ deploy │  │  ┌──────────┐ ┌─────────┐  │  │  │
│  │  │  GitLab Runner  │──┼────────┼─►│  │ Nginx    │►│ Node.js │  │  │  │
│  │  │  (Ansible job)  │  │  SSH   │  │  │ (HTTPS)  │ │ (pm2)   │  │  │  │
│  │  └─────────────────┘  │        │  │  └──────────┘ └─────────┘  │  │  │
│  └───────────────────────┘        │  └────────────────────────────┘  │  │
│                                   └──────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

**Stages of the pipeline:**

1. **Provision** — Terraform boots an Ubuntu 24.04 cloud image as a libvirt/KVM VM, injects an SSH key and static IP via cloud-init, and configures the QEMU guest agent.
2. **Push** — code is pushed to the self-hosted GitLab instance.
3. **Trigger** — GitLab CI runs on commit to the default branch; the `deploy` job spins up a Python container with Ansible.
4. **Deploy** — Ansible SSHes into the VM as `ubuntu` and runs `site.yml`, which: upgrades packages → installs Node.js + pm2 → rsyncs the app and (re)starts it under pm2 → installs a hardened Nginx config with a self-signed TLS cert and reverse-proxies to the app on `:3000`.

## How the Pipeline Works

### `.gitlab-ci.yml`

The whole pipeline is a single `deploy` stage. It uses a `python:3.12-slim` image, installs Ansible + `rsync` + `openssh-client`, materializes the deploy SSH key from a base64-encoded CI/CD variable, and runs the playbook against the VM.

```yaml
deploy:
  stage: deploy
  image: python:3.12-slim
  before_script:
    - pip install --no-cache-dir "ansible-core==2.18.*"
    - echo "$ENCODED_DEPLOY_SSH_KEY" | base64 -d > ~/.ssh/id_rsa
  script:
    - ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
```

Two **CI/CD variables** must be defined in GitLab (Settings → CI/CD → Variables):

| Variable                 | Description                                                                                                                  |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| `ENCODED_DEPLOY_SSH_KEY` | The deploy **private** key (`base64`-encoded so it survives the variable editor), matching the public key on the VM. Masked. |
| `DEPLOY_HOST_KEYS`       | Output of a one-time `ssh-keyscan 192.168.122.100`, so the runner trusts the VM. Masked.                                     |

> The runner needs `network_mode = "host"` in its `config.toml` so it can reach the VM on the `192.168.122.0/24` libvirt bridge — see the [GitLab README](gitlab/README.md).

### `ansible/site.yml` — the deploy playbook

```
site.yml
├── [base]   hosts: all         → apt/dnf package upgrade
├── [node]   hosts: webservers  → Node.js + pm2, pm2 systemd startup
├── [deploy] hosts: webservers  → rsync app/, npm ci, pm2 restart, .env guard
└── [nginx]  hosts: webservers  → Nginx + OpenSSL, self-signed cert, hardened config, reload
```

The Nginx configuration is a hardened fork of [h5bp/server-configs-nginx](https://github.com/h5bp/server-configs-nginx) — security headers (CSP, HSTS, X-Frame-Options, Referrer-/Permissions-/Cross-Origin-Policy), TLS session caching, gzip, and a `node-app.local` reverse-proxy vhost that forwards to `127.0.0.1:3000` over HTTPS.

---

## Repository Layout

```
.
├── .gitlab-ci.yml            # CI pipeline: Ansible deploy job
├── terraform/                # IaC — libvirt VM (the active config)
│   ├── main.tf               # VM, volumes, cloud-init, network
│   ├── *.tftpl               # cloud-init templates (user/meta/network)
│   └── iso/                  # earlier single-VM Terraform variant
├── ansible/                  # Configuration management
│   ├── site.yml              # Playbook entry point
│   ├── inventory/            # hosts.yml + group_vars/
│   └── roles/                # base, node, deploy, nginx (+ h5bp configs)
├── app/                      # The Node.js application being deployed
│   ├── src/index.js          # "Hello, World!" HTTP server
│   └── package.json
├── gitlab/                   # Self-hosted GitLab + Runner (docker-compose)
│   ├── docker-compose.yaml
│   └── example.env
└── ci/                       # CI helper assets
    ├── ansible/              # Custom Ansible runner image (Dockerfile)
    └── keys/                 # Deploy SSH keypair (see Security note)
```

---

## Tech Stack

| Layer          | Tool                                                                                             | Why                                           |
| -------------- | ------------------------------------------------------------------------------------------------ | --------------------------------------------- |
| Infrastructure | **Terraform** + [`dmacvicar/libvirt`](https://registry.terraform.io/providers/dmacvicar/libvirt) | Local VMs via IaC, no cloud account needed    |
| Hypervisor     | **libvirt / KVM**                                                                                | Native Linux virtualization                   |
| OS             | **Ubuntu 24.04** (cloud image)                                                                   | cloud-init friendly, qemu-guest-agent for IPs |
| CI/CD          | **Self-hosted GitLab CE + GitLab Runner**                                                        | Runs locally; no public IP required           |
| Config Mgmt    | **Ansible** (ansible-core 2.18)                                                                  | Idempotent provisioning + deploy              |
| Runtime        | **Node.js + pm2**                                                                                | Process manager with systemd startup          |
| Web/Proxy      | **Nginx** (h5bp hardened)                                                                        | TLS termination + reverse proxy               |
| TLS            | **OpenSSL** self-signed                                                                          | Local lab has no real domain                  |

---

## Prerequisites

All on the **host machine** (a Linux box with KVM support):

- **libvirt + KVM** and a `default` NAT network (`virsh net-list`)
- **Terraform** `~> 1.15`
- **Docker** + Docker Compose (for GitLab)
- **Ansible** (only for running the playbook manually; CI uses its own image)
- An **SSH keypair** for the deploy user (default `~/.ssh/id_rsa{,.pub}`)

---

## Getting Started

The whole lab is brought up bottom-up: VM → GitLab → CI connection → deploy. Each step has detail in its sub-README.

### 1 — Provision the VM with Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars      # adjust IP/key path if needed
# download the Ubuntu cloud image once:
wget -O iso/noble-server-cloudimg-amd64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
terraform init
terraform apply
```

The VM comes up at `192.168.122.100` (cloud-injected SSH key, qemu-guest-agent). Verify:

```bash
ssh ubuntu@192.168.122.100
```

> Full details and variables: [`terraform/README.md`](terraform/README.md)

### 2 — Start the self-hosted GitLab

```bash
cd ../gitlab
cp example.env .env
docker compose up -d
```

Add the GitLab hostname to your hosts file:

```bash
echo "127.0.0.1 gitlab.local" | sudo tee -a /etc/hosts
```

Wait for GitLab to become healthy (`docker compose ps`), then log in at `http://gitlab.local` and register the runner (token from Admin → CI/Runners). Make sure the runner's `config.toml` uses `network_mode = "host"` so it can reach the VM.

> Full details: [`gitlab/README.md`](gitlab/README.md)

### 3 — Add the project to GitLab

Create a project in your GitLab instance, add it as a remote, and push:

```bash
git remote add gitlab git@gitlab.local:<you>/gitlab-cicd-lab.git
git push gitlab main
```

### 4 — Configure the CI/CD variables

In GitLab → **Settings → CI/CD → Variables**, add (both masked):

- `ENCODED_DEPLOY_SSH_KEY` → `base64 < ~/.ssh/id_rsa` (the key the VM authorizes)
- `DEPLOY_HOST_KEYS` → output of `ssh-keyscan 192.168.122.100`

### 5 — Push and watch it deploy

```bash
git commit --allow-empty -m "trigger deploy" && git push gitlab main
```

Open the pipeline in GitLab. On success, the app is live over HTTPS:

```bash
curl -k https://node-app.local        # → Hello, World!
# (add `192.168.122.100 node-app.local` to /etc/hosts if not already)
```

> About the app: [`app/README.md`](app/README.md)

---

## Configuration Reference

### Network plan

| Component       | Address           | Notes                                   |
| --------------- | ----------------- | --------------------------------------- |
| VM (webserver)  | `192.168.122.100` | Static, via cloud-init `network-config` |
| libvirt gateway | `192.168.122.1`   | Default NAT network                     |
| GitLab (host)   | `gitlab.local`    | Maps to `127.0.0.1` on the host         |
| Node.js (in VM) | `127.0.0.1:3000`  | pm2-managed, behind Nginx               |

### Key variables

| Where                               | Variable                 | Default / Example            |
| ----------------------------------- | ------------------------ | ---------------------------- |
| `terraform.tfvars`                  | `vm.ip_address`          | `192.168.122.100`            |
| `terraform.tfvars`                  | `ssh_public_key_path`    | `~/.ssh/id_rsa.pub`          |
| `ansible/group_vars/webservers.yml` | `deploy_dir`             | `/opt/app`                   |
| `ansible/group_vars/webservers.yml` | `web_user`               | `ubuntu`                     |
| GitLab CI var                       | `ENCODED_DEPLOY_SSH_KEY` | base64 of deploy private key |
| GitLab CI var                       | `DEPLOY_HOST_KEYS`       | `ssh-keyscan` of the VM      |

---

## Key Engineering Decisions

- **Local libvirt over DigitalOcean.** The roadmap.sh project targets a cloud VPS; without a public IP, I provisioned the same Ubuntu 24.04 cloud image locally with Terraform. Cloud-init sets the static IP, hostname, and authorized key; the qemu-guest-agent lets Terraform read the assigned IP.
- **Self-hosted GitLab over GitHub Actions.** GitHub Actions can't reach a non-public VM via webhook/SSH without a tunnel. GitLab CE + a local runner (with `network_mode = host`) deploy directly over the libvirt bridge.
- **rsync over git-clone for the deploy.** The CI job already has the source, so `ansible.posix.synchronize` pushes `app/` straight to `/opt/app` — no deploy tokens, no extra creds on the VM.
- **pm2 + systemd for process management.** `pm2 startup` generates a systemd unit so the Node app survives reboots.
- **h5bp Nginx configs for hardening.** Rather than write a vhost from scratch, the nginx role ships the battle-tested h5bp config tree plus a `node-app.local` reverse-proxy server block.

---

## Troubleshooting

- **Runner can't reach the VM** (`unreachable` in the job log) — confirm the runner has `network_mode = "host"` in `/etc/gitlab-runner/config.toml` and restart it, and that `192.168.122.0/24` is routable from the host.
- **`ENCODED_DEPLOY_SSH_KEY` decrypts to garbage** — re-encode with `base64 -w 0 ~/.ssh/id_rsa` and paste as a single line; ensure the variable is set to _Masked_, not _File_.
- **Job hangs on SSH host verification** — set `DEPLOY_HOST_KEYS` from a fresh `ssh-keyscan 192.168.122.100` and recheck `~/.ssh/known_hosts`.
- **Terraform hangs reading the VM IP** — the qemu-guest-agent must be installed and running inside the VM (cloud-init installs it). `virsh qemu-agent-command <domain> '{"execute":"guest-ping"}'` should return a reply.
- **Nginx won't start after deploy** — the cert generation is gated by `creates: /etc/nginx/certs/default.crt`; delete it to force regeneration, then re-run the nginx role.

---

## Project History

This repo grew iteratively, and some early components were superseded:

- The original setup used **Vagrant** — replaced by the **Terraform/libvirt** config in `terraform/main.tf`.
- `terraform/iso/` is an **earlier single-variable Terraform variant** kept for reference; `terraform/main.tf` is the active one.
- The `ci/ansible/` Dockerfile pre-bundles the Ansible collections for an offline runner image; the current `.gitlab-ci.yml` installs them at runtime instead.
- Some Nginx config under `roles/nginx/files/nginx/` is vendored from h5bp and carries its own MIT license.

---

## Sub-project READMEs

- [`terraform/README.md`](terraform/README.md) — VM provisioning
- [`ansible/README.md`](ansible/README.md) — playbook, roles, and the h5bp Nginx config
- [`gitlab/README.md`](gitlab/README.md) — self-hosted GitLab + Runner setup
- [`app/README.md`](app/README.md) — the Node.js sample app

---

## License

MIT for project-authored code. The Nginx configuration under `ansible/roles/nginx/files/nginx/` is derived from [h5bp/server-configs-nginx](https://github.com/h5bp/server-configs-nginx) and retains its MIT license (see `LICENSE.txt` in that directory).
