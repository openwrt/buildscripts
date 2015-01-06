#!/bin/bash


#DL_URL="https://downloads.openwrt.org/barrier_breaker/14.07"
#DL_URL="file:///BB/sync/barrier_breaker/14.07"
DL_URL="openwrt@downloads.openwrt.org:barrier_breaker/14.07"
UL_URL="openwrt@downloads.openwrt.org:barrier_breaker/14.07"

IDENT="/home/jow/.ssh/id_rsa_openwrt_rsync"

N="
"

tmp="/home/jow/relman/.cache"

mkdir -p "$tmp"

call_rsync() {
	LC_ALL=C rsync ${IDENT+-e "ssh -i $IDENT"} "$@"
}

cache_rsync_files() {
	if [ ! -d "$tmp/rsync" ] || [ $do_update -gt 0 -a ! -e "$tmp/.rsync-updated" ]; then
		mkdir -p "$tmp/rsync"
		touch "$tmp/.rsync-updated"
		call_rsync -avz --delete -m --include='*/' --include='**/Packages.gz' --include='**/OpenWrt-SDK-*.tar.bz2' --exclude='*' \
			"$DL_URL/" "$tmp/rsync/" >/dev/null 2>/dev/null
	fi
}

terminate() {
	local jobs="$(jobs -p)"

	echo "Terminating..."

	pkill -P $$
	exit 1
}

fetch_remote() {
	case "$1" in
		file:*)
			cat "${1#file:}"
		;;
		http:*|https:*|ftp:*)
			wget -qO- "$1"
		;;
		*)
			cache_rsync_files
			cat "$tmp/rsync${1#$DL_URL}"
		;;
	esac
}

fetch_remote_dirlist() {
	local entry

	case "$1" in
		file:*)
			/bin/ls -1 "${1#file:}" | while read entry; do
				if [ -d "${1#file:}/$entry" ]; then
					echo "$entry"
				fi
			done
		;;
		http:*|https:*|ftp:*)
			wget -qO- "$1" | sed -ne 's,^<a href="\(.\+\)/".\+$,\1,p'
		;;
		*)
			cache_rsync_files
			/bin/ls -1 "$tmp/rsync${1#$DL_URL}" | while read entry; do
				if [ -d "$tmp/rsync${1#$DL_URL}/$entry" ]; then
					echo "$entry"
				fi
			done
		;;
	esac
}

fetch_remote_filelist() {
	local entry

	case "$1" in
		file:*)
			/bin/ls -1 "${1#file:}" | while read entry; do
				if [ -f "${1#file:}/$entry" ]; then
					echo "$entry"
				fi
			done
		;;
		http:*|https:*|ftp:*)
			wget -qO- "$1" | sed -ne 's,^<a href="\(.\+[^/]\)".\+$,\1,p'
		;;
		*)
			cache_rsync_files
			/bin/ls -1 "$tmp/rsync${1#$DL_URL}" | while read entry; do
				if [ -f "$tmp/rsync${1#$DL_URL}/$entry" ]; then
					echo "$entry"
				fi
			done
		;;
	esac
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
		fetch_remote_dirlist "$DL_URL" | while read target; do
			[ "$target" = "logs" ] && continue
			fetch_remote_dirlist "$DL_URL/$target" | while read subtarget; do
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
			fetch_remote_dirlist "$DL_URL/$target/packages" > "$tmp/feeds.lst"
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
				fetch_remote "$DL_URL/$target/packages/$feed/Packages.gz" \
					> "$tmp/repo-remote/$target/packages/$feed/Packages.gz"
			fi
		done
	done
}

fetch_remote_sdk() {
	local target="$1" sdk

	if [ ! -s "$tmp/repo-remote/$target/sdk.tar.bz2" ]; then
		fetch_remote_filelist "$DL_URL/$target" | while read sdk; do
			case "$sdk" in OpenWrt-SDK-*.tar.bz2)
				echo " * [$slot:$target] Fetching $sdk"
				mkdir -p "$tmp/repo-remote/$target"
				fetch_remote "$DL_URL/$target/$sdk" > "$tmp/repo-remote/$target/sdk.tar.bz2"
			;; esac
		done
	fi
}

