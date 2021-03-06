#!/bin/bash

MYDIR=$(dirname "$0")
MYDIR=$(cd "$MYDIR" || exit 1; pwd)

# shellcheck source=lib.sh
. "${MYDIR}/lib.sh"

pushd "${WORKDIR}"
	export SKIP_CLEAN=1
	"${WORKDIR}/bin/bamboo.pl" "${COMPILE_OPTIONS[@]}" "${SKIP_TESTS[@]}" -v dependency:go-offline
popd
