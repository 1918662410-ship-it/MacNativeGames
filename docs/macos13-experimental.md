# Experimental macOS 13 / Metal 3 port

This branch starts from `m3-macos15` at `f71ea7b`. It is **not a validated playable game build**.

## Implemented

- The Metal 3 backend uses the existing classic `CAMetalLayer.nextDrawable` presentation thread. It does not import or instantiate `CAMetalDisplayLink`.
- `M3ResidencySet` owns registered resources until the existing retirement path removes them. Render and compute encoders explicitly declare indirect resources with `useResource`. A generation number avoids repeating declarations when the resource list has not changed. This conservative implementation declares all registered resources and needs gameplay performance measurement.
- The renderer and window share a device selector. On this test Mac, the default Metal device was nil, but enumeration returned the M1 Max. The fallback selects an enumerated unified-memory Metal 3 device.
- Shader compilation uses `fastMathEnabled = NO` for precise arithmetic. Frame interpolation remains disabled by the existing Metal 3 stubs.
- `TOTK_M3_EXPERIMENTAL_MACOS13=1`, together with `TOTK_M3=1`, selects macOS 13 for prerequisites, runtime compilation, launcher compilation and the packaged minimum system version. Without the experimental variable, the builder still requires macOS 15.

## Verified on M1 Max / macOS 13.7.8 / SDK 13.3

Run from the repository root. Output must be outside the checkout:

```sh
python3 games/totk/tests/macos13_compat/run.py --output ../metal3-compat-check --window
```

The runner builds 20 graphics translation units, 32 runtime units for 1.4.3 and the launcher. It also runs:

- Resource lifetime, duplicate registration, late allocation and encoder-generation checks.
- Real GPU indirect-buffer access through an argument buffer: input 41, output 42.
- 52 floating-point and render-attachment semantic checks.
- A classic drawable window, rendered gradient, presentation and pixel readback. The image is `render.png`.

`verification.json` records each exit code and log path. The three runtime units requiring generated game headers (`loader.c`, `romfs.c`, `shared_font.c`) are explicitly skipped. The runner does not link or launch the complete game.

## Remaining work

- `R11G11B10` packed **vertex input** needs conversion on macOS 13. Encountering it now stops with an explicit error. It is not replaced with a different format. This does not disable the separate R11G11B10 texture format.
- A full game build needs the user's validated shared fonts or firmware. Game code and rewritten-code hashes remain pinned. Font and NPDM validation follow upstream PR #47 and the current upstream handling of re-signed metadata: valid fonts are bound by their actual hashes, and alternate NPDM metadata requires matching code modules and the correct title ID.
- Full game link, shader preparation, title screen, gameplay, frame pacing, memory use and saves remain unverified.
- MetalFX spatial upscaling has compiled but has not been exercised by these tests.

After providing fonts, use the normal builder with both variables above and an external work folder. Do not interpret an experimental minimum version as proof of game compatibility.

## Firmware validation update

Firmware 22.5.0 supplied locally produced all six fonts. The extraction verified the NCA filesystem hashes and IVFC levels; the builder accepted the BFTTF structures and manifest. Four fonts differ from the original reference firmware, as anticipated by upstream issue #45. The backported container tests pass (14 tests), including rejecting damaged fonts and requiring matching code alongside re-signed NPDM metadata. Firmware 23.0.1 could not be read using the supplied 22.5.0 keys; no key contents were logged.

## Options-menu glyph regression (2026-11-13)

The 1.4.3 Options menu lost individual letters although the title menu rendered correctly.
The same failure reproduced on a copied profile at 960x540. Runtime render-stream, vertex-stream,
uniform-snapshot and binding switches did not repair the already-created glyph caches;
waiting after each GPU commit did not prevent the failure either.