prepare_sdk() {
	local target="$1"

	if [ ! -d "$tmp/sdk/$target/.git" ]; then
		echo " * [$slot:$target] Initializing SDK"

		fetch_remote_sdk "$target"

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
	elif [ $do_clean -gt 0 ]; then
		echo " * [$slot:$target] Resetting SDK"

		(
			cd "$tmp/sdk/$target"
			git reset --hard HEAD
			git clean -f -d
		) >/dev/null
	fi
}

find_pkg_dependant_sources() {
	local pkg

	find_pkg_dependant_ipks "$@" | while read pkg; do
		sed -ne "s!^package-\$(CONFIG_PACKAGE_${pkg}) += .\+/!!p" "$tmp/sdk/$target/tmp/.packagedeps"
	done | sort -u
}

find_pkg_dependant_ipks() {
	local target="$1" pkg="$2" deps="" dep

	if [ $do_dependants -gt 0 ]; then
		for dep in $(zcat "$tmp/repo-remote/$target/packages"/*/Packages.gz | \
			grep -B2 -E "^Depends:.* ${pkg%%:*}(,|\$)" | sed -ne 's!^Package: !!p'); do
			deps="$deps$N$dep"
		done
	fi

	echo "${pkg%%:*}$deps" | sort -u
}

find_source_provided_pkgs() {
	local pkg="$1"

	find "$tmp/repo-remote/" -name Packages.gz | xargs zcat | \
		grep -B3 -E "^Source: (.+/)?$pkg\$" | sed -ne 's!^Package: !!p' | \
		sort -u
}

install_sdk_feeds() {
	local pkg feed target="$1"; shift

	echo " * [$slot:$target] Installing packages"

	(
		flock -x 8

		cd "$tmp/sdk/$target"

		if [ ! -s "feeds.conf" ]; then
			if ! grep -sq " base " "feeds.conf.default"; then
				sed -e '/oldpackages/ { p; s!oldpackages!base!; s!packages.git!openwrt.git! }' \
					feeds.conf.default > feeds.conf
			else
				cp feeds.conf.default feeds.conf
			fi
		fi

		./scripts/feeds update >/dev/null

		echo " * [$slot:$target] feeds install"
		for pkg in "$@"; do
			case "$pkg" in
				*:*) feed="${pkg#*:}"; pkg="${pkg%%:*}" ;;
				*) feed="" ;;
			esac

			find_pkg_dependant_ipks "$target" "$pkg" | while read pkg; do
				#echo " * [$slot:$target] feeds install $pkg"
				#./scripts/feeds install ${feed:+ -p "$feed"} "$pkg" >/dev/null
				echo "$pkg"
			done
		done | sort -u | xargs ./scripts/feeds install >/dev/null

		sed -i -e "/CONFIG_PACKAGE_/d" .config
		echo "CONFIG_ALL=y" >> .config
		make defconfig >/dev/null
	) 8>"$tmp/feeds.lock" 2>/dev/null
}

compile_sdk_packages() {
	local pkg feed target="$1"; shift

	echo " * [$slot:$target] Compiling packages"

	for pkg in "$@"; do
		find_pkg_dependant_sources "$target" "$pkg"
	done | sort -u | while read pkg; do
		echo " * [$slot:$target] make package/$pkg/download"
		(
			flock -x 9

			cd "$tmp/sdk/$target"
			if ! make "package/$pkg/download" >/dev/null 2>/dev/null; then
				echo " * [$slot:$target] make package/$pkg/download - FAILED!"
			fi
		) 9>"$tmp/download.lock" 2>/dev/null

		echo " * [$slot:$target] make package/$pkg/compile"
		(
			cd "$tmp/sdk/$target"
			if ! make "package/$pkg/compile" IGNORE_ERRORS=y >/dev/null 2>/dev/null; then
				echo " * [$slot:$target] make package/$pkg/compile - FAILED!"
			fi
		)
	done

	for pkg in "$@"; do
		find_pkg_dependant_ipks "$target" "$pkg"
	done | sort -u | while read pkg; do
		for pkg in "$tmp/sdk/$target/bin"/*/packages/*/"${pkg}"_[^_]*_[^_]*.ipk; do
			if [ -s "$pkg" ]; then
				feed="${pkg%/*}"; feed="${feed##*/}"
				mkdir -p "$tmp/repo-local/$target/packages/$feed"
				cp -a "$pkg" "$tmp/repo-local/$target/packages/$feed/"
			else
				echo " * [$slot:$target] $pkg - MISSING!"
			fi
		done
	done
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
		find_pkg_dependant_ipks "$target" "$pkg" | while read pkg; do
			feed="$(find_remote_pkg_feed "$target" "$pkg")"
			[ -n "$feed" ] && patch_index_cmd "$target" "$feed" \
				--remove "${pkg%%:*}"

			feed="$(find_local_pkg_feed "$target" "$pkg")"
			[ -n "$feed" ] && patch_index_cmd "$target" "$feed" \
				--add "$tmp/repo-local/$target/packages/$feed/${pkg%%:*}"_*.ipk
		done
	done

	while read feed; do
		dir="$tmp/repo-local/$target/packages/$feed"
		if [ -s "$dir/Packages" ]; then
			gzip -c -9 "$dir/Packages" > "$dir/Packages.gz"
		fi
	done < "$tmp/feeds.lst"
}

