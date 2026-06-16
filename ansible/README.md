# Ansible — Provisioning & Deploy Playbook

The Ansible side of the [gitlab-cicd-lab](../README.md) pipeline. A single playbook (`site.yml`) takes a fresh Ubuntu VM from the Terraform stage and turns it into a running Node.js app behind a security-hardened Nginx reverse proxy.

> This is the **deploy** stage of the pipeline. GitLab CI invokes `ansible-playbook site.yml` against the VM at `192.168.122.100`. It can also be run by hand for local iteration.

---

## What It Does

Four roles, run in order:

```
site.yml
├── [base]   hosts: all         → full apt/dnf package upgrade
├── [node]   hosts: webservers  → Node.js + npm + pm2 (global), pm2 systemd startup
├── [deploy] hosts: webservers  → rsync app/ → /opt/app, npm install, pm2 restart
└── [nginx]  hosts: webservers  → Nginx + OpenSSL, self-signed cert, hardened config, reload
```

### `base`
Generic OS hardening first step — upgrades every package with `apt` (Debian) or `dnf` (RedHat), guarded by `ansible_os_family` so the role stays portable.

### `node`
Installs `nodejs` + `npm` from apt, then `pm2` globally. Generates a per-user systemd unit via `pm2 startup` so managed Node processes survive reboots. Idempotent: it checks whether the `pm2-<user>.service` unit already exists before regenerating it.

### `deploy`
Pushes the application to the VM and keeps it running:
- Ensures `{{ deploy_dir }}` (`/opt/app`) exists, owned by `{{ web_user }}` (`ubuntu`).
- `ansible.posix.synchronize` (rsync) copies `app/` into the deploy dir, excluding `node_modules`, `.git`, and `.env`.
- Copies `app/.env.example` → `deploy_dir/.env` with `force: false`, so an existing `.env` is **never overwritten** by deploys.
- Runs `npm install` (via `community.general.npm`).
- Restarts the app under pm2 (`pm2 restart app --update-env`, falling back to `pm2 start`), then `pm2 save`.