Two corrections are required: capture the dirty generation before upload protection/copy,
and retain that generation as `NvPkg.seen` (as in upstream's issue-90 correction);
validate linear CPU textures against guest-write generations even within one submission.
Descriptor views use a distinct linear-texture kind so their fast path follows the same rule.
Non-linear textures keep the existing once-per-submission policy.

`probe-gpu-linear-rt` now includes a descriptor-cached CPU texel update within one submission.
The real-GPU probe passed 602672 component checks with Metal API validation enabled.
The top and bottom of the actual Options menu rendered complete labels and values.
Evidence and the repeatable driver are outside this checkout in
`../metal3-compat-check/ui-test/` (`report.html`, `case.py`, screenshots and logs).
Tests use a profile under the user's MacNativeGames `tests/ui-glyph-20261113` directory.
No font replacement or game-data hash bypass was involved.

The launcher preserves an optional `language` setting (for example `zh-Hans`) in
`launcher-settings.json`; `TOTK_LANG` overrides it. The simplified-Chinese Options page
was also checked with the fixed runtime. The user app retains the `perf: true` setting.

Window sizing: a nonempty launcher `window_size` now disables `TOTK_WINDOW_MAX`.
On the current Retina display, 640x360 logical points with `perf: false` produces
a 1280x720 drawable and a matching 1280x720 content area. This changes presentation
resolution, not every internal game render target.


## Mouse backport (2026-11-14)

Ported `runtime/mouse_look.h` from the local upstream mainline (ly05010419/MacNativeGames). The old frontend uses click-to-capture and key **7** to toggle. The first click only captures. Command-Tab, loss of key-window status, close, and native text entry release the cursor and clear mouse state. Text entry does not automatically recapture. Existing keyboard mappings remain unchanged.

Mouse movement drives the right stick and gyro at 100 Hz. Hold Q / controller L to point in the ability wheel without decay. Left click attacks; right click draws the bow; left click while right is held releases ZR to shoot; middle click maps ZL. Enable motion controls in the game for mouse gyro aiming. `TOTK_MOUSE_SENSITIVITY=1..100` (50 default), `TOTK_MOUSE_INVERT_Y=1`, and `TOTK_MOUSE_GYRO=0` are supported. Mouse input owns the gyro only while captured. It does not consume controller press edges. Mouse press edges are separate from keyboard edges and are cleared on release.

Window content now retains its initial aspect ratio while resizing. User-selected output is 2048×1152, with a 1024×576-point window on this 2× display, drawable scale 1. This describes the game output canvas and presentation; it does not establish the resolution of every internal 3D pass. The matching HeapDef overlay adds 16 MiB and retains original/modified hashes in its manifest.

Validation sources: `games/totk/tests/mouse_backport/`. External evidence: `../metal3-compat-check/mouse-test/`. The upstream math probe passed 26 checks; the integration probe checks axis signs, decay, persistent wheel selection, bow release, keyboard coexistence, no stale clicks after release, and gyro ownership. The AppKit probe passes when launched as a standard App via Launch Services. Two earlier bare-executable attempts aborted on the test's key-window assertion; the harness now reports failure without crashing. The actual runtime builds with macOS 13 minimum and warnings-as-errors. Manual gameplay aiming sensitivity remains user-dependent.


### PC keyboard bindings

Physical Return maps A (confirm), Space maps X (jump), P maps Plus, and Tab remains Minus (map). Esc maps Plus while the 1.4.3 Player is active, or B when paused / unknown (title/loading). Esc also releases mouse capture. The action is latched until key-up, so opening a menu during a held Esc cannot turn the same press into Back. Existing J/K/I aliases remain; remapped native keys are tracked separately so releasing Return cannot cancel a held J. Focus loss clears both sets. Scripted key codes retain their original ABI.

The read-only context reader is upstream `bow_state.h`, using the upstream 1.4.3 scene slot 0x3add238 and actor name offset 0x218. All guest reads use `mach_vm_read_overwrite`; bad/stale/unavailable pointers fall back to B. Its fake-memory tests cover paused, active, missing, wrong and stale actors. The input integration probe verifies bindings, held-key repeats, alias coexistence, and preserved scripted Return=Plus. External evidence: `../metal3-compat-check/keyboard-test/`.


### Selective streamed-pass texture residency experiment (2026-11-14)

`TOTK_M3_SELECTIVE_TEXTURES=1` is an opt-in experiment. The default remains off.
Only render-stream encoders omit global texture declarations. They still declare
all registered buffers conservatively. The existing argument reflection `USE`
points enqueue retained texture views, access flags, and shader stage before the
draw. Argument and slot-cache reuse is limited to the same render pass; earlier
declarations remain valid for that encoder. Compute and direct helper encoders
retain full global declarations. Encoder reuse resets the selective marker.

Validation: `tests/macos13_compat/probe.m` covers fallback and encoder recycling;
`tests/macos13_compat/selective_texture.m` reads back exact pixels from indirect
texture arguments across four real GPU passes with Metal API Validation enabled.
These probes do not establish full game correctness or 40 FPS. Controlled moving
scene comparisons remain required. External evidence is under
`metal3-compat-check/compat-profile/` beside the checkout, including the build,
validation, frame logs and screenshots.

The original user process aborted after SIGSTOP/SIGCONT: `rs_sync` counts elapsed
wall time and its 30-second watchdog included roughly 239 seconds of suspension.
Do not suspend a live user session for benchmark isolation. Use independent test
profiles and coordinate test ownership before restarting a test window.


Historical validation failure (before the registry fix below): selective residency had NOT passed. The user reported
stretched terrain triangles and colored rectangular artifacts after jumping from
the cave into the sky-island scene. Captures: `selective-artifact.png` and
`conservative-geometry.png` in the external evidence directory. Disabling the
render stream in that process restored full declarations for subsequent passes,
but did not remove all artifacts. A restart with the experiment disabled returned
to the cave autosave with no visible artifacts there; this does not validate the
sky-island scene or establish selective residency as the sole cause. These pre-fix frame-rate measurements were not accepted. The experiment remains default-off pending broader validation.
The test profile was backed up before restart; the user profile was not modified.


### Buffer address registry overflow (confirmed, 2026-11-14)

The Metal 3 registry used a fixed 1024-entry array and silently ignored additional
buffers. The sky-island artifact log contains a failed GPU address lookup at
vertex slot 16. `buffer_registry.m` reproduces failure at index 1024 against the
old implementation. The registry now doubles its capacity, reports growth, rejects
duplicate registration, and fails explicitly if allocation fails. Lookup and
retirement locking remain unchanged. The new regression passes 4097 logical
buffers with boundaries, removals and re-adds. With `--gpu` and Metal API Validation,
a real compute dispatch binds the 1050th GPU buffer via M3ArgTable and reads back
42. The full runtime builds successfully. This establishes a real defect and its unit-level fix. The subsequent sky-island replay is recorded below; the 40 FPS goal remains unmet.
Evidence: `registry-validation.log`, `registry-gpu-validation.log`, and
`registry-build.log` in the external compatibility evidence directory.


### Post-fix sky-island replay and submission cost (2026-11-14)

The player entered the sky-island scene with the growing registry. Capacity
grew from 1024 to 2048. No failed address binding was logged, and sampled images
did not show the previous stretched geometry (`registry-island-entered.png`).
This validates the sampled transition, not every game location.

A live crossover with selective textures off/on/off measured frame medians
82.90 / 39.18 / 78.32 ms, with GPU medians 74.47 / 33.17 / 70.67 ms.
The player could move during this test; it is observational, not identical-frame
benchmarking. Full buffer declarations remained enabled. Selective buffer access
permissions improved only about 1 FPS and remain disabled in the active test.

Per-pass resource declaration deduplication preserves stage and permission
escalation. Its regression covers duplicate, write, stage, pass, collisions, and
saturation fallback. The Makefile now defines header dependencies before the
Metal 3 object rule, ensuring header edits actually rebuild those objects.

CPU sampling then identified repeated `conformsToProtocol:` calls in
`rs_use_indirect_resource`. Shader reflection already distinguishes samplers,
textures and buffers. The helper now accepts `id<MTLResource>` directly; the
sampler branch keeps diagnostics but sends no resource packet. Resource ownership
and declaration permissions are unchanged. Evidence lives outside the checkout in
`metal3-compat-check/compat-profile`: `cache-cpu-sample.txt`,
`typed-resource-build.log`, `typed-cpu-sample.txt`, and `typed-test-results.log`.
These builds run from the external workspace; the installed app has not yet
been replaced. Do not report these experimental settings as deployed defaults.


### Stage-boundary GPU measurements and compute residency experiment

`DM_NVN_PASSGPU` is restored on Metal 3: render-pass attachments record vertex
and fragment boundaries, compute descriptors are passed through, and the final
command buffer resolves the submission's samples. A per-ring semaphore prevents
sample-buffer reuse until its completion callback finishes, independently of the
normal game fence. The TSV also includes all four raw render-stage timestamps.
The render worker and mid-submission commits stay enabled. Compute encoder reuse
is disabled while profiling so each dispatch has its own interval.

A 622-frame stationary sample after loading measured medians: 129 passes,
4433.5 draws, 26.05 ms first-to-last GPU stage span, 4.32 ms vertex interval union,
10.02 ms fragment union, 0.65 ms compute union, 15.06 ms union of all stages.
Intervals include stalls, and gaps can include unsampled blits or driver work;
these are not hardware utilization counters. Never add overlapping stage spans.
Evidence: `pass-counter.tsv`, `pass-counter-timeline.tsv`, and `bottleneck.html`.

`flag m3_selective_compute 1` is an experimental default-off path. Only reflected
game compute dispatches opt in. The encoder retains full global buffer residency,
while each actual indirect texture is declared with its reflected read/write
usage. Built-in and helper kernels retain their conservative path. The experiment
uses a separate encoder per dispatch to avoid marking a shared helper encoder.
`selective_compute.m` validates a four-dispatch indirect texture write/read chain
(result 45 from 41) and nonzero ordered stage timestamps, with Metal API Validation.
Performance and gameplay acceptance require the ongoing crossover and a separate
profiling-disabled movement test. No reduction in output resolution is permitted.


Dynamic survey update: four 20-second movement/camera groups were executed at
2048x1152. Fully contained 300-frame windows measured 30.8 FPS running forward,
30.2 FPS rotating right, and 25.6 FPS walking/turning together. The last group
had no fully contained 300-frame window, so no median FPS is assigned to it.
The raw per-frame hitch trace remains available for all four groups. Frame 7433
was 306.9 ms with 263.1 ms of shader/library and pipeline creation; frames 7549
and 7553 exceeded one second with concentrated compilation. This is distinct
from sustained GPU-limited performance. The test launchers had explicitly set
`DM_PSO_MANIFEST=off` to shorten diagnostic restarts. Restore automatic full
warm-up before judging cache reuse or final gameplay stutter. This diagnostic
setting must not be deployed as a performance default.

The compute residency crossover measured approximately 31 ms off/on/off and did
not establish a meaningful gain. It remains default-off. The gameplay survey
used the conservative compute path. Evidence: `compute-ab-results.log`,
`movement-results.json`, `movement-hitches.json`, and `movement-report.html`.


### Precise streamed-render buffer scope (default off)

`flag m3_selective_buffers 2` tests omission of global buffer declarations on
streamed render encoders only. Mode 0 retains global read/write declarations;
mode 1 retains global read declarations. All modes still declare actual indirect
resources with their stage and access permissions. Direct Metal bindings are
tracked by Metal. Inline uniform updates, uniform snapshots, and patched matrices
now explicitly declare the allocation containing the GPU address actually bound,
in addition to the original pool. Driver bank storage pools are conservative RW.
An unresolved GPU address queues a per-pass fallback to global buffer residency.
This mode is latched when the worker opens the encoder, not changed mid-pass by
the control thread. Compute and helper encoders keep their original declarations.

The real GPU buffer regression passes mode 2 with atomic writes and a final
conservative fallback, under Metal API Validation (`buffer-scope-validation.log`).
A synthetic 1200-unused-buffer test did not show a repeatable large GPU gain;
acceptance requires the game crossover and moving-scene replay. No performance
claim is made for mode 2 yet. Full builds: `buffer-scope-final-build.log`.


### Kernel submission cost and precise declarations (2026-11-14, default on)

CPU samples during user-controlled movement showed about 64% of wall time inside
`IOGPUCommandQueueSubmitCommandBuffers` on the Metal command-queue dispatch thread.
A standalone benchmark (120 tiny passes in one command buffer) measured the kernel
submission growing with declared entries per pass: none 0.75 ms, 1000 read entries
9.5 ms, 1000 read/write entries 17–19 ms. Texture views of one base texture did not
show this cost.

`TOTK_M3_DECL_STATS=1` attributes global declarations to call sites every ten
seconds. With streamed passes already precise, the remaining load was about 30
compute encoders per frame (`pg_compute`), the cube copy kernel and the present
pass, each declaring all ~2650 resident resources: roughly 90,000 entries per frame.

Changes, each with an opt-out:

- `m3_selective_compute 2` (`TOTK_M3_SELECTIVE_COMPUTE`, default 2): reflected game
  dispatches declare their actual indirect textures and buffers, including inline
  update / snapshot allocations and storage pools reachable through driver bank 0.
  An unresolved buffer address makes that one encoder fall back to the full
  declaration. Helper kernels bind only through direct Metal slots and declare
  nothing extra.
- Streamed-pass textures (`TOTK_M3_SELECTIVE_TEXTURES`, `0` disables), streamed-pass
  buffers (`TOTK_M3_SELECTIVE_BUFFERS`, default 2), upload and present encoders
  (`TOTK_M3_UPLOAD_DIRECT`, `TOTK_M3_PRESENT_DIRECT`, `0` disables) now default on.
  `TOTK_ARG_BIND_CACHE` defaults on for Metal 3, matching the measured configuration.

Stationary A/B/A/B in one process at 2048×1152 (35 s phases, 300-frame windows):
frame median 25.28 / 19.76 / 25.26 / 20.20 ms, GPU span 21.2 / 17.7 / 21.3 / 18.2 ms.
User-controlled movement afterwards: window medians 18–22 ms (median 20.0 ms, worst
window 22.4 ms) against 29–36 ms before. These are observational, not identical-frame
runs. Sampled images showed no artifacts; this does not validate every location.

### WriteTexels region writes (2026-11-14)

`TOTK_HITCH_WATCH=<ms>` logs the presenting thread's stack (and one snapshot of the
other threads) when the gap since the last present exceeds the threshold. The
100–200 ms frames that render timing could not explain had the game thread waiting
in `runtime_core_back` after `nvnQueueSubmitCommands`, while another guest thread
held the core inside `mtl_write_texels`: each call converted the whole level of a
16 MiB mirrored texture to linear and back to patch one rectangle.

