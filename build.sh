#!/bin/sh

# this file is part of packlim-recipes.
#
# Copyright (c) 2016 Dima Krasner
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

MAKE="make -j$(grep ^processor /proc/cpuinfo | wc -l) V=1"
export HERE=$(pwd)
WRKDIR=$(mktemp -d)
TODAY=$(date +%d%m%Y)

export HOST_PKG_CONFIG=$(which pkg-config)
export PFIX=opt/packlim

export CC=clang
case $(uname -m) in
	i?86)
		CFLAGS="-march=i486 -mtune=i686 $CFLAGS"
		;;
	armv7l)
		CFLAGS="-march=armv7-a -mtune=cortex-a9 -mfpu=vfpv3-d16 -mfloat-abi=hard"
		;;
	*)
		CFLAGS="-mtune=generic $CFLAGS"
		;;
esac
export CFLAGS="$CFLAGS \
               -Os \
               -fomit-frame-pointer \
               -ffunction-sections \
               -fdata-sections \
               -fmerge-all-constants \
               -pipe"
export LDFLAGS="-Wl,-gc-sections -Wl,--sort-common"

download() {
	local i

	for i in $PKG_SRCS
	do
		case $i in
			*.git)
				dest=$1-git$TODAY.tar.gz
				;;

			svn://*)
				dest=$1-svn$TODAY.tar.gz
				;;

			*/hg)
				dest=$1-hg$TODAY.tar.gz
				;;

			http://*|https://*|ftp://*)
				dest=${i##*/}
				;;
		esac

		if [ ! -f $HERE/src/$dest ]
		then
			case $i in
				*.git)
					git clone --recursive --depth 1 $i $1-git$TODAY
					tar -f - -c $1-git$TODAY | gzip -9 > $HERE/src/$dest
					;;

				svn://*)
					svn co $i $1-svn$TODAY
					tar -f - -c $1-svn$TODAY | gzip -9 > $HERE/src/$dest
					;;

				*/hg)
					hg clone $i $1-hg$TODAY
					tar -f - -c $1-hg$TODAY | gzip -9 > $HERE/src/$dest
					;;

				http://*|https://*|ftp://*)
					wget -O $HERE/src/$dest $i
					;;
			esac
		fi

		ln -s $HERE/src/$dest .
	done
}

list_deps() {
	local i

	for i in $@
	do
		PKG_DEPS=
		. ./rule/$i
		list_deps $PKG_DEPS
		echo $i
	done
}

list_uniq_deps() {
	local i j

	uniq=
	for i in $(list_deps $1)
	do
		dup=0
		for j in $uniq
		do
			if [ $j = $i ];
			then
				dup=1
				break
			fi
		done

		[ $dup -eq 0 ] && uniq="$uniq $i"
	done

	echo "$uniq"
}

update_pkg_list() {
	tmp=$(mktemp -u)

	[ -f $HERE/repo/available ] && grep -v ^$1\| $HERE/repo/available > $tmp
	echo "$1|$2|$3|$1.pkg|$4" >> $tmp

	packlim sign < $tmp > $HERE/repo/available.sig

	mv -f $tmp $HERE/repo/available
}

cleanup() {
	rm -rf $WRKDIR
}

trap cleanup EXIT INT TERM

pkgs=$(list_uniq_deps $1)

for i in $pkgs
do
	export DESTDIR=$HERE/staging/$i
	built=0

	if [ ! -d $HERE/staging/$i ]
	then
		mkdir $WRKDIR/$i
		cd $WRKDIR/$i

		unset -f build
		PKG_VER=$TODAY
		. $HERE/rule/$i
		download $i

		for j in $(ls *.tar* 2>/dev/null)
		do
			tar -xf $j
		done

		for j in *
		do
			case $j in
				$i-*|$i)
					[ ! -d $j ] && continue
					cd $j
					break
					;;
			esac
		done

		if [ -d $HERE/patch/$i ]
		then
			for j in $HERE/patch/$i/*
			do
				patch -p 1 < $j
			done
		fi

		type build > /dev/null 2>&1
		if [ $? -eq 0 ]
		then
			build
		else
			$MAKE
		fi

		package

		if [ -d $DESTDIR/$PFIX/lib ]
		then
			rm -f $DESTDIR/$PFIX/lib/lib*.la 2>/dev/null
		fi

		[ -f $HERE/post-build/$i ] && . $HERE/post-build/$i
		built=1

		set -e

		for name in $i $i-common
		do
			[ ! -f $HERE/template/$name ] && continue

			while read path
			do
				dest=$(dirname $path)
				mkdir -p $HERE/output/$name/$PFIX/$dest
				cp -a -P -v $DESTDIR/$PFIX/$path $HERE/output/$name/$PFIX/$dest/
			done < $HERE/template/$name

			find $HERE/output -name .gitignore -delete

			if [ -d $HERE/output/$name/$PFIX/bin ]
			then
				strip -s -R .note -R .comment $HERE/output/$name/$PFIX/bin/* 2>/dev/null
			fi

			tar -f - -c -C $HERE/output/$name . |
			lzip -9 |
			packlim package > $HERE/repo/$name.pkg
		done

		deps=
		for dep in $PKG_DEPS
		do
			[ -n "$deps" ] && deps="$deps "
			if [ -f $HERE/repo/$dep-common.pkg ]
			then
				deps="$deps$dep-common"
			else
				deps="$deps$dep"
			fi
		done

		if [ -f $HERE/repo/$i-common.pkg ]
		then
			update_pkg_list $i-common $PKG_VER "$PKG_DESC" "$deps"
			deps="$i-common"
		fi

		[ -f $HERE/repo/$i.pkg ] && update_pkg_list $i $PKG_VER "$PKG_DESC" "$deps"

		set +e
	fi

	if [ -d $DESTDIR/$PFIX/include ]
	then
		export CFLAGS="-I$DESTDIR/$PFIX/include $CFLAGS"
	fi

	if [ -d $DESTDIR/$PFIX/lib ]
	then
		export LDFLAGS="-L$DESTDIR/$PFIX/lib $LDFLAGS"
	fi

	[ $built -eq 0 -a -f $HERE/post-build/$i ] && . $HERE/post-build/$i
done

exit 0
