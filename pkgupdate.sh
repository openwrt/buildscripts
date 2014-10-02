#!/bin/bash


#U="https://downloads.openwrt.org/barrier_breaker/14.07"
U="file:///BB/sync/barrier_breaker/14.07"
R="user@remote:/foo/barrier_breaker/14.07"

tmp="/home/jow/.relman"

mkdir -p "$tmp"

terminate() {
	local jobs="$(jobs -p)"

	echo "Terminating..."

	pkill -P $$
	exit 1
}

fetch_remote() {
	if [ -f "${1#file:}" ]; then
		cat "${1#file:}"
	else
		wget -qO- "$1"
	fi
}

fetch_remote_dirlist() {
	local entry

	if [ -d "${1#file:}" ]; then
		/bin/ls -1 "${1#file:}" | while read entry; do
			if [ -d "${1#file:}/$entry" ]; then
				echo "$entry"
			fi
		done
	else
		wget -qO- "$1" | sed -ne 's,^<a href="\(.\+\)/".\+$,\1,p'
	fi
}

fetch_remote_filelist() {
	local entry

	if [ -d "${1#file:}" ]; then
		/bin/ls -1 "${1#file:}" | while read entry; do
			if [ -f "${1#file:}/$entry" ]; then
				echo "$entry"
			fi
		done
	else
		wget -qO- "$1" | sed -ne 's,^<a href="\(.\+[^/]\)".\+$,\1,p'
	fi
}

fetch_remote_targets() {
	local target subtarget

	if [ -n "$use_targets" ]; then
		for target in $use_targets; do
			echo "$target"
		done
		return 0
	fi

	if [ ! -s "$tmp/targets.lst" ]; then
		fetch_remote_dirlist "$U" | while read target; do
			[ "$target" = "logs" ] && continue
			fetch_remote_dirlist "$U/$target" | while read subtarget; do
				echo "$target/$subtarget" >> "$tmp/targets.lst"
			done
		done
	fi

	cat "$tmp/targets.lst"
	return 0
}

fetch_remote_feeds() {
	local target

	if [ ! -s "$tmp/feeds.lst" ]; then
		fetch_remote_targets | while read target; do
			fetch_remote_dirlist "$U/$target/packages" > "$tmp/feeds.lst"
			break
		done
	fi

	cat "$tmp/feeds.lst"
	return 0
}

fetch_remote_index() {
	local target feed

	echo "Fetching remote package indizes..."

	fetch_remote_targets | while read target; do
		fetch_remote_feeds | while read feed; do
			if [ ! -s "$tmp/repo-remote/$target/packages/$feed/Packages.gz" ]; then
				echo " * $target $feed"
				mkdir -p "$tmp/repo-remote/$target/packages/$feed"
				wget -qO "$tmp/repo-remote/$target/packages/$feed/Packages.gz" "$U/$target/packages/$feed/Packages.gz"
			fi
		done
	done
}

fetch_remote_sdk() {
	local target sdk

	echo "Fetching remote SDKs..."

	fetch_remote_targets | while read target; do
		if [ ! -s "$tmp/repo-remote/$target/sdk.tar.bz2" ]; then
			fetch_remote_filelist "$U/$target" | while read sdk; do
				case "$sdk" in OpenWrt-SDK-*.tar.bz2)
					echo " * $target $sdk"
					mkdir -p "$tmp/repo-remote/$target"
					fetch_remote "$U/$target/$sdk" > "$tmp/repo-remote/$target/sdk.tar.bz2"
				;; esac
			done
		fi
	done
}

prepare_sdk() {
	local target="$1"

	if [ ! -d "$tmp/sdk/$target/.git" ]; then
		echo " * [$slot:$target] Initializing SDK"

		rm -rf "$tmp/sdk/$target"
		mkdir -p "$tmp/sdk/$target"
		tar --strip-components=1 -C "$tmp/sdk/$target" -xjf "$tmp/repo-remote/$target/sdk.tar.bz2"

		mkdir -p "$tmp/dl"
		rm -rf "$tmp/sdk/$target/dl"
		ln -sf "$tmp/dl" "$tmp/sdk/$target/dl"

		mkdir -p "$tmp/feeds"
		rm -rf "$tmp/sdk/$target/feeds"
		ln -sf "$tmp/feeds" "$tmp/sdk/$target/feeds"

		(
			cd "$tmp/sdk/$target"
			git init .
			find . -maxdepth 1 | xargs git add
			git commit -m "Snapshot"
		) >/dev/null
	else
		echo " * [$slot:$target] Resetting SDK"

		(
			cd "$tmp/sdk/$target"
			git reset --hard HEAD
			git clean -f -d
		) >/dev/null
	fi
}

install_sdk_feeds() {
	local pkg feed target="$1"; shift

	echo " * [$slot:$target] Installing packages"

	(
		flock -x 9

		cd "$tmp/sdk/$target"

		./scripts/feeds update

		for pkg in "$@"; do
			case "$pkg" in
				*:*) feed="${pkg#*:}"; pkg="${pkg%%:*}" ;;
				*) feed="" ;;
			esac

			./scripts/feeds install -d m${feed:+ -p "$feed"} "$pkg"
		done
	) 9>"$tmp/feeds.lock" 2>/dev/null >/dev/null
}

