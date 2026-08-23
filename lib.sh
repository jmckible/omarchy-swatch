#!/bin/bash
# Shared by index.sh, thumbs.sh and apply.sh — sourced, never executed.
#
# Trust model: an installed theme is untrusted input (anyone can
# `omarchy theme install` a hostile repo), and so is anything in a writable
# directory, our own cache included. Nothing in this plugin decides trust on a
# pathname and then opens that pathname again. Bytes reach a parser only
# through read_bounded(), which opens once and verifies the object it opened.

MAX_THEMES=512
MAX_BACKGROUNDS=200
MAX_DIR_ENTRIES=4096        # readdir entries examined per directory, before sorting
MAX_NAME_BYTES=64
MAX_PATH_BYTES=512
MAX_TOML_BYTES=32768        # colors.toml / shell.toml are hundreds of bytes to a few KB
MAX_PALETTE_BYTES=16384     # omarchy-theme-color --all is ~60 short lines
MAX_IMAGE_BYTES=67108864    # 64 MB — 4K PNG wallpapers run 10–30 MB
MAX_PIXELS=50000000         # 50 MP — 8K is 33 MP
MAX_INDEX_BYTES=8388608     # an index.json above this is refused, not parsed
LOADERS='^(jpegload|pngload|webpload|gifload)$'
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

SWATCH_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/swatch
SWATCH_THUMBS=$SWATCH_CACHE/thumbs
SWATCH_INDEX=$SWATCH_CACHE/index.json

# A theme name becomes a cache filename and an omarchy-theme-set argument.
valid_name() {
  [[ ${#1} -le $MAX_NAME_BYTES && $1 =~ $NAME_RE && $1 != *..* ]]
}

# read_bounded FILE MAX [ROOT...]
#
# The one trust decision in this plugin, taken on a file descriptor and
# nowhere else. FILE is opened exactly once with O_NOFOLLOW (a symlink in the
# final component is refused by the kernel, not by a prior lstat that could
# be raced) and O_NONBLOCK (a FIFO or device left at the path opens instead of
# parking the process). The object behind *that* descriptor is then verified
# with fstat — a regular file of at most MAX bytes — and, when ROOTs are
# given, its resolved path (/proc/self/fd) must lie under one of them, so a
# theme cannot hand us something outside its own directory. The bytes are
# read through the same descriptor with a one-byte-past-the-ceiling check:
# a file that grows mid-read is refused, never used as a truncated prefix.
#
# Owner and mode are deliberately not checked: stock themes live under
# /usr/share/omarchy and are root-owned, which is the un-replaceable case.
#
# Bash cannot pass open flags on a redirection, hence the interpreter:
# python3 when present (Omarchy's session manager depends on it), perl
# otherwise (a dependency of git). Both enforce the same rules. Bytes on
# stdout; exit 0 = accepted, 3 = no such file, 1 = refused, 124 = deadline.
read -r -d '' SWATCH_READ_PY <<'PY'
import errno, os, stat, sys
path, cap, roots = sys.argv[1], int(sys.argv[2]), [r for r in sys.argv[3:] if r]
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
except OSError as e:
    raise SystemExit(3 if e.errno == errno.ENOENT else 1)
buf = bytearray()
try:
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or st.st_size > cap:
        raise SystemExit(1)
    if roots:
        real = os.readlink("/proc/self/fd/%d" % fd)
        if not any(real.startswith(r + "/") for r in roots):
            raise SystemExit(1)
    while len(buf) <= cap:
        chunk = os.read(fd, 1 << 16)
        if not chunk:
            break
        buf += chunk
finally:
    os.close(fd)
if len(buf) > cap:
    raise SystemExit(1)
sys.stdout.buffer.write(buf)
PY

read -r -d '' SWATCH_READ_PL <<'PL'
use strict; use warnings; use Fcntl qw(O_RDONLY O_NOFOLLOW O_NONBLOCK);
my ($path, $cap, @roots) = @ARGV; @roots = grep { length } @roots;
my $fh;
unless (sysopen($fh, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)) { exit($!{ENOENT} ? 3 : 1) }
my @st = stat($fh) or exit 1;
exit 1 unless -f $fh;
exit 1 if $st[7] > $cap;
if (@roots) {
  my $real = readlink("/proc/self/fd/" . fileno($fh));
  exit 1 unless defined $real && grep { index($real, "$_/") == 0 } @roots;
}
my $buf = "";
while (length($buf) <= $cap) {
  my $n = sysread($fh, $buf, 65536, length($buf));
  exit 1 unless defined $n;
  last if $n == 0;
}
exit 1 if length($buf) > $cap;
binmode(STDOUT); print STDOUT $buf;
PL

read_bounded() {
  local f=$1 max=$2; shift 2
  if command -v python3 >/dev/null 2>&1; then
    timeout 10s python3 -c "$SWATCH_READ_PY" "$f" "$max" "$@"
  elif command -v perl >/dev/null 2>&1; then
    timeout 10s perl -e "$SWATCH_READ_PL" -- "$f" "$max" "$@"
  else
    return 1
  fi
}

# snapshot FILE MAX DEST [ROOT...] — read_bounded into DEST, a file inside a
# private directory this run created. DEST is removed when FILE is refused.
snapshot() {
  local f=$1 max=$2 dest=$3 rc; shift 3
  read_bounded "$f" "$max" "$@" >"$dest"; rc=$?
  (( rc == 0 )) || rm -f -- "$dest"
  return $rc
}
