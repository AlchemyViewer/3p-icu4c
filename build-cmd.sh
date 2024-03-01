#!/usr/bin/env bash

cd "$(dirname "$0")"
top="$(pwd)"

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain about undefined variables
set -u

ICU4C_SOURCE_DIR="icu"
VERSION_HEADER_FILE="$ICU4C_SOURCE_DIR/source/common/unicode/uvernum.h"
VERSION_MACRO="U_ICU_VERSION"

if [ -z "$AUTOBUILD" ] ; then
    exit 1
fi

if [ "$OSTYPE" = "cygwin" ] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

stage="$(pwd)/stage"

# load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

pushd "$ICU4C_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in
        windows*)
            load_vsvars

            export MSYS2_ARG_CONV_EXCL="*"

            # According to the icu build instructions for Windows,
            # runConfigureICU doesn't work for the Microsoft build tools, so
            # just use the provided .sln file.

            pushd source
                msbuild.exe "$(cygpath -w "allinone\allinone.sln")" "-t:Build" "-p:Configuration=Release;Platform=$AUTOBUILD_WIN_VSPLATFORM;PlatformToolset=$AUTOBUILD_WIN_VSTOOLSET"
            popd

            mkdir -p "$stage/lib/release"
            mkdir -p "$stage/include"

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then
              libdir=./lib
              bindir=./bin
            else
              libdir=./lib64
              bindir=./bin64
            fi
            # avoid confusion with Windows find.exe, SIGH
            # /usr/bin/find: The environment is too large for exec().
            while read var
            do unset $var
            done < <(compgen -v | grep '^LL_BUILD_' | grep -v '^LL_BUILD_RELEASE$')
            INCLUDE='' \
            LIB='' \
            LIBPATH='' \
            /usr/bin/find $libdir -name 'icu*.lib' -print -exec cp {} $stage/lib/release \;
            /usr/bin/find $libdir -name 'icu*.pdb' -print -exec cp {} $stage/lib/release \;
            /usr/bin/find $bindir -name 'icu*.dll' -print -exec cp {} $stage/lib/release \;

            cp -R include/* "$stage/include"

            # populate version_file
            cl /DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
               /DVERSION_MACRO="$VERSION_MACRO" \
               /Fo"$(cygpath -w "$stage/version.obj")" \
               /Fe"$(cygpath -w "$stage/version.exe")" \
               "$(cygpath -w "$top/version.c")"
            "$stage/version.exe" > "$stage/version.txt"
            rm "$stage"/version.{obj,exe}
        ;;
        darwin*)
            pushd "source"

                opts="-arch $AUTOBUILD_CONFIGURE_ARCH $LL_BUILD_RELEASE -DU_CHARSET_IS_UTF8=1"
                plainopts="$(remove_cxxstd $opts)"
                export CFLAGS="$plainopts"
                export CXXFLAGS="$opts"
                export LDFLAGS="$plainopts"
                export common_options="--prefix=${stage} --enable-shared=no \
                    --enable-static=yes --disable-dyload --enable-extras=no \
                    --enable-samples=no --enable-tests=no --enable-layout=no"
                mkdir -p $stage
                chmod +x runConfigureICU configure install-sh
                # HACK: Break format layout so boost can find the library.
                ./runConfigureICU MacOSX $common_options --libdir=${stage}/lib/

                make -j$(nproc)
                make install
            popd

            # Move the libraries to the place the autobuild manifest expects 
            mkdir $stage/lib/release
            mv $stage/lib/*.a $stage/lib/release

            # populate version_file
            cc -DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
               -DVERSION_MACRO="$VERSION_MACRO" \
               -o "$stage/version" "$top/version.c"
            "$stage/version" > "$stage/version.txt"
            rm "$stage/version"
        ;;
        linux*)
            pushd "source"
                ## export CC="gcc-4.1"
                ## export CXX="g++-4.1"
                export CXXFLAGS="-m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE"
                export CFLAGS="$(remove_cxxstd $CXXFLAGS)"
                export common_options="--prefix=${stage} --enable-shared=no \
                    --enable-static=yes --disable-dyload --enable-extras=no \
                    --enable-samples=no --enable-tests=no --enable-layout=no"
                mkdir -p $stage
                chmod +x runConfigureICU configure install-sh
                # HACK: Break format layout so boost can find the library.
                ./runConfigureICU Linux $common_options --libdir=${stage}/lib/

                make -j$(nproc)
                make install
            popd

            # populate version_file
            cc -DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
               -DVERSION_MACRO="$VERSION_MACRO" \
               -o "$stage/version" "$top/version.c"
            "$stage/version" > "$stage/version.txt"
            rm "$stage/version"
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp LICENSE "$stage/LICENSES/icu.txt"
popd
