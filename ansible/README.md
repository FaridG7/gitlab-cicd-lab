# Ansible Nginx Provisioner

An Ansible-based infrastructure automation project that provisions a production-ready Nginx web server on a local virtual machine, including automated application deployment from a Git repository.

> **Learning objectives:** Infrastructure as Code (IaC), Ansible role design, Nginx hardening, local VM provisioning with Vagrant + libvirt/KVM.
> Built as part of the [roadmap.sh Configuration Management project](https://roadmap.sh/projects/configuration-management), with several extensions beyond the base requirements.

---

## Overview

This project automates the full setup of a secure, performant Nginx web server using Ansible. Starting from a bare Ubuntu 24.04 VM (managed via Vagrant and libvirt/KVM), the playbook handles everything: system updates, Nginx installation and hardening, TLS certificate generation, and deploying a web application directly from a GitHub repository.

The Nginx configuration is based on the [h5bp/server-configs-nginx](https://github.com/h5bp/server-configs-nginx) project — a community-maintained collection of best-practice server configs focused on security headers, performance optimizations, and correct MIME type handling.

This project was built following the [roadmap.sh Configuration Management](https://roadmap.sh/projects/configuration-management) prompt, which calls for a `base` role, an `nginx` role, and an application deployment role. This implementation goes beyond those requirements by adding a local Vagrant + KVM environment (instead of a cloud VM), a hardened h5bp Nginx configuration, self-signed TLS with HTTPS redirect, and a Git-based deploy role with proper system user isolation.

## Architecture

```
site.yml                    # Main playbook entry point
├── roles/
│   ├── base/               # OS-level updates (apt/dnf)
│   ├── nginx/              # Nginx install, config sync, TLS setup
│   └── deploy/             # Git-based app deployment
└── inventory/
    ├── hosts.yml           # Target host definitions
    └── group_vars/         # Per-group variable overrides
```

**Provisioning flow:**

```
Vagrant VM (Ubuntu 24.04, libvirt/KVM)
        ↓
  [base] System package upgrades
        ↓
  [nginx] Install Nginx + OpenSSL → sync hardened config → generate self-signed cert → reload
        ↓
  [deploy] Install git → create web user → clone app repo → set file permissions
```

## What It Does

**Base role** — Updates all system packages using `apt` (Debian) or `dnf` (RedHat), keeping the OS-family detection generic for portability.

**Nginx role** — Installs Nginx and OpenSSL, generates a self-signed TLS certificate, then syncs a complete hardened Nginx configuration including:

- Security headers: `Content-Security-Policy`, `Strict-Transport-Security`, `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`, and Cross-Origin policies (COEP/COOP/CORP)
- TLS configuration with session caching, OCSP stapling, and TLSv1.2/1.3 cipher policies (balanced and strict profiles)
- Gzip compression with fine-grained MIME type control
- Cache expiration rules and `Cache-Control` directives mapped per content type
- CORS configuration for fonts and images
- Filename-based cache busting and file descriptor caching
- Protection against host-header attacks via a default `444` catch-all server block
- Hidden file and sensitive file access denial

**Deploy role** — Creates a dedicated unprivileged system user (`www-data`), ensures the deployment directory exists with correct ownership, clones (or pulls) the application from a configurable Git repository, and enforces file permissions recursively.

## Tech Stack

- **Ansible** — Playbook orchestration and role management
- **Vagrant** — Local VM lifecycle management
- **libvirt / KVM** — Hypervisor backend for the development VM
- **Nginx** — Web server (h5bp hardened configuration)
- **OpenSSL** — Self-signed TLS certificate generation
- **Ubuntu 24.04** — Target OS (cloud image via custom Packer box)

## Prerequisites

- Ansible installed on your control machine
- Vagrant with the `vagrant-libvirt` plugin
- KVM/libvirt on the host machine
- SSH access configured (Vagrant handles this automatically)

## Getting Started

**1. Start the VM**

```bash
vagrant up
```

**2. Run the full playbook**

```bash
ansible-playbook -i inventory/hosts.yml site.yml
```

**3. Run a specific role only**

```bash
# Nginx only
ansible-playbook -i inventory/hosts.yml site.yml --tags nginx

# Deploy only
ansible-playbook -i inventory/hosts.yml site.yml --tags deploy
```

**4. Verify Nginx on the VM**

```bash
vagrant ssh test
curl -k https://dummy-website.local
```

## Configuration

All tunable variables live in `inventory/group_vars/`:

| Variable      | Default                        | Description                         |
| ------------- | ------------------------------ | ----------------------------------- |
| `deploy_dir`  | `/var/www/dummy-website.local` | Path where the app is deployed      |
| `web_user`    | `www-data`                     | System user that owns the web files |
| `repo_url`    | _(see webservers.yml)_         | Git repository URL to deploy from   |
| `repo_branch` | `master`                       | Branch to track                     |

To deploy a different application, update `inventory/group_vars/webservers.yml`:

```yaml
repo_url: https://github.com/your-user/your-app.git
repo_branch: main
deploy_dir: /var/www/your-app
```

## VM Specification

The development VM is defined in the `Vagrantfile`:

| Property | Value                       |
| -------- | --------------------------- |
| Box      | `packer-ubuntu-cloud-24.04` |
| IP       | `192.168.47.10`             |
| Memory   | 8192 MB                     |
| CPUs     | 4                           |
| Provider | libvirt (KVM)               |

## Key Learning Outcomes

- Structuring Ansible projects with reusable, single-responsibility roles
- Using `ansible.builtin.synchronize` to manage config file trees idempotently
- Nginx security hardening with modern HTTP security headers
- TLS setup and self-signed certificate generation via Ansible tasks
- Idempotent Git-based deployment with correct file ownership and permissions
- Vagrant + libvirt integration for reproducible local infrastructure

## Project Structure

```
.
├── inventory/
│   ├── hosts.yml               # Host inventory
│   └── group_vars/
│       ├── all.yml             # Global variables
│       └── webservers.yml      # Web server group variables
├── roles/
│   ├── base/
│   │   └── tasks/main.yml      # Package upgrades
│   ├── nginx/
│   │   ├── files/nginx/        # Full Nginx config tree (h5bp-based)
│   │   ├── handlers/main.yml   # Nginx reload handler
│   │   └── tasks/main.yml      # Install, configure, cert generation
│   └── deploy/
│       ├── defaults/main.yml   # Default variable values
│       └── tasks/main.yml      # Git deploy tasks
├── site.yml                    # Main playbook
└── Vagrantfile                 # VM definition
```

## Possible Extensions

**Replace static config files with Jinja2 templates**
The current nginx role uses `ansible.builtin.synchronize` to push a pre-written config tree. A natural next step is converting the server block configs into Jinja2 templates (`.conf.j2`) rendered with `ansible.builtin.template`. This would let you drive values like `server_name`, `root`, TLS cert paths, and security header policies directly from inventory variables — making the role truly reusable across different hosts without touching any config files.

**Add an `ssh` role**
The original roadmap.sh prompt includes an `ssh` role for adding authorized public keys to the server. This would use `ansible.builtin.authorized_key` and could also harden `sshd_config` (disable root login, enforce key-only auth, change the default port).

**Let's Encrypt / Certbot integration**
Replace the self-signed certificate with a real one via Certbot. An `ssl` role could use `community.crypto` or the `certbot` CLI to obtain and auto-renew Let's Encrypt certificates, then notify the nginx handler to reload on renewal.

**Add a `fail2ban` role**
The roadmap.sh spec mentions `fail2ban` as part of the base setup. Adding a dedicated role to install and configure it — with jail rules for Nginx and SSH — would round out the security story significantly.

**Multi-host inventory and staging environments**
Extend the inventory to support multiple environments (e.g. `staging` and `production`) with separate `group_vars`. This would demonstrate environment-specific variable overrides, a common pattern in real-world Ansible usage.

**Molecule tests**
Add [Molecule](https://ansible.readthedocs.io/projects/molecule/) with a Docker driver to write automated tests for each role. This is the standard approach to CI-testing Ansible roles and would make the project much stronger as a portfolio piece.

## License

The Nginx configuration files under `roles/nginx/files/nginx/` are derived from [h5bp/server-configs-nginx](https://github.com/h5bp/server-configs-nginx) and are licensed under the [MIT License](roles/nginx/files/nginx/LICENSE.txt). All other project files are available under the MIT License as well.
