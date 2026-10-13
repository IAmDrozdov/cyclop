# Meetings bring the first package and a native library built with CMake

The Meetings tab records a call and turns it into a transcript on the Mac, with nothing sent anywhere. That takes two things the fork did without until now: FluidAudio, the first third-party Swift package (speech recognition and voice separation on Core ML, pinned to an exact version), and LocalVQE, a native echo canceller built with CMake from a pinned revision into `liblocalvqe.dylib` and loaded from the app bundle. CMake becomes a build requirement; `CYCLOP_SKIP_LOCALVQE=1` builds the bundle without it, and the transcript is then made from the raw tracks.

Rejected:

- **Amanu installed alongside and driven through its command line.** The least work, and its folder-per-meeting layout would have fitted. But it is a second app with its own updater and analytics, and the owner wants one app.
- **A text-only echo filter, no LocalVQE.** It cannot tell an echo from the owner repeating the other side's words, and it fails exactly when the other side is loud. It stays as the second layer, not the first.
- **The speech model of the Handy app.** It is ONNX; FluidAudio reads Core ML.

## Consequences

- `Package.swift` has a dependency, and `SECURITY.md`, the READMEs and the site stop saying there is none.
- The app asks macOS for the microphone and for system audio recording, on the first Start; Downloads is asked about on the first export. The one-time model download from Hugging Face happens only on a button and is a second network connection.
- Audio recording permissions follow the code signature, and an ad-hoc signature changes with every build. A self-signed certificate named «Cyclop Local» is found by `Scripts/bundle.sh` and signs without the hardened runtime (`docs/signing.md`). The Developer ID path signs the library before the app.
- Recording is a tab's background work like a poll: it runs with the panel collapsed and stops when the tab is switched off.
