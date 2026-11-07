#!/usr/bin/env bash
# check_version_pins.sh - every version this repo names must be the one it pins.
#
#   bash scripts/check_version_pins.sh                 # verify
#   bash scripts/check_version_pins.sh --set-cljw vX.Y.Z
#   bash scripts/check_version_pins.sh --set-zwasm vX.Y.Z
#
# The repo states its pinned versions in several places - the Dockerfile ARG the
# image builds from, the run_local.sh default a contributor builds from, and the
# README / DEPLOY prose a reader believes. They have to agree, and nothing made
# them.
#
# They did not agree. `run_local.sh` sat at cljw v1.0.0 through BOTH the v1.6.0
# and the v1.7.0 bumps (commits 3f31f4b, e04039f) - five releases of drift -
# because a bump was a manual sweep, and a manual sweep is exactly as complete
# as the person's memory. Anyone running the playground locally built a cljw
# from a different era than the deployed one, which is the worst kind of
# difference: it makes a local reproduction of a production bug unreliable
# without saying so.
#
# Classification is per OCCURRENCE, not per line. The first version of this
# script skipped any LINE mentioning zwasm - and `DEPLOY.md:4` names both
# versions on one line, so neither was rewritten AND the check did not look at
# it. A false green, in the script written to prevent false greens.
#
# `vX.Y.Z+` is a FLOOR ("since vX.Y.Z"), a capability statement that stays true
# as the pin moves. Excluded; the trailing `+` is the marker, visible in the
# prose rather than listed here.
set -euo pipefail
cd "$(dirname "$0")/.."

FILES=(Dockerfile run_local.sh README.md DEPLOY.md)

# Emit "<file>:<line>:<which>:<version>" per occurrence. `which` is zwasm when
# the 40 characters before the version mention zwasm or zig, else cljw.
scan() {
    for f in "${FILES[@]}"; do
        [[ -f "$f" ]] || continue
        perl -ne '
            while (/v(\d+\.\d+\.\d+)(?!\+)/g) {
                my $ver = $1;
                my $before = substr($_, 0, pos($_) - length($ver) - 1);
                $before = substr($before, -40);
                my $which = ($before =~ /zwasm|zig|ZIG_VERSION/i) ? "zwasm" : "cljw";
                print "$ARGV:$.:$which:v$ver\n";
            }
        ' "$f"
    done
}

set_one() { # set_one <which> <version>
    local which="$1" want="$2"
    [[ "$want" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a vX.Y.Z tag: $want" >&2; exit 1; }
    for f in "${FILES[@]}"; do
        [[ -f "$f" ]] || continue
        WHICH="$which" WANT="$want" perl -pi -e '
            my $which = $ENV{WHICH}; my $want = $ENV{WANT};
            s{v(\d+\.\d+\.\d+)(?!\+)}{
                my $ver = $1;
                my $before = substr($`, -40);
                my $is_zwasm = ($before =~ /zwasm|zig|ZIG_VERSION/i) ? 1 : 0;
                (($is_zwasm && $which eq "zwasm") || (!$is_zwasm && $which eq "cljw")) ? $want : "v$ver";
            }ge;
        ' "$f"
    done
    echo "check_version_pins: set every $which version mention to $want"
}

case "${1:-}" in
    --set-cljw)  set_one cljw  "${2:?usage: --set-cljw vX.Y.Z}" ;;
    --set-zwasm) set_one zwasm "${2:?usage: --set-zwasm vX.Y.Z}" ;;
    "") ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
esac

fail=0
for which in cljw zwasm; do
    hits="$(scan | grep ":${which}:" || true)"
    n="$(printf '%s\n' "$hits" | grep -c . || true)"
    [[ "$n" -eq 0 ]] && continue
    vers="$(printf '%s\n' "$hits" | cut -d: -f4 | sort -u)"
    if [[ "$(printf '%s\n' "$vers" | grep -c .)" -ne 1 ]]; then
        echo "check_version_pins: this repo names MORE THAN ONE $which version:" >&2
        printf '%s\n' "$hits" | awk '{print "    " $0}' >&2
        echo "  Fix with: bash scripts/check_version_pins.sh --set-$which vX.Y.Z" >&2
        fail=1
    else
        echo "    version_pins: every $which mention says $vers ($n site(s))"
    fi
done
exit "$fail"
