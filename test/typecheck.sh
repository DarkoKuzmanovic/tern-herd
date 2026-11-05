#!/usr/bin/env bash
# Static type-check of the herd plugin against Tern's Luau declarations.
#
#   test/typecheck.sh [--defs PATH]
#
# Downloads luau-lsp and Tern's pinned tern.d.luau into a cache, verifies both
# SHA-256 digests and runs `luau-lsp analyze` over every plugins/herd/*.luau
# module from the repository root, including helpers nothing requires yet;
# host.luau, window.luau and common.luau must exist. Exit 0 means no type
# errors; lint warnings alone do not fail the run. `--defs PATH` checks
# against a local copy, e.g. one made by `tern plugin types DIR`, instead of
# the pinned download.
#
# The cache is ${TYPECHECK_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/tern-herd-typecheck}
# (CI sets it to $RUNNER_TEMP). A cached file is reused only while its digest
# still matches, so after the first run this works offline.
#
# Both pins are deliberate: Tern is closed, so tern.d.luau comes from the
# public tern-sdk mirror at a fixed commit, and luau-lsp is pinned to the digest
# the release publishes in its asset metadata. Bump the version, URL, digest and
# the docs together; Cargo's checksum files are not published, so the digest is
# recorded here and re-verified on every run.
#
# The analyze gate uses the default formatter on purpose: `--formatter=plain`
# prints the same errors but still exits 0, so it cannot be the gate. Relative
# requires need no .luaurc or source map; luau-lsp resolves them per script.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CACHE=${TYPECHECK_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/tern-herd-typecheck}

LUAU_LSP_VERSION=1.70.1
LUAU_LSP_URL=https://github.com/JohnnyMorganz/luau-lsp/releases/download/$LUAU_LSP_VERSION/luau-lsp-linux-x86_64.zip
LUAU_LSP_SHA256=1a2ea1ae4f98f8946cefd970a4b54853e11ab4775e6932faa7f60cf920346567

TERN_DEFS_COMMIT=0479f7048274aedc9f3496ca60675b754953e5a4
TERN_DEFS_URL=https://raw.githubusercontent.com/stencil-hq/tern-sdk/$TERN_DEFS_COMMIT/plugins/tern.d.luau
TERN_DEFS_SHA256=50ac8b5dcc41f6e853730d05db5525566992d765e5d3a249ce5e0a5ec4f7749e

DEFS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --defs)
      [ $# -ge 2 ] || { echo "typecheck: --defs needs a path" >&2; exit 2; }
      DEFS=$2
      shift 2
      ;;
    --defs=*) DEFS=${1#--defs=}; shift ;;
    -h | --help)
      sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "typecheck: unknown option $1" >&2; exit 2 ;;
  esac
done

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# fetch URL DEST SHA256 LABEL: cache DEST while its digest matches SHA256.
fetch() {
  local url=$1 dest=$2 want=$3 label=$4 have
  if [ -f "$dest" ]; then
    have=$(sha256 "$dest")
    if [ "$have" = "$want" ]; then
      echo "typecheck: cached $label $have"
      return 0
    fi
    echo "typecheck: cached $label is $have, wanted $want; downloading again" >&2
    rm -f "$dest"
  fi
  curl -fsSL --retry 3 --retry-delay 2 -o "$dest.part" "$url"
  have=$(sha256 "$dest.part")
  if [ "$have" != "$want" ]; then
    rm -f "$dest.part"
    echo "typecheck: $label digest mismatch: got $have, expected $want" >&2
    exit 1
  fi
  mv "$dest.part" "$dest"
  echo "typecheck: downloaded $label $have"
}

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64 | Linux/amd64) ;;
  *)
    echo "typecheck: the pinned luau-lsp asset is linux x86_64 only; set --defs or run elsewhere" >&2
    exit 1
    ;;
esac

mkdir -p "$CACHE"
ZIP=$CACHE/luau-lsp-$LUAU_LSP_VERSION.zip
LSP=$CACHE/luau-lsp-$LUAU_LSP_VERSION
fetch "$LUAU_LSP_URL" "$ZIP" "$LUAU_LSP_SHA256" "luau-lsp $LUAU_LSP_VERSION"
if [ ! -x "$LSP/luau-lsp" ]; then
  rm -rf "$LSP" "$LSP.tmp"
  mkdir -p "$LSP.tmp"
  unzip -q -o "$ZIP" -d "$LSP.tmp"
  chmod +x "$LSP.tmp/luau-lsp"
  mv "$LSP.tmp" "$LSP"
  echo "typecheck: unpacked luau-lsp $LUAU_LSP_VERSION"
fi

if [ -n "$DEFS" ]; then
  [ -f "$DEFS" ] || { echo "typecheck: no definitions file at $DEFS" >&2; exit 1; }
  DEFS=$(cd "$(dirname "$DEFS")" && pwd)/$(basename "$DEFS")
  echo "typecheck: local definitions $DEFS $(sha256 "$DEFS"); pinned $TERN_DEFS_SHA256"
else
  DEFS=$CACHE/tern.d.luau
  fetch "$TERN_DEFS_URL" "$DEFS" "$TERN_DEFS_SHA256" "tern.d.luau@${TERN_DEFS_COMMIT:0:12}"
fi

cd "$REPO"
for f in plugins/herd/host.luau plugins/herd/window.luau plugins/herd/common.luau; do
  [ -f "$f" ] || { echo "typecheck: missing $f" >&2; exit 1; }
done
# Every module in the plugin directory, referenced or not: a new half or helper
# joins the gate without editing this script.
mapfile -t FILES < <(printf '%s\n' plugins/herd/*.luau | LC_ALL=C sort)

echo "typecheck: $("$LSP/luau-lsp" --version) analyze --platform=standard --definitions=@tern=$DEFS ${FILES[*]}"
status=0
"$LSP/luau-lsp" analyze --platform=standard --definitions="@tern=$DEFS" "${FILES[@]}" || status=$?
if [ "$status" -ne 0 ]; then
  echo "typecheck: FAILED (luau-lsp exited $status)" >&2
fi
exit "$status"
