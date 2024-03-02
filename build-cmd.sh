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
                # Setup osx sdk platform
                SDKNAME="macosx"
                export SDKROOT=$(xcodebuild -version -sdk ${SDKNAME} Path)

                # Setup build flags
                ARCH_FLAGS_X86="-arch x86_64 -mmacosx-version-min=10.15 -isysroot ${SDKROOT} -msse4.2"
                ARCH_FLAGS_ARM64="-arch arm64 -mmacosx-version-min=11.0 -isysroot ${SDKROOT}"
                DEBUG_COMMON_FLAGS="-O0 -g -fPIC -DPIC"
                RELEASE_COMMON_FLAGS="-O3 -g -fPIC -DPIC -fstack-protector-strong"
                DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
                RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
                DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
                RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
                DEBUG_CPPFLAGS="-DPIC"
                RELEASE_CPPFLAGS="-DPIC"
                DEBUG_LDFLAGS="-Wl,-headerpad_max_install_names"
                RELEASE_LDFLAGS="-Wl,-headerpad_max_install_names"

                # x86 deploy target
                export MACOSX_DEPLOYMENT_TARGET=10.15

                export CXXFLAGS="$ARCH_FLAGS_X86 $RELEASE_CXXFLAGS"
                export CFLAGS="$ARCH_FLAGS_X86 $RELEASE_CFLAGS"
                export common_options="--prefix=${stage} --enable-shared=no \
                    --enable-static=yes --disable-dyload --enable-extras=no \
                    --enable-samples=no --enable-tests=no --enable-layout=no"
                mkdir -p $stage
                chmod +x runConfigureICU configure install-sh
                # HACK: Break format layout so boost can find the library.
                ./runConfigureICU MacOSX $common_options --libdir=${stage}/lib/

                make -j$AUTOBUILD_CPU_COUNT
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
                # Default target per autobuild build --address-size
                opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE}"
                DEBUG_COMMON_FLAGS="$opts -Og -g -fPIC -DPIC"
                RELEASE_COMMON_FLAGS="$opts -O3 -g -fPIC -DPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2"
                DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
                RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
                DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
                RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
                DEBUG_CPPFLAGS="-DPIC"
                RELEASE_CPPFLAGS="-DPIC"

                export CXXFLAGS="$RELEASE_CXXFLAGS"
                export CFLAGS="$RELEASE_CFLAGS"
                export common_options="--prefix=${stage} --enable-shared=no \
                    --enable-static=yes --disable-dyload --enable-extras=no \
                    --enable-samples=no --enable-tests=no --enable-layout=no"
                mkdir -p $stage
                chmod +x runConfigureICU configure install-sh
                # HACK: Break format layout so boost can find the library.
                ./runConfigureICU Linux $common_options --libdir=${stage}/lib/release

                make -j$AUTOBUILD_CPU_COUNT
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
