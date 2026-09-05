# Rebuilding DataChannel.xcframework

The checked-in binary target must honour RelaySwarmKit's macOS 14.0 minimum.
The verifier inspects every Mach-O object in the merged static archive and
rejects non-macOS objects, missing deployment metadata, unexpected
architectures, or a deployment minimum newer than 14.0.

The current archive uses libdatachannel commit
`51085b8de4e6185dc019e3705c88b87933d7c3f6` and OpenSSL 3.6.1. Build it on
Apple silicon with:

```bash
git clone --recurse-submodules https://github.com/paullouisageneau/libdatachannel.git
cd libdatachannel
git checkout 51085b8de4e6185dc019e3705c88b87933d7c3f6
git submodule update --init --recursive
MACOSX_DEPLOYMENT_TARGET=14.0 cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DNO_MEDIA=1 -DNO_EXAMPLES=1 -DNO_TESTS=1 \
  -DOPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl@3
MACOSX_DEPLOYMENT_TARGET=14.0 cmake --build build --parallel
```

Then, from RelaySwarmKit:

```bash
scripts/build-xcframework.sh \
  /absolute/path/to/libdatachannel/build \
  /opt/homebrew/opt/openssl@3/lib \
  14.0
```

The OpenSSL static archives are part of the final binary. The script will
stop before replacing the checked-in artifact if the installed archives
were built for a newer macOS version. In that case, build the pinned OpenSSL
release from source with `MACOSX_DEPLOYMENT_TARGET=14.0` and pass its `lib`
directory explicitly. Never raise the package minimum merely to silence a
linker warning.
