ARG ALPINE_MINIROOTFS

FROM scratch

ARG ALPINE_MINIROOTFS
ADD ${ALPINE_MINIROOTFS} /

RUN apk add --no-cache \
    build-base \
    linux-headers \
    autoconf \
    automake \
    pkgconf

WORKDIR /ltp
CMD ["/bin/sh"]
