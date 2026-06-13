# DevOps Home Lab: GitLab CI/CD (Infrastructure)

This repository contains the `Dockerfile` and `docker-compose.yml` configurations used during my DevOps practices.

> **Note:** If you are looking for the primary project code repository, you can find it [here](https://github.com/FaridG7/DevOps-Practice-1).

### Infrastructure Overview

The `docker-compose.yml` includes service definitions for:

* **GitLab:** A self-hosted GitLab instance.
* **GitLab Runner:** Configured for CI/CD pipelines.
* **Apache & Alpine (Rsync):** A web server setup with a shared volume to facilitate file synchronization via rsync.

---

## Getting Started

### Prerequisites

* Docker and Docker Compose installed.
* Basic knowledge of Linux terminal operations.

### Setup Instructions

1. **Initialize Environment:**
    Copy the example configuration to create your local `.env` file:

```bash
cp example.env .env
```
1. **(Optional) Customize COnfigurations:**
    Edit the .`env` file to adjust hostnames or environment varables:

```bash
vim .env
```
1. **Launch the Services:**

```bash
docker compose up -d
```
1. **Verify Status:Ensure all containers are running and healthy:**

```bash
docker compose ps
```
1. **Configure Local Hosts:Map the GitLab hostname to your local machine** (replace \<gitlab-hostname\> with the value defined in your .env):

```bash
echo "127.0.0.1 <gitlab-hostname>" | sudo tee -a /etc/hosts
```

---

## GitLab Runner Configuration

To enable CI/CD functionality, follow these steps to register your runner:

### 1. Retrieve GitLab Credentials

Get the initial root password to access the web interface:

```bash
docker compose exec gitlab cat /etc/gitlab/initial_root_password
```

### 2. Register the Runner
* Navigate to your GitLab instance in your browser and log in with the `root` account.
* Follow the [Official GitLab Instructions](https://docs.gitlab.com/ci/runners/runners_scope/#create-an-instance-runner-with-a-runner-authentication-token) to generate your registration token.

### 3. Update Runner Configuration

Because this runner operates within a Docker Compose network, you must ensure it can communicate with the GitLab container. Add the network mode to the runner configuration:

```bash
docker compose exec runner1 sh -c 'echo "network_mode = \"gitlab-cicd-lab_gitlab_net\"" >> /etc/gitlab-runner/config.toml'
```

### 4. (Optional) Custom Helper Image

If you are located in a region with restricted access to `registry.gitlab.com`, specify a mirror/helper image from Docker Hub:

```bash
# Update the helper_image path accordingly 
docker compose exec runner1 sh -c 'echo "helper_image = \"gitlab/gitlab-runner-helper:x86_64-v18.11.3\"" >> /etc/gitlab-runner/config.toml'
```
