ARG TARGETPLATFORM
# =================================================
# STAGE 1: BUILDER C/C++/Rust
# =================================================
FROM ghcr.io/void-linux/void-musl-busybox:latest AS smartdns-builder

# FIX HERE: Declare ARG to be available in the stage
ARG TARGETPLATFORM

# Install build dependencies
RUN xbps-install -Suy && \
    xbps-install -y binutils perl curl make git musl-devel libatomic-devel base-devel rust cargo openssl-devel libunwind-devel libgcc-devel clang cmake

# Clone & Build
RUN git clone https://github.com/pymumu/smartdns.git /build/smartdns
WORKDIR /build/smartdns

# Build C/C++ Core
RUN \
    case "${TARGETPLATFORM}" in \
      "linux/amd64")   ARCH=x86_64 ;; \
      "linux/arm64")   ARCH=aarch64 ;; \
      "linux/arm/v7")  ARCH=armv7l ;; \
      *) echo "Unsupported C/C++ TARGETPLATFORM: ${TARGETPLATFORM}" && exit 1 ;; \
    esac && \
    EXTRA_CFLAGS="" && EXTRA_LDFLAGS="" && \
    case "$ARCH" in \
      "aarch64") EXTRA_CFLAGS="-mno-outline-atomics"; EXTRA_LDFLAGS="-latomic" ;; \
      "armv7l")  EXTRA_LDFLAGS="-latomic" ;; \
    esac && \
    export CC=gcc CFLAGS="${EXTRA_CFLAGS}" LDFLAGS="${EXTRA_LDFLAGS}" && \
    sh ./package/build-pkg.sh --platform linux --arch "${ARCH}" && \
    (cd package && tar -xvf *.tar.gz && chmod a+x smartdns/etc/init.d/smartdns) && \
    strip /build/smartdns/package/smartdns/usr/sbin/smartdns && \
    mkdir -p /release/etc/smartdns/ && \
    mkdir -p /release/usr && \
    cp -a package/smartdns/usr/* /release/usr/

# Build Rust Plugin
RUN \
    case "${TARGETPLATFORM}" in \
      "linux/amd64")   RUST_TARGET=x86_64-unknown-linux-musl ;; \
      "linux/arm64")   RUST_TARGET=aarch64-unknown-linux-musl ;; \
      "linux/arm/v7")  RUST_TARGET=armv7-unknown-linux-musleabihf ;; \
      *) echo "Unsupported Rust TARGETPLATFORM: ${TARGETPLATFORM}" && exit 1 ;; \
    esac && \
    cd /build/smartdns/plugin/smartdns-ui && \
    cargo build --target ${RUST_TARGET} --release && \
    ls -l target/${RUST_TARGET}/release/ && \
    mkdir -p /release/usr/lib && \
    cp target/${RUST_TARGET}/release/libsmartdns_ui.so /release/usr/lib/

# =================================================
# STAGE 2: BUILDER FRONTEND
# =================================================
FROM node:lts-alpine AS frontend-builder

# Install git
RUN apk add --no-cache git

# Clone & Build
RUN git clone https://github.com/pymumu/smartdns-webui.git /build/frontend
WORKDIR /build/frontend
RUN npm install && NODE_ENV=production npm run build --no-analytics && mv out wwwroot && mkdir -p /release/usr/share/smartdns && cp -r wwwroot /release/usr/share/smartdns

# =================================================
# STAGE 3: RUNTIME FINAL
# =================================================
FROM ghcr.io/void-linux/void-musl-busybox:latest AS runtime

# Install runtime dependencies
RUN mkdir -p /etc/smartdns /usr/sbin /usr/lib /usr/share/smartdns && \
    xbps-install -Sy libatomic libgcc libunwind    

# Copy the build results from ALL previous builders
COPY --from=smartdns-builder /release/etc /etc
COPY --from=smartdns-builder /release/usr/sbin /usr/sbin
COPY --from=smartdns-builder /release/usr/lib /usr/lib
COPY --from=frontend-builder /release/usr/share/smartdns /usr/share/smartdns

EXPOSE 53/udp 53/tcp 6080
VOLUME ["/etc/smartdns/"]
HEALTHCHECK --interval=5m CMD test $(nslookup dns.pub 127.0.0.1 |grep answer |wc -l) -gt 0
CMD ["/usr/sbin/smartdns", "-f", "-x", "-p", "-"]
