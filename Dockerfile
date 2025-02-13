# Initial base from https://github.com/leonardochaia/docker-monerod/blob/master/src/Dockerfile
# Alpine specifics from https://github.com/cornfeedhobo/docker-monero/blob/f96711415f97af1fc9364977d1f5f5ecd313aad0/Dockerfile

# Set Monero branch or tag to build
ARG MONERO_BRANCH=v0.18.3.4

# Set the proper HEAD commit hash for the given branch/tag in MONERO_BRANCH
ARG MONERO_COMMIT_HASH=b089f9ee69924882c5d14dd1a6991deb05d9d1cd

# Select Alpine 3 for the build image base
FROM alpine:3 AS build
LABEL author="seth@sethforprivacy.com" \
      maintainer="seth@sethforprivacy.com"

# Upgrade base image
RUN set -ex && apk --update --no-cache upgrade

# Install all dependencies for a static build
RUN set -ex && apk add --update --no-cache \
    autoconf \
    automake \
    boost \
    boost-atomic \
    boost-build \
    boost-build-doc \
    boost-chrono \
    boost-container \
    boost-context \
    boost-contract \
    boost-coroutine \
    boost-date_time \
    boost-dev \
    boost-doc \
    boost-fiber \
    boost-filesystem \
    boost-graph \
    boost-iostreams \
    boost-libs \
    boost-locale \
    boost-log \
    boost-log_setup \
    boost-math \
    boost-prg_exec_monitor \
    boost-program_options \
    boost-python3 \
    boost-random \
    boost-regex \
    boost-serialization \
    boost-stacktrace_basic \
    boost-stacktrace_noop \
    boost-static \
    boost-system \
    boost-thread \
    boost-timer \
    boost-type_erasure \
    boost-unit_test_framework \
    boost-wave \
    boost-wserialization \
    ca-certificates \
    cmake \
    curl \
    dev86 \
    doxygen \
    eudev-dev \
    file \
    g++ \
    git \
    graphviz \
    gnupg \
    libsodium-dev \
    libtool \
    libusb-dev \
    linux-headers \
    make \
    miniupnpc-dev \
    ncurses-dev \
    openssl-dev \
    pcsc-lite-dev \
    pkgconf \
    protobuf-dev \
    rapidjson-dev \
    readline-dev \
    zeromq-dev

# Set necessary args and environment variables for building Monero
ARG MONERO_BRANCH
ARG MONERO_COMMIT_HASH
ARG NPROC
ARG TARGETARCH
ENV CFLAGS='-fPIC'
ENV CXXFLAGS='-fPIC'
ENV USE_SINGLE_BUILDDIR=1
ENV BOOST_DEBUG=1

# Build expat, a dependency for libunbound
ARG EXPAT_VERSION="2.6.4"
ARG EXPAT_HASH="8dc480b796163d4436e6f1352e71800a774f73dbae213f1860b60607d2a83ada"
RUN set -ex && wget https://github.com/libexpat/libexpat/releases/download/R_2_6_4/expat-${EXPAT_VERSION}.tar.bz2 && \
    echo "${EXPAT_HASH}  expat-${EXPAT_VERSION}.tar.bz2" | sha256sum -c && \
    tar -xf expat-${EXPAT_VERSION}.tar.bz2 && \
    rm expat-${EXPAT_VERSION}.tar.bz2 && \
    cd expat-${EXPAT_VERSION} && \
    ./configure --enable-static --disable-shared --prefix=/usr && \
    make -j${NPROC:-$(nproc)} && \
    make -j${NPROC:-$(nproc)} install

# Build libunbound for static builds
WORKDIR /tmp
ARG LIBUNBOUND_VERSION="1.22.0"
ARG LIBUNBOUND_HASH="c5dd1bdef5d5685b2cedb749158dd152c52d44f65529a34ac15cd88d4b1b3d43"
RUN set -ex && wget https://www.nlnetlabs.nl/downloads/unbound/unbound-${LIBUNBOUND_VERSION}.tar.gz && \
    echo "${LIBUNBOUND_HASH}  unbound-${LIBUNBOUND_VERSION}.tar.gz" | sha256sum -c && \
    tar -xzf unbound-${LIBUNBOUND_VERSION}.tar.gz && \
    rm unbound-${LIBUNBOUND_VERSION}.tar.gz && \
    cd unbound-${LIBUNBOUND_VERSION} && \
    ./configure --disable-shared --enable-static --without-pyunbound --with-libexpat=/usr --with-ssl=/usr --with-libevent=no --without-pythonmodule --disable-flto --with-pthreads --with-libunbound-only --with-pic && \
    make -j${NPROC:-$(nproc)} && \
    make -j${NPROC:-$(nproc)} install

# Switch to Monero source directory
WORKDIR /monero

