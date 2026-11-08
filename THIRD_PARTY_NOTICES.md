# Third-party components

This project's integration source is provided under the MIT license. It does not relicense the original game, launcher core, artwork, or other dependencies.

- **Platinum Together:** original Core assembly, launcher media, and install/sign-in protocol are obtained from the [official launcher endpoint](https://pt-relay.kaicrits.com/beta-downloads/v1/launcher.zip). Original ownership and terms apply. The game and ROM are not redistributed in this release. Official site: https://platinumtogether.online
- **Wine 11.18:** LGPL 2.1 or later. [Distributed binaries and associated source/build information](https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.18), [upstream source](https://gitlab.winehq.org/wine/wine/-/tree/wine-11.18). `licenses/Wine-LGPL-2.1.txt`. No Wine source changes are made; optional Mono/Gecko packages are omitted because the game is native Windows code.
- **Mesa 26.2.4:** [Windows package and build/source information](https://github.com/pal1000/mesa-dist-win/releases/tag/26.2.4), [Mesa license information](https://docs.mesa3d.org/license.html). Included opengl32.dll and libgallium_wgl.dll provide llvmpipe software OpenGL. See the Mesa and LLVM notices in `licenses/`. Mesa consists of components under their respective licenses.
- **WineMetalGL 3.9.0 (optional GPU backend):** LGPL-3.0-or-later. Not bundled or redistributed by this project. When the user enables the GPU renderer, the pinned signed release is downloaded at runtime from the [WineMetalGL project](https://github.com/metalsharp/WineMetalGL) and installed under `~/Library/Application Support/Platinum Together/WineMetalGL/`. Source for the pinned version: https://github.com/metalsharp/WineMetalGL/releases/tag/winemetalgl-3.9.0 (includes its vendored glslang/SPIRV-Cross and their licenses). The launcher does not link WineMetalGL; Wine loads it as a separate module inside the game process, and it remains user-replaceable.
- **.NET 10:** [runtime source and licenses](https://github.com/dotnet/runtime). The bridge includes a self-contained macOS runtime and its accompanying license/notices files.
- **NSec 25.4.0 and libsodium:** see the original notices copied into `licenses/` and the official launcher Licenses folder.
- **Zig 0.17.0** and **7-Zip 26.05** are build tools downloaded by the build script; they are not bundled as user-facing tools. https://ziglang.org/ and https://www.7-zip.org/

No endorsement is implied. Preserve these notices with redistributed bundles.