compile_sdk_packages() {
	local pkg target="$1"; shift

	echo " * [$slot:$target] Compiling packages"

	for pkg in "$@"; do
		(cd "$tmp/sdk/$target"; make "package/${pkg%%:*}/compile") >/dev/null

		mkdir -p "$tmp/repo-local/$target/packages"
		cp -a "$tmp/sdk/$target/bin"/*/packages/* "$tmp/repo-local/$target/packages/"
	done
}

find_remote_pkg_name() {
	local feed name target="$1" pkg="$2"

	while read feed; do
		name="$(zcat "$tmp/repo-remote/$target/packages/$feed/Packages.gz" | \
			sed -ne "s/Filename: \\(${pkg%%:*}_.\\+\\.ipk\\)\$/\1/p")"

		if [ -n "$name" ]; then
			echo "$target/packages/$feed/$name"
			return 0
		fi
	done < "$tmp/feeds.lst"

	return 1
}

find_remote_pkg_feed() {
	local feed target="$1" pkg="$2"

	while read feed; do
		if zcat "$tmp/repo-remote/$target/packages/$feed/Packages.gz" | grep -qE "^Package: ${pkg%%:*}\$"; then
			echo "$feed"
			return 0
		fi
	done < "$tmp/feeds.lst"

	return 1
}

find_local_pkg_feed() {
	local feed file target="$1" pkg="$2"

	while read feed; do
		for file in "$tmp/repo-local/$target/packages/$feed/${pkg%%:*}"_[^_]*_[^_]*.ipk; do
			if [ -s "$file" ]; then
				echo "$feed"
				return 0
			fi
		done
	done < "$tmp/feeds.lst"

	return 1
}

patch_index_cmd() {
	local target="$1" feed="$2"; shift; shift
	local idir="$tmp/repo-remote/$target/packages/$feed"
	local odir="$tmp/repo-local/$target/packages/$feed"

	if [ ! -s "$odir/Packages" ]; then
		mkdir -p "$odir"
		zcat "$idir/Packages.gz" > "$odir/Packages"
	fi

	./bin/patch-index.pl --index "$odir/Packages" "$@" > "$odir/Packages.$$"

	mv "$odir/Packages.$$" "$odir/Packages"
}

patch_indexes() {
	local target="$1" feed pkg dir; shift

	echo " * [$slot:$target] Patching repository index"

	for pkg in "$@"; do
		feed="$(find_remote_pkg_feed "$target" "$pkg")"
		[ -n "$feed" ] && patch_index_cmd "$target" "$feed" \
			--remove "${pkg%%:*}"

		feed="$(find_local_pkg_feed "$target" "$pkg")"
		[ -n "$feed" ] && patch_index_cmd "$target" "$feed" \
			--add "$tmp/repo-local/$target/packages/$feed/${pkg%%:*}"_*.ipk
	done

	while read feed; do
		dir="$tmp/repo-local/$target/packages/$feed"
		if [ -s "$dir/Packages" ]; then
			gzip -c -9 "$dir/Packages" > "$dir/Packages.gz"
		fi
	done < "$tmp/feeds.lst"
}

rsync_files() {
	local target="$1" pkg path; shift

	echo " * [$slot:$target] Syncing files"

	mkdir -p "$tmp/empty"

	for pkg in "$@"; do
		path="$(find_remote_pkg_name "$target" "$pkg")"

		[ -n "$path" ] && echo rsync --dry-run -rv \
			--delete="${path##*/}" --exclude="*" "$tmp/empty/" "$R/${path%/*}/"

		echo rsync --dry-run -rv "$tmp/repo-local/$target/packages/" "$R/$target/packages/"
	done

}

run_jobs() {
	local targets=$(fetch_remote_targets)
	local target slot count

	#echo "* Compiling packages"

	for slot in $(seq 0 $((num_jobs-1))); do (
		count=1; for target in $targets; do
			if [ $((count++ % $num_jobs)) -eq $slot ]; then
				if [ $do_compile -gt 0 ]; then
					prepare_sdk "$target"
					install_sdk_feeds "$target" "$@"
					compile_sdk_packages "$target" "$@"
				fi

				if [ $do_index -gt 0 ]; then
					patch_indexes "$target" "$@"
				fi

				if [ $do_rsync -gt 0 ]; then
					rsync_files "$target" "$@"
				fi
			fi
		done
	) & done
}

trap terminate INT TERM

do_compile=0
do_index=0
do_rsync=0

num_jobs=$(grep processor /proc/cpuinfo | wc -l)

use_targets=""
use_packages=""

usage() {
	cat <<-EOT
$0 {-a|-c|-i|-r} [-j jobs] -p package [-p package ...]

  -a
     Perform all build steps (compile, rebuild, rsync)

  -c
     Compile packages for all architectures.

  -i
     Rebuild indexes for all architectures.

  -r
     Rsync files for all architecures.

  -j jobs
     Use the given number of jobs when compiling packages.
     Default is $num_jobs jobs.

  -p package[:feed]
     Add given package to the queue. If a feed suffix is
     given then prefer this feed name when installing the
     package into the SDK.


  -t target
     Restrict operation to given targets.

	EOT
	exit 1
}

while getopts ":acirp:t:" opt; do
	case "$opt" in
		a)
			do_compile=1
			do_index=1
			do_rsync=1
		;;
		c) do_compile=1 ;;
		i) do_index=1 ;;
		r) do_rsync=1 ;;
		j) num_jobs="$OPTARG" ;;
		p) use_packages="${use_packages:+$use_packages }$OPTARG" ;;
		t) use_targets="${use_targets:+$use_targets }$OPTARG" ;;
	esac
done

[ -z "$use_packages" ] && usage

echo "* Preparing metadata"
fetch_remote_targets >/dev/null
fetch_remote_feeds >/dev/null

run_jobs "$use_packages"