### `nginx`
Installs `nginx` + `openssl`, generates a self-signed TLS cert (gated by `creates:` so it's only done once), then `synchronize`s the full hardened config tree to `/etc/nginx/` and notifies a reload handler. The config is a vendored, lightly-customized copy of [h5bp/server-configs-nginx](https://github.com/h5bp/server-configs-nginx).

The active vhost is `conf.d/node-app.local.conf`: an HTTP→HTTPS redirect plus an HTTPS server block that reverse-proxies to the Node upstream at `127.0.0.1:3000`, with WebSocket/keepalive headers and the h5bp security rules.

## Prerequisites

The target VM must already be up — provision it with [Terraform](../terraform/README.md) first. From the control machine:

- **Ansible** (`ansible-core` 2.18) with two collections: `ansible.posix` and `community.general`. The CI image installs these; for local runs do:
  ```bash
  ansible-galaxy collection install ansible.posix community.general
  ```
- **rsync** on the control machine (used by `synchronize`).
- **SSH access** to the VM as `ubuntu` with your key.

## Getting Started

Run the whole playbook against the VM:

```bash
ansible-playbook -i inventory/hosts.yml site.yml
```

Run a single role with tags:

```bash
ansible-playbook -i inventory/hosts.yml site.yml --tags node
ansible-playbook -i inventory/hosts.yml site.yml --tags deploy
ansible-playbook -i inventory/hosts.yml site.yml --tags nginx
```

Check what would change (no-op):

```bash
ansible-playbook -i inventory/hosts.yml site.yml --check --diff
```

Verify the result:

```bash
curl -k https://node-app.local      # → Hello, World!
# (add `192.168.122.100 node-app.local` to /etc/hosts first)
```

## Inventory

`inventory/hosts.yml` defines one host, `webserver1`, in the `webservers` group:

```yaml
all:
  hosts:
    webserver1:
      ansible_host: 192.168.122.100
      ansible_user: ubuntu
      ansible_ssh_private_key_file: ~/.ssh/id_rsa
  children:
    webservers:
      hosts:
        webserver1:
```

## Configuration

Tunable variables live in `inventory/group_vars/`:

| Variable      | Default     | Where                 | Description                              |
| ------------- | ----------- | --------------------- | ---------------------------------------- |
| `deploy_dir`  | `/opt/app`  | `webservers.yml`      | Where the app is rsynced on the VM       |
| `web_user`    | `ubuntu`    | `webservers.yml`      | Owner of the app files + pm2 startup user|

To deploy to a different path or user, edit `inventory/group_vars/webservers.yml`:

```yaml
deploy_dir: /opt/app
web_user: ubuntu
```

## Project Structure

```
ansible/
├── site.yml                        # Playbook entry point (4 plays)
├── inventory/
│   ├── hosts.yml                   # webserver1 @ 192.168.122.100
│   └── group_vars/
│       ├── all.yml                 # (empty — reserved for globals)
│       └── webservers.yml          # deploy_dir, web_user
└── roles/
    ├── base/tasks/main.yml         # apt/dnf upgrade
    ├── node/tasks/main.yml         # Node.js + pm2 + systemd startup
    ├── deploy/
    │   ├── defaults/main.yml       # deploy_dir default
    │   └── tasks/main.yml          # rsync, npm, pm2 restart
    └── nginx/
        ├── tasks/main.yml          # install, cert, sync config, reload
        ├── handlers/main.yml       # nginx reload handler
        └── files/nginx/            # full h5bp-derived config tree
            ├── nginx.conf
            ├── conf.d/
            │   ├── node-app.local.conf   # ← active reverse-proxy vhost
            │   ├── default.conf          # HTTPS 444 catch-all
            │   ├── no-ssl.default.conf   # HTTP 444 catch-all
            │   └── templates/            # example.com reference vhosts
            └── h5bp/                     # security/tls/performance snippets
```

## The Nginx Configuration (h5bp)

`roles/nginx/files/nginx/` is a vendored copy of [h5bp/server-configs-nginx](https://github.com/h5bp/server-configs-nginx) (MIT). It provides:

- **Security headers** — CSP, HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy, and Cross-Origin policies (COEP/COOP/CORP), applied per-content-type via `map` directives.
- **TLS** — session caching/tickets, OCSP stapling config, and balanced/strict cipher policies (TLS 1.2/1.3).
- **Performance** — gzip with fine-grained MIME types, cache expiration and `Cache-Control` per content type, filename-based cache busting, file-descriptor caching.
- **Hardening** — `server_tokens off`, default `444` catch-all server blocks against host-header attacks, hidden-file and sensitive-file access denial.

The custom addition is **`conf.d/node-app.local.conf`**, which adds the Node.js reverse proxy described above. See `files/nginx/README.md` for the upstream h5bp documentation.

## Key Learning Outcomes

- Designing reusable, single-responsibility Ansible roles and composing them in one playbook.
- Idempotency patterns: `creates:` for cert generation, `force: false` for `.env`, `stat`-gated systemd setup.
- Using `ansible.posix.synchronize` to push an app tree efficiently with rsync excludes.
- Nginx reverse-proxy hardening — TLS termination, security headers, and a default-server catch-all.
- Process management with pm2 wired into systemd for boot-time startup.

## Possible Extensions

- **Jinja2 templates instead of static config** — drive `server_name`, `root`, and cert paths from inventory instead of committing a fixed `node-app.local.conf`.
- **Let's Encrypt via Certbot** — replace the self-signed cert with a real one and auto-renewal, using `community.crypto` or the `certbot` CLI.
- **Molecule tests** — add [Molecule](https://ansible.readthedocs.io/projects/molecule/) with a Docker driver to CI-test each role.
- **Multi-environment inventory** — split `staging`/`production` with separate `group_vars`.

## License

The Nginx configuration files under `roles/nginx/files/nginx/` are derived from [h5bp/server-configs-nginx](https://github.com/h5bp/server-configs-nginx) and licensed under the [MIT License](roles/nginx/files/nginx/LICENSE.txt). All other files in this directory are MIT-licensed as well.
