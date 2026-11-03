# Deploying sosh on a NixOS server: a runbook for an agent

You're on the NixOS machine that serves makeavoy.com, with root (sudo). The
goal: sosh running at https://sosh.makeavoy.com, behind site-delta. The
server image is built by GitHub Actions (`.github/workflows/image.yml`, for
x86_64 and arm64) and **pulled** from `ghcr.io/auxnon/sosh`: nothing is
compiled here. (Building it here instead is the last section, for when the
registry can't be used.) site-delta has its own runbook,
`DEPLOY.md` in github.com/Auxnon/site-delta; do that one too if site-delta
isn't running here yet, or is older than the `feat/sosh-subdomain` merge
(it must route `sosh.makeavoy.com`).

```
Cloudflare (proxied) ─▶ site-delta :443 ─▶ 127.0.0.1:4000 sosh ─▶ sosh-db (postgres:17)
                                            └─ podman containers, network "sosh" ─┘
```

## Rules

- Never delete or overwrite `/var/lib/sosh/env` or `/var/lib/sosh/postgres`.
  They're the secrets and the database. `POSTGRES_PASSWORD` only takes
  effect when Postgres first creates its data, so a new password with old
  data locks the server out.
- Never print the env file's values. Don't run `podman system prune`,
  `podman volume rm`, or `rm` under `/var/lib/sosh`.
- Use `sudo podman`, not rootless podman: the services run as root and only
  see root's images.
- `nixos-rebuild test` first, `switch` once it's healthy.
- Back up before every update (step 6).
- Stop and report if a step fails twice the same way. Don't improvise
  around a database error.

## 1. Look before changing anything

```sh
uname -m                                  # x86_64 or aarch64: the image has both
free -g; df -h /var/lib                   # ~1 GB RAM for sosh + Postgres, a few GB of disk
nixos-version
ls /etc/nixos/                            # flake.nix there means a flake config
systemctl status podman-sosh podman-sosh-db 2>&1 | head -20   # is it already deployed?
sudo test -e /var/lib/sosh/env && echo "env exists: keep it"
```

If `podman-sosh` already exists, this is an update: skip to step 6.

## 2. The source (for the NixOS module)

```sh
sudo mkdir -p /srv && cd /srv
sudo git clone https://github.com/Auxnon/sosh.git    # or `git -C /srv/sosh pull` if it's there
cd /srv/sosh && git log --oneline -1
```

Deploy the branch the owner names, `main` by default; it has to have
`deploy/nixos/sosh.nix` (until `feat/android-social` is merged, only that
branch does: `sudo git checkout feat/android-social`).

## 3. Pull the image

```sh
sudo podman pull ghcr.io/auxnon/sosh:latest
sudo podman image inspect ghcr.io/auxnon/sosh:latest --format '{{.Architecture}} {{.Created}}'
```

- `unauthorized` or `denied`: the package is private. Ask the owner to make
  it public (GitHub, Packages, sosh, Package settings, Change visibility),
  or for a token with `read:packages` to `sudo podman login ghcr.io` with.
- `manifest unknown`: the workflow hasn't published `latest` yet. It runs
  on every push to `main`; check https://github.com/Auxnon/sosh/actions.

## 4. The secrets file (first deploy only)

```sh
sudo mkdir -p /var/lib/sosh
sudo test -e /var/lib/sosh/env || sudo sh -c 'umask 077; {
  echo "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d "\n")"
  echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)"
} > /var/lib/sosh/env'
sudo stat -c '%a %U' /var/lib/sosh/env    # 600 root
```

If openssl is missing, use `nix-shell -p openssl --run '...'`. Email is
optional: the owner adds `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`,
`SMTP_PASSWORD` and `MAIL_FROM` (see `deploy/env.example`). Until then,
sign-up and reset codes only go to the journal. Tell the owner that.

## 5. The NixOS configuration

Add the module and the service. Without flakes, in
`/etc/nixos/configuration.nix`:

```nix
{
  imports = [ /srv/sosh/deploy/nixos/sosh.nix ];

  services.sosh = {
    enable = true;
    environmentFile = "/var/lib/sosh/env";
    # image = "ghcr.io/auxnon/sosh:latest";   # the default
    # autoUpdate = true;   # pull a newer :latest daily and restart: a push to main deploys itself
  };
}
```

With a flake config, add the input `sosh.url = "git+file:///srv/sosh";`
(or `"github:Auxnon/sosh"`), then put `inputs.sosh.nixosModules.default` in
the system's `modules` with the same `services.sosh` block. After a
`git pull` in `/srv/sosh`, run `nix flake update sosh` in `/etc/nixos`.

Keep the edit minimal and leave the rest of the file alone. Then:

```sh
sudo nixos-rebuild test
```

Don't open port 4000 in the firewall. It's published on 127.0.0.1 only, for
site-delta.

## 6. Updating (an existing deploy)

```sh
sudo podman exec sosh-db pg_dump -U sosh sosh | gzip > ~/sosh-$(date +%F-%H%M).sql.gz
sudo podman image inspect ghcr.io/auxnon/sosh:latest --format '{{index .Labels "org.opencontainers.image.revision"}}'   # the commit running now, to roll back to
sudo systemctl restart podman-sosh        # pulls a newer :latest first (pull = "newer")
cd /srv/sosh && sudo git pull --ff-only   # only matters if the module changed
```

Migrations run on every start. If the module itself changed (`git log -p
deploy/nixos`), run `sudo nixos-rebuild switch` too.

**Rolling back:** pin the image to the commit noted above, by its first 7
characters: `services.sosh.image = "ghcr.io/auxnon/sosh:sha-<7 chars>";`,
then `sudo nixos-rebuild switch`. Remove the pin once a fixed `latest` is
out. If a migration already ran and the old release can't read the
database, restore the dump. Ask the owner before doing that: it drops
everything since the dump.

## 7. Check it works

```sh
systemctl is-active podman-sosh-db podman-sosh            # active active
journalctl -u podman-sosh -n 50 --no-pager                # "Running SoshWeb.Endpoint", no crash loop
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4000/                # 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4000/game.game.png   # 200
# a websocket upgrade to the game socket: 101
curl -s -o /dev/null -w '%{http_code}\n' --http1.1 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Origin: https://sosh.makeavoy.com' \
  'http://127.0.0.1:4000/socket/websocket?vsn=2.0.0'
```

Through site-delta (on this machine, skipping DNS):

```sh
curl -sk -o /dev/null -w '%{http_code}\n' --resolve sosh.makeavoy.com:443:127.0.0.1 https://sosh.makeavoy.com/   # 200
```

From outside, `https://sosh.makeavoy.com/` should load the game.
- 502 means site-delta can't reach 127.0.0.1:4000.
- 526 means Cloudflare's Full (strict) mode doesn't accept site-delta's
  certificate for `sosh.makeavoy.com`.

When all of it passes, `sudo nixos-rebuild switch`.

## Troubleshooting

| symptom | look at |
|---|---|
| `podman-sosh` restarting | `journalctl -u podman-sosh -n 200`: `DB_*`/password errors mean the env file and the database disagree (see Rules) |
| `podman-sosh-db` failing | `journalctl -u podman-sosh-db`; permissions on `/var/lib/sosh/postgres` |
| `network sosh not found` | `systemctl restart sosh-network`, then the two containers |
| image pull fails at start | step 3: the package's visibility, or `sudo podman login ghcr.io` |

Useful afterwards:
- A console: `sudo podman exec -it sosh bin/sosh remote`
- Giving someone a server: `Sosh.Servers.give(server_id, "handle")` in that console
- Logs: `journalctl -u podman-sosh -f`
- The full reference: `deploy/README.md`

## Building the image here instead

Only if the registry is unusable: it compiles the Petrichor64 engine twice
and the Elixir release (15 to 40 minutes, ~4 GB RAM, ~15 GB disk).

```sh
cd /srv/sosh && sudo podman build -t localhost/sosh .
```

Then set `services.sosh.image = "localhost/sosh";` and leave `autoUpdate`
off. Updating then means `git pull`, the build again, and a restart.

Report back the commit you deployed (`git -C /srv/sosh log --oneline -1`),
the check results from step 7, and anything you skipped.
