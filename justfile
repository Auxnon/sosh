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

desktop:
    just -f client/justfile desktop

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
