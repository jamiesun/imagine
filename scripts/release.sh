#!/bin/sh
# One-command release for imagine.
#
#   scripts/release.sh 0.3.3        # bump version, tag, push, trigger the release
#   scripts/release.sh --current    # release the version already in src/version.zig
#   scripts/release.sh 0.3.3 --no-watch
#
# Why this exists: `talkincode/imagine` is a fork of `jamiesun/imagine`, and
# GitHub does not create push-triggered workflow runs for forks (this repo's
# history has zero push runs while `workflow_dispatch` works fine). So a plain
# `git push --tags` would never publish anything here; the tag has to be handed
# to the workflow explicitly.
#
# Env: IMAGINE_REPO (default talkincode/imagine), IMAGINE_REMOTE (default origin),
#      IMAGINE_SKIP_TESTS=1 to skip the local `zig build test` gate.

set -eu

REPO="${IMAGINE_REPO:-talkincode/imagine}"
REMOTE="${IMAGINE_REMOTE:-origin}"
WATCH=1

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

ARG=""
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --current) ARG="--current" ;;
    --no-watch) WATCH=0 ;;
    -*) echo "error: unknown option: $a" >&2; exit 2 ;;
    *) ARG="$a" ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have git || die "git not found"
have gh || die "gh CLI not found (the release is triggered with 'gh workflow run')"
[ -z "$(git status --porcelain)" ] || die "working tree is dirty; commit or stash first"

CURRENT="$(sed -n 's/.*string *= *"\([^"]*\)".*/\1/p' src/version.zig | head -n1)"
[ -n "$CURRENT" ] || die "cannot read the version from src/version.zig"

if [ "$ARG" = "--current" ]; then
  VERSION="$CURRENT"
else
  [ -n "$ARG" ] || { usage; exit 2; }
  VERSION="${ARG#v}"
fi

case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "version must look like X.Y.Z (got '$VERSION')" ;;
esac

TAG="v$VERSION"

if [ "$VERSION" != "$CURRENT" ]; then
  echo "==> bumping $CURRENT -> $VERSION"
  sed -i.bak "s/pub const string = \"$CURRENT\";/pub const string = \"$VERSION\";/" src/version.zig && rm -f src/version.zig.bak
  sed -i.bak "s/    .version = \"$CURRENT\",/    .version = \"$VERSION\",/" build.zig.zon && rm -f build.zig.zon.bak
  grep -q "\"$VERSION\"" src/version.zig || die "failed to bump src/version.zig"
  grep -q "\"$VERSION\"" build.zig.zon || die "failed to bump build.zig.zon"
  git add src/version.zig build.zig.zon
  GIT_EDITOR=true git commit -q -m "chore: release $VERSION"
fi

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  die "release $TAG already exists on $REPO"
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "==> tag $TAG already exists locally"
else
  git tag -a "$TAG" -m "imagine $TAG"
fi

if [ "${IMAGINE_SKIP_TESTS:-0}" != "1" ] && have zig; then
  echo "==> zig build test"
  zig build test
fi

echo "==> pushing $REMOTE main + $TAG"
git push "$REMOTE" main
git push "$REMOTE" "$TAG"

echo "==> triggering the release workflow for $TAG"
gh workflow run release --repo "$REPO" -f "tag=$TAG"

if [ "$WATCH" = "1" ]; then
  echo "==> watching the run (Ctrl-C to detach; the release continues server-side)"
  sleep 8
  RUN_ID="$(gh run list --repo "$REPO" --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
  gh run watch "$RUN_ID" --repo "$REPO" --exit-status || die "release run failed (gh run view $RUN_ID --repo $REPO --log-failed)"
  gh release view "$TAG" --repo "$REPO" --json url --jq '"released: " + .url'
fi
