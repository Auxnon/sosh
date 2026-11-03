# The production image: the Phoenix release serving the web game.
#
#   podman build -t sosh .            (from the repo root)
#
# Three stages: the Petrichor64 web engine and the packed game (Rust, wasm),
# the Elixir release (with the Rust NIF), and a slim runtime. The engine is
# fetched from GitHub at P64_REF, the commit the client is known to work with
# (it takes its Lua, silt-lua, from silt-lua's GitHub main). Keep it in step
# with .github/workflows/release.yml.

ARG P64_REPO=https://github.com/Auxnon/Petrichor64.git
ARG P64_REF=b7c976c3bc4ce4af5e96f2f1853a81ede74ee834

# --- 1. web engine + game.game.png ------------------------------------------
# trixie: trunk's prebuilt arm64 wasm-bindgen needs glibc 2.38+ (bookworm has 2.36)
FROM docker.io/library/rust:1-trixie AS web
RUN apt-get update && apt-get install -y --no-install-recommends \
      pkg-config libasound2-dev libudev-dev perl \
 && rm -rf /var/lib/apt/lists/*
RUN rustup target add wasm32-unknown-unknown \
 && cargo install --locked wasm-pack trunk
# (declared after the tools, so a new engine commit doesn't rebuild them)
ARG P64_REPO
ARG P64_REF
WORKDIR /p64
RUN git init -q . && git remote add origin "$P64_REPO" \
 && git fetch -q --depth 1 origin "$P64_REF" && git checkout -q FETCH_HEAD
# the browser build: the synth worklet, then the engine
RUN wasm-pack build synth --release --target web --out-dir ../web/synth \
      -- --no-default-features --features worklet \
 && trunk build --release
# a native chor just to pack the game (the web build always has websockets);
# its clipboard links xcb
RUN apt-get update && apt-get install -y --no-install-recommends \
      libxcb1-dev libxcb-render0-dev libxcb-shape0-dev libxcb-xfixes0-dev \
 && rm -rf /var/lib/apt/lists/* \
 && cargo build --release --bin chor
COPY client /client
RUN mkdir -p /static && cp web/dist/* /static/ \
 && cp /client/web/gamepad.js /client/web/recover.js /static/ \
 && perl -pi -e 's#</body>#  <script src="/gamepad.js"></script>\n  <script src="/recover.js"></script>\n  </body>#' /static/index.html \
 && target/release/chor pack /client /static/game.game.png

# --- 2. the release ----------------------------------------------------------
FROM docker.io/library/elixir:1.18 AS build
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal \
 && mix local.hex --force && mix local.rebar --force
ENV PATH=/root/.cargo/bin:$PATH MIX_ENV=prod
WORKDIR /app
COPY server/mix.exs server/mix.lock ./
RUN mix deps.get --only prod && mkdir config
COPY server/config/config.exs server/config/prod.exs config/
RUN mix deps.compile
COPY server/Cargo.toml server/Cargo.lock ./
COPY server/native native
COPY server/lib lib
COPY server/priv priv
COPY server/rel rel
COPY --from=web /static/ priv/static/
COPY server/config/runtime.exs config/
RUN mix compile && mix phx.digest && mix release

# --- 3. runtime --------------------------------------------------------------
# Same Debian as the elixir image above (trixie today), or the release's ERTS
# won't find the libraries it was built against.
FROM docker.io/library/debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 MIX_ENV=prod PHX_HOST=sosh.makeavoy.com PORT=4000
RUN useradd --system --create-home --home-dir /app sosh
WORKDIR /app
COPY --from=build --chown=sosh:sosh /app/_build/prod/rel/sosh ./
USER sosh
EXPOSE 4000
# DATABASE_URL and SECRET_KEY_BASE are required; see deploy/README.md.
CMD ["/app/bin/server"]
