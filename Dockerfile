# syntax=docker/dockerfile:1
#
# rbrun is a mountable engine; the deployable app is test/dummy (its host). This image builds the whole
# repo (engine + path sub-gems + dummy host), precompiles assets, and boots the dummy app's Puma. The
# sqlite DB lives on a mounted volume (see config/deploy.yml), never in the image.
#
# Build target arch is amd64 (the Hetzner box); on an arm64 laptop Kamal cross-builds via buildx.

ARG RUBY_VERSION=3.4.4
FROM docker.io/library/ruby:${RUBY_VERSION}-slim AS base

WORKDIR /rails

# Runtime env. RAILS_ENV=production is baked so every stage (incl. assets:precompile) runs in production.
ENV RAILS_ENV=production \
    BUNDLE_PATH=/usr/local/bundle \
    RAILS_SERVE_STATIC_FILES=1 \
    RAILS_LOG_TO_STDOUT=1

# Runtime OS deps only (sqlite + yaml shared libs, curl for healthcheck).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libsqlite3-0 libyaml-0-2 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# ---- build stage: compilers + full source, produces gems + precompiled assets ----
FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Copy the whole repo before bundling: the root gemspec Dir-globs app/config/db/lib and the sub-gems are
# path deps, so a partial copy would resolve an incomplete file list. Correctness over layer-caching here.
COPY . .

# Not --deployment: the committed Gemfile.lock is authored on arm64-darwin; letting bundler resolve the
# linux/amd64 platform in-image avoids a "platform missing from the lockfile" failure on the cross-build.
RUN bundle install && rm -rf "${BUNDLE_PATH}"/ruby/*/cache

# Precompile with a throwaway key. Boot runs the engine's after_initialize, but its seeders skip cleanly
# with no DB (they guard on table_exists? and rescue ConnectionNotEstablished), so no database is needed.
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# ---- final stage: runtime only ----
FROM base

COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# Run as a non-root user. The DB volume mounts at test/dummy/storage; Docker seeds a fresh named volume
# with the ownership of the image dir, so chowning it here makes the volume writable by uid 1000.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p /rails/test/dummy/storage /rails/test/dummy/tmp /rails/test/dummy/log && \
    chown -R rails:rails /rails/test/dummy/storage /rails/test/dummy/tmp /rails/test/dummy/log
USER 1000:1000

ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 3000
CMD ["./bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
