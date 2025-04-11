#!/bin/sh
#************************************************************************************************
#
# Build Script for WebRTC
# Copyright (c)2025 PreSonus Software Ltd.
#
# Filename    : build/build_webrtc.sh
# Description : Build WebRTC
# 
# ./build_webrtc.sh <branch> [<workingdirectory>]
#
#************************************************************************************************

scriptdir="$(dirname $0)"
cd "${scriptdir}"
scriptdir="$(pwd)"

if [ "$#" -ge 1 ]; then
	branch=${1}
else
	branch=${BuildBranch}
fi
if [ -z "${branch}" ]; then
	echo "no build branch specified" 1>&2
	echo "./build_webrtc.sh <branch> [<workingdirectory>]" 1>&2
	exit 1
fi

if [ "$#" -ge 2 ]; then
	workdir=${2}
else
	workdir=${WORKSPACE}
fi
if [ -z "${workdir}" ]; then
	workdir="${scriptdir}"
fi
cd "${workdir}"
workdir="$(pwd)"
echo "working directory: ${workdir}"

# Check operating system
case "$(uname -s)" in

	Darwin)
		system=mac
		;;

	Linux)
		system=linux
		;;

	CYGWIN*|MINGW32*|MSYS*|MINGW*)
		system=win
		;;

	*)
		echo 'Unknown operating system' 1>&2
		exit 1
		;;
esac

# Clone and setup depot tools
if [ -d "${workdir}/depot_tools" ]; then
	rm -Rf "${workdir}/depot_tools"
fi
if [ -d "${workdir}/webrtc-checkout" ]; then
	rm -Rf "${workdir}/webrtc-checkout"
fi
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "depot_tools"

export PATH="${workdir}/depot_tools:${PATH}"

if [ "${system}" = "win" ]; then
	export DEPOT_TOOLS_WIN_TOOLCHAIN=0
	export GYP_MSVS_VERSION=2022
fi

# Clone WebRTC sources
mkdir -p "${workdir}/webrtc-checkout"
cd "${workdir}/webrtc-checkout"

gclient

echo "initializing working copy"
fetch --nohooks webrtc
gclient sync

cd "${workdir}/webrtc-checkout/src"
gclient sync --with_branch_heads --with_tags
git fetch

echo "checking out release branch"

git checkout -b jenkins refs/remotes/${branch}
git reset --hard
git clean -xdf
cd "${workdir}/webrtc-checkout/src/build"
git reset --hard
git clean -xdf
cd "${workdir}/webrtc-checkout/src"
gclient sync --with_branch_heads --with_tags

echo "resetting depot_tools to latest main"
cd "${workdir}/depot_tools"
git checkout main
cd "${workdir}/webrtc-checkout/src"

echo "applying patches"

# fix linking in c++17-compiled projects

sed -i 's/++14/++17/g' build/config/compiler/BUILD.gn
sed -i 's/"\/TP"/"\/TP","\/std:c++17"/g' build/config/win/BUILD.gn

cd "${workdir}/webrtc-checkout/src"
git apply --reject "${scriptdir}/build_webrtc_c++17.patch"
git apply --reject "${scriptdir}/build_webrtc_winarm64.patch"

cd "${workdir}/webrtc-checkout/src/third_party"
git apply --reject "${scriptdir}/build_webrtc_winarm64_thirdparty.patch"

cd "${workdir}/webrtc-checkout/src"
sed -i 's/19041/22621/g' build/toolchain/win/setup_toolchain.py

cd "${workdir}/webrtc-checkout/src/build/util"
echo 0 > LASTCHANGE
echo 0 > LASTCHANGE.committime

# Use Visual Studio 2022

cd "${workdir}/webrtc-checkout/src/build"
git checkout main -- vs_toolchain.py
line="('2019', '16.0'),"
sed -i "s/${line}//g" vs_toolchain.py
cd "${workdir}/webrtc-checkout/src"

# Use dynamic crt on Windows
if [ "${system}" = "win" ]; then
	sed -i 's/:static_crt/:dynamic_crt/g' build/config/win/BUILD.gn
fi

buildargs='treat_warnings_as_errors=false rtc_build_examples=false rtc_build_tools=false rtc_include_tests=false rtc_exclude_audio_processing_module=true rtc_exclude_transient_suppressor=true is_component_build=false'
debugargs='is_debug=true enable_dsyms=true symbol_level=2'
releaseargs='is_debug=false enable_dsyms=false symbol_level=0'
if [ "${system}" = "mac" ]; then
	buildargs="${buildargs} use_custom_libcxx=false"
	ide="xcode"
	architectures="x64 arm64"
