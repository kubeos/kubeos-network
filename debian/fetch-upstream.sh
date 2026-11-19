#!/bin/sh
# KubeOS network: fetch the two pinned upstream artefacts at build time.
#
# WHY    flannel and CoreDNS ship as GitHub release tarballs, neither is packaged for Debian,
#        and the node has no network after installation. (The CNI plugins come from the
#        kubernetes-cni package - see debian/control.) Fetching them
#        here keeps the repository small; every download is verified - with the checksum file
#        the project publishes where there is one, and with a pinned digest where there is not
#        (flannel publishes none: that pin was measured from the v0.28.10 tarball).
# SAFE   Writes only into the directories it is given, and only after a checksum matches.
set -eu

USR_BIN=${1:?usage: fetch-upstream.sh <usr-bin-dir>}

FLANNEL_VERSION=${FLANNEL_VERSION:-v0.28.10}
# Pin, not an upstream-signed digest: measured from flannel-v0.28.10-linux-amd64.tar.gz.
FLANNEL_SHA256=${FLANNEL_SHA256:-7382a05edf2de4df31950eae3d654ea3e140c3aaac1b7e1dd2048ff33b63211f}
COREDNS_VERSION=${COREDNS_VERSION:-1.14.6}

log() { printf 'fetch-upstream: %s\n' "$*"; }
die() { printf 'fetch-upstream: ERROR: %s\n' "$*" >&2; exit 1; }

install -d "$USR_BIN"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fetch() {
    _i=0
    while [ "$_i" -lt 4 ]; do
        _i=$((_i + 1))
        if curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors -o "$2" "$1"; then
            return 0
        fi
        log "attempt $_i/4 failed: $1"
        [ "$_i" -lt 4 ] && sleep 5
    done
    return 1
}

# --- flanneld: no upstream checksum, pinned digest --------------------------
TARBALL="flannel-${FLANNEL_VERSION}-linux-amd64.tar.gz"
BASE="https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}"
log "fetching $BASE/$TARBALL"
fetch "$BASE/$TARBALL" "$WORK/$TARBALL" || die "could not download $TARBALL"
GOT=$(sha256sum "$WORK/$TARBALL" | cut -d' ' -f1)
[ "$GOT" = "$FLANNEL_SHA256" ] || die "flannel checksum mismatch
    expected $FLANNEL_SHA256
    got      $GOT
    If this is a deliberate bump, re-measure FLANNEL_SHA256."
tar -xzf "$WORK/$TARBALL" -C "$WORK"
install -m 0755 "$WORK/flanneld" "$USR_BIN/flanneld"

# --- coredns: upstream publishes a .sha256 ---------------------------------
TARBALL="coredns_${COREDNS_VERSION}_linux_amd64.tgz"
BASE="https://github.com/coredns/coredns/releases/download/v${COREDNS_VERSION}"
log "fetching $BASE/$TARBALL"
fetch "$BASE/$TARBALL" "$WORK/$TARBALL" || die "could not download $TARBALL"
fetch "$BASE/$TARBALL.sha256" "$WORK/$TARBALL.sha256" || die "could not download the coredns checksum"
( cd "$WORK" && sha256sum -c "$TARBALL.sha256" ) || die "coredns checksum mismatch"
tar -xzf "$WORK/$TARBALL" -C "$WORK"
install -m 0755 "$WORK/coredns" "$USR_BIN/coredns"

# --- prove the versions we think we shipped --------------------------------
case "$("$USR_BIN/flanneld" --version 2>&1 | head -n 1)" in
    *"$FLANNEL_VERSION"*) log "flanneld $FLANNEL_VERSION ok" ;;
    *) die "flanneld does not report $FLANNEL_VERSION" ;;
esac
case "$("$USR_BIN/coredns" -version 2>&1 | head -n 1)" in
    *"$COREDNS_VERSION"*) log "coredns $COREDNS_VERSION ok" ;;
    *) die "coredns does not report $COREDNS_VERSION" ;;
esac
log "ok: flanneld and coredns installed"
