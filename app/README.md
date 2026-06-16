# Node.js Sample App

A minimal Node.js HTTP server — the **payload** that the [gitlab-cicd-lab](../README.md) pipeline deploys. It exists to have something real to ship through the GitLab CI → Ansible → Nginx pipeline; the deployment machinery is the point, not the app itself.

> This is what lives behind Nginx on the VM at `127.0.0.1:3000`, managed by pm2 and reverse-proxied over HTTPS at `https://node-app.local`.

## What It Does

A single `http.createServer` that responds `Hello, World!` to every request, with `HOST` and `PORT` read from the environment (via `dotenv`):

```js
const server = http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end("Hello, World!\n");
});

server.listen(PORT, HOST, () => { /* ... */ });
```

## Files

```
app/
├── src/index.js     # the server
├── package.json     # 'app', deps: dotenv
├── .env.example     # template — copied to .env (gitignored)
├── .env             # YOUR values (gitignored, created from .env.example)
└── .gitignore       # ignores node_modules/ and .env
```

## Configuration

Environment variables (from `.env`, defaults shown):

| Variable | Default       | Description                          |
| -------- | ------------- | ------------------------------------ |
| `HOST`   | `127.0.0.1`   | Bind address — Nginx proxies to it   |
| `PORT`   | `3000`        | Listen port — matches the Nginx upstream |

`HOST` is set to `127.0.0.1` deliberately so the app is reachable only through the Nginx reverse proxy, never directly.

## Run Locally

```bash
cp .env.example .env
npm install
npm run serve
```

Then:

```bash
curl http://127.0.0.1:3000     # → Hello, World!
```

## How It's Deployed

The app itself never clones a repo on the server. During a GitLab CI run:

1. The `deploy` Ansible role `rsync`s this directory onto the VM at `/opt/app` (excluding `node_modules`, `.git`, `.env`).
2. `.env.example` is copied to `/opt/app/.env` **only if it doesn't already exist** — so on-machine config edits survive redeployments.
3. `npm install` runs on the VM.
4. pm2 (re)starts `src/index.js` as a process named `app` and saves the list so systemd resurrects it on reboot.

See the [Ansible README](../ansible/README.md) for the full playbook.