elif [ "${system}" = "win" ]; then
	buildargs="${buildargs} is_clang=false"
	debugargs="${debugargs} enable_iterator_debugging=true"
	ide="vs2019"
	architectures="x86 x64 arm64"
elif [ "${system}" = "linux" ]; then
	buildargs="${buildargs} use_custom_libcxx=false"
	ide="json"
	architectures="x64"
fi

echo "preparing build directories"
for arch in ${architectures}; do
	gn gen out/${system}/${arch}Debug --ide="${ide}" --args="target_cpu=\"${arch}\" ${buildargs} ${debugargs}"
	gn gen out/${system}/${arch}Release --ide="${ide}" --args="target_cpu=\"${arch}\" ${buildargs} ${releaseargs}"
	if [ "${system}" = "win" ]; then
		gn gen out/${system}/${arch}StrippedDebug --ide="${ide}" --args="target_cpu=\"${arch}\" ${buildargs} ${debugargs} enable_dsyms=false symbol_level=0"
	fi
done

echo "building"
for arch in ${architectures}; do
	ninja -C out/${system}/${arch}Debug
	ninja -C out/${system}/${arch}Release
	if [ "${system}" = "win" ]; then
		ninja -C out/${system}/${arch}StrippedDebug
	fi
done

if [ "${system}" = "mac" ]; then
	lipo -create out/mac/x64Release/obj/libwebrtc.a out/mac/arm64Release/obj/libwebrtc.a -output out/mac/libwebrtc_universal.a
fi

mkdir -p ./out/include/call
mkdir -p ./out/include/common_video/generic_frame_descriptor
mkdir -p ./out/include/modules/async_audio_processing
mkdir -p ./out/include/modules/audio_coding
mkdir -p ./out/include/modules/audio_device
mkdir -p ./out/include/modules/audio_processing
mkdir -p ./out/include/modules/congestion_controller
mkdir -p ./out/include/modules/rtp_rtcp
mkdir -p ./out/include/modules/rtp_rtcp
mkdir -p ./out/include/modules/utility
mkdir -p ./out/include/modules/video_coding/codecs/interface
mkdir -p ./out/include/modules/video_coding/codecs/h264
mkdir -p ./out/include/modules/video_coding/codecs/vp8
mkdir -p ./out/include/modules/video_coding/codecs/vp9
mkdir -p ./out/include/system_wrappers
mkdir -p ./out/include/p2p/base
mkdir -p ./out/include/logging/rtc_event_log/events

rsync -zarv --include="*/" --include="*.h" --exclude="*" "./api" "./out/include/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./call/" "./out/include/call/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./common_audio/include" "./out/include/common_audio/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./common_video/include" "./out/include/common_video/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./common_video/" "./out/include/common_video/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./common_video/generic_frame_descriptor/" "./out/include/common_video/generic_frame_descriptor/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./media/base" "./out/include/media/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./media/engine" "./out/include/media/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./modules/async_audio_processing/" "./out/include/modules/async_audio_processing/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./modules/audio_coding/include" "./out/include/modules/audio_coding/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./modules/audio_device/" "./out/include/modules/audio_device/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./modules/audio_device/include" "./out/include/modules/audio_device/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./modules/audio_processing/include" "./out/include/modules/audio_processing/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./modules/congestion_controller/include" "./out/include/modules/congestion_controller/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./modules/include" "./out/include/modules/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./modules/rtp_rtcp/include" "./out/include/modules/rtp_rtcp"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./modules/rtp_rtcp/source" "./out/include/modules/rtp_rtcp"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./modules/utility/include" "./out/include/modules/utility"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./modules/video_coding/" "./out/include/modules/video_coding/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./modules/video_coding/codecs/interface/" "./out/include/modules/video_coding/codecs/interface/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./modules/video_coding/codecs/h264/include" "./out/include/modules/video_coding/codecs/h264/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./modules/video_coding/codecs/vp8/include" "./out/include/modules/video_coding/codecs/vp8/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./modules/video_coding/codecs/vp9/include" "./out/include/modules/video_coding/codecs/vp9/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./modules/video_coding/include" "./out/include/modules/video_coding/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./pc" "./out/include/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./rtc_base" "./out/include/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./system_wrappers/include" "./out/include/system_wrappers/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./p2p/base/" "./out/include/p2p/base/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./logging/rtc_event_log/" "./out/include/logging/rtc_event_log/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./logging/rtc_event_log/events/" "./out/include/logging/rtc_event_log/events/"
rsync -zarv --include="*/" --include="*.h" --exclude="*" "./third_party/abseil-cpp/absl" "./out/include/"

exit 0
