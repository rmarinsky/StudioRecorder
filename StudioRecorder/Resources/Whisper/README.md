# Local Ukrainian transcription helper

`whisper-cli` is a static arm64 build of `ggml-org/whisper.cpp` at commit
`d09f61a708f3487afa956ff578e60eae5e7a233c`. Its SHA-256 is
`3ee2787a95ad90a03fe19be21df073484a2512767b449c291ac02abb152a06c1`.
The upstream license is bundled as `Whisper-LICENSE.txt`.

The build uses CMake options `GGML_NATIVE=OFF`, `BUILD_SHARED_LIBS=OFF`,
`GGML_METAL=OFF`, and `GGML_BLAS=ON`. Rebuild with the current Xcode macOS SDK,
then check that `otool -L whisper-cli` lists only system libraries and run the
bundled-helper test. This local build has not been verified for notarized release.

Each transcription job downloads `ggml-base.bin` from revision
`5359861c739e955e79d9a303bcbc70fb988958b1` of the official
`ggerganov/whisper.cpp` model repository, verifies SHA-256
`60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe`,
and removes the temporary model after the job. The recognition mode uses
experimental DTW word bounds. The app stores those words as **uncertain** and
requires manual waveform timing adjustment before cutting one word.
