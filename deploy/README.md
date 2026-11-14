# Deploying sosh

```
browser / desktop / app ──https──▶ Cloudflare (proxied) ──▶ site-delta :443 ──▶ 127.0.0.1:4000 sosh ──▶ sosh-db
                                                            (Host: sosh.makeavoy.com)   (podman)       (postgres:17)
```

- **The server** is one container image, built by the `Containerfile` at the
  repo root: the Phoenix release with the Rust NIF, and the web game (the
  Petrichor64 wasm engine plus the packed client) in `priv/static`.
  `.github/workflows/image.yml` builds it on GitHub, for x86_64 and arm64
  (native runners), and pushes it to `ghcr.io/auxnon/sosh` for every release:
  a `v*` tag, say `v1.2.0`, publishes `1.2.0`, `1.2`, `1` and `latest`.
  Pushes to main publish nothing. The server only pulls it; nothing compiles
  there.
- **The clients** come from `.github/workflows/release.yml` on a `v*` tag:
  a Windows exe, a Linux AppImage and an Android APK, all pointed at
  `https://sosh.makeavoy.com` by default.
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
      # autoUpdate = true;   # pull a newer :latest (the newest release) daily and restart
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

Then `sudo nixos-rebuild switch`. Migrations run on every start.

- Logs: `journalctl -u podman-sosh -f`
- Update by hand: `sudo podman pull ghcr.io/auxnon/sosh:latest && sudo systemctl restart podman-sosh`
  (or `autoUpdate = true`)
- A console: `sudo podman exec -it sosh bin/sosh remote`
- Give someone a server: in that console, `Sosh.Servers.give(server_id, "handle")`
- Back up: `sudo podman exec sosh-db pg_dump -U sosh sosh > sosh.sql`

The image on ghcr.io starts out private. Make the package public (GitHub,
your profile's Packages, sosh, Package settings), or log the machine in with
`sudo podman login ghcr.io` and a token with `read:packages`.

### Building the image on the machine instead

```sh
git clone https://github.com/Auxnon/sosh && cd sosh
sudo podman build -t localhost/sosh .
```

and set `services.sosh.image = "localhost/sosh";`. It takes a while: the
engine is built twice (wasm and native, to pack the game).

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

A `v*` tag is the only thing that publishes: the server image
(`image.yml`: `0.2.0`, `0.2`, `0` and `latest`) and the clients
(`release.yml`, a GitHub release). A pre-release tag (`v0.3.0-rc1`) gets
its own image tag but not `latest`, so servers following `latest` stay put.

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
