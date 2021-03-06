#!/bin/bash

MYDIR=$(dirname "$0")
MYDIR=$(cd "$MYDIR" || exit 1; pwd)

# shellcheck source=lib.sh disable=SC1091
. "${MYDIR}/lib.sh"

OUTPUTDIR="$1"; shift
# shellcheck disable=SC2154
REPODIR="$HOME/.m2/repository-${bamboo_planKey}"

SPLIT_SIZE="250m"

if [ -z "$OUTPUTDIR" ]; then
	echo "usage: $0 <opennms-source-directory> <backup-output-directory>"
	echo ""
	exit 1
fi

mkdir -p "$OUTPUTDIR"

pushd "$WORKDIR" || exit 1
	echo "* packing target directories to $OUTPUTDIR/target.tar.gz.part*"
	find . -type d -name target | tar -T - -czf - | split -b "$SPLIT_SIZE" - "$OUTPUTDIR/target.tar.gz.part"
popd || exit 1

if [ -d "$REPODIR" ]; then
	pushd "$REPODIR" || exit 1
		echo "* packing $REPODIR to $OUTPUTDIR/repo.tar.gz.part*"
		tar -czf - . | split -b "$SPLIT_SIZE" - "$OUTPUTDIR/repo.tar.gz.part"
	popd || exit 1
else
	echo "repository $REPODIR does not exist"
	ls -1 "$HOME/.m2"
fi
