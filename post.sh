#!/bin/bash

MYDIR=$(dirname "$0")
MYDIR=$(cd "$MYDIR" || exit 1; pwd)

# shellcheck source=lib.sh disable=SC1091
. "${MYDIR}/lib.sh"

stop_compiles
stop_opennms
clean_opennms
stop_firefox
reset_postgresql
reset_docker
fix_ownership "${WORKDIR}"
