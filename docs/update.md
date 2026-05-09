# Updating MatrixHub

> This doc is **mirrored verbatim** in
> [`agent-matrix/matrix-hub`](https://github.com/agent-matrix/matrix-hub)
> and
> [`agent-matrix/matrixhub-db`](https://github.com/agent-matrix/matrixhub-db),
> so operators see one consistent procedure regardless of which repo
> they open. Pair this with [`architecture.md`](./architecture.md) for
> the wider stack picture.

MatrixHub ships as three independently versioned services:

| Service | Repo | Where it runs | How it updates |
|---|---|---|---|
| Frontend | [`ruslanmv/matrixhub`](https://github.com/ruslanmv/matrixhub) | Vercel | Vercel auto-deploys on push to `master` (or via `.github/workflows/deploy-vercel.yml`) |
| Backend | [`agent-matrix/matrix-hub`](https://github.com/agent-matrix/matrix-hub) | OCI Ubuntu VM (`api.matrixhub.io`) | `release: published` → SSH → `scripts/update.sh` |
| Database | [`agent-matrix/matrixhub-db`](https://github.com/agent-matrix/matrixhub-db) | OCI OL9 VM | `release: published` → SSH → `make build && make up && make verify` |

The rest of this document explains exactly what happens during an
update, what credentials are needed, how to update manually, and how
to roll back.

---

## 1. Update flow at a glance

```
   developer:      gh release create v0.1.8 …
                            │
   GitHub:                  ▼  release.published webhook
                  .github/workflows/deploy-server.yml
                            │  uses DEPLOY_SSH_KEY
                            ▼
   GH-Actions runner ── ssh ──▶  ubuntu@<vm>
                                    │  cd ~/<repo>
                                    │  git fetch --tags --prune
                                    │  AUTO=1 TARGET_TAG=v0.1.8 bash scripts/update.sh
                                    │     ├─ tag current image as rollback
                                    │     ├─ stop/rm container
                                    │     ├─ git checkout tags/v0.1.8
                                    │     ├─ scripts/build_container.sh   (or `make build`)
                                    │     ├─ scripts/run_container.sh     (or `make up`)
                                    │     └─ poll /health  (auto-rollback on failure)
                                    ▼
   GH-Actions runner ── curl ──▶  https://api.matrixhub.io/health?check_db=true
                                    │
                                    ▼  green smoke = release succeeded
```

Releases are the **source of truth**. To update production you publish
a new GitHub release on the relevant repo; everything else is
automatic.

---

## 2. Required credentials & secrets

Configure the same set on **each** repo (`matrix-hub` and `matrixhub-db`).

**Repo Settings → Secrets and variables → Actions → Secrets:**

| Name | Value | Notes |
|---|---|---|
| `DEPLOY_HOST` | `129.213.165.60` (Hub) / `141.148.40.165` (DB) | Public IP or DNS of the target VM. |
| `DEPLOY_USER` | `ubuntu` (Hub) / `opc` (DB) | SSH user. |
| `DEPLOY_SSH_KEY` | full PEM contents of a dedicated deploy key | One key per VM. **Do not** reuse personal keys. |
| `DEPLOY_KNOWN_HOSTS` | output of `ssh-keyscan -H <DEPLOY_HOST>` | Pins the host key so the runner can't be MITMed. |

**Variables** tab (optional):

| Name | Default | Override when |
|---|---|---|
| `DEPLOY_PATH` | `~/matrix-hub` (Hub) / `~/matrixhub-db` (DB) | Your checkout lives elsewhere. |
| `UPDATE_SCRIPT` | `scripts/update.sh` | You renamed/replaced the updater. |
| `PROBE_URL` | `https://api.matrixhub.io/health?check_db=true` | You probe a different URL. |
| `DISABLE_DEPLOY` | unset | Set `true` to pause auto-deploys (forks, maintenance windows). |

### One-time key setup

```bash
# On your laptop, one keypair per VM:
ssh-keygen -t ed25519 -f ~/deploy_matrix_hub_ed25519     -C "gh-actions@matrix-hub"   -N ""
ssh-keygen -t ed25519 -f ~/deploy_matrixhub_db_ed25519   -C "gh-actions@matrixhub-db" -N ""

# Append the public keys to the right VMs:
ssh ubuntu@129.213.165.60 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys" < ~/deploy_matrix_hub_ed25519.pub
ssh opc@141.148.40.165    "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys" < ~/deploy_matrixhub_db_ed25519.pub

# Pin host fingerprints:
ssh-keyscan -H 129.213.165.60   # → DEPLOY_KNOWN_HOSTS for matrix-hub repo
ssh-keyscan -H 141.148.40.165   # → DEPLOY_KNOWN_HOSTS for matrixhub-db repo
```

Paste the **private** key files and `ssh-keyscan` output into the two
repos' Actions secrets.

### OCI security list

The OCI subnet security list must allow inbound TCP 22 from the
GitHub-hosted runner's outbound range. GitHub does not publish a
small static list; the practical options are:

- Allow `0.0.0.0/0` for TCP 22 with **key-only** auth (least friction).
- Allow [GitHub Actions IPs](https://api.github.com/meta) (volatile —
  rotate on a schedule).
- Use a **self-hosted runner** inside the VCN and drop public SSH
  altogether (see §6).

---

## 3. Triggering an update

### Automatic (recommended)

```bash
# matrix-hub backend
gh release create v0.1.8 --repo agent-matrix/matrix-hub \
  --title "v0.1.8" --notes "Whatever changed."

# matrixhub-db
gh release create v1.2.3 --repo agent-matrix/matrixhub-db \
  --title "v1.2.3" --notes "Schema/ops change details."
```

When the release is published, GitHub fires a `release: published`
webhook that runs `.github/workflows/deploy-server.yml` in that repo.

### Manual (one-off)

```bash
# From either repo's Actions tab → "Deploy to server" → Run workflow:
gh workflow run "Deploy to server" \
  --repo agent-matrix/matrix-hub \
  -f tag=v0.1.8
```

Leaving `tag` empty makes `update.sh` default to the latest published
tag. Useful for re-running an interrupted deploy.

---

## 4. What `scripts/update.sh` does

Both repos ship `scripts/update.sh`. The matrix-hub variant is the
canonical one; the matrixhub-db variant wraps `make` instead of the
container scripts but follows the same lifecycle.

```text
0. preflight              # docker, git, curl present? scripts executable?
1. show current state     # branch, commit, current tag, container running?
2. fetch tags             # git fetch --tags --prune
3. choose target tag      # TARGET_TAG env, or interactive list, or AUTO=latest
4. tag current image      # docker tag <id> matrix-hub:rollback-YYYYMMDD-HHMMSS
5. stop & rm container
6. git checkout tags/<T>
7. build image            # scripts/build_container.sh    (Hub)
                          # make build                    (DB)
8. start container        # scripts/run_container.sh      (Hub)
                          # make up                       (DB)
9. health probe           # poll /health?check_db=true up to HEALTH_TIMEOUT
                          # for the DB repo: make health
10. on success → done
    on failure → offer automatic rollback via the saved image tag
```

### Knobs

```bash
TARGET_TAG=v0.1.8                       # skip the picker
AUTO=1                                  # answer YES to every prompt (CI-friendly)
HEALTH_TIMEOUT=180                      # seconds to wait for /health to return 200
HEALTH_URL=https://127.0.0.1:443/health?check_db=true
CONTAINER_NAME=matrixhub                # override the docker container name
IMAGE_NAME=matrix-hub                   # base name for the rollback tag
BUILD_SCRIPT=./scripts/build_container.sh
RUN_SCRIPT=./scripts/run_container.sh
REMOTE=origin
```

---

## 5. Manual update procedures

If the workflow is unavailable (e.g. GitHub outage, no SSH from the
runner), update from the box itself.

### matrix-hub (Ubuntu VM, `api.matrixhub.io`)

```bash
ssh ubuntu@129.213.165.60
cd ~/matrix-hub

git fetch --tags --prune
bash scripts/update.sh                   # interactive picker
# or
TARGET_TAG=v0.1.8 AUTO=1 bash scripts/update.sh
```

Verify:

```bash
curl -ksS https://127.0.0.1:443/health?check_db=true   # should return db:"ok"
docker ps --filter name=matrixhub
docker logs --tail=80 matrixhub
```

### matrixhub-db (OL9 VM)

```bash
ssh opc@141.148.40.165
cd ~/matrixhub-db

git fetch --tags --prune
git checkout tags/v1.2.3
make build
make up
make health
make verify
```

(Once the DB-flavoured `scripts/update.sh` lands in this repo it can
be invoked the same way as the Hub one.)

### Frontend (`ruslanmv/matrixhub`)

```bash
# Either merge to master and let Vercel auto-deploy:
gh pr merge <PR> --squash --delete-branch

# Or push a release tag — the .github/workflows/deploy-vercel.yml
# workflow handles the production promote (provided VERCEL_TOKEN /
# VERCEL_ORG_ID / VERCEL_PROJECT_ID secrets are set):
gh release create v0.2.6 --repo ruslanmv/matrixhub
```

The frontend doesn't need an SSH key — Vercel pulls from GitHub
directly via its native Git integration.

---

## 6. Rolling back

`update.sh` tags the previously running image as
`<image-name>:rollback-YYYYMMDD-HHMMSS` **before** stopping the
container. If the new build fails the health check, it offers
automatic rollback. If you need to roll back later (e.g. you noticed
a regression an hour after deploy):

```bash
# 1. List rollback images
docker images --format '{{.Repository}}:{{.Tag}}\t{{.CreatedAt}}' \
  | grep ':rollback-'

# 2. Stop the bad container
docker stop matrixhub && docker rm matrixhub

# 3. Re-tag the rollback image as :latest and start
docker tag matrix-hub:rollback-20260509-101530 matrix-hub:latest
bash scripts/run_container.sh

# 4. Move HEAD back to the old tag (so the next update.sh starts from a
#    known-good base)
git checkout tags/v0.1.7
```

For the database, rollback is **NOT** image-based — schema changes
applied by the Hub's Alembic migrations are not reverted by switching
images. Restore from the most recent backup instead:

```bash
# On the OL9 VM
ls -1tr ~/matrixhub-db/backups/ | tail -n 5
make restore                 # uses the most recent backup
```

---

## 7. Self-hosted runner alternative

If you'd rather not expose SSH to the GitHub runner range, install a
self-hosted runner on each VM:

```bash
# On the VM, as the deploy user
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -fsSLo runner.tar.gz \
  https://github.com/actions/runner/releases/download/v2.319.1/actions-runner-linux-x64-2.319.1.tar.gz
tar xzf runner.tar.gz
./config.sh --url https://github.com/agent-matrix/matrix-hub \
  --token <REGISTRATION_TOKEN_FROM_REPO_SETTINGS>
sudo ./svc.sh install
sudo ./svc.sh start
```

Then change the workflow's `runs-on:` to
`[self-hosted, matrix-hub]` and remove the SSH-config + remote-ssh
steps. The runner already lives on the box and can call
`bash scripts/update.sh` directly. Tradeoff: one more service per VM
to monitor and patch.

---

## 8. Troubleshooting

| Symptom | First check |
|---|---|
| Workflow run errors with `Missing required secrets: …` | Add the listed secrets in repo Settings → Secrets and variables → Actions, or set repo variable `DISABLE_DEPLOY=true` to silence. |
| `Permission denied (publickey)` from the runner | The deploy public key isn't in the VM's `~/.ssh/authorized_keys`, or `DEPLOY_USER` is wrong (Hub=`ubuntu`, DB=`opc`). |
| `Host key verification failed` | `DEPLOY_KNOWN_HOSTS` is missing or stale — re-run `ssh-keyscan -H <ip>` and update the secret. |
| `update.sh` aborts at "tag … does not exist locally" | Run `git fetch --tags --prune` on the VM. The auto-deploy workflow does this for you. |
| Health probe fails after deploy | `bash scripts/diagnosis.sh` on the VM. Common causes: `.env` not mounted into the container; `DATABASE_URL` not set so the Hub fell back to SQLite; OOM (workers SIGKILL'd) on a 1 GB micro instance. |
| Hub keeps reporting `db: "error"` | DB host firewall closed (5432), wrong password, or `PG_ALLOW_CIDR` doesn't include the Hub's private IP. Run `make verify` on the DB host. |
| Smoke probe in the workflow returns 502 with `upstream_timeout` | Workflow ran on the Hub VM successfully but the *backend* container is unreachable from the public internet. Check Cloudflare proxy state and OCI security-list rules for TCP 443. |
| Workflow stalls at "Run update on the server" | The container is rebuilding; allow up to `HEALTH_TIMEOUT` seconds (default 120). For a slow first build, run manually with `HEALTH_TIMEOUT=300 AUTO=1 bash scripts/update.sh`. |
| Want to pause deploys without deleting the workflow | Set repo variable `DISABLE_DEPLOY=true` in Settings → Secrets and variables → Actions → Variables. |

---

## 9. Quick reference

```bash
# Fresh-VM bootstrap (Hub):
git clone https://github.com/agent-matrix/matrix-hub.git
cd matrix-hub
scp cf-origin.pem cf-origin.key user@host:~/matrix-hub/   # optional TLS
bash scripts/bootstrap_host.sh                            # interactive

# Fresh-VM bootstrap (DB):
git clone https://github.com/agent-matrix/matrixhub-db.git
cd matrixhub-db
cp .env.db.example .env.db && $EDITOR .env.db
make init && make verify

# Update (any repo, on the VM):
bash scripts/update.sh

# Health snapshot (any repo, on the VM):
bash scripts/diagnosis.sh

# Trigger a deploy from anywhere:
gh release create v0.1.8 --repo agent-matrix/matrix-hub
gh workflow run "Deploy to server" --repo agent-matrix/matrix-hub -f tag=v0.1.8
```

If anything in this doc drifts from reality, the source of truth is
`scripts/update.sh` and `.github/workflows/deploy-server.yml` in the
relevant repo.
