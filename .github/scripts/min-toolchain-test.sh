#!/bin/bash
# Minimum-toolchain check: (optionally) build x265 8/10/12-bit, then encode a
# small matrix and verify every output with FFmpeg's per-frame MD5 check.
#   BUILD=1  build with CMake + make (macOS/Linux). On Windows the builds are
#            done by the workflow (MSVC env) into build-8/10/12 beforehand.
set -u
ROOT=$(pwd)
EXE=x265; [ -f build-8/x265.exe ] && EXE=x265.exe
SUM=${GITHUB_STEP_SUMMARY:-/dev/stdout}
fail=0

if [ "${BUILD:-0}" = 1 ]; then
  NPROC=$(sysctl -n hw.logicalcpu 2>/dev/null || nproc)
  for d in 8 10 12; do
    opts="-DCMAKE_BUILD_TYPE=Release -DENABLE_SHARED=OFF -DENABLE_HDR10_PLUS=ON"
    [ $d = 10 ] && opts="$opts -DHIGH_BIT_DEPTH=ON"
    [ $d = 12 ] && opts="$opts -DHIGH_BIT_DEPTH=ON -DMAIN12=ON"
    mkdir -p build-$d && (cd build-$d && cmake ../source $opts > cmake.log 2>&1 && make -j$NPROC > make.log 2>&1) \
      || { echo "::error::BUILD FAIL ${d}bit"; tail -n 40 build-$d/cmake.log build-$d/make.log 2>/dev/null; exit 1; }
  done
fi

echo "## Builds" >> $SUM
echo "| depth | -std flags | warnings | build info |" >> $SUM
echo "|---|---|---|---|" >> $SUM
for d in 8 10 12; do
  B=build-$d
  std=$(grep -rhoE "(std=(gnu|c)\+\+[0-9]+|std:c\+\+[0-9]+|LanguageStandard>[a-z0-9]+)" $B --include=flags.make --include=build.ninja --include=*.vcxproj 2>/dev/null | sort -u | tr '\n' ' ')
  warns=$(cat $B/make.log $B/build.log 2>/dev/null | grep -ci "warning")
  info=$(./$B/$EXE --version 2>&1 | grep "build info" | sed 's/.*build info //')
  caps=$(./$B/$EXE --version 2>&1 | grep "capabilities" | sed 's/.*capabilities: //')
  echo "| ${d}bit | $std | $warns | $info — $caps |" >> $SUM
  echo "${d}bit: $info | $caps | $std"
done

# Test inputs generated locally (no downloads): 8-bit 420, 10-bit 420, 8-bit 422, 8-bit 444
mkdir -p in out
ffmpeg -nostdin -v error -y -f lavfi -i testsrc2=size=1280x720:rate=30 -frames:v 30 -pix_fmt yuv420p     in/t420.y4m
ffmpeg -nostdin -v error -y -f lavfi -i testsrc2=size=1280x720:rate=30 -frames:v 20 -pix_fmt yuv420p10le -strict -1 in/t420p10.y4m
ffmpeg -nostdin -v error -y -f lavfi -i testsrc2=size=640x360:rate=30  -frames:v 20 -pix_fmt yuv422p     in/t422.y4m
ffmpeg -nostdin -v error -y -f lavfi -i testsrc2=size=640x360:rate=30  -frames:v 20 -pix_fmt yuv444p     in/t444.y4m

CFGS=("ultrafast|--preset ultrafast" "medium|--preset medium" "slow_vbv|--preset slow --bitrate 4000 --vbv-maxrate 5000 --vbv-bufsize 8000" "mcstf|--preset medium --mcstf" "noasm|--preset medium --no-asm")

echo "## Encodes" >> $SUM
echo "| depth | input | config | result | fps | md5 |" >> $SUM
echo "|---|---|---|---|---|---|" >> $SUM
for d in 8 10 12; do
  X=./build-$d/$EXE
  for i in t420 t420p10 t422 t444; do
    for c in "${CFGS[@]}"; do
      n=${c%%|*}; a=${c#*|}; o=out/${d}_${i}_$n.hevc
      if $X --input in/$i.y4m --no-info --hash 1 $a -o $o > out/${d}_${i}_$n.log 2>&1 < /dev/null; then
        err=$(ffmpeg -nostdin -v error -err_detect crccheck -i $o -f null - 2>&1 | head -1)
        fps=$(grep -oE "\(([0-9.]+) fps\)" out/${d}_${i}_$n.log | tr -d '()fps ')
        md5=$( (md5sum $o 2>/dev/null || md5 -r $o) | cut -c1-12)
        if [ -z "$err" ]; then r=PASS; else r="FAIL: ${err:0:80}"; fail=1; fi
      else
        r="FAIL: encode error $(tail -1 out/${d}_${i}_$n.log)"; fps=; md5=; fail=1
      fi
      echo "| ${d}bit | $i | $n | $r | $fps | $md5 |" >> $SUM
      echo "${d}bit $i $n: $r"
    done
  done
done
exit $fail
