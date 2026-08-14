ARG NEXUS_REVISION=v0.1.1

FROM golang:1.26.6-alpine AS nexus-builder

ARG NEXUS_REVISION
RUN GOBIN=/out CGO_ENABLED=0 go install github.com/git-pkgs/nexus/cmd/nexus@${NEXUS_REVISION}

FROM ruby:4.0.6-alpine

ENV APP_ROOT=/usr/src/app
ENV DATABASE_PORT=5432
ENV RUBY_YJIT_ENABLE=1
ENV LD_PRELOAD=/usr/lib/libjemalloc.so.2
WORKDIR $APP_ROOT

# * Setup system
# * Install Ruby dependencies
RUN apk add --update \
    build-base \
    netcat-openbsd \
    git \
    postgresql-dev \
    tzdata \
    curl-dev \
    libc6-compat \
    bash \
    yaml-dev \
    libffi-dev \
    jemalloc \
    ca-certificates \
 && rm -rf /var/cache/apk/*

# Will invalidate cache as soon as the Gemfile changes
COPY Gemfile Gemfile.lock $APP_ROOT/

RUN bundle config --global frozen 1 \
 && bundle config set without 'test' \
 && bundle install --jobs 2

# ========================================================
# Application layer

# Copy application code
COPY . $APP_ROOT
COPY --from=nexus-builder /out/nexus /usr/local/bin/nexus

RUN bundle exec bootsnap precompile --gemfile app/ lib/
RUN nexus sync -h >/dev/null

# Startup
CMD ["bin/docker-start"]
