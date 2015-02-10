#!/usr/bin/env bash

. ./shared/functions.sh

terminate() {
	local jobs="$(jobs -p)"

	echo "Terminating..."

	pkill -P $$
	exit 1
}

trap terminate INT TERM

do_clean=0
do_build=0
do_index=0
do_rsync=0
do_dependants=0
do_update=0

num_jobs=$(grep processor /proc/cpuinfo | wc -l)

use_targets=""
use_packages=""
use_sources=""

usage() {
	cat <<-EOT
$0 {-a|-c|-i|-r} [-j jobs] -p package [-p package ...]

  -a
     Perform all build steps (compile, rebuild, rsync)

  -c
     Perform clean step in SDK.

  -b
     Compile packages for all architectures.

  -i
     Rebuild indexes for all architectures.

  -r
     Rsync files for all architecures.

  -d
     Process dependant packages as well (useful for libraries)

  -u
     Update remote metadata.

  -j jobs
     Use the given number of jobs when compiling packages.
     Default is $num_jobs jobs.

  -p package[:feed]
     Add given package to the queue. If a feed suffix is
     given then prefer this feed name when installing the
     package into the SDK.

  -t target
     Restrict operation to given targets.

  -D
     Print download URL and exit.

  -U
     Print upload URL and exit.

	EOT
	exit 1
}

while getopts ":abcirduj:p:s:t:" opt; do
	case "$opt" in
		a)
			do_clean=1
			do_build=1
			do_index=1
			do_rsync=1
		;;
		c) do_clean=1 ;;
		b) do_build=1 ;;
		i) do_index=1 ;;
		r) do_rsync=1 ;;
		d) do_dependants=1 ;;
		u) do_update=1 ;;
		j) num_jobs="$OPTARG" ;;
		p) use_packages="${use_packages:+$use_packages }$OPTARG" ;;
		s) use_sources="${use_sources:+$use_sources }$OPTARG" ;;
		t) use_targets="${use_targets:+$use_targets }$OPTARG" ;;
	esac
done

[ -z "$use_packages" ] && [ -z "$use_sources" ] && [ $do_update -lt 1 ] && usage

if [ $do_clean -gt 0 ]; then
	echo "* Purging local cache"
	rm -rf "$CACHE_DIR/repo-local"
fi

if [ $do_update -gt 0 ] || [ ! -d "$CACHE_DIR/mirror" ]; then
	mkdir -p "$CACHE_DIR"
	echo "* Preparing metadata"
	rm -f "$CACHE_DIR/.mirrored"
	rm -rf "$CACHE_DIR/repo-remote"/*/*/packages
	fetch_remote_index
fi

if [ -n "$use_sources" ]; then
	for src in $use_sources; do
		for pkg in $(find_source_provided_pkgs "$src"); do
			echo "* Selecting package $pkg for source $src"
			use_packages="${use_packages:+$use_packages }$pkg"
		done
	done
fi

[ -n "$use_packages" ] && run_jobs $use_packages