rsync_delete_remote() {
	local target="$1" feed name pkg dep include line; shift

	while read feed; do
		include=""

		for pkg in "$@"; do
			for dep in $(find_pkg_dependant_ipks "$target" "$pkg"); do
				name="$(zcat "$tmp/repo-remote/$target/packages/$feed/Packages.gz" | \
					sed -ne "s/Filename: \\(${dep%%:*}_.\\+\\.ipk\\)\$/\1/p")"

				include="${include:+$include }${name:+--include=$name}"
			done
		done

		if [ -n "$include" ]; then
			mkdir -p "$tmp/empty"
			call_rsync -rv --delete $include --exclude="*" "$tmp/empty/" "$UL_URL/$target/packages/$feed/" 2>&1 | \
				grep "deleting " | while read line; do
					echo " * [$slot:$target] rsync: $line"
				done
		fi
	done < "$tmp/feeds.lst"
}

rsync_files() {
	local target="$1" line; shift

	echo " * [$slot:$target] Syncing files"

	rsync_delete_remote "$target" "$@"
	call_rsync -rv "$tmp/repo-local/$target/packages/" "$UL_URL/$target/packages/" 2>&1 | \
		grep "/" | while read line; do
			echo " * [$slot:$target] rsync: $line"
		done
}

run_jobs() {
	local targets=$(fetch_remote_targets)
	local target slot count job

	#echo "* Compiling packages"

	for slot in $(seq 0 $((num_jobs-1))); do (
		count=1; for target in $targets; do
			if [ $((count++ % $num_jobs)) -eq $slot ]; then
				if [ $do_build -gt 0 ]; then
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

	for job in $(jobs -p); do
		wait "$job"
		echo "* Job $job completed"
	done
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
	rm -rf "$tmp/repo-local"
fi

if [ $do_update -gt 0 ] || [ ! -s "$tmp/targets.lst" ]; then
	echo "* Preparing metadata"
	rm -f "$tmp/targets.lst" "$tmp/feeds.lst" "$tmp/.rsync-updated"
	rm -rf "$tmp/repo-remote"/*/*/packages
	fetch_remote_index >/dev/null
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
