# Local Ukrainian transcription helper

`whisper-cli` is a static arm64 build of `ggml-org/whisper.cpp` at commit
`d09f61a708f3487afa956ff578e60eae5e7a233c`. Its SHA-256 is
`24b538fe169b1f25b3ebaa0478536130302a21d582fa83a8f0c9a9f354f14981`.
The upstream license is bundled as `Whisper-LICENSE.txt`.

The arm64 build uses CMake options `GGML_NATIVE=OFF`, `BUILD_SHARED_LIBS=OFF`,
`GGML_METAL=ON`, `GGML_METAL_EMBED_LIBRARY=ON`, and `GGML_BLAS=ON`, with macOS
14.0 as the deployment target. Build with the Xcode macOS SDK, then check that
`otool -L whisper-cli` lists Metal, MetalKit, Accelerate, and system libraries
only. Run the bundled-helper test and a local transcription on Apple Silicon.
This local build has not been verified for notarized release.

Each transcription job downloads `ggml-small-q5_1.bin` from revision
`5359861c739e955e79d9a303bcbc70fb988958b1` of the official
`ggerganov/whisper.cpp` model repository, verifies SHA-256
`ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb`,
and removes the temporary model after the job. Recognition uses Metal by
default and disables flash attention because whisper.cpp disables DTW word
timestamps when flash attention is enabled. The app stores those experimental
word bounds as **uncertain** and
requires manual waveform timing adjustment before cutting one word.

On a 60-second Ukrainian recording on an M1 Pro, the same quantized small model
and DTW options took 5.69 seconds with warm Metal and 13.95 seconds with two
CPU threads. The first Metal launch spent about 29 seconds compiling embedded
shaders. Each job still downloads the model. These measurements do not establish
word-timing accuracy or predict throughput on every recording.

On two earlier 45-second clips from existing Ukrainian recordings, the quantized small
model produced visibly more coherent text than the previous base model. It took
12.18 and 10.16 seconds of recognition versus 4.37 and 3.55 seconds for base
on this Mac. The temporary download is 181 MiB versus 142 MiB for base. These
clips have no human-labelled word boundaries, so this comparison does not
establish timing accuracy or permit automatic word cuts.