# Git pull Monero source at specified tag/branch and compile statically-linked monerod binary
RUN set -ex && git clone --recursive --branch ${MONERO_BRANCH} \
    --depth 1 --shallow-submodules \
    https://github.com/monero-project/monero . \
    && test `git rev-parse HEAD` = ${MONERO_COMMIT_HASH} || exit 1 \
    && curl -L https://github.com/monero-project/monero/pull/9460.patch | git apply \
    && curl -L https://github.com/monero-project/monero/pull/9775.patch | git apply \
    && case ${TARGETARCH:-amd64} in \
        "arm64") CMAKE_ARCH="armv8-a"; CMAKE_BUILD_TAG="linux-armv8" ;; \
        "amd64") CMAKE_ARCH="x86-64"; CMAKE_BUILD_TAG="linux-x64" ;; \
        *) echo "Dockerfile does not support this platform"; exit 1 ;; \
    esac \
    && mkdir -p build/release && cd build/release \
    && cmake -D ARCH=${CMAKE_ARCH} -D STATIC=ON -D BUILD_64=ON -D CMAKE_BUILD_TYPE=Release -D BUILD_TAG=${CMAKE_BUILD_TAG} -D STACK_TRACE=OFF ../.. \
    && cd /monero && nice -n 19 ionice -c2 -n7 make -j${NPROC:-$(nproc)} -C build/release daemon

# git pull and validate ban list
RUN set -ex && git clone https://github.com/Boog900/monero-ban-list \
    && cd monero-ban-list \
    && wget https://raw.githubusercontent.com/Cuprate/cuprate/7b8756fa80e386fb04173d8220c15c86bf9f9888/misc/gpg_keys/boog900.asc \
    && wget -O rucknium.asc https://rucknium.me/pgp.txt \
    || wget -O rucknium.asc https://gist.githubusercontent.com/Rucknium/262526e37732241bb0e676c670b8c60d/raw \
    && wget https://raw.githubusercontent.com/monero-project/monero/004ead1a14d60ff757880c5b16b894b526427829/utils/gpg_keys/jeffro256.asc \
    && gpg --import boog900.asc \
    && gpg --import rucknium.asc \
    && gpg --import jeffro256.asc \
    && gpg --verify --status-fd 1 --verify ./sigs/boog900.sig ban_list.txt 2>/dev/null \
    && gpg --verify --status-fd 1 --verify ./sigs/Rucknium.sig ban_list.txt 2>/dev/null \
    && gpg --verify --status-fd 1 --verify ./sigs/jeffro256.sig ban_list.txt 2>/dev/null

# Begin final image build
# Select Alpine 3 for the base image
FROM alpine:3 AS final

# Upgrade base image
RUN set -ex && apk --update --no-cache upgrade

# Install all dependencies for static binaries + curl for healthcheck
RUN set -ex && apk add --update --no-cache \
    curl \
    ca-certificates \
    libsodium \
    ncurses-libs \
    pcsc-lite-libs \
    readline \
    tzdata \
    zeromq

# Add user and setup directories for monerod
RUN set -ex && adduser -Ds /bin/bash monero \
    && mkdir -p /home/monero/.bitmonero \
    && chown -R monero:monero /home/monero/.bitmonero

# Copy and enable entrypoint script
ADD entrypoint.sh /entrypoint.sh
RUN set -ex && chmod +x entrypoint.sh
ENTRYPOINT [ "/entrypoint.sh" ]

# Install and configure fixuid and switch to MONERO_USER
ARG MONERO_USER="monero"
ARG TARGETARCH
ARG FIXUID_VERSION="0.6.0"
RUN set -ex && case ${TARGETARCH:-amd64} in \
        "arm64") curl -SsL https://github.com/boxboat/fixuid/releases/download/v${FIXUID_VERSION}/fixuid-${FIXUID_VERSION}-linux-arm64.tar.gz | tar -C /usr/local/bin -xzf - ;; \
        "amd64") curl -SsL https://github.com/boxboat/fixuid/releases/download/v${FIXUID_VERSION}/fixuid-${FIXUID_VERSION}-linux-amd64.tar.gz | tar -C /usr/local/bin -xzf - ;; \
        *) echo "Dockerfile does not support this platform"; exit 1 ;; \
    esac && \
    chown root:root /usr/local/bin/fixuid && \
    chmod 4755 /usr/local/bin/fixuid && \
    mkdir -p /etc/fixuid && \
    printf "user: ${MONERO_USER}\ngroup: ${MONERO_USER}\n" > /etc/fixuid/config.yml
USER "${MONERO_USER}:${MONERO_USER}"

# Switch to home directory and install newly built monerod binary
WORKDIR /home/${MONERO_USER}
COPY --chown=monero:monero --from=build /monero/build/release/bin/monerod /usr/local/bin/monerod
COPY --chown=monero:monero --from=build /monero/monero-ban-list/ban_list.txt ./ban_list.txt

# Expose p2p port
EXPOSE 18080

# Expose restricted RPC port
EXPOSE 18089

# Add HEALTHCHECK against get_info endpoint
HEALTHCHECK --interval=30s --timeout=5s CMD curl --fail http://localhost:18081/get_height || exit 1

# Start monerod with sane defaults that are overridden by user input (if applicable)
CMD ["--rpc-restricted-bind-ip=0.0.0.0", "--rpc-restricted-bind-port=18089", "--no-igd", "--no-zmq", "--enable-dns-blocklist", "--ban-list=/home/monero/ban_list.txt"]
