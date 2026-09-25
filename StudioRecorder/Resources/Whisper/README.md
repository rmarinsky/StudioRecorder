# Local Ukrainian transcription helper

`whisper-cli` is a static arm64 build of `ggml-org/whisper.cpp` at commit
`d09f61a708f3487afa956ff578e60eae5e7a233c`. Its SHA-256 is
`3ee2787a95ad90a03fe19be21df073484a2512767b449c291ac02abb152a06c1`.
The upstream license is bundled as `Whisper-LICENSE.txt`.

The build uses CMake options `GGML_NATIVE=OFF`, `BUILD_SHARED_LIBS=OFF`,
`GGML_METAL=OFF`, and `GGML_BLAS=ON`. Rebuild with the current Xcode macOS SDK,
then check that `otool -L whisper-cli` lists only system libraries and run the
bundled-helper test. This local build has not been verified for notarized release.

Each transcription job downloads `ggml-small-q5_1.bin` from revision
`5359861c739e955e79d9a303bcbc70fb988958b1` of the official
`ggerganov/whisper.cpp` model repository, verifies SHA-256
`ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb`,
and removes the temporary model after the job. The recognition mode uses
experimental DTW word bounds. The app stores those words as **uncertain** and
requires manual waveform timing adjustment before cutting one word.

On two 45-second clips from existing Ukrainian recordings, the quantized small
model produced visibly more coherent text than the previous base model. It took
12.18 and 10.16 seconds of recognition versus 4.37 and 3.55 seconds for base
on this Mac. The temporary download is 181 MiB versus 142 MiB for base. These
clips have no human-labelled word boundaries, so this comparison does not
establish timing accuracy or permit automatic word cuts.
