################################################################################
# Set up environment variables, OS packages, and scripts that are common to the
# build and distribution layers in this Dockerfile
FROM alpine:3.11 AS base

# Must be one of 'gmp' or 'simple'; used to build GHC with support for either
# 'integer-gmp' (with 'libgmp') or 'integer-simple'
#
# Default to building with 'integer-gmp' and 'libgmp' support
ARG GHC_BUILD_TYPE

# Must be a valid GHC version number
# tested with 8.4.4, 8.6.4, 8.6.5, 8.8.3
ARG GHC_VERSION=8.8.3

# Add ghcup's bin directory to the PATH so that the versions of GHC it builds
# are available in the build layers
ENV GHCUP_INSTALL_BASE_PREFIX=/
ENV PATH=/.ghcup/bin:$PATH

# Use the latest version of ghcup (at the time of writing)
ENV GHCUP_VERSION=0.1.6
ENV GHCUP_SHA256="bdbec0cdf4c8511c4082dd83993d15034c0fbcb5722ecf418c1cee40667da8af  ghcup"

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
ARG GHC_VERSION=8.8.3
ARG GHC_BOOTSTRAP_VERSION=8.6.5

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
        llvm9 \
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

ENV STACK_VERSION=2.3.1
ENV STACK_SHA256="4bae8830b2614dddf3638a6d1a7bbbc3a5a833d05b2128eae37467841ac30e47  stack-${STACK_VERSION}-linux-x86_64-static.tar.gz"

# Download, verify, and install stack
RUN echo "Downloading and installing stack" &&\
    wget -P /tmp/ "https://github.com/commercialhaskell/stack/releases/download/v${STACK_VERSION}/stack-${STACK_VERSION}-linux-x86_64-static.tar.gz" &&\
    cd /tmp &&\
    if ! echo -n "${STACK_SHA256}" | sha256sum -c -; then \
        echo "stack-${STACK_VERSION} checksum failed" >&2 &&\
        exit 1 ;\
    fi ;\
    tar -xvzf /tmp/stack-${STACK_VERSION}-linux-x86_64-static.tar.gz &&\
    cp -L /tmp/stack-${STACK_VERSION}-linux-x86_64-static/stack /usr/bin/stack &&\
    rm /tmp/stack-${STACK_VERSION}-linux-x86_64-static.tar.gz &&\
    rm -rf /tmp/stack-${STACK_VERSION}-linux-x86_64-static

################################################################################
# Assemble the final image
FROM base

# Carry build args through to this stage
ARG GHC_BUILD_TYPE=gmp
ARG GHC_VERSION=8.8.3

COPY --from=build-ghc /.ghcup /.ghcup
COPY --from=build-tooling /usr/bin/stack /usr/bin/stack

# NOTE: 'stack --docker' needs bash + usermod/groupmod (from shadow)
RUN apk add --no-cache bash shadow openssh-client tar

RUN ghcup set ghc ${GHC_VERSION} &&\
    stack config set system-ghc --global true
