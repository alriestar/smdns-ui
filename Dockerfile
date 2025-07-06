# =================================================
# STAGE 1: BUILDER
# =================================================
FROM ghcr.io/void-linux/void-musl-busybox:latest AS smartdns-builder

# 1) prepare builder (Void Linux musl)
# CHANGE: Removed 'clang' because we are using gcc.
RUN xbps-install -Suy && \
    xbps-install -y binutils perl curl make git musl-devel libatomic-devel base-devel nodejs rust cargo openssl-devel libunwind-devel libgcc-devel

# 2) clone & build core SmartDNS
RUN git clone https://github.com/pymumu/smartdns.git /build/smartdns
    
# 3) build core SmartDNS
WORKDIR /build/smartdns
RUN \
    # 1. Determine ARCH based on the build platform
    case "${TARGETPLATFORM}" in \
      "linux/amd64")   ARCH=x86_64 ;; \
      "linux/arm64")   ARCH=aarch64 ;; \
      "linux/arm/v7")  ARCH=armv7l ;; \
      *)               ARCH=$(uname -m) ;; \
    esac && \
    \
    # 2. Initialise additional flags per architecture
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
    \
    # 3. Export environment variables by combining flags.
    # CHANGE: Remove irrelevant /opt/build path.
    export CC=gcc \
           CFLAGS="${EXTRA_CFLAGS}" \
           LDFLAGS="${EXTRA_LDFLAGS}" && \
    \
    # 4. Run the build script with the correct ARCH
    sh ./package/build-pkg.sh --platform linux --arch "${ARCH}" && \
    \
    # 5. Continuation of the packaging process (no changes required)
    (cd package && tar -xvf *.tar.gz && chmod a+x smartdns/etc/init.d/smartdns) && \
    strip /build/smartdns/package/smartdns/usr/sbin/smartdns && \
    mkdir -p /release/etc/smartdns/ && \
    mkdir -p /release/usr && \
    cp -a package/smartdns/usr/* /release/usr/
    
# 4) build Rust plugin (with cross-compilation) <-- MAJOR CHANGE
RUN \
    # Set the Rust target based on TARGETPLATFORM
    case "${TARGETPLATFORM}" in \
      "linux/amd64")   RUST_TARGET=x86_64-unknown-linux-musl ;; \
      "linux/arm64")   RUST_TARGET=aarch64-unknown-linux-musl ;; \
      "linux/arm/v7")  RUST_TARGET=armv7-unknown-linux-musleabihf ;; \
      *) echo "Unsupported TARGETPLATFORM: ${TARGETPLATFORM}" && exit 1 ;; \
    esac && \
    \
    # Move to the plugin directory
    cd /build/smartdns/plugin/smartdns-ui && \
    \
    # Build with the right target
    cargo build --target ${RUST_TARGET} --release && \
    \
    # Copy the plugin from the correct target path
    mkdir -p /release/usr/lib && \
    cp "target/${RUST_TARGET}/release/libsmartdns_ui.so" /release/usr/lib/
    
# 5) build frontend
# CHANGES: Combined several commands for layer optimisation.
RUN git clone https://github.com/pymumu/smartdns-webui.git /build/smartdns/plugin/smartdns-ui/frontend && \
    cd /build/smartdns/plugin/smartdns-ui/frontend && \ 
    npm install && \
    npm run build && \
    mkdir -p /release/usr/share/smartdns && \
    mv out wwwroot && \
    cp -r wwwroot /release/usr/share/smartdns

# 6) clean up the entire build directory
RUN rm -rf /build/smartdns

# =================================================
# STAGE 2: RUNTIME
# =================================================
FROM ghcr.io/void-linux/void-musl-busybox:latest AS runtime

# Create a directory and install runtime dependencies
RUN mkdir -p \
    /etc/smartdns \
    /usr/sbin \
    /usr/lib \
    /usr/share/smartdns && \
    xbps-install -Sy \
      libatomic \
      libgcc \
      libunwind    

# Copy the finished build from the builder
COPY --from=smartdns-builder /release/etc      /etc
COPY --from=smartdns-builder /release/usr/sbin /usr/sbin
COPY --from=smartdns-builder /release/usr/lib  /usr/lib
COPY --from=smartdns-builder /release/usr/share/smartdns /usr/share/smartdns

EXPOSE 53/udp 53/tcp 6080
VOLUME ["/etc/smartdns/"]

CMD ["/usr/sbin/smartdns", "-f", "-x", "-p", "-"]
