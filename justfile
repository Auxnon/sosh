# The recipes live in client/justfile; these run them from the repo root.

default:
    @just -f client/justfile --list

db:
    just -f client/justfile db

serve:
    just -f client/justfile serve

pack:
    just -f client/justfile pack

web:
    just -f client/justfile web

web-engine:
    just -f client/justfile web-engine

engine:
    just -f client/justfile engine

# The desktop app (desktop/): the social client, styled like the Android
# app, with the world (the game, run by the engine as a library) inside it.
desktop *args:
    cd desktop && cargo run --release -- {{args}}

app *args:
    just desktop {{args}}

assets:
    just -f client/justfile assets

android:
    just -f client/justfile android

android-install:
    just -f client/justfile android-install

install:
    just -f client/justfile install

android-test:
    just -f client/justfile android-test

# The checkout as it is (uncommitted changes included) is built here, copied
# over and put live by `sosh-deploy load` (deploy/README.md). HOST's
# architecture has to match this machine's.
# Build the server image here and deploy it on HOST over ssh
ship host:
    #!/usr/bin/env bash
    set -euo pipefail
    sha="$(git rev-parse --short HEAD)$(git diff --quiet HEAD || echo -dirty)"
    podman build --label "org.opencontainers.image.version=0.0.0-$sha" -t "localhost/sosh:ship-$sha" .
    file="$(mktemp -d)/sosh-server-$sha.tar.gz"
    podman save "localhost/sosh:ship-$sha" | gzip > "$file"
    scp "$file" "{{host}}:sosh-server-$sha.tar.gz"
    rm -rf "$(dirname "$file")"
    ssh -t "{{host}}" "sudo sosh-deploy load sosh-server-$sha.tar.gz && rm -f sosh-server-$sha.tar.gz"
