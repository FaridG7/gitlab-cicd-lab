# Self-hosted GitLab + Runner

The CI/CD backend for the [gitlab-cicd-lab](../README.md) project. Runs **GitLab CE** and a **GitLab Runner** as Docker Compose services on the host, so the pipeline can deploy to the local libvirt VM without needing a public IP or a cloud account.

> This is the **CI server** in the architecture diagram. The runner executes the `.gitlab-ci.yml` deploy job from the repository root.

---

## What's Here

```
gitlab/
├── docker-compose.yaml   # gitlab + runner1 services
├── example.env           # template — copy to .env
└── .env                  # YOUR values (gitignored)
```

`docker-compose.yaml` defines two services:

- **`gitlab`** — `gitlab/gitlab-ce`, exposed on host ports `80`/`443`/`22`, three named volumes for config/logs/data, Prometheus monitoring disabled (saves RAM on a home-lab host), and a health check against `/-/health`.
- **`runner1`** — `gitlab/gitlab-runner`, mounts the Docker socket so jobs can run containers, with a `gitlab-runner verify` health check.

## Prerequisites

- **Docker** and **Docker Compose** (v2 / `docker compose`) on the host.
- Enough RAM — GitLab CE is heavy; ~4 GB free is a sensible minimum.

## Getting Started

**1. Create your `.env`**

```bash
cp example.env .env
```

Defaults:

```env
GITLAB_TAG=18.10.5-ce.0
GITLAB_HOSTNAME="gitlab.local"

RUNNER_TAG=v18.11.3
RUNNER_HOSTNAME=runner1.local
```

Adjust the image tags or hostname if you like, then bring it up:

```bash
docker compose up -d
```

GitLab takes a few minutes to become healthy. Watch it:

```bash
docker compose ps
```

**2. Point your host at the GitLab hostname**

```bash
echo "127.0.0.1 gitlab.local" | sudo tee -a /etc/hosts
```

Open `http://gitlab.local` in your browser.

## GitLab Runner Configuration

GitLab is up, but the runner isn't registered yet — it can't pick up jobs until it is.

### 1. Get the initial root password

```bash
docker compose exec gitlab cat /etc/gitlab/initial_root_password
```

Log in to GitLab at `http://gitlab.local` as `root` with that password.

### 2. Create a registration token

Follow the [official GitLab docs](https://docs.gitlab.com/ci/runners/runners_scope/#create-an-instance-runner-with-a-runner-authentication-token) to create an instance runner and copy the **runner authentication token**.

Register it inside the runner container:

```bash
docker compose exec runner1 gitlab-runner register \
  --url http://gitlab.local \
  --token <your-runner-authentication-token> \
  --executor docker \
  --docker-image python:3.12-slim
```

### 3. Use host networking so the runner can reach the VM

The VM lives on the `192.168.122.0/24` libvirt bridge, which is only reachable from the host network. Add host networking to the runner's config so its job containers can SSH to the VM:

```bash
docker compose exec runner1 sh -c 'echo "network_mode = \"host\"" >> /etc/gitlab-runner/config.toml'
docker compose restart runner1
```

### 4. (Optional) Custom helper image

If you're in a region where `registry.gitlab.com` is blocked, point the runner at the Docker Hub helper image:

```bash
docker compose exec runner1 sh -c 'echo "helper_image = \"gitlab/gitlab-runner-helper:x86_64-v18.11.3\"" >> /etc/gitlab-runner/config.toml'
```

## Verifying the Setup

```bash
docker compose ps                 # both services should be "healthy"
docker compose exec runner1 gitlab-runner verify   # runner talks to GitLab
```

Once a project is created and the CI/CD variables from the [root README](../README.md#4--configure-the-cicd-variables) are set, push to the default branch and the `deploy` job will run here.

## Notes

- **RAM usage** — Prometheus is disabled (`prometheus_monitoring['enable'] = false`) specifically to keep memory footprint down for a home lab. Re-enable it if you want built-in monitoring.
- **Persistence** — `gitlab_config`, `gitlab_logs`, `gitlab_data`, and `runner1_config` are named volumes, so `docker compose down` preserves state. Use `docker compose down -v` to wipe everything.
- **HTTPS** — GitLab itself serves over plain HTTP in this lab. The TLS termination that matters (for the deployed app) is done by Nginx on the VM, not here.

## Teardown

```bash
docker compose down        # stop, keep data
docker compose down -v     # stop and delete all volumes (irreversible)
```
