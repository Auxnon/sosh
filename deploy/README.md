# Deploying sosh

```
browser / desktop / app ──https──▶ Cloudflare (proxied) ──▶ site-delta :443 ──▶ 127.0.0.1:4000 sosh ──▶ sosh-db
                                                            (Host: sosh.makeavoy.com)   (podman)       (postgres:17)
```

- **The server** is one container image, built by the `Containerfile` at the
  repo root: the Phoenix release with the Rust NIF, and the web game (the
  Petrichor64 wasm engine plus the packed client) in `priv/static`.
  It's built one of three ways, and `sosh-deploy` puts any of them live
  (see [Redeploying](#redeploying)):
  - **a release**: `.github/workflows/release.yml` builds it with the
    clients on a `v*` tag, for x86_64 and arm64, pushes it to
    `ghcr.io/auxnon/sosh` (`v1.2.0` publishes `1.2.0`, `1.2`, `1` and
    `latest`) and attaches it to the GitHub release as
    `sosh-server-amd64.tar.gz` / `-arm64`. Pushes to main publish nothing.
  - **on the server**, from a checkout of any branch or commit.
  - **on your own machine**, copied over by `just ship <host>`.
- **The clients** come from the same `release.yml` on a `v*` tag:
  the desktop app and the world alone for Windows, Linux and macOS, and the
  Android APK, all pointed at `https://sosh.makeavoy.com` by default.
- **site-delta** (github.com/Auxnon/site-delta), the makeavoy.com server,
  passes `sosh.makeavoy.com` through to `127.0.0.1:4000`, websockets
  included, with the client's address in `x-real-ip` (from Cloudflare's
  `CF-Connecting-IP`).

## NixOS

An agent deploying on the server: follow `deploy/AGENT.md`, a step-by-step
runbook that builds the image on the machine.

The module (`deploy/nixos/sosh.nix`, or the flake's `nixosModules.default`)
runs the image and Postgres as podman containers on their own network,
with the server on 127.0.0.1:4000.

```nix
# flake.nix of the machine
inputs.sosh.url = "github:Auxnon/sosh";
# ...
modules = [
  inputs.sosh.nixosModules.default
  {
    services.sosh = {
      enable = true;
      environmentFile = "/var/lib/sosh/env";
      # source = "/srv/sosh";   # a checkout, for `sosh-deploy build`
    };
  }
];
```

Without flakes: `imports = [ "${builtins.fetchGit { url = "https://github.com/Auxnon/sosh"; }}/deploy/nixos/sosh.nix" ];`
(or a path to a checkout).

The secrets file, root-only (`sudo install -m 600 /dev/null /var/lib/sosh/env`),
like `deploy/env.example`:

```sh
SECRET_KEY_BASE=...        # openssl rand -base64 48 | tr -d '\n'
POSTGRES_PASSWORD=...      # openssl rand -hex 24  (used by both containers)
# SMTP_HOST=smtp.example.com
# SMTP_PORT=587
# SMTP_USERNAME=...
# SMTP_PASSWORD=...
# MAIL_FROM=no-reply@makeavoy.com
```

Without `SMTP_HOST`, emails aren't sent: they're logged in full, so you can
read sign-up and reset codes with `journalctl -u podman-sosh | grep -A8 Subject`.
Set up a sender (any SMTP provider; 465 is TLS, other ports STARTTLS) before
inviting people.

Then `sudo nixos-rebuild switch`. The service runs `localhost/sosh:live`, a
tag only this machine has; the first start fills it with the newest release
from ghcr.io. If there's no release yet (or the registry is private), it
fails to start: `sudo sosh-deploy build` builds one from the checkout and
starts it. Migrations run on every start.

To follow releases on their own instead, set
`image = "ghcr.io/auxnon/sosh:latest"` and `autoUpdate = true` (a newer
release is pulled daily and on every restart); `sosh-deploy` doesn't work
with a registry image, since a restart would pull over what it deployed.

- Logs: `journalctl -u podman-sosh -f`
- Redeploy: `sudo sosh-deploy ...`, below
- A console: `sudo podman exec -it sosh bin/sosh remote`
- Give someone a server: in that console, `Sosh.Servers.give(server_id, "handle")`
- Back up: `sudo podman exec sosh-db pg_dump -U sosh sosh > sosh.sql`

The image on ghcr.io starts out private. Make the package public (GitHub,
your profile's Packages, sosh, Package settings), or log the machine in with
`sudo podman login ghcr.io` and a token with `read:packages`.

## Redeploying

`sosh-deploy` (the module installs it; it's `deploy/sosh-deploy`) does the
same thing whichever image you pick: backs up the database to
`/var/lib/sosh/backups` (the last 10 kept), keeps the running image as
`localhost/sosh:previous`, tags the new one `localhost/sosh:live`, restarts
`podman-sosh` and waits for it to answer.

```sh
sudo sosh-deploy release            # the newest release
sudo sosh-deploy release 1.2.0      # or a given one
sudo sosh-deploy build              # git pull in /srv/sosh, build it here
sudo sosh-deploy build main         # or a branch, tag or commit
sudo sosh-deploy load FILE          # an image saved elsewhere (podman save, gzipped or not)
sudo sosh-deploy rollback           # back to the one before (again: forward)
sudo sosh-deploy status
```

- `release` pulls `ghcr.io/auxnon/sosh:<version>`, or if that fails
  (private package, no network to ghcr.io), downloads the release's
  `sosh-server-<arch>.tar.gz` from GitHub.
- `build` compiles here: 15 to 40 minutes, ~4 GB RAM, ~15 GB disk (the
  engine builds twice, wasm and native, to pack the game).
- From your own machine: `just ship <host>` builds the image there (your
  checkout as it is, uncommitted changes too), copies it to `<host>` and
  runs `sosh-deploy load` on it. The machines' architectures have to match.

There's no hot code swap: the Rust NIF can't be replaced in a running
node, migrations want a start, and a restart is a few seconds. Universes
save on the way down and clients reconnect on their own.

Rolling back after a release that ran a migration: the old server may not
read the newer database. Then restore the backup taken just before it,
which drops everything since:

```sh
sudo systemctl stop podman-sosh
sudo podman exec sosh-db dropdb -U sosh sosh
sudo podman exec sosh-db createdb -U sosh sosh
gunzip -c /var/lib/sosh/backups/<file> | sudo podman exec -i sosh-db psql -q -U sosh sosh
sudo sosh-deploy rollback
```

## Without NixOS

Anything that runs containers does: the image needs `SECRET_KEY_BASE` and
either `DATABASE_URL` (`ecto://USER:PASS@HOST/DB`) or `DB_HOST`,
`DB_PASSWORD` (and `DB_USER`, `DB_NAME`, default `sosh`). `PHX_HOST`
defaults to `sosh.makeavoy.com`, `PORT` to 4000. Set `TRUST_PROXY=1` only
if nothing but your proxy can reach it.

## Cloudflare

- DNS: `sosh` as a proxied record (orange cloud) to the same origin as
  makeavoy.com. Cloudflare passes websockets through.
- SSL/TLS: with **Full (strict)**, the certificate site-delta serves
  (`config.txt`) has to cover `sosh.makeavoy.com`: a Cloudflare Origin
  certificate for `makeavoy.com, *.makeavoy.com` does; a certificate for
  `makeavoy.com` alone doesn't, and Cloudflare answers 526.

## Old apps

Set `SOSH_MIN_ANDROID` / `SOSH_MIN_DESKTOP` in the env file to the oldest
app this server still talks to (see `deploy/env.example`). Older apps get
an update screen with a link to the download instead of signing in.
Development builds (`-debug`, `-dev`, `0.0.0-<commit>`) and the web game
(always the server's own) are never turned away.

## Releasing

```sh
git tag v0.2.0 && git push origin v0.2.0
```

A `v*` tag is the only thing that publishes, all from `release.yml`: the
server image (`0.2.0`, `0.2`, `0` and `latest` on ghcr.io, and the image
files on the release) and the clients, as one GitHub release. A
pre-release tag (`v0.3.0-rc1`) gets its own image tag but not `latest`, so
`sosh-deploy release` and servers following `latest` stay put. Then on the
server: `sudo sosh-deploy release`.

The Petrichor64 engine they're built on is pinned by commit (`P64_REF` in
`release.yml` and the `Containerfile`; bump both together). The engine takes
its Lua, silt-lua, from silt-lua's GitHub `main`, resolved at build time:
a change pushed to silt's main reaches the next build.

For Android updates to install over each other, every release has to be
signed by the same key. Make one once and keep it safe:

```sh
keytool -genkeypair -v -keystore sosh-release.jks -alias sosh -keyalg RSA -keysize 4096 -validity 10000
base64 -w0 sosh-release.jks   # -> the ANDROID_KEYSTORE_BASE64 secret
```

and add the repository secrets `ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` (`sosh`) and, if it
differs, `ANDROID_KEY_PASSWORD`. Without them the APK is signed with a
throwaway debug key.
