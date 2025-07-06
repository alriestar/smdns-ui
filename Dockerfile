# =================================================
# STAGE 1: MAIN BUILDER (C/C++ & Rust)STAGE 1: MAIN BUILDER (C/C++ & Rust)
# =================================================
FROM ghcr.io/void-linux/void-musl-busybox:latest AS smartdns-builder

# CHANGE: 'nodejs' has been removed from here.
RUN xbps-install -Suy && \
    xbps-install -y binutils perl curl make git musl-devel libatomic-devel base-devel rust cargo openssl-devel libunwind-devel libgcc-devel

# Clone repo (only needed once)
RUN git clone https://github.com/pymumu/smartdns.git /build/smartdns
    
# Build core SmartDNS
WORKDIR /build/smartdns
RUN \
    case "${TARGETPLATFORM}" in \
      "linux/amd64")   ARCH=x86_64 ;; \
      "linux/arm64")   ARCH=aarch64 ;; \
      "linux/arm/v7")  ARCH=armv7l ;; \
      *)               ARCH=$(uname -m) ;; \
    esac && \
    EXTRA_CFLAGS="" && \
    EXTRA_LDFLAGS="" && \
    case "$ARCH" in \
      "aarch64") \
        EXTRA_CFLAGS="-mno-outline-atomics"; \
        EXTRA_LDFLAGS="-latomic"; \
        ;; \
      "armv7l") \
        EXTRA_LDFLAGS="-latomic"; \
        ;; \
    esac && \
    export CC=gcc \
           CFLAGS="${EXTRA_CFLAGS}" \
           LDFLAGS="${EXTRA_LDFLAGS}" && \
    sh ./package/build-pkg.sh --platform linux --arch "${ARCH}" && \
    (cd package && tar -xvf *.tar.gz && chmod a+x smartdns/etc/init.d/smartdns) && \
    strip /build/smartdns/package/smartdns/usr/sbin/smartdns && \
    mkdir -p /release/etc/smartdns/ && \
    mkdir -p /release/usr && \
    cp -a package/smartdns/usr/* /release/usr/
    
# Build plugin Rust
RUN \
    case "${TARGETPLATFORM}" in \
      "linux/amd64")   RUST_TARGET=x86_64-unknown-linux-musl ;; \
      "linux/arm64")   RUST_TARGET=aarch64-unknown-linux-musl ;; \
      "linux/arm/v7")  RUST_TARGET=armv7-unknown-linux-musleabihf ;; \
      *) echo "Unsupported TARGETPLATFORM: ${TARGETPLATFORM}" && exit 1 ;; \
    esac && \
    cd /build/smartdns/plugin/smartdns-ui && \
    cargo build --target ${RUST_TARGET} --release && \
    mkdir -p /release/usr/lib && \
    cp "target/${RUST_TARGET}/release/libsmartdns_ui.so" /release/usr/lib/

# =================================================
# STAGE 2: BUILDER FRONTEND (Node.js) <-- STAGE BARU
# This stage will only run once, not for every platform.
# =================================================
FROM node:18-alpine AS frontend-builder

# Clone repo web UI
RUN git clone https://github.com/pymumu/smartdns-webui.git /build/frontend
WORKDIR /build/frontend

# Build frontend
RUN npm install && \
    npm run build && \
    mv out wwwroot

# =================================================
# STAGE 3: FINALISASI BUILD
# Next, return to the main builder to copy the frontend build results.
# =================================================
FROM smartdns-builder AS final-builder

# Copy the frontend build results (which are architecture-independent) to the release directory
COPY --from=frontend-builder /build/frontend/wwwroot /release/usr/share/smartdns/wwwroot

# Cleanup
RUN rm -rf /build/smartdns

# =================================================
# STAGE 4: RUNTIME
# =================================================
FROM ghcr.io/void-linux/void-musl-busybox:latest AS runtime

RUN mkdir -p \
    /etc/smartdns \
    /usr/sbin \
    /usr/lib \
    /usr/share/smartdns && \
    xbps-install -Sy \
      libatomic \
      libgcc \
      libunwind    

# CHANGES: Taking the results from the 'final-builder' stage
COPY --from=final-builder /release/etc      /etc
COPY --from=final-builder /release/usr/sbin /usr/sbin
COPY --from=final-builder /release/usr/lib  /usr/lib
COPY --from=final-builder /release/usr/share/smartdns /usr/share/smartdns

EXPOSE 53/udp 53/tcp 6080
VOLUME ["/etc/smartdns/"]

# MINOR IMPROVEMENT: Removed extra spaces in CMD
CMD ["/usr/sbin/smartdns", "-f", "-x", "-p", "-"]
