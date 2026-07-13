FROM alpine:3.24 AS builder

ARG SOFTETHER_REF=5.02.5187

RUN apk add --no-cache \
    build-base \
    cmake \
    git \
    libsodium-dev \
    linux-headers \
    ncurses-dev \
    openssl-dev \
    readline-dev \
    zlib-dev

WORKDIR /usr/local/src
RUN git clone --depth 1 --branch "${SOFTETHER_REF}" https://github.com/SoftEtherVPN/SoftEtherVPN.git SoftEtherVPN

WORKDIR /usr/local/src/SoftEtherVPN
RUN git submodule update --init --recursive && \
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 && \
    cmake --build build --target vpnserver vpnclient vpncmd hamcore-archive-build --parallel "$(nproc)"

RUN test -x build/vpnclient && \
    test -x build/vpnserver && \
    test -x build/vpncmd && \
    test -f build/libcedar.so && \
    test -f build/libmayaqua.so && \
    test -f build/hamcore.se2

FROM alpine:3.24

RUN apk add --no-cache \
    gnu-libiconv \
    iptables \
    libsodium \
    openssl \
    readline

ENV LD_PRELOAD=/usr/lib/preloadable_libiconv.so

WORKDIR /usr/local/bin

COPY --from=builder /usr/local/src/SoftEtherVPN/build/vpncmd /usr/local/src/SoftEtherVPN/build/hamcore.se2 ./
COPY --from=builder /usr/local/src/SoftEtherVPN/build/libcedar.so /usr/local/src/SoftEtherVPN/build/libmayaqua.so /usr/local/lib/
COPY --from=builder /usr/local/src/SoftEtherVPN/build/vpnserver /usr/local/src/SoftEtherVPN/build/vpnclient ./
COPY softether-entrypoint.sh /usr/local/bin/softether-entrypoint.sh
RUN chmod 0755 /usr/local/bin/softether-entrypoint.sh

CMD ["/usr/local/bin/softether-entrypoint.sh", "client"]
