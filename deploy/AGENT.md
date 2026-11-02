# Deploying sosh on a NixOS server: a runbook for an agent

You're on the NixOS machine that serves makeavoy.com, with root (sudo). The
goal: sosh running at https://sosh.makeavoy.com, built **on this machine**
(no registry), behind site-delta. site-delta has its own runbook,
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
uname -m                                  # x86_64 or aarch64: both work, the image builds natively
free -g; df -h /var/lib                   # the build wants ~4 GB RAM free and ~15 GB of disk
nixos-version
ls /etc/nixos/                            # flake.nix there means a flake config
systemctl status podman-sosh podman-sosh-db 2>&1 | head -20   # is it already deployed?
sudo test -e /var/lib/sosh/env && echo "env exists: keep it"
```

If `podman-sosh` already exists, this is an update: skip to step 6.

## 2. The source

```sh
sudo mkdir -p /srv && cd /srv
sudo git clone https://github.com/Auxnon/sosh.git    # or `git -C /srv/sosh pull` if it's there
cd /srv/sosh && git log --oneline -1
```

Deploy the branch the owner names, `main` by default; it has to have
`deploy/nixos/sosh.nix` (until `feat/android-social` is merged, only that
branch does: `sudo git checkout feat/android-social`).

## 3. Build the image

```sh
cd /srv/sosh
sudo podman build -t localhost/sosh .
```

This takes 15 to 40 minutes the first time: it builds the Petrichor64 engine
twice (wasm and native) and the Elixir release. Run it in the foreground,
or in the background with its output going to a log you can read. Don't
start a second build while one runs. The engine comes from GitHub at
`P64_REF` (the `Containerfile`), and its Lua, silt-lua, from silt-lua's
GitHub `main`.

It's done when `sudo podman image exists localhost/sosh && echo ok` says ok.

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
    image = "localhost/sosh";             # the image from step 3
    environmentFile = "/var/lib/sosh/env";
    # autoUpdate stays false: it pulls from a registry, and this image isn't in one
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
cd /srv/sosh && sudo git pull --ff-only
sudo podman tag localhost/sosh localhost/sosh:previous   # to roll back to
sudo podman build -t localhost/sosh .
sudo systemctl restart podman-sosh
```

Migrations run on every start. If the module itself changed (`git log -p
deploy/nixos`), run `sudo nixos-rebuild switch` too.

**Rolling back:** `sudo podman tag localhost/sosh:previous localhost/sosh &&
sudo systemctl restart podman-sosh`. If a migration already ran and the old
release can't read the database, restore the dump. Ask the owner before
doing that: it drops everything since the dump.

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
| image not found at start | it was built rootless: rebuild with `sudo podman build` |
| the build is killed | out of memory: stop other heavy work, retry once |

Useful afterwards:
- A console: `sudo podman exec -it sosh bin/sosh remote`
- Giving someone a server: `Sosh.Servers.give(server_id, "handle")` in that console
- Logs: `journalctl -u podman-sosh -f`
- The full reference: `deploy/README.md`

Report back the commit you deployed (`git -C /srv/sosh log --oneline -1`),
the check results from step 7, and anything you skipped.
