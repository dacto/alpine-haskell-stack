################################################################################
# Set up environment variables, OS packages, and scripts that are common to the
# build and distribution layers in this Dockerfile
FROM alpine:3.13.5 AS base

# Must be one of 'gmp' or 'simple'; used to build GHC with support for either
# 'integer-gmp' (with 'libgmp') or 'integer-simple'
#
# Default to building with 'integer-gmp' and 'libgmp' support
ARG GHC_BUILD_TYPE

# Must be a valid GHC version number
# tested with 8.4.4, 8.6.4, 8.6.5, 8.8.3, 8.10.1, 8.10.3, 8.10.4
ARG GHC_VERSION=8.10.4

# Add ghcup's bin directory to the PATH so that the versions of GHC it builds
# are available in the build layers
ENV GHCUP_INSTALL_BASE_PREFIX=/
ENV PATH=/.ghcup/bin:$PATH

# Use the latest version of ghcup (at the time of writing)
ENV GHCUP_VERSION=0.1.14.1
ENV GHCUP_SHA256="59e31b2ede3ed20f79dce0f8ba0a68b6fb25e5f00ba2d7243f6a8af68d979ff5  ghcup"

# Install the basic required dependencies to run 'ghcup' and 'stack'
RUN apk upgrade --no-cache &&\
    apk add --no-cache \
        curl \
        gcc \
        git \
        libc-dev \
        xz &&\
    if [ "${GHC_BUILD_TYPE}" = "gmp" ]; then \
        echo "Installing 'libgmp'" &&\
        apk add --no-cache gmp-dev; \
    fi

# Download, verify, and install ghcup
RUN echo "Downloading and installing ghcup" &&\
    wget -O /tmp/ghcup "https://downloads.haskell.org/ghcup/${GHCUP_VERSION}/x86_64-linux-ghcup-${GHCUP_VERSION}" &&\
    cd /tmp &&\
    if ! echo -n "${GHCUP_SHA256}" | sha256sum -c -; then \
        echo "ghcup-${GHCUP_VERSION} checksum failed" >&2 &&\
        exit 1 ;\
    fi ;\
    mv /tmp/ghcup /usr/bin/ghcup &&\
    chmod +x /usr/bin/ghcup

################################################################################
# Intermediate layer that builds GHC
FROM base AS build-ghc

# Carry build args through to this stage
ARG GHC_BUILD_TYPE=gmp
ARG GHC_VERSION=8.10.4
ARG GHC_BOOTSTRAP_VERSION=8.8.4

RUN echo "Install OS packages necessary to build GHC" &&\
    apk add --no-cache \
        autoconf \
        automake \
        binutils-gold \
        build-base \
        coreutils \
        cpio \
        ghc=~${GHC_BOOTSTRAP_VERSION} \
        linux-headers \
        libffi-dev \
        llvm10 \
        musl-dev \
        ncurses-dev \
        perl \
        python3 \
        py3-sphinx \
        zlib-dev

COPY docker/build-gmp.mk /tmp/build-gmp.mk
COPY docker/build-simple.mk /tmp/build-simple.mk
RUN if [ "${GHC_BUILD_TYPE}" = "gmp" ]; then \
        echo "Using 'integer-gmp' build config" &&\
        apk add --no-cache gmp-dev &&\
        mv /tmp/build-gmp.mk /tmp/build.mk && rm /tmp/build-simple.mk; \
    elif [ "${GHC_BUILD_TYPE}" = "simple" ]; then \
        echo "Using 'integer-simple' build config" &&\
        mv /tmp/build-simple.mk /tmp/build.mk && rm tmp/build-gmp.mk; \
    else \
        echo "Invalid argument \[ GHC_BUILD_TYPE=${GHC_BUILD_TYPE} \]" && exit 1; \
fi

RUN echo "Compiling and installing GHC" &&\
    LD=ld.gold \
    SPHINXBUILD=/usr/bin/sphinx-build-3 \
      ghcup -v compile ghc -j $(nproc) -c /tmp/build.mk -v ${GHC_VERSION} -b ${GHC_BOOTSTRAP_VERSION} &&\
    rm /tmp/build.mk &&\
    echo "Uninstalling GHC bootstrapping compiler" &&\
    apk del ghc &&\
    ghcup set ghc ${GHC_VERSION}

################################################################################
# Intermediate layer that assembles 'stack' tooling
FROM base AS build-tooling

ENV STACK_VERSION=2.7.1
ENV STACK_SHA256="2bc47749ee4be5eccb52a2d4a6a00b0f3b28b92517742b40c675836d7db2777d  stack-${STACK_VERSION}-linux-x86_64.tar.gz"

# Download, verify, and install stack
RUN echo "Downloading and installing stack" &&\
    wget -P /tmp/ "https://github.com/commercialhaskell/stack/releases/download/v${STACK_VERSION}/stack-${STACK_VERSION}-linux-x86_64.tar.gz" &&\
    cd /tmp &&\
    if ! echo -n "${STACK_SHA256}" | sha256sum -c -; then \
        echo "stack-${STACK_VERSION} checksum failed" >&2 &&\
        exit 1 ;\
    fi ;\
    tar -xvzf /tmp/stack-${STACK_VERSION}-linux-x86_64.tar.gz &&\
    cp -L /tmp/stack-${STACK_VERSION}-linux-x86_64/stack /usr/bin/stack &&\
    rm /tmp/stack-${STACK_VERSION}-linux-x86_64.tar.gz &&\
    rm -rf /tmp/stack-${STACK_VERSION}-linux-x86_64

################################################################################
# Assemble the final image
FROM base

# Carry build args through to this stage
ARG GHC_BUILD_TYPE=gmp
ARG GHC_VERSION=8.10.4

COPY --from=build-ghc /.ghcup /.ghcup
COPY --from=build-tooling /usr/bin/stack /usr/bin/stack

# NOTE: 'stack --docker' needs bash + usermod/groupmod (from shadow)
RUN apk add --no-cache bash shadow openssh-client tar

RUN ghcup set ghc ${GHC_VERSION} &&\
    stack config set system-ghc --global true
