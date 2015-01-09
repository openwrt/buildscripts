#MIRROR_URL="https://downloads.openwrt.org/barrier_breaker/14.07"
#MIRROR_URL="file:///BB/sync/barrier_breaker/14.07"
MIRROR_URL="openwrt@downloads.openwrt.org:barrier_breaker/14.07"

IDENT="$HOME/.ssh/id_rsa_openwrt_rsync"

PATTERN_SDK="OpenWrt-SDK-*.tar.bz2"
PATTERN_FEED="Packages.gz"

CACHE_DIR="$(readlink -f .)/.cache"

N="
"

call_rsync() {
	LC_ALL=C rsync ${IDENT+-e "ssh -o IdentitiesOnly=yes -o IdentityFile=$IDENT"} "$@"
}

mirror_rsync() {
	if [ ! -d "$CACHE_DIR/mirror" ] || [ $do_update -gt 0 -a ! -e "$CACHE_DIR/.mirrored" ]; then
		mkdir -p "$CACHE_DIR/mirror"
		call_rsync -avz --delete -m \
			--include='*/' --include="**/$PATTERN_SDK" --include="**/$PATTERN_FEED" --exclude='*' \
			"$MIRROR_URL/" "$CACHE_DIR/mirror/"

		touch "$CACHE_DIR/.mirrored"
	fi
}

mirror_http() {
	if [ ! -d "$CACHE_DIR/mirror" ] || [ $do_update -gt 0 -a ! -e "$CACHE_DIR/.mirrored" ]; then
		mkdir -p "$CACHE_DIR/mirror"
		lftp -e "open $MIRROR_URL/ && mirror -P 2 -vvv --use-cache --only-newer --no-empty-dirs --delete -I '$PATTERN_SDK' -I '$PATTERN_FEED' -x logs/ . $CACHE_DIR/mirror/ && exit"
		touch "$CACHE_DIR/.mirrored"
	fi
}

mirror_file() {
	if [ ! -d "$CACHE_DIR/mirror" ] || [ $do_update -gt 0 -a ! -e "$CACHE_DIR/.mirrored" ]; then
		mkdir -p "$CACHE_DIR/mirror"
		rsync -av --delete -m \
			--include='*/' --include="**/$PATTERN_SDK" --include="**/$PATTERN_FEED" --exclude='*' \
			"${MIRROR_URL#file:}/" "$CACHE_DIR/mirror/"

		touch "$CACHE_DIR/.mirrored"
	fi
}

fetch_remote_targets() {
	local target

	if [ -n "$use_targets" ]; then
		for target in $use_targets; do
			echo "$target"
		done
		return 0
	fi

	find "$CACHE_DIR/mirror/" -type f -name "$PATTERN_SDK" -printf "%h\n" | while read target; do
		echo "${target##*/mirror/}"
	done | sort -u
	return 0
}

fetch_remote_feeds() {
	local feed target="$1"

	find "$CACHE_DIR/mirror/$target/" -type f -name "$PATTERN_FEED" -printf "%h\n" | while read feed; do
		echo "${feed##*/}"
	done | sort -u
	return 0
}

fetch_remote_index() {
	local target feed

	echo "Fetching remote package indizes..."

	case "$MIRROR_URL" in
		file:*)
			mirror_file
		;;
		http:*|https:*|ftp:*)
			mirror_http
		;;
		*)
			mirror_rsync
		;;
	esac

	fetch_remote_targets | while read target; do
		echo -n "* $target:"
		fetch_remote_feeds "$target" | while read feed; do
			if [ ! -s "$CACHE_DIR/repo-remote/$target/packages/$feed/Packages.gz" ]; then
				echo -n " $feed"
				mkdir -p "$CACHE_DIR/repo-remote/$target/packages/$feed"
				cp -a "$CACHE_DIR/mirror/$target/packages/$feed/Packages.gz" \
					"$CACHE_DIR/repo-remote/$target/packages/$feed/Packages.gz"
			fi
		done
		echo ""
	done
}

prepare_sdk() {
	local target="$1"

	if [ ! -d "$CACHE_DIR/sdk/$target/.git" ]; then
		echo " * [$slot:$target] Initializing SDK"

		local sdk
		for sdk in "$CACHE_DIR/mirror/$target/"$PATTERN_SDK; do
			if [ ! -f "$sdk" ]; then
				echo " * [$slot:$target] $sdk - MISSING!"
				exit 0
			fi
		done

		rm -rf "$CACHE_DIR/sdk/$target"
		mkdir -p "$CACHE_DIR/sdk/$target"
		tar --strip-components=1 -C "$CACHE_DIR/sdk/$target" -xjf "$sdk"

		mkdir -p "$CACHE_DIR/dl"
		rm -rf "$CACHE_DIR/sdk/$target/dl"
		ln -sf "$CACHE_DIR/dl" "$CACHE_DIR/sdk/$target/dl"

		mkdir -p "$CACHE_DIR/feeds"
		rm -rf "$CACHE_DIR/sdk/$target/feeds"
		ln -sf "$CACHE_DIR/feeds" "$CACHE_DIR/sdk/$target/feeds"

		(
			cd "$CACHE_DIR/sdk/$target"
			git init .
			find . -maxdepth 1 | xargs git add
			git commit -m "Snapshot"
		) >/dev/null
	elif [ $do_clean -gt 0 ]; then
		echo " * [$slot:$target] Resetting SDK"

		(
			cd "$CACHE_DIR/sdk/$target"
			git reset --hard HEAD
			git clean -f -d
		) >/dev/null
	fi
}

