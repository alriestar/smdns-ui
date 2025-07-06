FROM ghcr.io/void-linux/void-musl-busybox:latest AS smartdns-builder
#LABEL previous-stage=smartdns-builder

# prepare builder (Void Linux musl)
RUN xbps-install -Suy && \
    xbps-install -y binutils perl curl make clang git musl-devel libatomic-devel base-devel nodejs rust cargo openssl-devel
    
# do make
# 1. build core SmartDNS
RUN git clone https://github.com/pymumu/smartdns.git /build/smartdns/ && \
    cd /build/smartdns && \
    export CC=gcc \
           CFLAGS="-I/opt/build/include -mno-outline-atomics" \
           LDFLAGS="-L/opt/build/lib -L/opt/build/lib64 -latomic" && \
    sh ./package/build-pkg.sh --platform linux --arch $(uname -m) && \
    (cd package && tar -xvf *.tar.gz && chmod a+x smartdns/etc/init.d/smartdns) && \
    strip /build/smartdns/package/smartdns/usr/sbin/smartdns && \
    mkdir -p /release/etc/smartdns/ && \
    mkdir -p /release/usr && \
    cp -a package/smartdns/usr/* /release/usr/
    
# 2. build plugin Rust
RUN cd /build/smartdns/plugin/smartdns-ui && \
    cargo build --release && \
    mkdir -p /release/usr/lib && \
    cp target/release/libsmartdns_ui.so /release/usr/lib/
    
# 3. build frontend
RUN git clone https://github.com/pymumu/smartdns-webui.git /build/smartdns/plugin/smartdns-ui/frontend && \
    cd /build/smartdns/plugin/smartdns-ui/frontend && \ 
    npm install && \
    npm run build && \
    mkdir -p /release/usr/share/smartdns && \
    mv out wwwroot && \
    cp -r wwwroot /release/usr/share/smartdns

# 4. cleanup seluruh build dir
RUN rm -rf /build/smartdns

#runtime
FROM ghcr.io/void-linux/void-musl-busybox:latest AS runtime

# Buat direktori manual karena image ini sangat minimal
RUN mkdir -p \
    /etc/smartdns \
    /usr/sbin \
    /usr/lib \
    /usr/share/smartdns && \
    xbps-install -Sy \
      libatomic \
      libgcc \
      libunwind    

COPY --from=smartdns-builder /release/etc      /etc
COPY --from=smartdns-builder /release/usr/sbin /usr/sbin
COPY --from=smartdns-builder /release/usr/lib  /usr/lib
COPY --from=smartdns-builder /release/usr/share/smartdns /usr/share/smartdns

EXPOSE 53/udp 53/tcp 6080
VOLUME ["/etc/smartdns/"]

CMD ["/usr/sbin/smartdns", "-f", "-x", "-p -"]
