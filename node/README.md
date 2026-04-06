# ZeroTier Core (`node/`)

`node/` contains the upstream C++ core library.

- this is the upstream C++ core, not the Zig reimplementation
- it exposes the stable C API through `include/ZeroTierOne.h`
- it aims to stay compact and portable
- it intentionally avoids pulling in broad OS integration work

If you are working on the Zig effort, the parallel tree is `src/node/` and the canonical overview is `ZIG.md`.