find_pkg_dependant_sources() {
	local pkg

	find_pkg_dependant_ipks "$@" | while read pkg; do
		sed -ne "s!^package-\$(CONFIG_PACKAGE_${pkg}) += .\+/!!p" "$CACHE_DIR/sdk/$target/tmp/.packagedeps"
	done | sort -u
}

find_pkg_dependant_ipks() {
	local target="$1" pkg="$2" deps="" dep

	if [ $do_dependants -gt 0 ]; then
		for dep in $(zcat "$CACHE_DIR/repo-remote/$target/packages"/*/Packages.gz | \
			grep -B2 -E "^Depends:.* ${pkg%%:*}(,|\$)" | sed -ne 's!^Package: !!p'); do
			deps="$deps$N$dep"
		done
	fi

	echo "${pkg%%:*}$deps" | sort -u
}

find_source_provided_pkgs() {
	local pkg="$1"

	find "$CACHE_DIR/repo-remote/" -name Packages.gz | xargs zcat | \
		grep -B3 -E "^Source: (.+/)?$pkg\$" | sed -ne 's!^Package: !!p' | \
		sort -u
}

install_sdk_feeds() {
	local pkg feed target="$1"; shift

	echo " * [$slot:$target] Installing packages"

	(
		flock -x 8

		cd "$CACHE_DIR/sdk/$target"

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
	) 8>"$CACHE_DIR/feeds.lock" 2>/dev/null
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

			cd "$CACHE_DIR/sdk/$target"
			if ! make "package/$pkg/download" >/dev/null 2>/dev/null; then
				echo " * [$slot:$target] make package/$pkg/download - FAILED!"
			fi
		) 9>"$CACHE_DIR/download.lock" 2>/dev/null

		echo " * [$slot:$target] make package/$pkg/compile"
		(
			cd "$CACHE_DIR/sdk/$target"
			if ! make "package/$pkg/compile" IGNORE_ERRORS=y >/dev/null 2>/dev/null; then
				echo " * [$slot:$target] make package/$pkg/compile - FAILED!"
			fi
		)
	done

	for pkg in "$@"; do
		find_pkg_dependant_ipks "$target" "$pkg"
	done | sort -u | while read pkg; do
		for pkg in "$CACHE_DIR/sdk/$target/bin"/*/packages/*/"${pkg}"_[^_]*_[^_]*.ipk; do
			if [ -s "$pkg" ]; then
				feed="${pkg%/*}"; feed="${feed##*/}"
				mkdir -p "$CACHE_DIR/repo-local/$target/packages/$feed"
				cp -a "$pkg" "$CACHE_DIR/repo-local/$target/packages/$feed/"
			else
				echo " * [$slot:$target] $pkg - MISSING!"
			fi
		done
	done
}

find_remote_pkg_feed() {
	local feed target="$1" pkg="$2"

	for feed in $(fetch_remote_feeds "$target"); do
		if zcat "$CACHE_DIR/repo-remote/$target/packages/$feed/Packages.gz" | grep -qE "^Package: ${pkg%%:*}\$"; then
			echo "$feed"
			return 0
		fi
	done

	return 1
}

find_local_pkg_feed() {
	local feed file target="$1" pkg="$2"

	for feed in $(fetch_remote_feeds "$target"); do
		for file in "$CACHE_DIR/repo-local/$target/packages/$feed/${pkg%%:*}"_[^_]*_[^_]*.ipk; do
			if [ -s "$file" ]; then
				echo "$feed"
				return 0
			fi
		done
	done

	return 1
}

patch_index_cmd() {
	local target="$1" feed="$2"; shift; shift
	local idir="$CACHE_DIR/repo-remote/$target/packages/$feed"
	local odir="$CACHE_DIR/repo-local/$target/packages/$feed"

	if [ ! -s "$odir/Packages" ]; then
		mkdir -p "$odir"
		zcat "$idir/Packages.gz" > "$odir/Packages"
	fi

	./shared/patch-index.pl --index "$odir/Packages" "$@" > "$odir/Packages.$$"

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
				--add "$CACHE_DIR/repo-local/$target/packages/$feed/${pkg%%:*}"_*.ipk
		done
	done

	for feed in $(fetch_remote_feeds "$target"); do
		dir="$CACHE_DIR/repo-local/$target/packages/$feed"
		if [ -s "$dir/Packages" ]; then
			gzip -c -9 "$dir/Packages" > "$dir/Packages.gz"
		fi
	done
}

rsync_delete_remote() {
	local target="$1" feed name pkg dep include line; shift

	for feed in $(fetch_remote_feeds "$target"); do
		include=""

		for pkg in "$@"; do
			for dep in $(find_pkg_dependant_ipks "$target" "$pkg"); do
				name="$(zcat "$CACHE_DIR/repo-remote/$target/packages/$feed/Packages.gz" | \
					sed -ne "s/Filename: \\(${dep%%:*}_.\\+\\.ipk\\)\$/\1/p")"

				include="${include:+$include }${name:+--include=$name}"
			done
		done

		if [ -n "$include" ]; then
			mkdir -p "$CACHE_DIR/empty"
			call_rsync -rv --delete $include --exclude="*" "$CACHE_DIR/empty/" "${MIRROR_URL#file:}/$target/packages/$feed/" 2>&1 | \
				grep "deleting " | while read line; do
					echo " * [$slot:$target] rsync: $line"
				done
		fi
	done
}

rsync_files() {
	local target="$1" line; shift

	case "$MIRROR_URL" in
		http:*|https:*|ftp:*)
			echo "* HTTP/FTP upload not supported!"
			exit 0
		;;
	esac

	echo " * [$slot:$target] Syncing files"

	rsync_delete_remote "$target" "$@"
	call_rsync -rv "$CACHE_DIR/repo-local/$target/packages/" "${MIRROR_URL#file:}/$target/packages/" 2>&1 | \
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
