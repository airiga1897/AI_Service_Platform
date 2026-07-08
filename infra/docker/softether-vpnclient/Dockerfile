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
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build --target vpnclient vpncmd --parallel "$(nproc)"

FROM alpine:3.24

RUN apk add --no-cache \
    gnu-libiconv \
    iptables \
    libsodium \
    openssl \
    readline

ENV LD_PRELOAD=/usr/lib/preloadable_libiconv.so

WORKDIR /usr/local/bin
VOLUME ["/var/log/softether", "/var/lib/softether", "/run/softether"]

COPY --from=builder /usr/local/src/SoftEtherVPN/build/vpncmd /usr/local/src/SoftEtherVPN/build/hamcore.se2 ./
COPY --from=builder /usr/local/src/SoftEtherVPN/build/libcedar.so /usr/local/src/SoftEtherVPN/build/libmayaqua.so /usr/local/lib/
COPY --from=builder /usr/local/src/SoftEtherVPN/build/vpnclient ./

CMD ["/usr/local/bin/vpnclient", "execsvc"]