`nvn_swizzle_region` now writes only the rectangle into block-linear or pitch
storage (`TOTK_WRITE_TEXELS_FULL=1` restores the round trip). A randomized
comparison against the round trip passed 3000 cases byte for byte (formats, 2D / 3D /
array targets, mip levels, linear layouts). On a 2048×2048 four-byte texture the
round trip took 10.1 ms and a 64×64 region 0.005 ms. During user-controlled
movement, frames of 50 ms or more in this class fell from 23 in about 7,500 frames
to 1 in about 10,200 frames. The comparison is `tests/test_write_texels_region.py`.

### First-use shaders off the submit thread (2026-11-14, default on)

After the two changes above, every remaining frame of 100 ms or more during play was
first-use work on the submit thread: `newLibraryWithSource` for a shader variant new
to this run (about two thirds of the stalled samples, much of it inside pipeline
prediction, which loaded the predicted shaders one after another), synchronous
`newRenderPipelineState`, and the translation service round trip for a variant new to
this machine.

`TOTK_ASYNC_SHADERS` (default on, `0` restores the synchronous behaviour):

- A shader not yet loaded is compiled on a background queue (`shader_get_async`); a
  variant not yet translated is translated on a serial background queue with the guest
  bytes copied (`rt_variant_async`). The variant index lock is no longer held across
  the translation service round trip.
- In passes with a depth attachment (scene and shadow geometry) the draws that need
  it are skipped until it is ready, as are draws whose pipeline is still compiling.
  The geometry appears a few frames late.
- Passes without depth (post-processing, UI) wait for the background result instead,
  so a full-screen pass is never dropped. Pipeline prediction only requests.

User-controlled runs of about 9,600 gameplay frames each: with synchronous
compilation, 11 frames of 50 ms or more were compilation, the worst 517 ms. With
background compilation and 81 new shaders in the run, the worst frame was 284 ms and
the remaining stalls were the synchronous translation. With background translation as
well, the run recorded no compilation or translation stall; it met only one new
shader, so that case needs more new-area play before it counts as covered. Skipped
draws can leave transient holes; no other artifact was observed in these runs.

Not caused by these changes: the Great Sky Island pond draws a sheet of water over
the bank beside the fence. The binary from before this work shows the same picture
at the same place (`wbase-water.png` against `wfull-water.png`).

Evidence: `metal3-compat-check/compat-profile/` (`precise1.log`, `hitch1.log`,
`hitch2.log`, `final1.log`, `async1.log`, `async2.log`, `restart-opt.py`, `opt-ab.py`).
