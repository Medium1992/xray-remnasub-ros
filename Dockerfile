# syntax=docker/dockerfile:1.7
FROM --platform=$BUILDPLATFORM alpine:latest AS package
ARG TARGETARCH
ARG TARGETVARIANT
ARG XRAY_VERSION=v26.7.28
RUN apk add --no-cache curl unzip
RUN set -eu; \
    case "$TARGETARCH/$TARGETVARIANT" in \
      amd64/*) asset=Xray-linux-64.zip ;; \
      arm64/*) asset=Xray-linux-arm64-v8a.zip ;; \
      arm/v7) asset=Xray-linux-arm32-v7a.zip ;; \
      arm/v5) asset=Xray-linux-arm32-v5.zip ;; \
      *) echo "unsupported architecture: $TARGETARCH/$TARGETVARIANT" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${asset}"; \
    curl -fsSL --retry 5 --retry-all-errors "$url" -o /tmp/xray.zip; \
    curl -fsSL --retry 5 --retry-all-errors "$url.dgst" -o /tmp/xray.zip.dgst; \
    digest="$(awk -F'= ' '$1 == "SHA2-256" {print $2}' /tmp/xray.zip.dgst)"; \
    [ -n "$digest" ]; \
    printf '%s  %s\n' "$digest" /tmp/xray.zip | sha256sum -c -; \
    unzip -q /tmp/xray.zip xray -d /tmp/xray; \
    install -Dm755 /tmp/xray/xray /final/usr/local/bin/xray
COPY entrypoint.sh lib.sh /final/
COPY web /final/www
COPY scripts /final/scripts
COPY LICENSE /final/usr/share/licenses/xray-remnasub-ros/LICENSE
RUN chmod 0755 /final/entrypoint.sh /final/lib.sh /final/www/cgi-bin/api /final/scripts/*.sh

# Базы по платформам. У Alpine нет образа под armv5, поэтому там scratch плюс
# готовый Buildroot-rootfs — тот же архив, что в mihomo-remnasub-ros и
# xray-proxy-ros. В нём уже лежат busybox httpd, jq, openssl, iptables, ip, tc,
# nc, wget и набор CA-сертификатов, поэтому apk на этой архитектуре не нужен —
# его там и нет.
FROM --platform=linux/amd64 alpine:latest AS linux-amd64
FROM --platform=linux/arm64 alpine:latest AS linux-arm64
FROM --platform=linux/arm/v7 alpine:latest AS linux-armv7
FROM --platform=linux/arm/v5 scratch AS linux-armv5
ADD rootfs.tar /

FROM ${TARGETOS}-${TARGETARCH}${TARGETVARIANT}
ARG TARGETARCH
ARG TARGETVARIANT
COPY --from=package /final /
# На arm64 и amd64 в образ идёт только nftables: в ядре RouterOS они есть с
# 7.21 и только на этих архитектурах. iptables там понадобится лишь тому, кто
# поставил контейнер на прошивку постарше, поэтому он не вшивается, а
# докачивается entrypoint-ом по наличию модуля nf_tables — образ не должен
# нести полтора мегабайта, нужные меньшинству. На armv7 наоборот: nftables в
# ядре не будет никогда, там iptables с legacy-симлинками ставится сразу.
RUN if [ "$TARGETARCH" = amd64 ] || [ "$TARGETARCH" = arm64 ]; then \
      apk add --no-cache busybox-extras ca-certificates iproute2 jq nftables openssl tzdata; \
    elif [ "$TARGETARCH/$TARGETVARIANT" = arm/v7 ]; then \
      apk add --no-cache busybox-extras ca-certificates iproute2 iptables iptables-legacy jq openssl tzdata; \
      ln -sf /usr/sbin/iptables-legacy /usr/sbin/iptables; \
      ln -sf /usr/sbin/iptables-legacy-save /usr/sbin/iptables-save; \
      ln -sf /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore; \
    fi
EXPOSE 80
VOLUME ["/etc/xray"]
ENTRYPOINT ["/entrypoint.sh"]
