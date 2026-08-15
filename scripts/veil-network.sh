#!/usr/bin/env bash
# The one rule that says which veil network a build belongs to.
#
# Sourced, not run: it exports XVEIL_NETWORK (prod|testnet) and SEED_FEATURE
# (the veil cargo feature that compiles in that network's builtin_seeds).
#
# There is one rule because there were four copies of it, in four build paths,
# and a mirrored constant in this repository has already cost a live debugging
# session once — the app bundled one seed list while the node held another, and
# the symptom was "Connected, 0 nodes" with nothing broken in any single place.
#
# The rule itself:
#   XVEIL_NETWORK set    -> that network
#   release profile      -> prod
#   anything else        -> testnet
#
# A debug build without a seed feature is NOT neutral: veil hands
# `debug_assertions` the production list, so development builds dialled
# production seeds. That is the thing this closes.
#
# Callers set PROFILE (debug|release) before sourcing; the Dart half applies
# the same rule from the same variable in lib/data/node/network_flavor.dart.

XVEIL_NETWORK="${XVEIL_NETWORK:-}"
if [[ -z "$XVEIL_NETWORK" ]]; then
  if [[ "${PROFILE:-debug}" == "release" ]]; then
    XVEIL_NETWORK=prod
  else
    XVEIL_NETWORK=testnet
  fi
fi

case "$XVEIL_NETWORK" in
  prod)    SEED_FEATURE="production-seeds" ;;
  testnet) SEED_FEATURE="testnet-seeds" ;;
  *)
    echo "unknown XVEIL_NETWORK=$XVEIL_NETWORK (want prod|testnet)" >&2
    exit 2
    ;;
esac

export XVEIL_NETWORK SEED_FEATURE
