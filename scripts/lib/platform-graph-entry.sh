#!/usr/bin/env bash
# Source only from an executable platform entry, before build paths initialize.
if [[ -z ${PLATFORM_GRAPH_INTERNAL:-} ]]; then
    platform_graph_help=0
    for platform_graph_arg in "$@"; do
        case $platform_graph_arg in help|-h|--help) platform_graph_help=1 ;; esac
    done
    if ((platform_graph_help == 0)) && [[ $# -gt 0 || ${0##*/} == orangepi-5-plus.sh ]]; then
        exec python3 "$ROOT_DIR/scripts/lib/platform-graph.py" "${0##*/}" "$@"
    fi
    unset platform_graph_help platform_graph_arg
fi
