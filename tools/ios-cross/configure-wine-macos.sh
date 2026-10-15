#!/usr/bin/env bash
# PLAYBOOK 3.3: wine/build-macos = a configure for aarch64-apple-darwin, using the real macOS SDK
# (config.h must say HAVE_NET_ROUTE_H etc.; the app itself is later compiled against the iOS SDK).
export PATH=/usr/lib/llvm-20/bin:$HOME/tools/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MACSDK=$HOME/xtool-sdk/darwin.xtoolsdk/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk
cd ~/madeira-ios/wine
[ -d build-macos-iossdk ] || { [ -d build-macos ] && mv build-macos build-macos-iossdk; }
rm -rf build-macos && mkdir build-macos && cd build-macos
../configure --host=aarch64-apple-darwin --enable-win64 --without-x --disable-tests \
  --without-freetype --without-vulkan --without-pcap --without-sdl --without-usb \
  --without-gstreamer --without-pulse --without-alsa --without-oss --without-cups --without-sane \
  --without-krb5 --without-opencl --without-unwind --without-v4l2 --without-wayland --without-capi --without-dbus \
  --with-gnutls GNUTLS_CFLAGS="-I$HOME/madeira-ios/toolchains/gnutls-ios/include" GNUTLS_LIBS="-lgnutls" ac_cv_lib_soname_gnutls=libgnutls.dylib ac_cv_func_gnutls_cipher_init=yes \
  --with-wine-tools=$HOME/madeira/wine/build-arm64ec \
  CC="clang-20 -target arm64-apple-macos14.0 -isysroot $MACSDK" \
  CXX="clang++-20 -target arm64-apple-macos14.0 -isysroot $MACSDK" \
  LDFLAGS="-fuse-ld=lld -mlinker-version=1000" \
  AR=/usr/lib/llvm-20/bin/llvm-ar > ~/wcfg.log 2>&1
rc=$?
echo "WCFG_EXIT=$rc" >> ~/wcfg.log
tail -4 ~/wcfg.log
exit $rc
