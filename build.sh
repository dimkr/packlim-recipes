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
HERE=$(pwd)
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
export LDFLAGS=

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

		if [ -f $HERE/src/$dest ]
		then
			cp $HERE/src/$dest .
		else
			case $i in
				*.git)
					git clone --recursive --depth 1 $i $1-git$TODAY
					tar -c $1-git$TODAY | gzip -9 > $dest
					;;

				svn://*)
					svn co $i $1-svn$TODAY
					tar -c $1-svn$TODAY | gzip -9 > $dest
					;;

				*/hg)
					hg clone $i $1-hg$TODAY
					tar -c $1-hg$TODAY | gzip -9 > $dest
					;;

				http://*|https://*|ftp://*)
					wget $i
					;;
			esac

			cp $dest $HERE/src/
		fi
	done
}

list_deps() {
	local i

	for i in $@
	do
		PKG_DEPS=""
		. ./rules/$i
		list_deps $PKG_DEPS
		echo $i
	done
}

list_uniq_deps() {
	local i j

	uniq=""
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

cleanup() {
	rm -rf $WRKDIR
}

trap cleanup EXIT INT TERM

pkgs=$(list_uniq_deps $1)

for i in $pkgs
do
	export DESTDIR=$HERE/staging/$i

	if [ ! -d $HERE/staging/$i ]
	then
		mkdir $WRKDIR/$i
		cd $WRKDIR/$i

		unset -f build
		. $HERE/rules/$i
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

		set -e

		for name in $i $i.common
		do
			[ ! -f $HERE/template/$name ] && continue

			while read path
			do
				dest=$(dirname $path)
				mkdir -p $HERE/output/$name/$PFIX/$dest
				cp -a -P -v $DESTDIR/$PFIX/$path $HERE/output/$name/$PFIX/$dest/
			done < $HERE/template/$name

			if [ -d $HERE/output/$name/$PFIX/bin ]
			then
				strip -s -R .note -R .comment $HERE/output/$name/$PFIX/bin/* 2>/dev/null
			fi
		done

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

	[ -f $HERE/post-build/$i ] && . $HERE/post-build/$i
done
