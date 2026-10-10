# mcl-sec-guard
#
# The security guardian, P0 shadow: observes denial facts and records proposals; applies nothing
#
# NO DATA VOLUME AS GENERATED. The scaffold writes nothing, and a named volume
# for data that does not exist is a promise the image cannot keep. Add one
# together with the code that writes it, and declare it here and in the compose
# file at the same time.

# ⚠ AN IMAGE PAIR, PINNED BY DIGEST, AND THE PAIR MOVES TOGETHER. The builder
# carries the whole toolchain: OTP 28.4.3 with an OpenSSL that has ML-DSA,
# rebar3, Rust (macula's NIFs always build from source) and a C toolchain. The
# runtime is the same distribution with only what the release loads, so the
# ERTS and NIFs built here match the libc and OpenSSL they run on. lint.yml
# runs in the same builder image, so CI tests what ships.
#
# A service that links the erlang `rocksdb' binding (barrel_docdb, for a read
# model of its own) needs a pair built for it, with librocksdb and its
# compression libraries in both images. Change both FROM lines together.
# Without the compression -dev packages rocksdb's CMake silently disables that
# backend and the build stays green, then barrel_docdb's default snappy blob
# compression fails at db_open: "The specified blob compression type Snappy is
# not available."
FROM ghcr.io/macula-io/macula-ci-otp:20260928-1800@sha256:7318a443021f8a4ceb7ad56b0ab21f52db95db92996ea0f0897a1eff0b678832 AS builder

# ⚠ THE OTP RELEASE, ASSERTED HERE, because an image's tag need not name one.
# The same check as lint.yml's toolchain step; the service tests read this
# line and compare it with lint's and .tool-versions. It runs first, so an
# image on another release fails before anything is compiled.
RUN erl -noshell -eval ' \
    Otp = string:trim(element(2, file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])))), \
    Mldsa = lists:member(mldsa87, crypto:supports(public_keys)), \
    io:format("OTP ~s, mldsa87 ~p~n", [Otp, Mldsa]), \
    case {Otp, Mldsa} of \
        {<<"28.4.3">>, true} -> halt(0); \
        _                    -> halt(1) \
    end.'

WORKDIR /build

# Dependencies resolve from rebar.config alone, so this layer survives every
# change to config/ and apps/.
COPY rebar.config ./
RUN rebar3 get-deps

COPY config ./config
COPY apps ./apps
RUN rebar3 as prod release

# ⚠ faber never ships (#16). The release carries mcl_sec_trainer (the
# console's run endpoint calls it) and must never carry faber: the learner,
# faber's only user, lives in its own app that is not in this release. A
# hard check here, so no build, CI or local, can produce a violating image.
RUN ls _build/prod/rel/mcl_sec_guard/lib | grep -q '^mcl_sec_trainer-' \
    && ! ls _build/prod/rel/mcl_sec_guard/lib | grep -q '^faber'

FROM ghcr.io/macula-io/macula-pq-runtime:20260928-1800@sha256:a1d18c6a6a22d8d7fba6086785c683bd113828e16fdfde147d96ae67d2c6892d
# LINKS THE PACKAGE TO THE REPOSITORY. On registries that read it, ghcr among
# them, a package without this label is an orphan: it does not appear on the
# repository page and does not inherit its visibility. A service that shipped
# private by accident failed its first pull with a bare "unauthorized", which
# names nothing and sends you looking in the wrong place.
LABEL org.opencontainers.image.source="https://github.com/macula-services/mcl-sec-guard"
# The commit this image was built from (build-push passes github.sha), so a
# digest a fleet pins can be traced back to its commit.
ARG REVISION=unknown
LABEL org.opencontainers.image.revision="${REVISION}"
# Nothing is installed here: the runtime image carries what the release loads.
# A program the service's own code shells out to is installed at this point,
# in one RUN, with the reason beside it.
WORKDIR /app
COPY --from=builder /build/_build/prod/rel/mcl_sec_guard ./

ENV HOME=/app
ENV RELX_REPLACE_OS_VARS=true

ENV MCL_NODE_NAME=mcl_sec_guard
ENV MCL_NODE_HOST=127.0.0.1
ENV MCL_COOKIE=mcl_sec_guard

VOLUME ["/etc/mcl/secrets"]

# /health is a Unix socket (health_socket in sys.config.src): no port is opened
# just to be health-checked.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS --unix-socket /run/mcl/health.sock http://localhost/health || exit 1

CMD ["/app/bin/mcl_sec_guard", "foreground"]
