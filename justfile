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
