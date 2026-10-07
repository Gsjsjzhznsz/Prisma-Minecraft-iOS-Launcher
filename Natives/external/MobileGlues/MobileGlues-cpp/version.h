// MobileGlues - version.h
// Copyright (c) 2025-2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v2.1:
//   https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt
// SPDX-License-Identifier: LGPL-2.1-only
// End of Source File Header

#ifndef MOBILEGLUES_VERSION_H

#define VERSION_DEVELOPMENT 0
#define VERSION_ALPHA 1
#define VERSION_BETA 2
#define VERSION_RC 3
#define VERSION_RELEASE 10

#define MAJOR 2
#define MINOR 0
// 0 -> 1: force-invalidate the on-disk GLSL conversion cache. The 2.0.0 builds
// that shipped with a mis-populated 3rdparty/ tree cached ESSL that ANGLE-Metal
// rejects with "ERROR: 1:1: '' : syntax error"; the cache key embeds
// MAJOR.MINOR.REVISION, so this bump makes every device discard those entries
// on first run instead of re-serving them.
// 1 -> 2: iOS host-driver binding rework (explicit ANGLE dlopen instead of the
// RTLD_DEFAULT free-for-all) + per-shader submit/readback records. The bump
// invalidates cached conversion results once more and, more importantly, makes
// "MobileGlues 2.0.2" visible in the runtime log so a stale dylib in the IPA
// is instantly obvious.
// 2 -> 3: mg_init_gles() now pins the GL ES table to the REAL ANGLE libGLESv2
// instead of libtinygl4angle, whose glShaderSource does not forward into
// ANGLE's object namespace (every pipeline died with "ERROR: 1:1: ''" and a
// zero-byte driver readback). Shader conversions now ALWAYS run on the
// dedicated 32 MB-stack thread (the >= 8 MB inline fast path depended on the
// caller's stack-size report and could still overflow inside glslang).
// 3 -> 4: process_sampler_buffer() rewrote texelFetch argument lists with a
// [^)]+? regex that truncated at the first ')', shredding any coordinate with
// nested calls. Sodium 0.9.x's
//     texelFetch(u_SectionTimeInfo, int((u_RegionID * 256u) + uint(chunkId)))
// became 'temp uint % uniform int' garbage -> glslang parse failure -> every
// Sodium terrain pipeline invalid -> no blocks rendered. Rewritten with a
// paren-depth scanner; coordinates now also pass through int(...) so
// driver-lenient uint indices cannot re-mix sign with u_BufferTexWidth.
// REVISION 6: stage-tagged SIGSEGV crash-site report + optimizer-disabled
// retry on the conversion thread.
// REVISION 7: buffer-texture emulation runtime repair. (1) Draw-time sampler
// rewiring now repoints ONLY the samplers converted from samplerBuffer at the
// emulation unit; it used to repoint every sampler2D in the program, which on
// Sodium 0.9's chunk program hijacked the block atlas (u_BlockTex) and light
// map (u_LightTex) onto the section-info texture -- every chunk fragment then
// discarded itself below ALPHA_CUTOUT and the whole terrain vanished
// (MobileGlues-release issue #432). (2) The snapshot is refreshed whenever the
// backing buffer is mutated (glBufferData/glBufferSubData/glUnmapBuffer/
// glBufferStorage); it used to be taken exactly once at glTexBuffer. (3) The
// GL_TEXTURE_BUFFER binding point no longer reaches an ES 3.0/3.1 driver (it
// answered GL_INVALID_ENUM there, silently swallowing every mutation MC issued
// through that target); it is tracked here and the mutations borrow
// GL_COPY_WRITE_BUFFER instead.
// REVISION 8: glslang emission-side swizzle null guards. Device log 2.0.7:
// 264 conversions SIGSEGV'd at ONE site -- (anon)::TGlslangToSpvTraverser::
// convertSwizzle+0x1c via visitBinary+0x1318 (symbolicated from the crash-site
// report, pc-libmobileglues+0x24a838) -- the selector aggregate read as
// missing/malformed on iOS/arm64 for inputs that convert cleanly under
// x86_64/qemu-arm64/ASan and converted fine in the 2.0.6 process. Same defect
// family as the 2.0.1-2.0.3 lValueErrorCheck kill, one stage later. The
// nullguard patch now covers SPIRV/GlslangToSpv.cpp: convertSwizzle returns
// bool and rejects unusable selectors (null/non-constant element, out-of-range
// index) instead of dereferencing them, and both call sites (visitBinary
// EOpVectorSwizzle, createInvertedSwizzle) fall back to the identity swizzle
// of the result's component count. Byte-identical output vs pristine glslang
// on all swizzle-heavy positive tests and every edge-case candidate.
// REVISION 9: MC 26.x transparency-pipeline depth-path hardening + device
// diagnostics. The game's clouds/weather/particles are composited by
// post/transparency.fsh, which per-pixel-sorts six layers (main + five
// dedicated FBOs, each with its own D32F depth texture) and blends far to
// near. If any depth texture reads garbage the sort degenerates to insertion
// order and the last layer -- clouds -- draws over everything, including from
// underground. A locally built libmobileglues (Linux) replaying the exact
// blaze3d call sequence against a conformant ES 3.0 driver (Mesa llvmpipe)
// passes every hop end to end: D32F allocation, D32F sampling, reversed-Z
// draw, copyDepthFrom's depth-only glBlitFramebuffer (byte-exact), composite
// sort. So the on-device breakage is a per-driver divergence this layer must
// flatten. Two changes: (1) glFramebufferTexture2D redirects depth-ONLY
// textures attached at GL_DEPTH_STENCIL_ATTACHMENT to GL_DEPTH_ATTACHMENT and
// detaches the stencil point. blaze3d's fallback DirectStateAccess attaches
// every depth texture at the combined point; strict drivers (Mesa, measured)
// answer FRAMEBUFFER_INCOMPLETE_ATTACHMENT for a depth-only image there, and
// the lenient drivers that accept it are left with a stencil attachment
// pointing at a stencil-less image. (2) One-shot W_FORCE diagnostics on the
// first depth-texture allocation (driver-reported internalformat/depth/
// stencil bits), the first combined-point depth+stencil attach (driver
// completeness verdict), the first DEPTH blit (both FBOs' completeness +
// error verdict), and the first draw of the composite program (all twelve
// sampler uniforms with unit, texture name and internalformat). Together
// these grade every hop the composite depends on directly from a device log.
// REVISION 10: 2.0.9 device log results -- the depth blit (copyDepthFrom) is
// healthy on device (both FBOs complete, GL_NO_ERROR), but the combined-point
// redirect never fired AND the composite sampler dump never fired. Two
// corrections and one new probe. (1) Constant correction: 36096 is
// GL_DEPTH_ATTACHMENT, not GL_DEPTH_STENCIL_ATTACHMENT -- MC attaches depth
// directly at GL_DEPTH_ATTACHMENT and the 2.0.9 combined-point redirect is
// dead code for this application (kept for spec hygiene). The attach
// diagnostic now grades the FIRST EIGHT depth-family attaches at whichever
// point they actually use, with the registry's view of each texture. (2) The
// depth-allocation probe read GL_TEXTURE_INTERNAL_FORMAT, which is not an
// ES 3.0 pname (ANGLE rejects it; Mesa tolerates it), so its zeros were
// ambiguous. Rewritten to separate the three confounded things per
// allocation: the shadow's texture, the DRIVER's texture on the active unit,
// the upload's own error, and GL_TEXTURE_DEPTH_SIZE of what the driver
// actually has. (3) The composite dump never fired because nothing verified
// the composite draws reach this layer's glDrawArrays at all; a 24-draw
// census plus a depth-sampler dump keyed on any program with a "Depth"-named
// sampler2D now grades reachability and the composite's inputs together.
// (4) One-shot symbol-theft check in glXGetProcAddress: the app-facing proc
// addresses come from dlsym(RTLD_DEFAULT), whose flat namespace also holds
// the host ANGLE libGLESv2; if dyld's image order ever lets ANGLE win a name
// this layer exports, the application bypasses this layer for that function
// entirely.
// REVISION 11: 2.0.10 device log results + the real reason the composite was
// never observed. The log graded three things: depth allocations healthy
// (shadow == driver binding, upload clean), depth blit healthy (both FBOs
// complete, GL_NO_ERROR), no symbol theft -- and the draw census answered a
// question nobody had asked: every one of the first 24 programs was first
// seen on "other draw", meaning MC 26.2 never issues plain glDrawArrays or
// glDrawElements at all. Disassembling the shipped client.jar's
// GlCommandEncoder.drawFromBuffers confirms it: the non-indexed branch is
// glDrawArraysInstanced / glDrawArraysInstancedBaseInstance, the indexed one
// glDrawElementsInstancedBaseVertex(_BaseInstance) -- there is NO plain
// glDrawArrays branch, so the transparency composite (a 3-vertex, 1-instance
// non-indexed draw) sailed through the glDrawArraysInstanced native
// passthrough without ever reaching prepareForDraw: no TBO sampler rewiring
// for any instanced draw, and no diagnostic could ever see the composite's
// inputs. (1) glDrawArraysInstanced moved from the native table into
// gl/drawing.cpp behind prepareForDraw(3); glDrawArraysInstancedBaseInstance
// now tags prepareForDraw(4); the ARB alias the NATIVE_FUNCTION_HEAD macro
// used to emit is kept. (2) The depth-family attach census turned out to
// query glCheckFramebufferStatus BEFORE the forward -- its odd 0x8cd7 rows
// measured the pre-attach emptiness of fresh temp fbos, not driver verdicts;
// it now runs after the forward and records the attach error plus the
// color0/depth attachment object names. (3) The depth blit gets a content
// probe: for the first two DEPTH blits, five depth texels are read back from
// both sides and logged -- NO_ERROR says the driver accepted the copy, only
// the values say the data moved. (4) The depth-sampler program dump (now
// reachable through the instanced hooks) grades per sampler: unit, shadow and
// driver texture, registry internal format, the texture's own MIN/MAG filter,
// and any bound sampler object's MIN/MAG filter -- sampling depth with a
// LINEAR filter is the classic silent killer on strict ES drivers (an
// unfilterable depth texture reads black, which in reversed-z is "infinitely
// far" and un-occludes everything), and the draw fbo's color0/depth
// attachments are logged with it.
// REVISION 12: 2.0.11 device log results + the root cause of the transparency
// occlusion break (clouds visible through terrain, underground clouds, water/
// particles/weather sorting against nothing). The log closed the case with the
// depth-sampler dump: the composite program's twelve sampler2D uniforms all
// have one SamplerCache sampler object bound over them whose MIN filter is
// GL_LINEAR_MIPMAP_NEAREST (9986) -- with the dump's 9728/9729 labels fixed,
// its MAG is GL_NEAREST, and the "LINEAR" the 2.0.11 log printed for MIN was
// the value 9986, not a NEAREST/linear mistake on MC's part. 9986 is what
// Mojang's GlSampler deliberately emits for minFilter=NEAREST (LINEAR goes to
// 9987), kept pointed at level 0 by TEXTURE_MAX_LEVEL=0 on the texture and the
// sampler's own MAX_LOD=0. The within-level part of 9986 is a LINEAR sample,
// and GLES 3.0 does not filter depth images (desktop GL does, which is why the
// same state renders fine on PC): on ANGLE Metal the composite's depth samples
// are undefined and read 0.0, which in reversed-z is "infinitely far", so
// every layer-vs-layer sort degenerates and the last-blended clouds layer
// wins over everything. The dump's own filter table had GL_NEAREST/GL_LINEAR
// swapped, which is why 2.0.11's log reads as MAG=LINEAR at first glance --
// fixed here so the next log is readable. The fix, desktop semantics on ES:
// (1) every depth-family allocation (TexImage2D/3D, TexStorage2D/3D) joins a
// depth registry and gets MIN/MAG = NEAREST on the texture object itself;
// (2) glTexParameteri/glTexParameterf aimed at a registered depth texture
// cannot set anything but NEAREST for MIN/MAG; (3) the sampler objects are
// now tracked (glGenSamplers/glDeleteSamplers/glBindSampler/glSamplerParameteri/
// glSamplerParameterf moved from the native table into gl/texture.cpp, ARB
// aliases kept), and prepareForDraw forces a bound sampler's driver-side
// MIN/MAG to NEAREST exactly while any unit it is bound on holds a depth
// image, restoring the application's parameters on the first draw where the
// pairing no longer holds (two-pass per draw so one cache sampler shared by a
// colour and a depth unit in the same composite draw converges on forced);
// comparison-mode samplers are left alone so hardware PCF is untouched; the
// enforcement is skipped while FSR1 makes the per-unit binding shadow
// untrustworthy. Retired diagnostics that had answered their questions: the
// 24-program draw census, the depth-family attach census, and the depth blit
// content probe (ANGLE Metal refuses every depth glReadPixels with
// GL_INVALID_OPERATION, so a probe can only report its own refusal). The
// depth-sampler program dump stays, with the corrected filter names, and the
// force/restore transitions log their first eight occurrences.
// REVISION 13: 2.0.12 device log results + why the depth-filter enforcement
// never armed where it was needed. The log shows deployment healthy, the
// composite dump firing (program 197, twelve sampler2D inputs, one SamplerCache
// sampler 26 bound across all of them, MIN 9986, six D32F depth textures whose
// texture-object filters read NEAREST/NEAREST from fix (1)) -- and not one
// "depth filter force" line. The enforcement's precondition,
// driver_texture_shadow_trustworthy(), is false on the iOS/ANGLE host for a
// reason nothing had exercised before: the app talks to ANGLE's libEGL
// directly, so mg_texture_bind_context never fires and the texture layer sits
// on the shared fallback record forever -- the same precondition the TBO
// rewiring survives by falling back to a direct driver query, which the
// enforcement lacked. (The dump's "tex 0/9" rows are this gate refusing to
// answer, not an empty binding map.) Fix: two modes in
// mg_enforce_depth_sampling_nearest. Tracked mode is 2.0.12 unchanged. The
// untracked mode treats the fallback record as a HINT -- every hooked bind
// still maintains it, and the decompiled GlCommandEncoder shows MC 26.2 binds
// textures exclusively through _activeTexture/_bindTexture/glBindSampler, all
// hooked -- and confirms every depth hint against the driver
// (glActiveTexture + GL_TEXTURE_BINDING_2D, borrowed and restored via the
// GLES entry points directly) before a filter may be forced. A stale hint
// costs a rejected confirmation; acting on the record alone is what the
// layer's invariant forbids. FSR1 keeps enforcement off entirely, as before:
// its binding leak is silent, so neither a record nor a confirm can see it.
// One line logs once when the untracked scan arms, so the next device log
// can distinguish "armed and confirming" from "never ran".
// REVISION 14: 2.0.13 verified on device (armed line + force/restore pairs +
// occlusion restored in play), and a self-correction the verification pass
// uncovered. The filter labels this layer printed since 2.0.12 -- and the
// gl.h definitions behind them -- were themselves wrong: the Khronos
// registry (and Mesa's and ANGLE's headers, all cross-checked) define
// 0x2701 = GL_LINEAR_MIPMAP_NEAREST and 0x2702 = GL_NEAREST_MIPMAP_LINEAR,
// so 2.0.12's "corrected" gl.h had in fact inverted a correct header, and
// Mojang's GlSampler maps minFilter=NEAREST to 9986 = GL_NEAREST_MIPMAP_
// LINEAR (nearest within a level, blended across levels, clipped to one
// level by MAX_LOD=0) -- not GL_LINEAR_MIPMAP_NEAREST. The mechanism
// narrative is relabelled accordingly and gets tighter: GLES 3.0 keeps a
// depth-family texture filter-complete only while MIN_FILTER is NEAREST or
// NEAREST_MIPMAP_NEAREST, so the MIPMAP_LINEAR family alone is enough to
// make every D32F image under that sampler read incomplete (0.0 on ANGLE
// Metal, "infinitely far" in reversed-z). No behavioural change to the
// enforcement itself: the force still writes plain NEAREST, and the
// decision paths only ever compared against GL_NEAREST. Fixed here: the
// gl.h pair, the dump's filter_name table (9985/9986 labels), the sampler
// record's GLES-default MIN (9986, not 9985 -- the restore write-back for a
// never-parameterised sampler used to hand back LINEAR_MIPMAP_NEAREST
// instead of the default), and the rationale comments in gl/texture.{h,cpp}.
// REVISION 15: the MC 26.3 SDL3 host turned the 2.0.10 theft canary from a
// hypothetical into the actual failure. 26.3's renderpearl GlBackend.loadLibrary
// cross-checks its two GL entry points: the LWJGL function provider (built on
// this layer's exported glXGetProcAddress) must return the SAME address for
// "glGetError" as SDL_GL_GetProcAddress (hooked by the host to dlsym this
// layer's handle). glXGetProcAddress resolved names through the process-wide
// flat namespace (RTLD_DEFAULT), where this layer and the host's ANGLE
// libGLESv2 both export every gl* name and dyld image order decides the
// winner. In the 26.3 path ANGLE loads first, the LWJGL side bound ANGLE's
// GLES exports, the SDL side bound this layer's exports, the pointer check
// failed ("glGetError mismatch"), the OpenGL backend was rejected and the
// game fell back to MoltenVK (which then died in shaderc's unpatched glslang).
// Fixed by resolving from this layer's own image first (RTLD_SELF: the
// calling image, then its dependents), so this layer's exports win regardless
// of image order; RTLD_DEFAULT remains the fallback for names this layer does
// not export. The flat-namespace canary stays as environment diagnostics --
// resolution no longer depends on what it reports.
// REVISION 16: 2.0.15's RTLD_SELF did not survive contact with the device --
// the 3c13d5e5 build still reported "glGetError mismatch" and fell back to
// MoltenVK. Root cause of the trap: dyld derives the "caller image" of the
// special handles (RTLD_SELF/RTLD_NEXT) from __builtin_return_address(0), and
// the host launcher rebinding dlsym process-wide (fishhook) redirects every
// dlsym issued from this layer through host code, so the "caller" dyld saw was
// the host binary, not this layer -- RTLD_SELF searched the host's dependency
// subtree and the outcome depended on where the dlopen'd renderers sit in it.
// Fixed by dropping special handles entirely: glXGetProcAddress now resolves
// through a handle to THIS image (dladdr on an own function + dlopen
// RTLD_NOLOAD, which can never map a duplicate) and falls back to
// RTLD_DEFAULT only for names this layer does not export. Handle-based dlsym
// has no caller-image ambiguity, so this layer's exports win for every name
// it implements, independent of image order and of who is calling. One-time
// W_FORCE line reports the resolved own-image path for device-log verification.
// REVISION 17: Amethyst Task 32 -- two ESSL-output bugs that surfaced once the
// Task 30/31 lifecycle locks stopped the SIGSEGV (build a09e020 ran all 390
// shaderc compiles with zero native crashes, revealing what the crash used to
// hide). (1) process_uniform_declarations() matched the "uniform" keyword as
// a raw substring, so RenderPearl's _uniform_instance_00_XX block-instance
// identifiers triggered a bogus has_initializer rewrite that destroyed the
// enclosing statement -- every core pipeline fragment failed in ANGLE with
// "'_uniform' : undeclared identifier" + "'_instance_00_XX' : syntax error".
// Now token-guarded on both sides. (2) Minecraft 26.x OIT shaders index
// fragment-output arrays (coeff[attachmentIndex][i]) with loop variables,
// which ESSL 300 rejects outright; the converter now routes those accesses
// through a scratch array and copies out with constant indices at the end of
// main(). This bump also force-invalidates the on-disk conversion cache:
// entries written by <= 2.0.16 embed the corrupted ESSL and would keep being
// re-served for identical sources. "MobileGlues 2.0.17" in the runtime
// Graphics Drivers line identifies the fixed build on device.
//
// REVISION 17 addendum (Amethyst Task 81, no bump): gl/texture.cpp's depth-
// sampling filter enforcement no longer switches itself off while FSR1 is
// engaged. The kill-switch dated from the era when FSR1's GLStateGuard leaked
// the render texture onto unit 0 once per presented frame (no shadow recorded
// it, so a stale hint could have flipped a colour sampler) AND fsr1Setting
// never engaged on iOS at all (its config was never read), so the switch cost
// nothing. Two changes invalidated each half: the guard now saves and restores
// unit 0's own binding (nets to zero), and the launcher passes fsr1Setting
// through -- so the first device session with FSR1 on (build 678e7b5) ran with
// the enforcement silently dead: the composite's sampler 26 kept MIN 9986 over
// six D32F units, every depth sample read 0.0 ("infinitely far" in reversed-z),
// and clouds/weather/particles/item entities rendered through terrain -- the
// exact symptom the enforcement was built to cure, back as an FSR1 side effect.
// Enforcement now always runs, and every depth hint is driver-confirmed while
// FSR1 is on (the untracked mode's borrow-and-restore, extended to tracked
// contexts for the duration). REVISION deliberately NOT bumped: the conversion
// cache key embeds MAJOR.MINOR.REVISION and no converter output changed, so a
// bump would only burn the on-disk cache (~400 entries) for nothing. The
// one-shot "[MG] depth filter scan: FSR1 active (Task 81)" log line identifies
// the fixed build on device, alongside the returning force/restore pairs.
// REVISION 17 addendum (Task 82): the glViewport render-size latch now refuses
// viewports that are not window-shaped -- larger than the EGL surface in either
// axis, or off the surface's aspect ratio by more than 3%. MC 26.x's animated
// atlas pass drives glViewport at the full blocks-atlas size (2048x2048 on a
// 2360x1640 surface), which the grow-only latch adopted as the render size and
// then could never drop: the upscale stretched the mostly-unwritten 2048x2048
// render texture over the whole surface and the game appeared shrunk into the
// bottom-left corner (ea27def). No converter output changed, so REVISION stays
// 17 -- the one-shot "[MG] FSR1 viewport latch rejected (Task 82)" line (plus
// the engage log now naming 1814x1262 instead of 2048x2048) identifies the
// fixed build on device.
// REVISION 17 addendum (Task 83, no bump): ApplyFSR now draws EASU straight
// into the surface when the target equals it (the common launcher case after
// the new <=4px rounding clamp), replacing the old clear + draw + blit triple
// with a single fullscreen pass; the resolution-slider-stacked sub-surface
// path keeps the blit. No converter output changed, so REVISION stays 17 --
// the steady-state per-frame cost drop is identified on device by the absence
// of the previously-per-frame target-FBO clear, with the engage log line
// unchanged from Task 82.
// REVISION 17 addendum (Task 84, no bump): FSRShaderSource.h now carries a
// manual packHalf2x16 / unpackHalf2x16 fallback under __VERSION__ < 420 --
// the builtins are GLSL 4.20 core and the zink/MoltenVK path caps at GLSL
// 4.10, where the EASU fragment compile previously died at the first packing
// helper (75c5e14 device log). The fallback is bit-exact against numpy
// float16 (RNE, subnormals, Inf/NaN) and preprocessed out entirely on 4.20+
// contexts, so no converter output changed and REVISION stays 17. The fixed
// build identifies itself on device by the zink engage line now appearing
// after "Task83b FSR shader #version adapted: 450 -> 410" instead of the
// "no function with name packHalf2x16" compile failure.
// REVISION 17 addendum (Task 85, no bump): the zink-side EASU pass in
// osm_bridge.mm now runs BEFORE the glFinish that triggers OSMesa's
// GPU-to-CPU readback, instead of after it. The Task 83 ordering drew the
// upscaled frame into the GPU-side image only after the client buffer had
// already been read back, so the displayed CGImage never contained the
// upscale result: the bottom-left window region showed the raw low-res
// frame while the rest showed the previous frame's EASU output -- the
// on-device "split picture". The pass additionally pins the default
// framebuffer (saving/restoring draw and read FBO bindings) and disables
// stencil test, making it hermetic against any FBO state a mod leaves
// bound at swap. Purely launcher-side presentation code, no converter
// output changed, so REVISION stays 17. The fixed build identifies itself
// on device by the zink engage line now ending in "(EASU pre-readback
// ordering, Task 85)".
// REVISION 17 addendum (Task 86, no bump): Tools.java (launcher.jar) now arms a
// launch watchdog daemon thread right before invoking Minecraft main. On-device
// evidence (BMC2 [FABRIC] 1.20.1, 537 mods, zink): the game main thread hard-
// blocked inside a Fabric client entrypoint ~5.6s after JVM start -- zero GC,
// zero JIT installs, zero log lines for 187s until the user cancelled, launch
// overlay stuck ("stuck on the loading screen"). The watchdog samples the game
// thread's stack every 15s during the entrypoint phase (compacting repeats to
// one heartbeat line) and, after the thread renames to "Render thread", runs a
// 30s freeze detector on the top stack frames. Log lines are prefixed with
// "[LaunchWatchdog] Task86" and name the blocking mod's class directly, turning
// the next reproduction into a one-read diagnosis. Launcher-side Java only;
// no MobileGlues converter surface touched, so REVISION stays 17.
// REVISION 17 addendum (Task 87, no bump): the watchdog paid off -- the 7b88b69
// log pair named the modpack stall AND exposed an LTW capability gap. (1) The
// 537-mod BMC2 stall is toni.missingmodschecker.MissingModsWindow.open's
// Object.wait(): a desktop utility mod popping a Swing dialog over missing
// (recommends-level) dependencies; the window can never be shown on iOS, so
// the game thread waited forever. JavaLauncher.m now auto-disables evidenced
// desktop-dialog mods before the JVM starts ([ModDialogGuard] Task87, rename
// to .jar.disabled -- Fabric ignores non-.jar files), and the watchdog logs a
// one-shot STARTUP BLOCK hint when it sees AWT/Swing frames or Object.wait
// held directly under mod code (the post-construction wait carries no AWT
// frames, so the detector matches the wait pattern itself). (2) The same log
// pair's LTW session crashed at 11.8s in the title-screen resource reload:
// MC 26.x's clouds pipeline (minecraft:core/rendertype_clouds) uses
// samplerBuffer under the desktop GL 3.3 profile LTW advertises, but LTW's
// iOS backend is Apple's system ANGLE GLES 3.0 (no GL_EXT_texture_buffer) and
// LTW has no TBO emulation layer -- "samplerBuffer: Illegal use of reserved
// word" kills pipeline/flat_clouds and the reload aborts. SurfaceViewController
// now gates LTW x MC >= 26 before launch with a dialog pointing at Zink or
// MobileGlues (this layer's own TBO emulation, REVISION 7+, is why MG runs
// 26.x unharmed). Launcher-side only; no MobileGlues converter surface
// touched, so REVISION stays 17.
// REVISION 17 addendum (Task 94, no bump): the 809b847 log pair (commit 3bc95fa
// build, both zink and LTW sessions of the 537-mod BMC2 pack on 1.20.1)
// proved the Task87 fixes engaged -- [ModDialogGuard] disabled
// missingmodschecker.jar and startup sailed past the old stall -- and then
// died at the SAME spot in BOTH renderers ~4s after JVM start: Sodium
// 0.5.13's PreLaunchChecks gate, which requires
// org.lwjgl.Version.getVersion().startsWith("3.3.1") for MC 1.20.1 and calls
// System.exit(1) otherwise ("Installed version: 3.4.1 / Required version:
// 3.3.1"). The launcher's JavaApp overlay Version.java/VersionImpl.java had
// hardcoded the reported version to "3.4.1" (added for Sodium 0.9+ on 26.x,
// which requires the 3.4.1 prefix), so every 1.18-1.20.x modpack with sodium
// 0.4+/0.5+ was rejected. The overlay now reports dynamically: Tools.java's
// preProcessLibraries captures "org.lwjgl:lwjgl:<ver>" from the instance's
// version.json (the same value Mojang paired with that MC version, which is
// exactly what sodium's REQUIRED constant derives from) into the
// org.lwjgl.version.report system property, and Version.getVersion() reads it
// live (fallback: -Dpojav.lwjgl.version=341 -> "3.4.1", otherwise "3.3.1").
// Bytecode-level proof: reflecting into the pack's actual sodium-fabric-
// 0.5.13+mc1.20.1.jar, isUsingKnownCompatibleLwjglVersion() returns false
// under the old hardcoded 3.4.1 and true under the fixed 3.3.1 report.
// PojavLauncher.java's LWJGL sanity log additionally escaped a brace bug that
// had trapped it inside the vulkan-only branch since introduction (the line
// never appeared in any device log). Purely launcher-side Java; no MobileGlues
// converter surface touched, so REVISION stays 17. The fixed build identifies
// itself on device by the pair "[Tools] LWJGL report version: 3.3.1 (from
// version metadata...)" + "[PojavLauncher] LWJGL selected by launcher: 333,
// reported version: 3.3.1 (metadata: 3.3.1)" -- and by the absence of the
// sodium "not compatible" exit.
// REVISION 17 addendum (Task 95, no bump): the 96c527f upload (commit 1ee7111
// build, BMC2 [FABRIC] 1.20.1, 536 mods, iPad Air M4 / iPadOS 27) verified the
// Task94 fix on device -- "[Tools] LWJGL report version: 3.3.1" and "[PojavLauncher]
// LWJGL selected by launcher: 333, reported version: 3.3.1 (metadata: 3.3.1)"
// both present, Sodium 0.5.13 passed its gate, and startup sailed into full mod
// init (deepest BMC2 run yet). The new crash is a different layer: the instance's
// mods folder is missing 8+ jars (the whole FTB suite ftbquests/ftblibrary/
// ftbteams/ftbbackups, balm, terrablender, kleeslabs -- zero of them in the
// "Loading 536 mods" list), while config/fabric-loader.json dependencyOverrides
// ("Dependencies overridden for certain_questing_additions, kleeslabs,
// netherportalfix, climaterivers, biomeswevegone") masked Fabric's clean missing-
// dependency rejection, so the pack died at the 'main' entrypoint with
// NoClassDefFoundError: dev/ftb/mods/ftblibrary/config/ui/EditConfigScreen
// (certain_questing_additions) + suppressed Balm/TerraBlender chains. Launcher-
// side hardening, no MobileGlues surface touched, REVISION stays 17:
// (1) ModpackImportService writes import_report.json into the instance root at
//     every import finale (failed/skipped lists + acknowledged flag; a clean
//     re-import rewrites it empty);
// (2) JavaLauncher's ImportGuard reads it pre-JVM and shows a one-shot reminder
//     when unacknowledged missing files exist (non-blocking, "[ImportGuard]
//     Task95" anchor);
// (3) PLCrashView gains CrashTypeMissingMods: parses "Could not execute
//     entrypoint stage" + ClassNotFoundException/NoClassDefFoundError chains,
//     maps dev.ftb.mods.*/net.blay09.mods.balm/terrablender.* to friendly names,
//     and surfaces the "Dependencies overridden" evidence in the crash UI.
// FAQ 27->28 (+missingMods entry). On-device anchors: "[ModpackImport] Task95:
// import report written ...", "[ImportGuard] Task95: incomplete import detected
// ...", and the crash view's missing-mod class list.
// REVISION 17 addendum (Task 97, no bump): the 2f90d13 upload (commit 6c3d49d
// build, BMC2 [FABRIC] 1.20.1, 474 mods, zink, iPad Air M4 / iPadOS 27) -- the
// user partially applied the Task95 advice (removed certain_questing_additions,
// balm/kleeslabs/terrablender now present, dependencyOverrides line gone), and
// startup reached the deepest point ever: all mods loaded, window init, resource
// reload, paintings json parsing -- then died at the 'main' entrypoint on TWO
// mods whose crashes share one root cause: the launcher passed -Duser.dir=
// <gameDir> but never chdir()'d, so java.io.File (raw process CWD) and
// java.nio.Files/Paths (user.dir) resolved relative paths against two DIFFERENT
// directories. paintings (Paintings++ 11.0.0.1) PaintingPackReader.scanPacks:
// Files.exists/isDirectory("./resourcepacks") true via user.dir, then
// folder.toFile().listFiles() NULL via process CWD -> Arrays.stream(null) NPE;
// sparsestructures 2.1.2: CONFIG_FILE_PATH.toFile().exists() false via CWD
// (guard passes), Files.createDirectories("config/sparsestructures.json5") hits
// the pack-shipped file via user.dir -> FileAlreadyExistsException. Desktop
// launchers always run java with CWD == game dir, which is why the same pack
// never trips there; both signatures reproduced bit-for-bit on a local JDK
// (verify_task97 D-section). Fix: JavaLauncher ame97_alignProcessCwdToGameDir
// chdir()s to the game dir (+ $PWD sync) immediately before both JLI_Launch
// sites (game + headless); failure is non-fatal with a "[CwdAlign] Task97"
// forensic anchor. Side-effect audit: latestlog capture is absolute-path pipe
// based, all dlopens resolve via @rpath/@loader_path, ObjC file IO is
// NSHomeDirectory/NSBundle-absolute -- no relative-path victims. Bonus: log4j's
// "Cannot access RandomAccessFile logs/latest.log" ENOENT (relative path into
// the old CWD) disappears, and the game writes real logs/ into the instance dir
// like desktop. FAQ 28->29 (+cwdMismatch). Launcher-side only, REVISION stays 17.
// REVISION 17 addendum (Task 98, no bump): the 2af8c45 upload (commit 6c3d49d
// build, MC 26.3 Fabric modpack, 110 mods incl. sodium 0.9.2 + iris 1.11.6, MG
// renderer, iPad Air M4) crashed renderer-independently at MC's
// NativeLibrariesBootstrap fifth load item: "Description: Loading library SDL" /
// NoClassDefFoundError org/lwjgl/sdl/SDL. Sodium's own LWJGL gate PASSED (Task94
// reporting 3.4.3 worked; the mod list printed and startup ran ~2s deep) -- the
// failure is the launcher's LWJGL set selection: the version ID was the Fabric
// form "fabric-loader-0.19.5-26.3-e4ecd7db", and ResolveLwjglVersion's old
// parser (split by ".", read parts[0]) saw "fabric-loader-0" -> intValue 0 ->
// LWJGL 333 picked, whose bundled jar set has no lwjgl-sdl classes (only the
// 341 set ships lwjgl-sdl.jar; MC 26.3 moved windowing/input from GLFW to SDL3
// and requires the SDL bindings). All previous 26.3 device sessions used
// vanilla-form IDs ("26.3-rc2" etc.) that the old parser happened to read
// correctly, so the blind spot only surfaced with the first Fabric modpack.
// Fix: new shared helper ame98_mcMajorFromVersionId (exported via
// JavaLauncher.h) -- 1.x-line early-out (protects "1.20.1-forge-47.3.0"'s forge
// build number 47 from being year-misread), then an anchored year regex
// "(?:^|[-_])(\d{2})(?=[.w])" that reads the MC major from any ID form
// ("26.3" / "26w14a" / "fabric-loader-0.19.5-26.3-e4ecd7db" -> 26;
// "fabric-loader-0.19.3-1.20.1-9c2ee306" -> 1; "25w45a" -> 25). Used by BOTH
// ResolveLwjglVersion (auto path -> 341 for >=26, "[LWJGLSel] Task98" anchor)
// and SurfaceViewController's ame87 LTW x 26.x gate (which had the same
// first-hyphen blind spot and would have let Fabric 26.x packs through to the
// guaranteed LTW title-screen crash). FAQ 29->30 (+mc26sdl: the log signatures,
// the prefix-blind selection explanation, the manual 3.4.1 profile override as
// old-build self-help). Launcher-side only, REVISION stays 17.
// REVISION 17 addendum (Task 99, no bump): two launcher-side fixes, both from
// the b919e0f/2253a10 device-log pair (7ed3d01 build). (A) MC 26.3 release's
// Window.<init> -> MacosUtil.disableCloseWindowMenuItem walks AppKit via
// jna-objc (NSApplication/NSMenu) which iOS does not have -> NoSuchMethodException
// "Initializing game" crash; JavaLauncher now registers minimal ObjC stub classes
// before JLI_Launch ("[AppKitStub] Task99" anchor, resolveInstanceMethod safety
// net). (B) 1.20.x modpack (BMC2) + zink + FSR: game image shrunk to the
// bottom-left corner -- the EASU upscale output does not reach the readback
// client buffer on this path (26.3-rc-3 same code renders full-screen);
// osm_bridge EASU pass now pins texture unit 0 + uInputTex, carries a one-shot
// GPU probe (glReadPixels top-strip pixel), a 120-swap condition heartbeat, a
// 90-frame CPU top-strip landing probe, and an automatic CG-stretch fallback
// presenting the game region full-screen via CoreAnimation when EASU is
// verified not landing ("[OSMBridge] Task99" anchors). FAQ 30->32
// (+macMenuStub, +fsrCorner). Launcher-side only, REVISION stays 17.
// REVISION 17 addendum (Task 100, no bump): two follow-ups from the
// f6352dc/7a30912 device-log pair (ccabe82 build = Task99 IPA, both problems
// still present on device). (A) 26.3: the Task99 stubs worked
// (sharedApplication returned the stub app) but MC 26.3's MacosUtil then
// fetched "windowsMenu" which hit the generic nil no-op -> jna-objc returned
// Java null -> NPE "because windowsMenu is null" at MacosUtil.java:27;
// NSApplication stub now answers windowsMenu/appleMenu/helpMenu/servicesMenu
// with the shared NSMenu stub ("[AppKitStub] Task100: windowsMenu requested"
// anchor). (B) BMC2 1.20.1 + zink + FSR: Task99's probes were all green (GPU
// probe alpha-stamped, CPU probe 88/90 nonzero -> verdict=1, heartbeat stable
// to swap#1080) yet the screen still showed the live game shrunk bottom-left
// -- proof the driver's glFinish readback fills the client buffer with a
// stale/pre-EASU image (nonzero top-strip = residue, misread as landing);
// osm_bridge now performs an authoritative present: after glFinish it binds
// fb0, glReadPixels the full surface into a scratch buffer, row-flips it into
// a driver-untouched present buffer, and the CGImage wraps THAT (the driver
// readback is bypassed for display entirely; bundle.buffer kept only for a
// forensic dual-track probe -- fb probe drives the verdict, driver probe
// reports transport health) ("[OSMBridge] Task100" anchors). FAQ content
// refreshed in place (macMenuStub/fsrCorner, count stays 32). Launcher-side
// only, REVISION stays 17.
#define REVISION 22
// REVISION addendum (Task 219, no bump -- identity unchanged, cache epoch
// rule): eleven-item round from the Task218 build's device logs (6cd2cbfb).
// (1) VirGL crash: the vtest server bridge never imported utils.h, so its
// NSLog went to os_log instead of the latestlog pipe (the "check [VirGL]
// logs above" message pointed at logs that did not exist in the file);
// socket path shortened to the app tmp dir with a pid suffix (the old
// $POJAV_HOME/.virgl_test ran ~170 bytes, past sockaddr_un.sun_path's 104,
// guaranteeing bind failure), libEGL + libvtestserver dlopen now walk the
// gl_bridge candidate chain (@executable_path first -- LiveContainer
// resolves @rpath against the host App.app), post-bootstrap verification
// (socket file + S_ISSOCK; deliberately NO connect probe -- vtest
// --no-loop-or-fork is single-shot and a probe would consume the only
// session), and on bootstrap failure the renderer diverts to Zink before
// the guest library loads (the guest aborts in virgl_vtest_negotiate_
// version when the socket is dead -- that was the crash). (2) ANGLE
// black screen on non-26.3: MC <=26.2 uploads desktop "#version 330"
// GLSL straight through glShaderSource (the shaderc->spirv-cross pipeline
// where the Task175 ES300 rewrite lives only serves 26.3), and the legacy
// tinygl4angle conversion only rewrites 1xx version digits -- the 330 head
// reached the ES3 context intact = "invalid version directive" = every
// pipeline failed = black screen; tinygl4angle now rewrites desktop heads
// (>=130) to "#version 300 es" + the ame176 precision preamble (proven by
// the 26.3 spvc path) and uploads via the ES branch. (3) The welcome
// wizard was rebuilt (its per-step content containers were constrained to
// the PREVIOUS step's container which was then removed -- AutoLayout
// dropped the referencing constraints, leaving a zero-size top-left
// unclickable stage; now a persistent UIScrollView owns the steps), with
// LiveContainer detection + host-bundle-id guidance, a JIT enabler picker
// (debug.jit_enabler, right-panel Task134 URL semantics), a back button,
// and About auto-open after completion. (4) Data export gained a
// preflight summary, compression-level choice (UZK None/Default/Best),
// and a progress bar with per-file detail. (5) TouchController install
// texts de-confused from Sodium (searching/not_found/download_failed/done
// keys + a 1.12.2 support pre-check). (6) Mod downloads and scans follow
// the profile's isolation (isolated dir created instead of silently
// falling back to the shared mods folder); the mods manager shows an
// isolation badge. (7) VGPU relabeled "VGPU (<=1.17)". REVISION stays 22:
// no identity change, launcher-side + renderer-side-internal only.
// REVISION 22 addendum (Task 220, no bump -- account/avatar/skin integrity
// round from the 50254b8d/e1f2114e/def65d79 log set, user report: genuine
// account misjudged as third-party, avatar + skin abnormal). Six fixes,
// all account-chain, zero renderer/identity touch. (1) checkMCProfile no
// longer overwrites the just-acquired Xbox gamerpic URL with the
// api.rms.net.cn head mirror -- that domain's DNS is dead on device
// ("Task169 avatar fetch failed ... host not found" x4 in one session),
// so every genuine account carried a guaranteed-dead primary avatar URL;
// dirty "(null)"/"(nil)" values are dropped instead, letting the
// crafatar/minotar fallback chain serve. (2) The dirty profilePicURL
// legacy (first-login-order bug) now heals ON DISK: loadSavedName scrubs
// + rewrites the account json, and the refresh-path repair scrubs the
// file too (read-modify-write, bypassing saveChanges which would demand
// a keychain token) -- previously the fix was memory-only and resurrected
// from disk at every boot when the refresh chain could not complete
// (keychain lost). (3) Hybrid account files (microsoft accountType with
// stray authserver/clientToken, or thirdparty with xuid/xboxGamertag --
// the exact state that made an MSA launch carry LittleSkin authlib
// injection while authlib itself logged "Setting accountType to msa")
// are defensively scrubbed on load by accountType; all four type
// discriminators (BaseAuthenticator.loadSavedName, AccountList label,
// context menu + selection, and Java Tools.isThirdPartyAccount via the
// new MinecraftAccount.accountType field) now share the accountType-first
// order with legacy sniffing fallback. (4) The retired home-card skin
// preview methods moved off the dead hardcoded http://111.170.35.224:3000
// mirror onto crafatar renders/body + minotar body fallback (zero live
// callers since Task136 -- fixed on the dead code so a revival cannot
// bring back the dead link). (5) tokenDataOfProfile self-clears a corrupt
// keychain entry (SecItem OK but unarchive failed) so the state collapses
// to a clean "missing" instead of a permanent "present but unreadable";
// re-login (setAccessToken delete+add) overwrites either way. (6) Launch
// gate: a non-Demo Microsoft account with a missing/corrupt keychain
// token is stopped pre-launch with the Task187 one-click repair dialog
// (delete + re-login + pendingLaunchAfterLogin auto-continue) instead of
// silently launching an unauthenticated session with broken skin and
// multiplayer auth. REVISION stays 22: no identity change.
// REVISION 21->22 bump addendum (Task 218): identity follows the cache epoch
// (Task214 rule) -- the bundle identifier moved AGAIN by explicit user order:
// com.air-devs -> com.air-devs.air (the upstream's exact id, opening the
// in-place update channel for upstream users; they update onto this build,
// export their data via the Task217 bridge, and later hop to the final
// com.prisma-devs build). Same round: repository renamed away from "air"
// (Gsjsjzhznsz/Air-Minecraft-iOS-Launcher -> Gsjsjzhznsz/Prisma-Minecraft-
// iOS-Launcher; update checker, control-repo, announcement cascade + pre-
// rename URLs kept as known-defaults so persisted news_url normalizes), the
// download-source dual-track retired (PLMirrorCenter is the single source of
// truth; legacy general.download_source readers all migrated), FCL-style
// crash identification (CrashAnalyzer + hs_err classification), and the
// first-use onboarding wizard. Wired: Info.plist id+scheme, Makefile x7,
// CI artifacts x6, entitlements x3, os_log x2, background session id,
// keychain primary+chain (Task217 interim gen added to the fallback).// REVISION 20->21 bump addendum (Task 217): the bundle identifier changed
// identity AGAIN -- by explicit user order this is the TEMPORARY migration
// build (com.prisma-devs.prisma -> com.air-devs, the upstream-family name,
// across Info.plist/Makefile/CI artifact names/entitlements/os_log
// subsystems/keychain service/background-session identifier), staged so the
// interim build can carry the data export/import bridge before the FINAL
// rename to com.prisma-devs in its own round. Cache epoch follows the app
// identity (same rule as the Task 214/216 bumps). Task 217 itself is
// launcher-side only (component-download 26.x fixes, mod-toggle error
// surfacing, auto-renderer crash learning, FCL-style isolation, About page,
// data export/import) -- no converter output changed beyond the epoch bump
// itself.
// REVISION 19->20 bump addendum (Task 216): the bundle identifier changed
// identity again with the second rebrand leg the user ordered
// (com.air-devs.prisma -> com.prisma-devs.prisma across Info.plist/Makefile/
// CI artifact names/entitlements/os_log subsystems/keychain service/
// background-session identifier), and the marketing version moved 6.0.0 ->
// 6.5.0, so the cache epoch follows the app identity (same rule as the Task
// 214 bump). Task 216 itself is launcher-side UI only (loader-list aligned
// to the version table, translucency slider monotonicity, instance-card
// button/shadow opacity binding, default-settings overhaul, footer wrap)
// -- no converter output changed beyond the epoch bump itself.
// REVISION 19 (Task 214): the rebrand-round bump the user ordered in the
// Task212/213 eight-item brief ("REVISION bump, Task 210 era = 18") that the
// delivery round missed: bundle identifier com.air-devs.air -> com.air-devs.
// prisma, os_log subsystems, keychain service and 54-language permission
// strings all changed identity with the Air -> Prisma rename, so the cache
// epoch follows. Task 214 itself is launcher-side UI only (memory-limit
// dialog l10n key, card corner radius, selection-ring hitTest passthrough,
// stats-label shrink-to-fit) -- no converter output changed beyond the epoch
// bump itself.
// REVISION 18: upstream 2.0.0-release sync + FSR1 compatibility audit.
// (1) Ported upstream 0f1e10b ([Fix] multidraw: grow-only resize for the
//     indirect command staging vector) -- prepare_indirect_buffer's staged
//     vector no longer shrinks after a small draw only to memset the tail on
//     the next large one; matches the grow-only policy of every other staging
//     vector in the hot path (drawing.cpp / rebased / zeros).
// (2) FSR1 audit vs the launcher integration (the user-facing concern of this
//     bump): the upstream 478d479 state-guard/perf rework is already in this
//     tree (GLStateGuard bits + link-time uniform caching + the
//     deleted-framebuffer republish on RecreateFSRFBO), the Amethyst fork
//     additions on top (Task 76 TeardownFSR1, Task 78 viewport-latched render
//     size, Task 80 uTargetSize, Task 130 RCAS pass) are intact, and the
//     config linkage is verified aligned: JavaLauncher writes
//     fsr1Setting (int, FSR1_Quality_Preset, bounds-checked here) and
//     fsr1RcasSharpness (double, clamped to [0,1]) into MG/config.json, which
//     config/settings.cpp reads under the same names and semantics. The
//     Android-adaptation mods on the fork side do not touch the FSR1 surface.
#define PATCH 0

#define VERSION_TYPE VERSION_RELEASE

#if VERSION_TYPE == VERSION_RC
#define VERSION_RC_NUMBER 2
#endif

// Development builds are numbered for the reason release candidates are: several
// of them carry the same MAJOR.MINOR.REVISION, and a bug report has to be able to
// name which one it came from. Bump this whenever a build leaves this machine.
#if VERSION_TYPE == VERSION_DEVELOPMENT
#define VERSION_DEV_NUMBER 4
#endif

#define VERSION_SUFFIX ""

#define MOBILEGLUES_VERSION_H

#endif // MOBILEGLUES_VERSION_H
// REVISION 17 addendum (Task 103, no bump): two fixes from the a605099/
// c241276/446b2a0 device-log triple (d37670e build = Task100 IPA). (A) 26.3
// modpack world-entry crash: sodium 0.9.2+mc26.3's block_layer_opaque.vsh
// died in GLSL preprocessing ("preprocessor directive cannot be preceded by
// another token") -> solid_terrain pipeline missing -> Render Frame crash.
// Root cause byte-level proven: sodium's three include files (globals.glsl
// ends '};', fog.glsl ends '}', chunk_vertex.glsl ends '#endif') all lack a
// trailing newline, and Natives/shaderc_include.c appended the '#line'
// fixup directly after the content -> the directive glued onto the last
// token line. All 17 vanilla includes end with '\n', which is why only the
// first sodium shader of the session died (compile#406, 405 vanilla
// compiles passed). Fixed by guaranteeing a newline before the '#line'
// append (repo-local repro with the real Modrinth jar shaders: 3 glued
// sites -> 0). (B) BMC2 corner-shrink: the Task100 present path still
// showed the raw game in the corner while BOTH probes read 89/90 nonzero --
// glReadPixels itself serves pre-EASU/stale content on this path, so the
// "authoritative readback" inherited the same untrustworthy transport. The
// EASU fragment shader (osm_bridge string surgery only, shared header
// untouched) now stamps a per-frame sentinel byte (1..254) into the alpha
// channel of output pixel (0,0) -- display ignores alpha
// (kCGImageAlphaNoneSkipLast), the swap path reads it back: 3 consecutive
// matches = EASU landed -> full-surface present; 3 consecutive misses =
// pre-EASU/stale transport or draw not landing -> CG stretch of the raw
// game region (full-screen geometry either way); 10 consecutive opposite
// votes flip the verdict across game-phase changes. GPU probe extended
// with a pre-glFinish sentinel read; verdict logs add a one-shot
// present-vs-bundle memcmp (same-source transport forensics); heartbeat
// gains mk=N/M. FAQ 32->33 (+sodiumGlsl, fsrCorner refreshed). Launcher
// side + shaderc_include.c only, REVISION stays 17.

// REVISION 17 addendum (Task 104, no bump): two fixes from the 341c110
// log pair (d00d695 build). (A) 26.3 FSR stuck at 30fps: MC 26.3's
// FramerateLimitTracker runs SHORT_AFK (min(maxFps,30)) when
// inactivityFpsLimit==AFK (26.3 default) and no MC-visible input for 60s
// -- modpack loading takes minutes -> the whole load + idle phases were
// capped at 30 (watchdog caught the render thread parked in
// FramerateLimiter.limitDisplayFPS). Fix layers: MCOptionUtils dedup
// (last-line-wins at MC load made our minimized write fragile) + on-disk
// post-save verification log; input_bridge_v3 AFK heartbeat pushes a
// (0,0) SDL_MOUSEWHEEL every 45s -> MouseHandler.onScroll calls
// onInputReceived unconditionally after the handle check, so the 60s
// clock can never expire while the game runs. Zero side effects:
// overlay!=null skips the body, in-game (0,0) wheel early-returns.
// (B) BMC2 corner-shrink round 3: the (0,0) sentinel proved only that
// SOME EASU fragment ran in the corner -- coverage remained unproven.
// The EASU fragment shader now stamps the same per-frame marker at the
// FAR corner too (top-right 4x4 block); the vote requires BOTH markers
// -> corner-only coverage flips the verdict to NOT LANDED and the CG
// stretch fallback takes over (geometry full-screen either way; fallback
// upgrades layer filters to Linear, LANDED restores Nearest). One-shot
// Task104 viewport check logs what the driver actually holds after
// glViewport. Desktop anchor lines: '[InputDiag] Task104 AFK heartbeat',
// '[PojavLauncher] Task104 on-disk verification', '[OSMBridge] Task104
// EASU viewport check', 'far=N/M' in the swap heartbeat.

// REVISION 17 addendum (Task 105, no bump): the c947464 log pair (bacbf1e
// build) closed both open questions. (A) 26.3 FSR "stuck at 30fps" is
// fixed-and-load: the AFK cap never engaged (no FramerateLimiter watchdog
// hits, inactivityFpsLimit=minimized verified on disk, heartbeat #1 seen);
// fps fluctuated 19-44 with memory peaking 5.4GB at view distance 32 and
// recovered 30->44+ still climbing after the user dropped to 16 -- pure
// GPU/CPU load, FAQ fpsUnlock now carries the guidance. (B) BMC2 1.20.1
// corner-shrink root layer finally isolated: dual sentinels LANDED (EASU
// pass covers the full surface, present==bundle byte-identical, 60fps)
// yet the GPU probe top-strip RGB read 000000 -- the EASU input region
// itself held a shrunk MC frame with black padding. i.e. MC-1.20.1/GLFW
// + BMC2's mod set presents into fb0 at a smaller region than the
// launcher-told window belief (vanilla 1.20.1 decompiled clean: blit uses
// glfwGetFramebufferSize == shim 1814x1262). Fix (renderer-side, immune
// to the upstream mod cause): osm_swap_buffers now reads the live GL
// viewport at swap time -- MC 1.20.1's final present blit sets
// _viewport(0,0,w,h) immediately before RenderSystem.flipFrame, so the
// query returns exactly what MC painted into fb0 this frame. The EASU
// input region, the landing probes, and the CG-stretch crop all follow
// this effective size. Gates: origin must be (0,0), positive dims that
// fit the surface, and area >= 1/4 of the window belief (aux/shadow
// viewports rejected -> fall back to the belief = old behavior). Viewport
// == belief (26.3/SDL path) -> byte-identical behavior; viewport ==
// surface (healed full-res path) -> EASU correctly skipped. Forensics:
// one-shot '[OSMBridge] Task105 viewport evidence: MC present viewport
// 0,0 WxH vs launcher window belief WxH -- match/DIVERGED/gated' per new
// size (pins the upstream mod number next round), and the Task99 swap
// heartbeat gains 'vp=WxH (adaptive)'. Desktop anchor lines:
// '[OSMBridge] Task105 viewport evidence ... DIVERGED: EASU input follows
// MC (adaptive) -- geometry restored' + 'vp=' in the swap heartbeat.
// Verifier maintenance: verify_task100 D14 anchor follows the code
// (upscale call now passes effW/effH); verify_task103 F3 re-anchored to
// the Task104 FAQ wording (far=N/M); task103_syntax_swap + verify_task85
// D1 stubs gain ame83_resolve_gl + gl.glGetIntegerv + GL_VIEWPORT.

// REVISION 17 addendum (Task 106, no bump): the 41cdff0 log pair (2e1ea09
// build) resolved both open issues. (A) BMC2 1.20.1 "crash on creating a
// world": the session reached world creation for the first time (previous
// sessions never got past the title screen), the server bootstrap hit
// spark's "Starting background profiler...", spark extracted its bundled
// spark/macos/libasyncProfiler.so (FAT x86_64+arm64, arm64 slice carries a
// real LC_CODE_SIGNATURE, platform=macOS) into config/spark/tmp/*.tmp and
// System.load()ed it -- the FIRST library ever to hit the
// PLPatchMachOPlatformForFile retag path on this device (0 occurrences in
// all prior logs). The macOS->iOS platform retag mutates the mach header,
// invalidating the code signature; dyld's signature validation then kills
// the process (silent SIGKILL -- no hs_err, no fatal trace; the log's last
// line is literally the "[Amethyst] Patching ...libasyncProfiler.so.tmp").
// Unsigned home-dir libs retag harmlessly (that is why every other lib
// works); signed ones die. Fix (two layers): hooked_dlopen blocks
// libasyncProfiler loads outright -- spark's own bytecode (1.10.53
// AsyncProfilerAccess.load) catches UnsatisfiedLinkError and degrades to
// its Java sampler, so world creation proceeds; and the retag path now
// neutralizes LC_CODE_SIGNATURE (in-place rewrite to the same-size benign
// LC_SOURCE_VERSION + zeroed blob) so any OTHER signed macOS dylib a mod
// extracts loads as unsigned instead of badly-signed. Desktop anchor:
// '[Amethyst] Task106: blocked dlopen of signed macOS profiler lib'.
// (B) 26.3 zink+FSR "still locked at 30fps": verdict REVISED -- Task105's
// "pure load" closure was wrong (its 44fps reading was the pause-menu
// moment, and in this session the user doubled the FSR scale (preset 1 ->
// 4, render pixels -58%) with fps unchanged at 28-30 -- a
// resolution-independent constant dominates the frame budget). The zink
// path was doing TWO full-surface GPU->CPU readbacks per frame (the
// driver's glFinish readback + Task100's authoritative glReadPixels) plus
// a 15.5MB row-flip memcpy. Fix: bundle-direct present -- the Task103
// dual sentinels (markerCode cycles 1..254 per frame) give per-frame
// ground truth that bundle.buffer holds THIS frame's full-surface EASU
// output; after 30 consecutive fresh frames the launcher skips the
// duplicate readback + row-flip and presents the driver buffer directly
// (OSMESA_Y_UP=0 is already top-down). Two consecutive sentinel misses
// revert to the authoritative path; the marker vote state machine is
// shared (ame103_marker_vote) between the scratch and bundle feeds.
// Plus per-phase timing instrumentation in the swap heartbeat (t=swap /
// [pre+easu glFinish readback] / frame / MC-side) so the next log
// decomposes the remaining frame budget exactly. Desktop anchors:
// '[OSMBridge] Task106 bundle-direct present engaged' + heartbeat
// 'bd=N/M t=swap ... MC-side=...ms'. Good news pinned by the same log:
// the BMC2 corner-shrink is FIXED on device by Task105 (vp=907x631
// adaptive, 60fps, full-screen geometry). FAQ 33->34 (+sparkProfiler);
// fpsUnlock carries the corrected verdict + timing-field guide; stale
// sync: FAQ count 33->34 across 12 verifiers (task106_faq_sync.py),
// verify_task100 D13 re-anchored to the bundle-direct present gate,
// verify_task105 E2 re-anchored to the Task106 wording; syntax gates
// (task83_syntax_osm.sh / task103_syntax_swap.py / verify_task85 D1)
// gain ame106/mach/vote-helper stubs.

// REVISION 17 addendum (Task 107, no bump): dyld_patch_platform.m now RE-SIGNS
// (ad-hoc) every library it platform-retags, replacing Task106's signature
// neutralization. The ce43a34 log pair (6a81ba5 build) proved the neutralized
// form fatal: iPadOS 27's dyld4 hard-rejects ANY dlopen'ed image without a
// code-signature blob ("missing code signature in <uuid>") while tolerating
// stale ad-hoc hashes in a debug-signed process -- so rewriting
// LC_CODE_SIGNATURE to LC_SOURCE_VERSION + zeroing the blob turned every
// previously-loadable retagged ad-hoc lib into a guaranteed dlopen failure.
// JNA's libjnidispatch was the first casualty (its LC_UUID matches the
// reported uuid verbatim): both sessions lost JNA, and 26.3 crashed outright
// at MacosUtil.disableCloseWindowMenuItem -> ca.weblite.objc.Runtime ->
// JNA (no degradation path), while 1.20.1 merely degraded (oshi caught,
// junixsocket suppressed) and ran on -- blurry. The re-signer (pure C in
// Natives/ame107_codesign.h, SHA-256 backend injected as a function pointer:
// CommonCrypto on device, OpenSSL in scripts/task107_harness.c) rebuilds a
// v0x20400 CS_ADHOC CodeDirectory over [0, dataoff) with SHA-256 4K-page
// hashes and swaps it in place (thin files may grow via realloc + ftruncate
// with __LINKEDIT filesize/vmsize kept in cover; FAT slices stay in place or
// keep the stale signature with a capped warning -- spark's team-signed FAT
// remains blocklisted by hooked_dlopen). Page-0 load commands are finalized
// BEFORE hashing (datasize tightened first), and any build failure rolls the
// header back to the original stale state. Device anchors: '[Amethyst]
// Task107: re-signed ad-hoc after platform retag (in place/grown)' and the
// warn variants. Same log pair's second finding: BMC2 1.20.1 blurriness =
// sodium-extra 0.5.4 reduce_resolution_on_mac halving the framebuffer under
// the launcher's Mac spoof (vp=590x410 vs belief 1180x820, exactly half;
// EASU then 4x-upscales to the 2360x1640 panel); PojavLauncher now flips
// config/sodium-extra-options.json's reduce_resolution_on_mac to false at
// launch (anchor '[PojavLauncher] Task107: sodium-extra
// reduce_resolution_on_mac true->false ...'); FAQ sparkProfiler amended +
// blurry gains cause #5 (both in place, count stays 34, zero cascade).

// REVISION 17 addendum (Task 108, no bump): two follow-ups on 382432d. (1) CI
// fix: the Task107 rewrite of dyld_patch_platform.m accidentally dropped the
// bare 'extern int dyld_get_active_platform();' declaration that every prior
// revision carried (<mach-o/dyld.h> declares it behind __API_AVAILABLE
// (macos(12.0), ios(15.0)) -- too new for this deployment target, hence the
// manual extern). CI's clang (C99+ mode, implicit-function-declaration is an
// error) failed the 382432d build at dyld_patch_platform.m:84 with exactly
// one error; the declaration is restored verbatim (the old include set
// already covered every other syscall in the file -- open/pwrite/ftruncate/
// read/fstat/pthread/CC_SHA256 -- proven by the CI-green Task106 build).
// (2) sodium-extra revert, user decision: the user confirmed the BMC2 1.20.1
// blurriness was their own configuration (reduce_resolution_on_mac was on by
// their own choice -- an fps measure), and the launcher must not rewrite the
// user's mod config on every launch. PojavLauncher's patchSodiumExtraResolution()
// is removed (call + method); the mechanism knowledge moves to the FAQ page
// ('画面模糊' cause #5 now tells the user to toggle the mod's own setting:
// 视频设置 → sodium-extra 设置 → 性能 → Mac 下降低分辨率; fps-seekers use the
// FSR preset instead). The '[PojavLauncher] Task107: sodium-extra
// reduce_resolution_on_mac true->false' anchor is retired with it. The 26.3
// re-signing fix (fix A) is untouched.

// REVISION 17 addendum (Task 109, no bump): the 698c6fe log pair (both sessions
// on 38fb316) closes the "26.3 modpack locked at 30fps but vanilla fine"
// question with per-phase data and ships a self-stabilizing experiment.
// VERDICT (superseded by Task 110 same log pair): the 30fps pin on the
// modpack is dynamic_fps 3.11.10 seeing an UNFOCUSED window (SDL focus bit
// never set -- see Task 110); the modpack session also measured MC-side
// 21-36ms/frame + our present ~10ms during its 13-second load-storm stay,
// vs vanilla's MC-side median 3.3ms + the SAME present ~10ms = 53fps median
// ("normal"). Zero VANILLA limiter hits (FramerateLimiter, maxFps=260, no
// vsync) -- the mod's throttle was invisible to our watchdog because it
// lives outside the vanilla classes we monitor. The launcher present path is identical across both
// sessions (glFinish phase ~8-15ms regardless of scene -- the heavier modpack
// session actually reads LOWER) = fixed driver
// sync/readback constant; our own authoritative readback (glReadPixels full
// surface + row-flip) measures only ~4ms/event, so the cost is NOT the data
// movement but the driver glFinish's internal synchronization. EXPERIMENT
// (osm_bridge.mm Task109 no-finish trial): in two fixed FSR-frame windows
// (FSR frames 300-419 and 1020-1139, 120 frames each) the driver glFinish is SKIPPED and the
// authoritative glReadPixels path (with its internal sync) takes over
// presenting; phase timing then shows [glFinish ~0 | readback +sync] vs
// neighbor windows -- the A/B decides next round (adopt permanently if
// cheaper; if not, the wait is inherent GPU completion and only the CA
// direct-present / IOSurface zero-copy architecture remains). Safety: the
// authoritative path is the same one that runs for the first ~30 frames of
// every session (incl. its circuit breaker); sentinel voting is skipped
// inside the window (bundle is stale by design, no false fallback logs); if
// the authoritative path fails mid-window a LATE glFinish runs so the legacy
// bundle wrap still shows the correct frame -- the screen can never break;
// non-FSR frames/sessions are untouched (legacy present needs the driver
// readback). Window enter/exit log lines carry trial-vs-baseline averages:
// '[OSMBridge] Task109 no-finish trial: window opens/closed ...'. FAQ
// fpsUnlock's modpack-vs-vanilla bullet was later re-attributed to the
// dynamic_fps root cause by Task 110 (same file). Binary forensics started:
// libOSMesa.8.dylib is Mesa 25.0.7 (git-742a20f48c) built from
// /Volumes/D/mesa-source gallium osmesa target; export trie parsed
// (OSMesaCreateContextAttribs 0x4078 / OSMesaMakeCurrent 0x4970 / glFinish
// 0x9204); MakeCurrent's format dispatch confirmed RGBA+UBYTE -> internal
// 0x33 vs BGRA+UBYTE -> 0x36 (formats DO diverge internally -- a BGRA client
// switch remains a candidate micro-opt if the no-finish trial fails).

// REVISION 17 addendum (Task 110, no bump): ROOT CAUSE of "26.3 modpack
// pinned at 30fps while vanilla runs free" -- dynamic_fps 3.11.10 sees an
// UNFOCUSED window. Chain: the user reported the pack stuck at 30 (698c6fe
// modpack session, 38fb316 build) while pure vanilla 26.3 was "completely
// normal"; the pack's mod list contains dynamic_fps 3.11.10, vanilla does
// not. Decompiled the ACTUAL Modrinth jar (dynamic-fps-3.11.10+minecraft-
// 26.3.0, nested common jar): WindowObserver's constructor queries
// SDLVideo.SDL_GetWindowFlags & SDL_WINDOW_INPUT_FOCUS (0x200) directly --
// it does NOT use vanilla's Window.focused (which starts true and is only
// flipped by SDL events 526/527 that we never deliver -- hence vanilla
// behaves fine). The power state machine
// focused ? (idle?ABANDONED : ... FOCUSED) : (hovered?HOVERED :
// (iconified?INVISIBLE : UNFOCUSED)) had ALL THREE inputs broken by our
// embed mode: the hidden SDL UIWindow (Task 32/49 anti-black-cover) holds
// no input focus (0x200=0), no mouse focus (0x400=0), and is flagged
// HIDDEN (0x4) -- so the mod sat in a throttle state (its defaults:
// unfocused=1fps, invisible=0fps; the device pinned at the observed 30
// per its config/render floor). Task 50's flag hook only stripped
// MINIMIZED (0x40, for renderpearl's acquireNextTexture); the focus bit
// was the escapee. FIX (sdl3_hook.m ame_SDL_GetWindowFlags): return
// (flags | SDL_WINDOW_INPUT_FOCUS) & ~MINIMIZED & ~HIDDEN -- completing
// the same harmless lie: in embed mode the game view IS the foreground
// focus and the visible picture; iOS freezes the app in the background
// anyway, so focus=1 is always true when it matters. With focus set the
// mod's machine short-circuits into FOCUSED (Config.ACTIVE,
// frame_rate_target=-1 = unlimited); the idle branch (ABANDONED, 10fps,
// default timeout 300s) is neutralized by the Task104 45s wheel heartbeat
// feeding IdleHandler.onActivity (mouse events 1536-1539 family, verified
// in the decompile). Vanilla's ONLY flags consumer is Window.isFullscreen
// (& 1 FULLSCREEN) -- untouched; renderpearl's MINIMIZED strip retained.
// Reachability proven: LWJGL SDLVideo resolves through the same hooked
// dlsym path Task 50's MINIMIZED strip already validated on device
// (622166a). FAQ fpsUnlock bullet re-attributed to this root cause with
// the [SDLHook] Task110 anchor. Task 109's no-finish experiment stands
// unchanged (the 8-15ms present constant is a separate, real cost).
//
// REVISION 17 addendum (Tasks 112-118, launcher 5.1.0 release train; no MG
// bump -- all changes are launcher-side):
//   Task 112 (OpenAL NPE on 26.3): SoundEngine -> Library.createDeviceTracker
//   -> CallbackDeviceTracker.isSupported() passed alcIsExtensionPresent(
//   "ALC_SOFT_system_events") but LWJGL's SOFTSystemEvents ICD pointer was
//   NULL -> Checks.check NPE -> crash. Our bundled libopenal.dylib (1.21-1.23
//   era, no such extension) always fell back cleanly -- so the crashing openal
//   had to come from a classpath-hijacked natives jar (LWJGL loadNative
//   bundledWithLWJGL=true prefers classpath resources over java.library.path).
//   FIX: -Dorg.lwjgl.openal.libname pinned to the absolute Frameworks path
//   (absolute paths bypass classpath extraction entirely).
//   Task 113 (MobileGL Vulkan): prebuilt libMobileGL.dylib vendored from the
//   upstream-verified caf6822 build (DirectVulkan: GL -> Vulkan -> MoltenVK ->
//   CAMetalLayer direct present, readback-free; upstream device log shows it
//   smooth where the OSMesa readback path carries an 8-15ms present constant).
//   Entry point is the mobilegl_vulkan switch next to the ANGLE ES driver
//   setting (user request: keep the renderer LIST uncluttered); the GLES
//   variant is intentionally NOT shipped (other backends misbehave upstream).
//   Task 114 (keyboard would not auto-open when a text field had a blinking
//   cursor): ported the upstream caf6822 SDL hooks verbatim -- Start/Stop
//   TextInput + StartTextInputWithProperties + SetTextInputArea marshalled to
//   the main thread (SDL's iOS backend touches UIKit from the render thread
//   otherwise), and SDL_InitSubSystem sets SDL_ENABLE_SCREEN_KEYBOARD=1 to
//   override MC's desktop-convention 0 (plus RETURN_KEY_HIDES_IME and the
//   srgb-framebuffer hint for bridge renderers).
//   Task 115: UpdateChecker now targets Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher (Task218 rename; was Air-Minecraft-iOS-Launcher)
//   (was pointing at the upstream repo).
//   Task 116: 12 preference.detail.* keys + 4 crash.* keys added to zh-Hans
//   and en (the settings page showed raw keys in detail mode after the UI
//   refresh tasks).
//   Task 118 (background focus release, complements Task 110): the Task 110
//   focus lie is now state-dependent -- foreground keeps (f|0x200)&~0x40&~0x4
//   (30fps pin fix intact); on UIApplicationDidEnterBackground the 0x200 bit
//   is released (still stripping 0x40/0x4) so dynamic_fps-class mods read
//   UNFOCUSED and legitimately throttle during the background transition
//   window (default 1fps); WillEnterForeground restores the Task 110
//   expression. Deliberately NOT INVISIBLE (0x4 passthrough would hit 0fps
//   and risks aggressive side effects in other mods).
//   Task 119 (MobileGL FSR): mgl_fsr.mm pre-swap EASU pass -- the 5.1.0 field
//   report "mg vulkan path FSR shrinks instead of upscaling" was the Task83
//   window-shrink linkage meeting a MobileGL path with NO upscaling hook;
//   MC rendered into the bottom-left corner of the full-size swapchain image
//   and eglSwapBuffers presented it curled. The new pass captures the render
//   region and EASU-upscales it into the default framebuffer (= the MobileGL
//   swapchain image) right before eglSwapBuffers, GPU-side, zero readback.
//   Task 120: mobilegl_vulkan (unconditional override) retired in favor of
//   the single mobilegl_backend pick (Vulkan default / GLES / Mithril /
//   off) with ame_effective_renderer() as the single source of truth --
//   explicit renderer selections now always win (the 1d4ff3a9 session had
//   zink silently swapped to MobileGL Vulkan).
//   Task 121: l10n parity -- en/zh-Hans were missing 23 keys, zh-CN/zh-Hant
//   22 behind; all four key sets now identical, pick rows show localized
//   labels instead of raw stored values.
//   Task 124: the 774fa7871-build crash verdict (zink -> vk override +
//   NSInvalidArgumentException naturalDrawableSizeMVK on a plain CALayer)
//   closed by the Task120 single-source renderer + explicit-selection
//   priority + CAMetalLayer for all MobileGL paths.
//   Task 125: auto update check on launch (general.auto_update_check,
//   default on) -- silent unless a newer release exists, then an in-app
//   neumorphic toast (NMToast) with a View action; never a modal dialog.
//   Task 126: showDialog's level-1000 UIWindow leaked after OK (the
//   "system popup you must manually dismiss" complaint) -- the OK handler
//   now hides the alert window and restores the previous key window;
//   Microsoft-login success/status notices moved to auto-dismissing toasts.
//   Task 127: all sub-level panels get the neumorphic base style via
//   UIViewController+NMPanel, enforced at one point (LauncherNavigation
//   Controller push + root), idempotent, transparent-by-design panels skip.
//   Task 128 (third-party login completely broken, zl2-referenced): three
//   stacked fixes -- (a) authlib-injector jar now bundled in the app
//   payload (Natives/resources/authlib-injector-1.2.7.jar; POJAV_HOME
//   copy installed locally from the bundle, network download demoted to
//   last-resort fallback), so login/launch never hard-depends on a download
//   again; (b) account selection no longer hard-fails when the Yggdrasil
//   refresh rejects an expired token -- the account is still selected with
//   a re-login toast (skins/server-auth may be limited), session-validated
//   accounts skip the refresh entirely (zl2 isSessionValidated semantics);
//   (c) explicit accountType marker ("thirdparty"/"microsoft"/"local") saved
//   at login and honored by every classifier (three divergent key-sniffing
//   discriminators unified; legacy files fall back to the old sniffing).
//   Launch-time agent wiring additionally falls back to the bundled jar when
//   the POJAV_HOME copy is missing (the silent 401 chain's missing link).
//   Task 129 (v5.1.0 field report, eight fixes): (a) 26.1.2 modpack crash =
//   OpenAL ALC_SOFT_system_events NPE -- MC 26.1.2's CallbackDeviceTracker
//   calls alcEventIsSupportedSOFT without the alcIsExtensionPresent guard
//   26.3 has, our openal-soft 1.20.1 impl lacks the extension, and LWJGL
//   3.4.1 throws NPE on a NULL ICD slot; fixed by the openal_shim re-export
//   wrapper (advertises the extension + stubs returning ALC_FALSE so MC
//   falls back to PollingDeviceTracker; auto-transparent if the impl is
//   ever upgraded to >=1.25). (b) third-party login FCL parity: multi-
//   server list (saved-server chips, auto-remember after ALI resolution,
//   long-press to remove) + multi-role management (login-time profile
//   picker instead of auto-binding the first; saved accounts carry
//   availableProfiles and offer long-press role switching via
//   switchToProfile/refresh rebind). (c) settings pickers unified back to
//   floating action sheets/popovers on iPhone AND iPad (the old iPad
//   UIContextMenuInteraction + _presentMenuAtLocation private-API compact
//   menu read as a second-level submenu and stopped presenting on
//   iPadOS 27, making FSR/download-source/backend rows unswitchable).
//   (d) MG Vulkan perf defaults: enable_ext_direct_state_access now YES
//   and max_glsl_cache_size 128 -- the old pref defaults (NO/32) silently
//   defeated the code's intended safe defaults via the getPrefObject
//   override chain (device log: "enable_ext_direct_state_access = 0").
//   (e) white-background on some devices (iPad9): a custom background
//   image that fails to decode left the window's systemBackgroundColor
//   (light mode = pure white) visible; both window and splitVC now paint
//   the neumorphic base under the background container and the image
//   loader drops a themed fallback view on decode failure. (f) iPad9
//   treated as a small-screen device: the UIKit idiom hook unconditionally
//   forced Phone; iPads are now always Pad idiom (model-derived, immune
//   to the pref-default evaluation-order trap). (g) launcher announcement
//   load failure: the default feed (air-api.vercel.app) now 404s (domain
//   repurposed); a bundled offline announcement (announcements-fallback
//   .json) serves when both network and cache are empty. (h) MC news
//   images covered by neomorphism: the collection-cell effect injector's
//   "first rounded subview" heuristic picked the thumbnail UIImageView
//   itself, whose neomorph caster sublayers paint over layer contents;
//   content-rendering views (UIImageView/UILabel/UITextView/UIControl)
//   are excluded from card-container detection.
//
// REVISION 17 addendum (Amethyst Task 130, no bump): FSR1 gains the RCAS
//   sharpening pass (mpv FSR.glsl-referenced, AMD FSR1 1.20210629 verbatim
//   32-bit non-packed body). Pipeline: EASU now draws into an offscreen
//   target and RCAS presents (5-tap cross, <0.5ms fullscreen on M-class
//   GPUs); the alpha channel passes through from the center pixel so the
//   Task103/104 per-frame sentinel survives. Sharpness is one preference
//   across all consumers: mobileglues.fsr_rcas_sharpness (mpv scale [0,1],
//   default 0.2, negative = off) -> config.json fsr1RcasSharpness for
//   MobileGlues (new config_get_double) AND the AMETHYST_FSR_RCAS_SHARPNESS
//   env var for the zink (osm_bridge) and MobileGL (mgl_fsr) pre-swap
//   paths; a 7-tier settings pick row sits next to the FSR preset. Any
//   compile/link/FBO failure degrades to EASU-only with a logged reason
//   (per backend: zink, MobileGL DirectVulkan/GLES/Mithril, MobileGlues
//   via __has_include so standalone builds stay EASU-only). Also this
//   round: the account list gains an inline "switch character" button
//   (password-free, shares Task129b's switchToProfile rebind), and the
//   launcher announcements moved to a repo-hosted announcements.json
//   (raw.githubusercontent.com primary + jsDelivr mirror cascade, the old
//   air-api.vercel.app feed is only kept as a known-default sentinel for
//   the customization check).

// REVISION 17 addendum (Amethyst Task 131, no bump): four field fixes from
//   the 1d4082f install. (a) 26.1.2 modpack SIGBUS at 0x12e550010 during
//   world join root-caused: controlify 3.0.1 (26.3 pack lacks it -- the
//   sole differential) loads SDL3 via JNA/libsdl4j; the jar's
//   darwin-aarch64 libSDL3.dylib links Cocoa/AppKit/Carbon (cannot load on
//   iOS), JNA falls back to the launcher's own bundled iOS libSDL3.dylib,
//   then SDLControllerManager registers SDL_SetEventFilter with a JNA
//   callback -- the libffi closure trampoline is a RW non-executable page
//   without the JIT entitlement, and the game-side per-frame
//   pojavPumpEvents -> SDL_PumpEvents -> SDL_PushEvent invokes it ->
//   SIGBUS (exec-of-non-exec on ARM64 Darwin). Fix: sdl3_hook intercepts
//   SDL_SetEventFilter/SDL_AddEventWatch at the dlsym layer (name-based
//   dispatch covers both LWJGL and JNA resolution) as logged no-ops;
//   controlify keeps working through its SDL_PollEvent tick path. (b) The
//   MG three backends return to the renderer floating menu (upstream
//   form): libMobileGL.dylib (Vulkan default) / libMobileGL-gles.dylib
//   (logical key mapped to the shared binary at the physical load sites;
//   MOBILEGL_BACKEND_TYPE selects DirectGLES) / libmithril.dylib
//   (auto-hidden while absent). The Task120 standalone mobilegl_backend
//   pick row is retired (user x4: "setting items still separate" / "second-
//   level entry unusable" -- it only applied under renderer=auto); legacy
//   auto+backend resolution is preserved for existing installs. (c)
//   Third-party profile switching: Blessing Skin servers reject any
//   rebinding refresh on a bound token ("the access token has already
//   been assigned a profile"), so switching now falls back to a fresh
//   /authenticate with credentials secured in the iOS Keychain at login
//   (loginIdentifier persisted on the account json; raw password only --
//   the 2FA-suffixed variant is never stored), then binds the target
//   profile on the new unbound token; without stored credentials the user
//   gets a guided one-time re-login. (d) Pick sheets present from the
//   topmost view controller (a presenting self would be silently
//   rejected) and log an evidence anchor per open.

// REVISION 17 addendum (Task 132, no bump): four field fixes from the 43ef4ae
// install logs. (a) 26.1.2 modpack crash (controlify 3.0.1 -> libsdl4j 3.2.18
// -> JNA): Task131's guards sit at the dlsym-resolution layer, but libjnidispatch
// calls dlsym through ITS OWN __la_symbol_ptr slot, which the startup fishhook
// pass cannot cover for images loaded later (the crash session shows LWJGL
// intercepted while JNA was not -- the same split). hooked_dlopen now detects
// the libjnidispatch load (the JVM's System.load path, proven live by Task106's
// profiler block) and rebinds that image's _dlsym pointer slots to hooked_dlsym
// (Mach-O indirect-symbol-table walk, fishhook's linkedit-base arithmetic,
// runtime page size, idempotent); JNA resolution then flows through
// amethyst_sdl3_hook_resolve and the Task131 no-op guards cover the JNA path
// too (real SDL_ symbols still pass through untouched). (b) The MG three
// backends leave the renderer menu and merge into ONE unified pick row in the
// MobileGlues section (in-place floating popup, exactly three options --
// Vulkan direct / GLES backend / OpenGL 4.0 experimental, Vulkan default;
// user-mandated wording), writing video.renderer directly (same storage layer
// as the renderer row; explicit selection always wins). (c) The TouchController
// child-pane entry is replaced by an in-place three-way popup (disabled / UDP /
// static lib) with its companion rows inlined (vibrate, intensity, move view,
// about); the pane file stays but is no longer referenced. (d) Third-party
// skins: bundled authlib-injector upgraded 1.2.7 -> 1.2.8 (build 56) -- MC
// 26.3+ rewrote authlib's service discovery, 1.2.7 only rewrites the legacy
// URL constants so the new chain bypassed the injection straight to Mojang
// (401, skins fell back to defaults); 1.2.8 adds httpd/DiscoveryFilter for the
// new chain and keeps Java 17/21/25 compatibility.

// REVISION 17 addendum (Task 138, no bump): eight fixes from the c68552a
// four-log install feedback (latestlog = 26.1.2 controlify SIGBUS persists /
// latestlog.old.txt = 26.2 MobileGL-gles SIGSEGV / latestlog.txt = 26.2
// Mithril UnsatisfiedLinkError / latestlog.txt.old.txt = 26.2 OSMesa 60fps
// clean run). (a) 26.1.2 crash FINAL root cause: JNA direct mapping. The new
// crash log proves every Task131/132/133/135 guard engaged as designed (three
// image detections, direct hdr+slide rebind invoked, jnilib slot idempotent
// hit -- the fishhook race hypothesis confirmed) yet the crash persists, and
// it happens BEFORE any SDL symbol resolution: controlify 3.0.1+26.1 bundles
// libsdl4j 3.2.18 whose Native.register path allocates libffi closure
// trampolines via ffi_closure_alloc + RegisterNatives; on iOS those pages are
// RW-only, so the first direct-mapped call jumps to page+0x10 and SIGBUSes
// (0x134ea0010 and 0x119a70010 share the +0x10 libffi free-list signature).
// Fix: setenv POJAV_NATIVEDIR (from POJAV_HOME) so Pojav-aware mods steer to
// the nonexistent libSDL3.so, UnsatisfiedLinkError is caught, controlify
// falls back to GLFWControllerManager and the game runs; verified against
// controlify source (only SDLNativesLoader/CUtil read the var; the 3.5.0 FFM
// loader ignores it). (b) TouchController + hide-controls were broken by
// Task134 writing config.json/order.json with NSDictionary/NSArray
// writeToFile (plist XML) while the mod parses JSON -- kotlinx threw
// JsonDecodingException reading '<', the config fell back to defaults and the
// clean-preset pointer was lost; also the read side (dictionaryWithContentsOfFile)
// could never read the mod's own JSON, so the "preserve mod settings" rewrite
// wiped them every launch. Both files now go through NSJSONSerialization
// helpers (ame138_readJSONDictionary/ame138_readJSONArray/ame138_writeJSON).
// (c) MobileGL-gles SIGSEGV: gl_bridge.m dlsym_EGL and sdl3_hook.m's renderer
// handle fallback used the logical key libMobileGL-gles.dylib verbatim for
// the @rpath dlopen (file does not exist -- the -gles variant shares
// libMobileGL.dylib); the shared mapping now lives in utils.h as
// ame_physical_renderer_dylib and both call sites use it. (d) Mithril pick
// with the dylib absent crashed with UnsatisfiedLinkError: the picker keeps
// all three family options (user mandate) but ame_effective_renderer now
// falls back to auto (ANGLE) with a once-per-process NMToast, and the pick
// handler warns immediately at selection time; new l10n key
// preference.warning.renderer_missing_dylib x4 languages. (e) Home avatar
// could turn square on tab switches: the radius was only set in
// layoutSubviews when bounds were final; a capsule constant (999) now makes
// the square view a perfect circle regardless of layout timing. (f) The
// announcement tile's fixed 90pt height clipped its action button; height is
// now measured from the preview-level text plus button (ame138_announcementTileHeight,
// floor 90) and the section reload animates via performBatchUpdates. (g)
// Download mirror strategy gains a third option "speed first" (FCL-style):
// PLMirrorCenter races official vs mirror per family (BMCLAPI / MCIM) with a
// 24h persisted cache, unknown-results default to mirror order; all four
// policy rows and the moved-in mod mirror row (from the launcher section,
// now a unified coarse control writing assetSearch+assetDownload) default to
// speed_first. (h) Animation polish: home tiles animate only on first
// appearance (no re-fade on scroll-back), item-level stagger, sidebar
// selection color cross-fades in 0.18s.

// REVISION 17 addendum (Task 139, no bump): eight fixes from the 8a6307f
// four-log install feedback (latestlog = 26.1.2 world-join crash /
// latestlog.txt = 26.2 MobileGL-gles input misalignment / latestlog.old.txt
// + latestlog.txt.old.txt = 26.2 static-lib TouchController + clean-layout
// sessions). (a) 26.1.2 world-join crash root cause: NOT a SIGBUS at all --
// voicechat 2.6.17's MicrophoneThread takes the macOS path (Platform.isMac
// spoof), opens our IOSAudioMixer TargetDataLine, and audio_capture_bridge's
// createCapture force-installed the tap with a constructed 1ch/48000 Float32
// format while the hardware input node's native format differs ->
// uncaught com.apple.coreaudio.avfaudio 'Failed to create tap due to format
// mismatch' NSException terminates the app (the three 26.2 sessions had no
// voicechat mod, which is why they survived). Fix: the tap is now installed
// with the input node's native format and the callback linearly resamples
// (absolute-position accumulation, mono mixdown, int16 quantize) to the
// requested rate; the whole creation + engine start is @try/@catch-guarded
// and destroyCapture removes the tap before freeing the capture state
// (use-after-free race). Failure now degrades to no-microphone instead of
// killing the game. (b) MobileGL-gles input misalignment: the 23:08 session
// proves the chain -- Task119's FSR-unavailable heal restored MC's window to
// the full surface (viewport 2360x1640, 'GLFW: Set size 2360x1640') but
// sendTouchPoint kept dividing by mgFsrScale(2.0), so touches landed at a
// quarter of the screen. New ame139_fsr_heal_reset_input_scale() (declared
// in utils.h, implemented in SurfaceViewController.m, called from BOTH heal
// sites -- mgl_fsr Task119 and osm_bridge Task83b) resets the divisor to 1.0
// on the main thread. (c) TouchController static-library mode dead input:
// mode==2 sends ProxyMessages into the native singleton transport, but mod
// 0.3.1-alpha14 (forced onto legacy UDP by TOUCH_CONTROLLER_PROXY from
// Task135) listens on the UDP socket -- menus kept working through the
// launcher's direct input path, in-world touch died. sendTouchControllerProxyMessage
// now dual-sends (native channel + TouchSender UDP; byte-identical wire
// format, mod consumes exactly one). (d) Hide-controls still showing
// controls: mod-side forensics (CFR on the actual Modrinth jar:
// GlobalConfigHolder.currentPreset resolves our empty preset whenever
// status==ENABLED, and the default IS ENABLED; preset files parse clean in
// all four logs) prove the mod side works -- the culprit is the launcher's
// OWN ctrlView (classic Pojav buttons) which never hid. New
// ame139_modControlsHidden gate hides it in loadCustomControls and guards
// both hardware_hide un-hide paths; order.json also moves to preset/ (the
// mod's PresetManager reads presetDir/order.json, the old location was
// never read). (e) Renderer selection resetting to auto: both settings rows
// wrote ONLY the global video.renderer while every launch-path reader
// resolves profile-first -- an instance profile with a stored renderer
// (version manager / instance settings / instance creation) permanently
// shadowed the settings pick. Both rows now dual-write (profile + global,
// ame139_writeRendererBoth), the main row displays profile-first, and
// ProfileSettingsViewController.saveSettings syncs the global key too. (f)
// mg OpenGL 4.0 backend showing 'not built': libmithril.dylib was never
// actually committed (the CI comment lied). Vendored the Mithril-Wrapper
// main-line build (3.5MB arm64 iOS, static MoltenVK, 44 egl + 380 gl
// exports verified from the symbol table) into Natives/resources/Frameworks/
// -- the option ships working now. (g) Forge install demanding manual JIT:
// launchHeadlessJVM now auto-requests (debug.jit_enabler dispatch identical
// to the launch-button flow, waiting dialog + poll) when JIT is off, and
// re-attaches the JIT26 script via stikjit:// on TXM devices when
// CS_DEBUGGED is set but no debugger is live (the RightPanel re-attach
// logic, previously missing in the headless path). (h) iPhone right panel
// streamlined: 168pt full-content column -> 96pt icon rail (username + info
// cards retired on phone, launch/version/jar buttons icon-only, avatar 44pt),
// matching the 56pt left sidebar's FCL-style language.

// REVISION 17 addendum (Task 140, no bump): four fixes from the d089745
// two-log install feedback (latestlog.txt = 26.2 MobileGL-gles session with
// FSR unavailable + blocks-not-rendering report / latestlog.old.txt = 26.2
// Mithril session crashing at GL.createCapabilities). (a) Renderer settings
// layering rebuilt (the "edited a game's renderer, it reverted to whatever
// Settings->MobileGlues had" report): the Task139 dual-write made every
// Settings renderer pick OVERWRITE the current game's per-profile renderer,
// while the game editor's picker never offered the MobileGL family backends
// (Task132 retired them from rendererCandidates and three dylibs missing
// from the bundle filtered the classic list down to 4) -- four writers
// fighting over one storage key. New FCL/HMCL-style split: Settings rows
// (video.renderer + mobileglues.renderer_backend) write the GLOBAL default
// only (ame140_writeRendererGlobal, with an NMToast when the current game's
// override shadows the pick); the game editor (ProfileSettingsViewController)
// owns per-game selection with the FULL option list (follow-global key
// removal + classic + MG family three, each marked with a checkmark) and
// writes profile-only; the RightPanel launch-time global rewrite is removed
// (launch reads profile-first via resolveKeyForCurrentProfile, the rewrite
// only polluted the global with the last launched game); the version
// manager's dead-code short-name array now maps by key value instead of
// index (the dylib filter made the old 7-name hardcode misalign with the
// 4-entry key list -- a "tap ANGLE, write Zink" landmine). (b) Mithril
// OpenGL 4.0 crash "There is no OpenGL context current in the current
// thread": gl_init_context selected context attribs by the mobileGL flag,
// so Mithril (desktopGL=YES, mobileGL=NO) got the ES attribs
// (EGL_CONTEXT_CLIENT_VERSION=3) AFTER eglBindAPI(EGL_OPENGL_API) -- the
// context MakeCurrent reported TRUE but the renderer's GL TLS never bound,
// and GlDevice.createCapabilities died. Attribs now select by desktopGL;
// a Task140 eglGetCurrentContext readback log after MakeCurrent (first 3)
// closes the forensic loop. (c) FSR "unavailable" on both MobileGL
// backends: mgl_fsr resolved its GL entry points via eglGetProcAddress
// (which returns NULL for core gl on MobileGL) with a dlsym(RTLD_DEFAULT)
// fallback -- the flat-namespace search hits the app's auto-linked ANGLE
// (libGLESv2.framework, in the global symbol table since process start,
// before libMobileGL's RTLD_GLOBAL dlopen), so all 41 "resolved" symbols
// were ANGLE's while the current context was MobileGL's; glCreateShader
// returned 0 through the only log-less failure path and the heal fired.
// ame119_resolve now dlsyms from the libMobileGL dylib handle directly
// (its export trie carries all 2851 gl/45 egl symbols -- verified), with
// source-bucket counters (handle/proc/default) in the resolve log and
// forensic logs on the two formerly-silent paths (glCreateShader==0 with
// glGetError, GLSL version query returning 0). With FSR actually engaging,
// the GLES session's mid-boot window flip-flop (Task83 linkage halves, heal
// restores full) also disappears -- a suspected contributor to the
// blocks-not-rendering report; if blocks still fail on DirectGLES after
// this build, the remaining cause is inside MobileGL's GL4.6-on-ES
// translation (upstream issue, report with the new log anchors). (d)
// TouchController virtual buttons missing ("static-lib touch works but no
// virtual buttons"): Task134 wrote an empty "Amethyst Clean" preset into
// the mod's config whenever the hide-controls switch was on, Task139 also
// hid the launcher's own ctrlView -- zero buttons on screen, while the
// user wanted the MOD's buttons (the upstream built-in preset ships a full
// set: joystick/dpad/jump/chat/pause). The mod-side write is retired
// entirely (the launcher never touches the mod's config now); the switch
// hides only the launcher's own classic controls; and
// ame140_remediateTouchControllerConfig one-time-removes the polluted
// empty-layout pointer (or restores the Task134 backup) so existing game
// dirs fall back to the mod's built-in full-button preset. l10n: 2 new
// keys (renderer_follow_global, renderer_shadowed_by_profile) + hide_controls
// + renderer_backend detail reworded x4 languages.

// REVISION 17 addendum (Task 142, no bump): renderer selection collapsed to a
// single "mg" entry + follow-global switch (the user's long-standing design,
// restated this round: "renderer selection should have only one mg, no
// backend written -- the backend follows the mg settings, Vulkan by
// default"). The renderer layer (video.renderer global + per-profile
// renderer key) now stores only logical keys (auto / mg / classic dylibs);
// the MobileGL family keys (libMobileGL / libMobileGL-gles / libmithril)
// moved to a dedicated backend key mobileglues.renderer_backend (default
// libMobileGL.dylib = Vulkan direct), picked in Settings > MobileGlues.
// ame_effective_renderer gains the mg branch: backend resolution via
// ame142_effective_backend_key (new key -> legacy global family key ->
// legacy mobilegl_backend tier -> Vulkan default) with a dylib guard that
// falls back to the default backend before auto; ame142_migrateRendererStorage
// one-time re-layers legacy direct-written family keys (global AND every
// profile) into the new scheme and retires the legacy tier key at the same
// time (explicit pick = the legacy end Task132 promised), keeping
// JavaLauncher's MOBILEGL_BACKEND_TYPE env consistent. The game editor
// (ProfileSettingsViewController) gets an EXTERNAL follow-global toggle row
// above the renderer row: ON removes the profile key and grays the renderer
// row out (value shows the global default's name); OFF enables the slim
// picker (classic list + the single mg entry, family keys checkmarked onto
// mg). The Settings backend row reads/writes its own key only (Task132-140
// wrote the renderer key -- the two layers masquerading as each other was
// the "picked a backend, the renderer row followed" confusion). Audit fix
// included: the Settings renderer row getPreference now returns the STORAGE
// key (Task140 returned the localized display name, which can never match
// pickKeys -- the picker checkmark was silently lost for auto/gl4es/zink;
// typePickField's ame132 branch maps the label). Device anchors:
// "[Amethyst] Task142: global renderer <family> migrated to 'mg'",
// "[PLPrefTable] Task142: renderer_backend written to OWN KEY", game editor
// toggle row + grayed renderer row, picker with a single "mg" option.
// l10n: -1 retired key (renderer_follow_global picker format) +3 new
// (renderer_follow_global_toggle / renderer.debug.mgfamily /
// mg_backend_missing_dylib) x4 languages.
// REVISION 17 addendum (Task 150, no bump): renderer GLOBAL control retired
// (user decree, [revertable] -- each game MUST own its renderer choice).
// The Settings-page global renderer row (video.renderer) is gone together
// with the game editor's follow-global toggle (Task142's external switch):
// PLProfiles resolveKey drops the video.renderer fallback (guarded against
// getPrefObject(nil)), so ame_effective_renderer now resolves
// [profile key -> auto] -- instances without an explicit choice run auto
// (user-confirmed default; 1.17+ resolves to MobileGL Vulkan direct via the
// Task144 upgrade). loadSettings defaults missing keys to "auto" and
// saveSettings writes explicit values (nil can no longer remove the key).
// l10n: -2 retired (renderer_follow_global_toggle /
// renderer_shadowed_by_profile) +6 new (component.sodium.*) x4 languages.
// Component install gains a Sodium entry (flame icon, Fabric-only): one
// tap downloads Sodium + Podium from Modrinth (exact-title match vs
// Sodium Extra / Podium Port forks; gameVersion+fabric loader matched
// like Fabric API) into the instance mods/ dir; Podium disables Sodium's
// PojavLauncher check, doubling the Task145 POJAV_RENDERER unwind.
// REVISION 17 addendum (Task 154, no bump): MobileGL FSR chain RETIRED to
// the da5918a semantics + Mithril double-classloader pin removed + Forge
// isolation v2. (1) The whole launcher-side MobileGL FSR linkage is retired
// (ame83_fsr_capable_renderer returns NO for both mg backends -- mgFsrScale
// pinned at 1.0: no window shrink, no touch division, no deferred arming;
// ame_mgl_fsr_before_swap hard-returns false behind a Task154 gate, full
// chain archived under #if 0): the 7c32bc3 Vulkan session proved
// libMobileGL's EGL is a fake-EGL (surface/ctx handles are 0x1, no current
// tracking) so eglGetCurrentDisplay/CurrentSurface return nothing and the
// Task153 deferred shrink never fires -- MC's window belief stays full
// while sendTouchPoint keeps dividing by mgFsrScale (touch quarter-screen
// misalignment, FSR no-op); the d36a24f sessions proved the chain's
// belief-geometry draws destroy frames when it DOES run (Vulkan corruption,
// ES "blocks not rendering"). User's own baseline: da5918a/5.1.0 (sessions
// 9f32cb4 + 1d4ff3a) shipped MobileGL with zero launcher-side FSR and was
// fully working; libMobileGL.dylib is byte-identical since da5918a, so the
// entire regression was launcher plumbing. FSR remains on MobileGlues/zink.
// (2) Task152b removed from Tools.launchMinecraft: preloading GL/Library
// through the SYSTEM classloader poisoned the JVM's
// one-native-library-per-classloader invariant for MC's Knot-loaded
// Library.<clinit> ("already loaded in another class loader", masked by
// LWJGL as "Failed to locate library: liblwjgl.dylib" -- the 3b35b26
// Mithril crash). Its premise (shipped GL.class ignoring
// org.lwjgl.opengl.libname) is disproven by jar inspection -- the MACOSX
// branch reads it since c71dcfa. The real Run #356 culprit, the
// GL$1 Delegate's eglGetProcAddress indirection (Mithril's returns broken
// pointers for core gl*), is fixed by scripts/patch_lwjgl_delegate_dlsym.py:
// a same-length constant-pool byte swap in lwjgl-341's lwjgl-opengl.jar
// ("eglGetProcAddress" -> "xglGetProcAddress") that dead-ends the
// indirection so every GL symbol resolves via dlsym on the provider
// handle -- which is how MobileGL (eglGetProcAddress returns 0 for gl
// names, Task140) and gl4es/tinygl4angle (no eglGetProcAddress export)
// already work today; OSMesaGetProcAddress stays for zink. Mithril's
// _glGetString/_glGetIntegerv/_glGetError dlsym exports are verified in
// its LC_DYLD_EXPORTS_TRIE (2082 exports). POJAV_RENDERER export retired
// for Mithril too (the 3b35b26 Mithril pack ships sodium 0.9.2, whose
// PostLaunchChecks throws on that env var -- Task145's own finding).
// (3) Forge split-package isolation v2: Task153's -Xbootclasspath/a move
// broke MinecraftAccount.<clinit>'s System.loadLibrary("AmethystAccountJNI")
// (boot loader searches only sun.boot.library.path -- "no AmethystAccountJNI
// in system library path", the 3b35b26 Forge crash). v2 uses
// BootstrapLauncher 1.1.2's own -DignoreList (source-verified filename-
// prefix matching): launcher.jar stays on -cp with the system classloader
// (loadLibrary intact) and is excluded from the MC-BOOTSTRAP module layer
// (no "launcher" automatic module -- the split package is rooted at the
// mechanism designed for exactly this). Device anchors:
// "[MGLFSR] Task154 MobileGL pre-swap FSR chain RETIRED", Vulkan/ES touch
// realignment + blocks rendering; Mithril past NativeLibrariesBootstrap
// with "[JavaLauncher] Task154 Forge ignoreList shield: '...launcher.jar'"
// on Forge sessions.

// REVISION 17 addendum (Task 156, no bump): four-render family + IME + UI.
// (1) ES (DirectGLES) blocks-invisible: pinned as an upstream MobileGL
//     26.08-dev Espryt translation-layer fault (every launcher-side suspect
//     was cleared across Tasks 140/153/154 -- d089745 already showed the
//     symptom pre-regression; Task113's "GLES variant misbehaves upstream"
//     warning was right). Binary strings expose the runtime tier switch:
//     MOBILEGL_ESPRYT_MULTIDRAW_MODE now forced to 'drawelements' (per-draw
//     glDrawElements loop) for the ES backend at both JavaLauncher and
//     egl_bridge selection sites -- chunk batches avoid the silently
//     dropping native/ext multi-draw tier. Vulkan (Magma) keeps its own
//     MOBILEGL_MAGMA_MULTIDRAW_MODE and is untouched. Device anchor:
//     "[JavaLauncher] Task156: Espryt multidraw tier forced to 'drawelements'".
// (2) Mithril (4.0) / by zero: decompiled MC 26.2 GlHeuristics -- DeviceLimits
//     reads GL33C.glGetInteger(35380) (GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT);
//     Mithril answers 0 -> DynamicUniformStorage's Mth.roundToward divides
//     by zero. New Natives/mithril_gl_shim.c builds libmithril_glshim.dylib
//     (Makefile dep_mithril_glshim, openal_shim re-export pattern): re-exports
//     every libmithril symbol, local glGetIntegerv/glGetInteger64v floor
//     zero limit enums (3379/34852/35361/35380 + 64-bit variants), and the
//     eglGetProcAddress funnel keeps dlsym-direct semantics under both GL$1
//     Delegate states. JavaLauncher points Mithril's
//     -Dorg.lwjgl.opengl.libname at the shim (existence-guarded). Anchor:
//     "[JavaLauncher] Task156: Mithril libname -> GL shim ...".
// (3) Forge android.util.ArrayMap: GLFW.class (the lwjgl overlay) declares
//     ArrayMap fields; the MC-BOOTSTRAP ModuleClassLoader parents to the boot
//     layer, so the -cp stub in launcher.jar is invisible to it (0d45e3f
//     latestlog.forge: GLFWErrorCallback$1 -> apiClassTokens ->
//     NoClassDefFoundError). The five android/util stubs are now ALSO
//     compiled into the lwjgl overlay (JavaApp/src/lwjgl/android/util/) so
//     both lwjgl-333 and lwjgl-341 merged jars carry them in the module
//     layer. Anchor: Forge reaches past DisplayWindow.initWindow.
// (4) IME (iPadOS 27): TrackedTextField gains the public UIKeyInput
//     insertText: catch-all (80 ms same-text dedup vs the private
//     insertFilteredText:/replaceRange paths) and nil-guarded/clamped
//     setAttributedMarkedText (NSNotFound backspace floods). The
//     TouchController text field is now the Ame156TCIMEAwareTextField
//     subclass: marked-text updates fire didChange and sendTextInputStatus
//     reports real markedTextRange composition bounds instead of 0/0.
// (5) UI: blur/opacity sliders get their (already localized) row titles
//     displayed + a semantics footer (background.effect.footer, l10n
//     1945->1946); the FSR row detail now states honestly that the mg
//     family (Vulkan/ES/4.0) has no launcher-side FSR and points to the
//     video Resolution scaler; the right panel's 7 info cards are tappable
//     and deep-link into settings (LauncherPreferencesViewController
//     ameDeepLinkKey scroll+flash; game version card -> VersionManager).

// REVISION 17 addendum (Task 158, no bump): mg backend remap back to
//     MobileGlues + Forge module-layer text2speech stubs + launch-time
//     library gate. User's ground truth (their own uploaded 5.1.0 logs,
//     9e6fc27 build): latestlog.4.0 (customGLVersion=40) and latestlog.es
//     (enableANGLE=3 + customGLVersion=32) both ran MC 26.2 fully playable
//     WITH fsr1Setting=4 (swapOK=1920 / 1034, exit(0)) -- those sessions
//     were libmobileglues.dylib, NOT the MobileGL/Mithril binaries the
//     Task131 rework silently substituted under the same "mg" label.
//     (1) ame_effective_renderer's mg branch now resolves the GLES and
//     OpenGL 4.0 backend keys to libmobileglues.dylib (MobileGlues; dylib
//     existence-guarded, falls back to the Task142 chain). ame83 FSR
//     capability therefore returns YES for them: the fsr1_setting preset
//     linkage (MC window = surface/scale + renderer-side FSR1 upscale +
//     matching touch math) is restored bit-for-bit to the 5.1.0 behavior.
//     init_loadMobileGluesConfig forces the 5.1.0 config per backend via
//     ame158_mg_mobileglues_mode(): GLES -> enableANGLE=3 (ForceEnable) +
//     customGLVersion=32; 4.0 -> enableANGLE=0 + customGLVersion=40; mode 0
//     (standalone MobileGlues / mg Vulkan-direct) keeps passing the user's
//     own MobileGlues section preferences through. Vulkan direct stays
//     libMobileGL.dylib (da5918a semantics; Task154's mgl_fsr retirement
//     untouched -- its EGL is fake, FSR linkage there equals input skew).
//     (2) Forge 1.20.1 Narrator CNFE (10cee5d latestlog.forge, crash at
//     GameNarrator.<init>): BootstrapLauncher 1.1.2 + securejarhandler
//     2.1.10 sources verified line-by-line (scripts/task158_bl/) -- the
//     MC-BOOTSTRAP/GAME ModuleClassLoaders parent to the boot/platform
//     layers, the system classloader is invisible to them, and
//     launcher.jar is ignoreListed (Task154), so nothing provides
//     com.mojang.text2speech inside the module layer. Fix: JavaApp/Makefile
//     now also builds mojang-stubs.jar (only the com/mojang/text2speech
//     stub classes, same bytes as launcher.jar's), shipped into app/libs
//     -> always on -cp -> always in java.class.path -> auto-modularized
//     into MC-BOOTSTRAP (filename matches no ignoreList prefix). The real
//     text2speech library stays _skipped in Java preProcessLibraries
//     (it would split-package with the stub module). Device anchor: Forge
//     gets past GameNarrator, no NoClassDefFoundError.
//     (3) Launch-time library gate (ame158_repairMissingLibraries,
//     non-blocking): before the JVM starts, every non-skipped library in
//     the merged version JSON is checked on disk; missing jars download
//     synchronously (official URL -> BMCLAPI mirror) so a silently-missing
//     library stops turning into an in-game NoClassDefFoundError crash
//     (BootstrapLauncher silently skips non-existent paths). Failures are
//     logged by name and never block (some missing libs are historically
//     tolerated). Anchors: "[JavaLauncher] Task158: library gate summary"
//     / "downloading missing library jar".
// REVISION 17 addendum (Task 159, no bump): resolution scale per-instance.
// The global Settings slider (video.resolution, 25-150%) is retired from the
// Settings page (same migration philosophy as Task 150's renderer retirement):
// each instance now owns its scale via the profile key "resolution", edited in
// the game editor right under the renderer row as an inline 25-100 number field
// with a separate "%" label (not inside the field). Resolution chain:
// [profile resolution -> legacy global video.resolution fallback -> 100], the
// PLProfiles prefDefaults mapping restored exactly like the reverted renderer
// fallback -- legacy global values keep applying to instances without an
// explicit choice until the user saves one. Launch-time single point:
// SurfaceViewController reads resolveKeyForCurrentProfile (same philosophy as
// ame_effective_renderer); the in-game resolution menu and the Java GUI
// ("Execute .jar", no instance context) keep reading/writing the global key.
// The memory-allocation card was replaced by a game-directory-style input
// dialog the same round (512..max-allocatable clamp); the auto-allocate switch
// retired with the card (stock memoryAuto profiles keep the stock auto-ratio
// semantics until one manual confirm). Manage Java gains the "26.0 and newer"
// preselect slot (tag 1_26_newer -> Java 25) with the launch/installer chains
// adapted to the three-tier defaultJRETag split. l10n: +5 new
// (manage_runtime.default.126 / footer.java25 / profile.title.resolution_scale
// / memory.adjust_title / memory.adjust_message) -1 retired (memory.current)
// x4 languages, baseline 1948->1952.
// REVISION 17 addendum (Task 160, no bump): Neumorphism UI regression + first-
// launch defaults. (1) The per-instance resolution-scale accessory is restyled
// to match the memory row (secondaryLabel gray digits at the system detail
// size, a separate % label, and a trailing chevron since the accessoryView
// suppresses the cell's disclosure arrow) and the clamp widens 25-100 ->
// 25-150 (the legacy global-slider range). (2) First-launch defaults only
// (stock users keep saved values): ui_theme dark->light, blur-mode uiOpacity
// 0.7->0.1 (panels nearly transparent against the wallpaper, readability
// carried by the 75% blur, up from 70%). (3) Modal sheets get their backdrop
// back: makeViewControllerTransparent now lays a page-level SystemThinMaterial
// glass layer under modal VCs (presenting chain check skips the sidebar /
// right panel / root content area, which keep showing wallpaper); the
// VersionManager section-header SystemMaterial block is deleted outright (the
// "Game directories / Installed versions" titles float on the wallpaper).
// (4) Neumorphism rebuilt natively per the user's CSS spec: dynamic surface
// #e0e0e0/#2c2c2c, dual outer shadows (dark bottom-right, highlight top-left)
// scaled by element size (340pt = 100% spec: radius 50 / offset 20 / blur 60,
// floors 8/4/12), primary text #333333/#f5f5f5, secondary #888888/#a0a0a0.
// The ame_apply{Card,Raised,Panel}Surface entry points now route through the
// engine; cell pipelines use a flat variant (shadows would clip/stack in
// lists). Settings-page text shadows (the "double-drawn text" ghosting) and
// the multi-line title/detail overlap are fixed back to native single-line
// label/secondaryLabel rendering. l10n baseline unchanged (1952).
// REVISION 17 addendum (Task 161, no bump): six-fix round on the 9c66184
// device logs ("3 backends all work now, but no FSR upscaling/sharpening
// anywhere, even zink"; wallpaper-settings page covered after the first-
// launch restart; Bing wallpaper still requiring a restart to silently
// load; appearance default; sidebar info-card crashes; keyboard auto-pop
// on MC <=26.2). (1) FSR root fix: renderer=auto now consumes the mg
// backend key (ame_effective_renderer's auto branch consults
// ame142_effective_backend_key -- GLES / OpenGL 4.0 remap to
// libmobileglues.dylib per Task158, Vulkan/default keeps returning "auto"
// so the legacy per-version ANGLE fallback is untouched); the modpack-
// imported profiles carry no renderer key and were permanently resolving
// to libMobileGL.dylib (Task154-retired FSR chain) while the user's
// backend pick in Settings > MobileGlues was silently ignored --
// ame158_mg_mobileglues_mode follows the same source so auto+GLES gets
// the 5.1.0 forced config (enableANGLE=3 + customGLVersion=32; without
// it the ES blocks-invisible regression returns). zink keeps its
// sentinel-verified EASU path untouched. (2) Wallpaper-settings cover:
// the Task160 modal glass backdrop must never be insertSubview'd into a
// UITableView (view==tableView form, i.e. BackgroundSettingsViewController)
// -- foreign subviews inside a table are unsupported and on iPadOS 27
// manifested as the whole page covered with dead sliders; table
// controllers now hang the glass on tableView.backgroundView, with the
// ame160 call moved to the tail of makeViewControllerTransparent (after
// the table branch nils backgroundView) and the settings pages' own
// viewWillAppear/reapply stops wiping it; the background container's
// decorative blur+dim layers get explicit userInteractionEnabled=NO.
// (3) Bing live-apply root cause: removeGlobalBackground nil-ed
// currentWindow/currentSplitVC AFTER applyBackgroundToWindow had just
// registered them, so every later setBingBackgroundImageAtPath took the
// both-nil branch (state saved, live UI never updated) = "needs a
// restart"; the host references are now left intact (both weak, mutual
// exclusivity owned by the apply methods). (4) Appearance default now
// "follow system" (ui_theme light->auto) with a one-time migration that
// only rewrites devices still sitting on the historical dark/light
// DEFAULTS and never those explicitly chosen (general.ui_theme_explicit
// marker set by the settings picker). (5) Sidebar info-card crash: the
// Task156 deep link indexed prefContents and called selectRowAtIndexPath
// while the target section was collapsed (PLPrefTable sections default to
// 1 header row) -- out-of-bounds selection on check_update / jit_enabler
// / memory_limit_help; the link now expands the section first and guards
// the row against the visible row count. (6) GLFW-path chat keyboard
// (MC <=26.2 has no text-input protocol unlike 26.3's SDL screen
// keyboard): nativeSendKey records the last pressed key; updateGrabState
// auto-shows inputTextField when an ungrab follows a T/slash within 1.5s
// (auto-shown flag auto-dismisses on re-grab; manual keyboard unaffected;
// SDL path untouched). JavaLauncher's stale "auto will be resolved to
// ANGLE" warning reworded to the Task144/161 semantics.

// REVISION 17 addendum (Task 162, no bump): eight-fix round on the bf91f41
// build (cbef9d5 logs, iPad Air M4 / iPadOS 27). (1) Profile identity
// consistency -- THE "switch a renderer and it silently reverts to auto"
// root cause: ProfileSettingsViewController saved under the profile's
// display NAME while the launch chain resolves by the dict KEY
// (selectedProfileName), and the modpack import collision suffix
// ("Name (2)" key vs "Name" field) plus the home version picker writing
// the name field into selectedProfileName made key!=name a reachable
// steady state; the editor now records profileDictKey at load and
// reads+writes the same key (rename re-keys old->new, existing-entry
// base taken from the target key so partial dicts never clobber real
// entries), and the picker selects by sorted key snapshot (allValues
// row-drift retired). Renderer/memory/resolution/java writes all land
// on the entry the launch reads. (2) Forge save-load crash: the lwjgl
// overlay's glfwSetInputMode called net.kdt.pojavlaunch.uikit.UIKit
// (launcher.jar-only class) on cursor grab -- Forge's MC-BOOTSTRAP
// module layer (launcher.jar ignoreList-ed) can't see it ->
// NoClassDefFoundError in ReceivingLevelScreen.onClose; the Java-side
// call is removed and the GLFW-path nativeSetGrabbing now runs the
// Task63 refreshGuiScaleNatively (same as the SDL path), keeping hotbar
// hit-testing fed with zero class-visibility dependencies. (3) Bing
// "loads but needs a restart": the already-today silent skip now checks
// isBackgroundLiveAttached (container in a live window + host refs
// alive) and re-plays setBingBackgroundImageAtPath when the registered
// state has no live UI, self-healing any past detached apply on every
// metadata sync / foreground / manual refresh. (4) Wallpaper defaults
// per user decree: frosted glass, opacity 60%, blur 100% (first-run /
// never-saved devices only). (5) Home avatar missing after tab switch:
// updateSkinDisplay now goes AvatarManager local -> session NSCache ->
// network (cache fill), so viewWillAppear renders instantly instead of
// flashing the placeholder through a full re-download. (6) Account list
// refreshes on viewWillAppear + AccountChanged/UpdateAccountInfo
// (adding an account no longer needs a manual refresh). (7) CurseForge
// source usable without an API key: with no key configured the API base
// URL is forced to the MCIM mirror (server-side public key, verified
// keyless GET /mods/search -> 200) and the five UI gates switch from
// isAPIKeyConfigured to isSourceAvailable -- official-direct remains
// available for keyed devices under the mirror policy. (8)
// announcements.json: server recommendation mysv.dpdns.org entry added
// (dated top-of-list) and the v6.0.0 defaults wording synced to the new
// 60%/100% + follow-system values. verify_task162 68 checks; cascades
// re-anchored: task150/157/159 announcement index [0] -> by-id (new
// entries legally take the head slot), task160 B2/B3/B5/F1/F4 re-anchored
// to the Task162 defaults decree.

// REVISION 17 addendum (Task 163, no bump): neumorphism scope correction on
// device feedback -- Task160 applied the raised surface to the wrong
// objects and left the intended ones flat. (1) Sidebar/right-panel shadow
// retirement: ame_applyPanelSurfaceWithRadius now routes to the flat
// variant (spec surface + clamped radius, no shadow host view) -- the
// full-height chrome containers sat near the 340pt metric base so their
// proportional offset/blur bled onto the central cards ("you changed what
// should not be changed"); maskedCorners (outer two corners only) and the
// creation-time masksToBounds=YES are untouched. (2) Home tiles and the
// download version cards gain the raised form:
// applyEffectToCollectionViewCell's no-wallpaper branch now mounts
// AmeNeumorphShadowView on the card target with the clip chain released
// (cell.clipsToBounds=NO, contentView masks=NO) so the dual shadow reads
// across tile gaps; wallpaper branches strip stale shadow hosts first via
// the new ame_removeNeumorphShadow (UIKit+NativeSurface). (3)
// VersionCardCell moves to the new applyNeumorphCardEffectToView:
// pipeline (wallpaper -> legacy applyEffectToView detour with shadow
// cleanup; no wallpaper -> raised surface). (4) ProfileSettings page-wide
// chevron unification: every UITableViewCellAccessoryDisclosureIndicator
// row (renderer / graphics API / Java / memory / game dir / managers)
// swaps to the same self-drawn chevron.right accessory as the Task160
// resolution row (ame162_disclosureChevron, 8x13 tertiaryLabel glyph in a
// 14x30 container) -- the mixed system/SF-symbol glyph weights read as a
// mismatch side by side. applyCardEffectToCell (table rows) and the
// Card/Raised surface methods keep their Task160 forms.

// REVISION 17 addendum (Task 164, no bump): ES / OpenGL 4.0 black-screen
// fix + wallpaper first-launch defaults repair. Device evidence
// (56c8173 logs, build 678a76f): both MG-remap sessions present the
// Task130 RCAS chain engaged (render 1180x820 -> EASU -> target
// 2360x1640 -> RCAS -> surface) with fps=58 / swap 100% OK / zero GL
// errors -- yet the screen stays black; the 5.1.0 healthy baseline
// (a0ac656 latestlog.es / latestlog.4.0) is byte-identical pipeline
// EXCEPT it is EASU-only (no RCAS pass existed) and shows a picture.
// The modpacks match (continuity/iris present in BOTH), so the delta is
// the RCAS pass itself. Four deviations from the proven zink RCAS form
// (osm_bridge, device-verified) are corrected in FSR1.cpp +
// FSRRCASSource.h: (1) FsrRcasLoadF now clamps its texelFetch taps to
// the input bounds via textureSize -- the fullscreen-quad entry
// generates out-of-range taps on every edge pixel (p+(0,-1) etc.);
// Mesa tolerates OOB texelFetch, ANGLE Metal maps it to MTLTexture
// read: which is UB and can void the whole frame (fps/swap green,
// screen black). Applies to all three TUs sharing the header (zink
// gains correct edge behavior, no visual regression). (2) Both
// directToSurface branches now disable GL_STENCIL_TEST (zink's
// five-state list; EGL configs carry stencil bits and mod shaders can
// leave a rejecting stencil test armed -- the quad gets discarded
// pixel-by-pixel while swap succeeds). (3) The RCAS draw now
// explicitly selects texture unit 0 and re-pins the sampler uniform
// every frame instead of relying on the init-time pin (zink form;
// glUniform1i(-1,..) stays a legal no-op). (4) A one-shot GPU probe
// (zink Task99 forensics form) reads a single fb0 edge pixel right
// after the first RCAS frame -- the install-verification anchor
// "[MG] Task164 RCAS GPU probe: ... nonzero = draw landed on GPU;
// all-zero = RCAS quad never landed" bisects state-eaten draws from
// presentation-layer failures on the next device round. Wallpaper
// defaults (BackgroundManager.loadUISettings): the Task162 range
// checks let never-saved keys fall through as valid values --
// integerForKey never-saved returns 0 == BackgroundUIEffectTranslucent
// (semi-transparent, NOT the decreed frosted glass) and floatForKey
// never-saved returns 0.0 which "< 0.0" cannot catch (0% blur). All
// three keys now branch on objectForKey == nil first (never saved ->
// frosted glass / 60% opacity / 100% blur; explicitly saved values,
// including a deliberate semi-transparent pick or 0% blur, are
// respected as-is). Vulkan-direct FSR remains upstream-impossible
// (libMobileGL ships zero FSR/EASU/RCAS symbols and no config
// surface; Task154 pseudo-EGL evidence stands) -- the FAQ fsr entry
// and the announcements support matrix carry the guidance: use the
// GLES / OpenGL 4.0 backend for the full MobileGlues FSR1
// (EASU upscale + RCAS sharpening).

// REVISION 17 addendum (Task 165, no bump): the REAL ES/4.0 black-screen
// root cause, found on the cc9bfe4 log pair (bc6c0b5 build) after Task164's
// four RCAS alignments changed nothing. Forensics: every black session (both
// backends, both log rounds) shows glXGetProcAddress NEVER called (the
// healthy 5.1.0 pair shows the own-image resolution + SYMBOL THEFT canary
// lines -- that function only fires from the frontend eglGetProcAddress,
// i.e. the app resolved through it), exactly 10 LWJGL "No context is
// current or a function that is not available" prints (healthy: zero), and
// the Task164 probe reading 000000ff (the Metal initial clear) with a
// pending 0x0500. Chain: Task154's patch_lwjgl_delegate_dlsym.py renamed the
// GL$1 Delegate's provider-library lookup "eglGetProcAddress" ->
// "xglGetProcAddress" (correctly killing Mithril's broken indirect layer),
// which silently forced MobileGlues sessions onto the per-name dlsym
// fallback; the flat namespace hands glDrawArrays / glTexImage2D /
// glFramebufferTexture2D (the canary trio) to the raw ANGLE image, so the
// application's draws bypassed gl/framebuffer.cpp's framebuffer-0 redirect
// and FSR1 upscaled a never-written render texture over the real frame.
// Invisible until Task161 re-armed the FSR linkage (the "3 backends fine"
// build ran libMobileGL for every backend setting). Fix: egl.cpp exports
// xglGetProcAddress -- the Delegate's dead-named lookup finds it in
// libmobileglues.dylib (pinned by -Dorg.lwjgl.opengl.libname) and gl*
// resolution owns the layer again; gated on AMETHYST_RENDERER containing
// "obileglues" (defense-in-depth -- other renderers keep Task154's dlsym
// semantics, OSMesa's OSMesaGetProcAddress untouched). FSR1.cpp gains (a) a
// one-shot render-texture probe (center pixel before the first EASU draw --
// nonzero = the app frame reached the render FBO, all-zero = the redirect
// was bypassed; splits the draw layer from the resolution layer on the next
// log) and (b) an RCAS runtime bail-out: first-frame fb0 corner AND center
// both black with healthy alpha-0xff reads latches EASU-only for the
// session and rescues the current frame with a direct EASU redraw -- the
// failure mode degrades from "black screen with healthy swap counter" to
// "unsharpened upscale" instead. Vulkan-direct FSR assessment (user ask):
// libMobileGL stays closed (zero FSR symbols, pseudo-EGL per Task154) and
// the mgl_fsr pre-swap war stays retired; the safe launcher-side option is
// a render-scale tier (window + drawableSize at render res, CA stretch)
// which trades EASU sharpness for determinism -- deferred pending the
// user's call, GLES/4.0 + full FSR1 at 60fps is the recommended path.

// Task 166 (REVISION 17 addendum, no bump): Vulkan-direct FSR ships + the
// real ES/4.0 black-screen config culprit. (1) Vulkan FSR: the Task154/165
// "upstream hard limit" verdict was re-litigated after finding the
// open-source upstream (MobileGL-Dev/MobileGL, LGPL) -- libMobileGL still
// has zero built-in FSR, but MoltenVK consumes its swapchain images through
// the id<CAMetalDrawable> ObjC protocol, so the launcher intercepts
// presentation instead: a private CAMetalLayer subclass (Layer B, render-res
// via explicit EGL_WIDTH/HEIGHT attribs) feeds MobileGL's pseudo-EGL ->
// vkCreateMetalSurfaceEXT -> MoltenVK swapchain at render resolution, while
// Layer B's overridden nextDrawable hands MoltenVK a wrapped drawable backed
// by an 8-slot MTLTexture ring; the wrapper's present runs AMD FSR1
// EASU (12-tap) + RCAS (5-tap, AMETHYST_FSR_RCAS_SHARPNESS, negative = off)
// ported verbatim to MSL (ffx_a.h 32-bit constants 0x7ef07ebb / 0x7ef19fff /
// 0x5f347d74, Task164-style OOB clamps inside the load helpers) into the
// view's real full-res layer. Zero changes to the MobileGL/MoltenVK
// binaries; the Task154 pre-swap GL war stays retired (pseudo-EGL root
// cause unchanged; double-upscale guarded); ame83_fsr_capable_renderer
// re-includes libMobileGL.dylib only (libMobileGL-gles stays excluded);
// ame48_swap_geometry_guard records Layer B so the surface-vs-layer
// comparison stays still; kill switch AME166_MGL_METAL_FSR=0; any init
// failure falls back to da5918a full-res direct semantics. Install anchors:
// "[MGLFSR] Task166 Metal FSR engaged", "first frame presented",
// "steady: 600 frames". (2) ES/4.0 black screen: after Task164 (RCAS edge
// clamps) and Task165 (xglGetProcAddress resolution routing) each failed to
// heal it, a three-session A/B on the same device/modpack/MobileGlues
// 2.0.17 isolated the sole config delta: enable_ext_direct_state_access
// (DSA). DSA=0 (9e6fc27 healthy pair) = "DSA support not detected" =
// playable with FSR; DSA=1 (cc9bfe4 pair + 3368468) = "ARB_direct_state_
// access detected, enabling DSA" = black screen with healthy swap counters.
// Task129d had forced DSA=1 citing zink perf (Mesa native DSA -- never
// applied to MobileGlues' DSAWrapper emulation under the FSR1 fb0
// redirect). Fix: default @NO in three places (PLPreferences,
// JavaLauncher config.json, ame130 migration branch retired) plus a one-shot
// reverse migration ame166_migrateMgDsaBlackScreen (persisted 1 -> 0,
// sentinel task166_dsa_blackscreen_migrated; Task130's 0->1 neutralized so
// fresh zeros are not flipped back); the settings toggle remains for manual
// override. verify_task129 D1/D3 and verify_task130 E9/E10 re-anchored.

// Task 167 (REVISION 17 addendum, no bump): the Task166 IPA's two fixes both
// failed on device (upload 1b76d19: Vulkan crashed, GLES/4.0 still black) --
// both root causes found and fixed the same session. (1) Vulkan crash:
// MoltenVK's surface extent source is NOT CAMetalLayer.drawableSize but the
// CAMetalLayer+MoltenVK category's naturalDrawableSizeMVK = bounds x
// contentsScale (MVKSurface::getNaturalExtent feeds surface capabilities'
// currentExtent). Task166's Layer B only set drawableSize, leaving bounds at
// CGRectZero -> currentExtent = {0,0} -> MobileGL's RecreateSwapchain
// zero-area guard installed NO swapchain -> m_images empty + first acquire
// deferred -> MC's first DSA glBlitNamedFramebuffer(fb0) hit
// SwapchainObject::GetImage(0) on an empty vector = nullptr load. The
// disassembly of the shipping dylib matches the device crash pc byte-for-
// byte (GetImage+0x28 is exactly the ldr x0,[x0] of m_images[index]; the
// assert is compiled out at INFO level, so the OOB/empty read is a raw
// SIGSEGV). Fix: Layer B writes bounds + contentsScale(1.0) alongside
// drawableSize at all three geometry sites (create / existing-layer sync /
// update_size hook); contentsScale=1.0 keeps natural == drawable ==
// swapchain extent so MVKSwapchain::hasOptimalSurface stays optimal. (2)
// The DSA reverse migration never executed: it was wired into
// application:configurationForConnectingSceneSession:, which UIKit only
// calls for NEW scene sessions -- devices whose session predates the code
// never run it again (60+ uploaded device logs contain zero log lines from
// anything inside that callback, including Task130-era unconditional
// lines). Meanwhile the Task129d-era @YES default was persisted into the
// plist by the defaults merge at every launch of those builds, so the
// stored 1 suppressed Task166's fresh @NO default and both 1b76d19 sessions
// still read enable_ext_direct_state_access = 1. Fix: the always-run call
// site moved to main.m right after toggleIsolatedPref (effective store
// active, before any consumer), the AppDelegate site kept as a fresh-install
// early trigger (sentinel makes the two idempotent), and
// ame166_migrateMgDsaBlackScreen gained NSNumber/NSString dual-type
// tolerance plus an unconditional run anchor log. Install anchors:
// Vulkan = "[MGLFSR] Task166 Metal FSR engaged" + "first frame presented"
// (and no GetImage crash); GLES/4.0 = "[Preferences] Task167 MG DSA
// black-screen migration ran (stored=1, flipped=1)" + "DSA support not
// detected" + a visible frame. verify_task166 C2 + verify_task130 E10
// re-anchored to the Task167 forms.

// Task 169 (REVISION 17 addendum, no bump; app version 6.0.0): device feedback
// quadruple fix + release prep (upload 485b18c, af9b807 -- the build where
// Task167 finally shipped: user confirmed Vulkan + ES/4.0 fixed, "OK了").
// (1) CurseForge source "completely unusable": the MCIM mirror's upstream key
// pool intermittently fails, returning HTTP 200 + valid JSON with NO "data"
// array ({"error":"Internal Server Error","code":500,"detail":"... 403 ..."}).
// The old parser treated that shape as "no results" and silently completed
// with @[] -- all four logged searches showed starting-request lines with
// zero completion logs, and the UI showed an empty list with no error.
// Sandbox reproduction confirmed the intermittency (3 failures in one window,
// then 6 straight successes). Fixes in CurseForgeAPI.m: gateway-error JSON
// detection (no "data"/"pagination" + error/code keys) with logging, ONE
// automatic retry after 1.5s (transient upstream failure), then a real NSError
// carrying the upstream detail (both async search and sync getEndpoint);
// CFACompiledAPIKey now rejects stringified NULL literals ("((void *)0)",
// "(nil)", "NULL", "0" -- the 11-char garbage the device logs showed being
// sent as x-api-key while suppressing the keyless forced-mirror fallback);
// gameVersion normalized (fabric build-hash suffix like "26.3-0a78cefc"
// stripped to "26.3") at both search builders.
// (2) Local modpack import required pre-copying into the app container: the
// document picker URL is a security-scoped resource; the old flow released
// the scope right after parsing, while the install phase (importModpack:)
// re-read the whole archive via info[@"filePath"] -- out-of-sandbox picks
// lost access by then (only "On My iPhone" copies happened to work).
// ModpackImportViewController now copies the picked file into app tmp WHILE
// the scope is alive (also materializing iCloud placeholders), and parse/
// preview/install all use the local copy; stale copies cleaned at next pick.
// (3) Home avatar sometimes required a tap: the fetch used dataWithContentsOfURL
// (default 60s hang, fully silent failure, no persistence). AvatarManager
// gains fetchAvatarFromURL:completion: (10s timeout, Caches disk cache keyed
// by djb2 of the URL, failure logging, main-thread single-shot completion);
// LauncherNewsViewController and the right panel use it; the news VC also
// directly updates visible ProfileTileCells (reloadSections can miss repaints
// in some layout timings).
// (4) "zink renderer launch stuck at the launcher screen": the log ends at
// the FIRST JIT-wait round (f95a219's successful sessions show the game
// launching 2 lines after the same dance) -- the stikjit:// enabler failed
// that time and all three invokeAfterJITEnabled implementations had
// unbounded while(!isJITEnabled) polls: the wait alert never dismissed.
// utils.m gains ame169_waitForJITCondition (120s bound, 10s heartbeat logs);
// all six wait loops (RightPanel/NavCtrl/DownloadVC x isJITEnabled/
// JIT26DebuggerKeepAttached) bounded, with a retry/cancel alert on timeout.
// (5) Announcements: AnnouncementItem gains a "pin" field (bool/string
// tolerant) sorted ahead of date-desc by AnnouncementService; the server
// recommendation (mysv.dpdns.org) is pinned first per user request; task169
// announcement added; v6-0-0-release rewritten to the FINAL truth (Vulkan-
// direct FSR ships via the Metal presentation layer; the old "Vulkan does
// not support FSR" matrix retired) and redated. Info.plist 5.1.0 -> 6.0.0
// (CFBundleShortVersionString + CFBundleVersion).
// Task 168 (2026-09-25): neumorphism wallpaper-mode visibility + FAQ JSON.
// (1) Root cause of "downloaded the latest commit but no neumorphism": the
// Task163 raised-card pipeline only engaged WITHOUT a custom wallpaper --
// with one set, cards fell back to the legacy frosted-glass branch and never
// showed the spec surface/shadows. Fix: applyNeumorphCardEffectToView: and
// applyEffectToCollectionViewCell: no longer early-return into the legacy
// pipeline. With a wallpaper the card FACE still follows the user's
// opacity/blur settings (dynamic neumorphism = face per wallpaper settings +
// dual-shadow overlay via the new ame_attachNeumorphShadowOnly, which keeps
// the face color untouched); the new "cardsNeumorphSolid" preference
// (BackgroundSettingsViewController switch, default OFF) forces the solid
// spec surface + dual shadows, giving up wallpaper transparency/blur.
// (2) The 34 help-FAQ entries moved out of hardcoded ObjC into a bundled
// JSON (help-faq.json, same pattern as announcements): repo root = editing
// source, Natives/resources/help-faq.json = bundled copy read at runtime,
// byte-identical, drift-guarded by verify_task168. LauncherHelpViewController
// now parses it (icon/title/description fields, empty-groups on parse
// failure). Stale FAQ conclusions updated in the same pass: FSR entry now
// states all three backends are supported (Vulkan via the Metal presentation
// layer, Task166/167), MobileGlues chunk-loading entry gains the
// Vulkan+FSR recommendation.

// Task 170 (2026-09-25): user followup on Task 168 -- the binary
// cardsNeumorphSolid toggle is retired in favor of a continuous
// "Neumorphism Opacity" slider (defaults key
// background_cards_neumorph_opacity, 0.0~1.0, default 1.0 = Task 168
// form untouched). The slider scales the WHOLE card as one unit
// (face + dual-shadow carrier + content) via the host view alpha,
// set in every terminal branch of applyNeumorphCardEffectToView /
// applyEffectToCollectionViewCell, so heavy edge halos reported on
// device can be dialed down directly. Home tile collection layout
// gaps unified to 20pt (item insets 10 + section insets 10), equal
// to the card-to-sidebar outer margin. l10n key renamed in place
// (background.cards.neumorph.opacity.title x6, count 1953). No
// engine (UIKit+NativeSurface) changes.

// Task 171 (2026-09-25): seven-symptom device-feedback round on the f26337d
// build (3 uploaded logs: latestlog.txt = ANGLE 26.3 FO pack, latestlog.old.txt
// = mg 26.3 multiplayer on mysv.dpdns.org, latestlog.old = mg 26.4-snapshot-1).
// (1) ANGLE renderer crash: libtinygl4angle.dylib was never in
// ame_glBridgeEnabled (sdl3_hook.m), so renderpearl's GlBackend pointer
// consistency check failed ("glGetError mismatch") -> Vulkan fallback ->
// Iris ExceptionInInitializerError (No GLCapabilities). The bridge now takes
// over SDL_GL for ANGLE too (AMETHYST_ANGLE_GL_BRIDGE=0 escape hatch).
// (2) Hotbar taps "a bit low": touchHotbar's hit rect ignored the FSR window
// ratio -- the visual bar spans physical 1640-88*1.7=1490..1640 but the gate
// was barY=1560 (device log: REJECT above bar y=1516/1556). Geometry is now
// ratio-aware (182x22 sprite x guiScale x physH/windowH; mcscale NOT used to
// avoid double resolutionScale division). (3) CurseForge "key not set at
// build time -> error": [headers] returning nil for keyless devices gated all
// three request paths on missingAPIKeyError BEFORE sending, while baseURL
// already forces the MCIM mirror -- keyless now sends Accept-only headers
// (mirror verified 200 keyless; official API is 403). (4) Home avatar missing
// on tab return: Task169's visible-cell direct sync only ran in the fetch
// completion; the session-cache-hit branch relied on reloadSections (dropped
// mid-transition). New ame171_syncVisibleProfileAvatar covers all branches +
// viewDidAppear. (5) Multiplayer intermittent crash: the referenced
// latestlog.old.txt session is CLEAN (60fps, exit(0)); the crashed session's
// log was lost to the one-generation rotation -- init_redirectStdio now
// preserves an exit-marker-less previous log as latestlog.crash.txt.
// (6) MC 26.4 falls back to Vulkan on zink and mg alike:
// PreferredGraphicsApi.DEFAULT.getBackendsToTry() flipped to {vulkan, gl} in
// 26.4 (26.3: {gl, vulkan}) + the OptionsForceDefaultGraphicsApiFix datafix
// resets the stored option -- Tools.java now appends --graphicsBackend opengl
// for MC >= 26.4 when the renderer is not native MoltenVK (both 26.3 and
// 26.4-snapshot-1 Main accept the argument; GL failure still falls through to
// Vulkan via the same order table). (7) Keyboard first-session race ("must
// press the IME button once after the keyboard appears"): device log shows
// becomeFirstResponder=1 on EVERY input-method press = the field loses first
// responder after each typed character (text=@" " assigned AFTER become +
// clearsOnBeginEditing fighting iPadOS 26+ UIAsyncTextInput session
// activation). Fix: sentinel text now written BEFORE becomeFirstResponder,
// clearsOnBeginEditing=NO, plus ame171_armKeyboardRecheck auto re-arm (0.4s
// health check, generation-guarded against user dismissal, max depth 2).

// REVISION 17 addendum (Amethyst Task 172, no bump): six-symptom round from
// the 9be2b53 device logs (760c07c upload: latestlog.txt = launch stuck at
// JIT wait, latestlog.old.txt = mg 26.3 multiplayer, latestlog.old = ANGLE
// 26.3 FO pack). (1) ANGLE glGetError mismatch PERSISTS with the bridge
// hooked -- CFR decompile of the bundled lwjgl-333 GL$1.class proves the
// macOS-platform provider chain NEVER consults eglGetProcAddress (LINUX:
// glXGetProcAddress/ARB, WINDOWS: wglGetProcAddress, fallback-for-all:
// OSMesaGetProcAddress; query: GPA(name) then library dlsym). The old mirror
// tried eglGetProcAddress first: harmless for MG/zink (both chains converge),
// fatal for libtinygl4angle whose dependency libEGL exports
// eglGetProcAddress while glGetError is a direct libGLESv2 export -- two
// different addresses, mismatch, Vulkan fallback, Iris No GLCapabilities.
// ame_SDL_GL_GetProcAddress now mirrors the true GL.1 macOS branch
// (OSMesaGetProcAddress only) -- pointer identity holds by construction for
// every renderer. (2) Launch stuck at JIT wait >120s then crash: the
// stikjit:// URL backgrounds the app; if StikJIT fails to switch back, iOS
// suspends the process and the 120s poll loop FREEZES (device log: zero
// heartbeats after "still waiting after 0s", zero timeout, log just ends).
// On manual return, CS_DEBUGGED can already be set while the JIT26 debugger
// died -- launching then hits brk #0x69 with no one servicing it = the
// reported crash. All three invokeAfterJITEnabled implementations now (a)
// hold a beginBackgroundTask assertion across the wait (heartbeats/timeout
// keep printing, StikJIT can attach while we are backgrounded), and (b)
// after the wait succeeds re-check debugger liveness on TXM devices and
// route through the extracted ame172_reattachJIT26ThenLaunch (foreground
// wait + stikjit:// + bounded debugger-live wait) instead of launching
// blind. (3) Keyboard "must press the IME button once": the field loses
// first responder because MC 26.3's SDL_StartTextInputWithProperties makes
// SDL's OWN UIKit textField first-responder -- its window is the hidden SDL
// UIWindow (Task32 embed), its text delivery is dead, so keystrokes vanish
// until the user re-arms the launcher field via the IME button. Start/Stop
// hooks now post AME172_SDLStartTextInput / AME172_SDLStopTextInput right
// AFTER the real calls; SurfaceViewController routes the keyboard to its own
// inputTextField (Task171 sentinel order + re-arm) and resigns it when MC
// closes the text context. (4) Home avatar still needs a tap after tab
// return: AvatarManager's fetch-failure and bad-URL paths called the
// completion OFF the main thread (contract violation) -- UICollectionView
// reloads from a session thread silently no-op until the next UI touch.
// Both paths now dispatch to main; updateSkinDisplay logs every branch
// (local / session-cache / fetch / missing-URL) and the visible-cell sync
// reports cell count + image size; viewDidAppear adds a 0.35s
// post-transition re-sync pass. (5) Per-profile TouchController (user
// request): ProfileSettingsViewController gains a TouchController row
// (advanced section; picker on/off; summary reuses existing
// preference.touchcontroller.mode.* l10n keys -- zero new keys, zero count
// cascade). UIKit_launchMinecraftSurfaceVC now calls
// ame172_applyProfileTouchController before the root-VC swap: profile key
// touchController=YES auto-configures control.mod_touch_enable=YES,
// control.mod_touch_mode=1 (UDP) and control.mod_touch_hide_controls=YES
// (Task140 semantics: launcher's own control layer hidden, the mod's virtual
// buttons stay); OFF leaves the global settings untouched. (6) CurseForge
// mirror 5xx: the device log shows a transient 502 on classId=4471 that
// succeeded on the user's manual retry 5s later -- the async search now
// retries 5xx (empty or non-JSON bodies) with a 2s backoff (max 2), and the
// sync getEndpoint wraps AFNetworking 5xx failures into the existing
// code-543 retry loop.
// REVISION 17 addendum (Amethyst Task 173, no bump): neumorphism rewritten to
// the "normal state" as the single card path. User's repro pinned the root
// cause: with a Bing wallpaper active, toggling any UI effect and then
// disabling the wallpaper made neumorphism snap back to normal -- proving the
// good form (spec surface #e0e0e0/#2c2c2c + dual shadows) always lived in the
// no-wallpaper branch, while the wallpaper-adaptive "dynamic face" (glass/
// translucent card + attachNeumorphShadowOnly + host alpha) read as heavy
// edge halos (dark 20/60px shadows over a translucent face on a wallpaper).
// Changes: (1) new cardsNeumorphEnabled preference (background_cards_neumorph_
// enabled, default YES) gates a rewritten three-stage card pipeline -- ON =
// wallpaper-agnostic normal state everywhere (applyNeumorphCardEffectToView,
// applyEffectToCollectionViewCell, applyCardEffectToCell; stray blur layers
// stripped, host chain unclipped for shadow overflow); OFF = legacy pipeline
// (glass/translucent with wallpaper per the other UI-effect options, native
// flat without). The dynamic-face wallpaper-adaptation branch is retired
// wholesale. (2) Settings: a "Neumorphic Interface" switch row now sits under
// Blur Intensity (always visible, even without a wallpaper): ON greys the
// legacy UI-effect rows (picker + opacity + blur sliders, alpha 0.35 +
// interaction off) and enables the card-opacity slider; OFF reverses.
// (3) Opacity respecified as CARD-BODY opacity (user: fonts excluded): new
// engine primitive ame_applyNeumorphCardOpacity fades the dynamic surface
// color (alpha applied inside the dynamic provider per-trait, so dark/light
// stays correct) and the shadow carrier's alpha, leaving text/icon subviews
// fully opaque -- the old whole-host view.alpha scaling is gone from all
// terminal branches. l10n: new key background.cards.neumorph.interface.title
// x6 (four-main count 1953 -> 1954, historical anchors re-locked).

// REVISION 17 addendum (Amethyst Task 173, no bump): ten-symptom round from
// the fd31b79 device logs (Task 172 build, three sessions: ANGLE FO pack on
// 26.3, Zombie Invade 100 Days on 1.20.1-forge, old Forge 1.8.9).
// (1) ANGLE renderer crash AFTER the GL backend was accepted: the session
// dies at Minecraft.loadCriticalShaders -> Failed

// REVISION 17 addendum (Amethyst Task 173, no bump): ten-symptom round from
// the fd31b79 device logs (Task 172 build, three sessions: ANGLE FO pack on
// 26.3, Zombie Invade 100 Days on 1.20.1-forge, old Forge 1.8.9).
// (1) ANGLE renderer crash AFTER the GL backend was accepted: the session
// dies at Minecraft.loadCriticalShaders -> "Failed to find or load pipeline
// minecraft:pipeline/gui" -- the LWJGL line "No context is current or a
// function that is not available..." pins NULL function pointers. CFR
// forensics of the real 26.3 client.jar renderpearl GL backend: GlDevice
// calls GL33C.glColorMaski/glEnablei/glDisablei, GlCommandEncoder uses
// glDrawElementsInstancedBaseVertex, GlQueryPool uses glQueryCounter, and
// Iris uses glTexImage1D -- none of which exist in the ES-only export set of
// the bundled libGLESv2 framework, so the GL$1 macOS chain (OSMesaGetProc
// =0 then plain dlsym, Task 172's verbatim mirror) resolves them to NULL.
// tinygl4angle.c now carries a desktop-GL completion layer: ~20 wrappers
// (per-slot blend, multi-draw family, queries, tex buffers, FBO layered
// attach, copy image, 1D textures, GLdouble adapters) resolved at first
// call via eglGetProcAddress with EXT/OES/KHR/NV/ARB suffix fallbacks and
// safe degradation (slot 0 falls through to the non-indexed variant,
// multi-draw unwinds to per-draw calls, glLogicOp no-ops). Two latent bugs
// fixed in the same file: glShaderSource early-returned WITHOUT uploading
// ES-versioned shader sources (compile-empty programs), and the GLSL
// version string "OpenGL GLSL 3.30 (ANGLE...)" broke Iris's semver regex
// (prefix now stripped in glGetString). One-shot forensics logs the
// resolved/missing table on first glGetString.
// (2) Old-Forge (1.8.9-forge-11.15.1.2318) launch crash: the generated
// version JSON lacks a "libraries" array, so Tools.getVersionInfo NPE'd at
// the customVer.libraries loop (line 752). Both sides now get empty-array
// guards + null library/name skips, and a missing parent-version JSON
// reports a locatable error instead of a raw NPE.
// (3) Zombie Invade 100 Days (244-mod 1.20.1 Forge pack) dies silently
// 53s into loading: the instance memory slider allowed 7165MB (the 0.8 x
// physical formula) which blows the iOS per-process Jetsam limit (heap +
// JVM native + renderer surfaces). ame173_safeHeapCeilingMB() derives an
// authoritative ceiling from os_proc_available_memory() minus a 1.2GB
// native reserve; ame141_currentLaunchAllocMem clamps every launch
// (profile or auto) through it with a bilingual toast, and the Profile
// memory slider is capped at ceiling+512MB so doomed values cannot be
// pre-selected.
// (4) CurseForge list ignored the sort menu: the UI passed Modrinth-style
// sort ("follows"/"downloads"/...) and loader ("fabric"/...) keys, but the
// CF search never mapped them -- sortField/sortOrder/modLoaderType are now
// appended on both the sync and async paths (2=Popularity, 6=TotalDownloads,
// 3=LastUpdated; loader enums 1/4/5/6), and ModrinthAPI gets the same
// treatment (its index was hardcoded relevance/follows -- the sort menu
// never worked on EITHER source; ame173_indexForSort maps the shared keys).
// (5) CF modpack version downloads all failed: double root cause -- the
// MCIM mirror's 302 keeps the zero-padded edge path (/files/8697/067/...)
// which mediafilez.forgecdn.net rejects with 403 (unpadded /8697/67/ works,
// verified live), and ModVersion.parseCurseForgeDictionary never ran the
// download URL through PLMirrorCenter (ModrinthAPI always did). CDN
// fallback now emits unpadded segments; CF primaryFile URLs are
// mirror-resolved like Modrinth's.
// (6) Download-page game-version picker stopped at 1.21.1/1.16.5: the
// manifest filter required the "1." prefix (26.x dropped), the 32-entry
// cap cut everything below 1.16.4, and a failed manifest load left a
// 5-entry fallback. Manifests now load through the PLMirrorCenter GameFile
// candidate chain (official + bmclapi), releases are accepted for any
// numeric id (26.x and 1.x, floor 1.8), the cap is 64, and the fallback
// list is the full common set (26.3 down to 1.8).
// (7) TouchController reworked into the Sodium-style component row (user
// decree "same style as Sodium, tap to auto-install AND auto-configure"):
// moved from the advanced section's toggle picker to the components
// section; installTouchControllerStandalone runs the exact Sodium flow
// (Fabric gate, bilingual confirm, Modrinth exact-title match, unified
// download task, jar into mods/) and arms the Task 172 auto-config key on
// success (UDP mode + launcher controls hidden at launch).
// (8) Home avatar disappearing on tab return (round 3): every
// showHomePage call allocated a FRESH LauncherNewsViewController, so the
// Task 169/171/172 timing patches could always be raced by the new
// instance's fetch. Both layout controllers now cache and reuse the home
// VC (cachedHomeVC) -- currentAvatar survives on the instance, and
// returning to the home tab is a zero-refetch path.
// (9) Wallpaper settings "default config inverted -> UI size and taps
// misaligned": the three slider rows (opacity/blur/card opacity) were
// built with top-aligned y=0 h=30 frames and fixed x offsets computed from
// the pre-layout cell width, mis-centring the thumb and overlapping the
// value label on wide form sheets and after rotation. All three rows are
// now built from one Auto Layout spec (icon -> title -> slider -> value,
// centerY-anchored, flexible width).
// (10) "After Forge's JIT install, launching the game pops a java runtime
// error until the launcher is restarted": one JVM per process -- the
// installer's headless JVM occupies it, and the old dialog told the user
// to restart manually. launchJVM's guard now offers Restart & Launch --
// internal.autolaunch_profile + exit(0), and LauncherRightPanel
// viewDidLoad consumes the key (selects the profile, waits 1.5s for
// UI/account readiness, fires launchGame through the full JIT wait chain).
// Plus: VGPU renderer added (PojavLauncherTeam/VGPU vendored under
// external/vgpu with iOS patches: @rpath framework dlopens, android/log
// removed, clang strict-implicit fixes; CMake builds it as libvgpu.dylib
// via two OBJECT libs to dodge the duplicate-basename collision); renderer
// list "Auto" label dropped its ": gl4es or ANGLE" suffix, MobileGlues is
// annotated (1.17+), and auto's legacy-MC branch switched from ANGLE to
// gl4es (per-version assignment, matching the CMake positioning of
// tinygl4angle as the 1.17+ wrapper).
// REVISION 17 addendum (Amethyst Task 174, no bump): neumorph canvas takeover
// + live opacity-percentage echo. Device feedback on the Task 173 neumorph
// build: "cannot reproduce the normal neumorphism at all -- everything has
// heavy halos" and "the neumorph opacity percentage does not display
// correctly". Root cause pinned: the neumorph Task 173 rewrote the CARDS to
// the normal state but kept the wallpaper layer underneath -- CSS-spec dual
// shadows (20pt offset / 60pt blur / opacity 1.0) cast onto a photo ALWAYS
// read as edge halos; the user's repro (Bing on -> tweak any UI effect ->
// Bing off) ends with the wallpaper REMOVED, so the terminal state's
// BACKGROUND is part of the normal state. Changes: (1) canvas takeover --
// with cardsNeumorphEnabled on, applyBackgroundToWindow /
// applyBackgroundToSplitViewController retire the wallpaper container behind
// a top gate (hosts painted native systemBackground; wallpaper state
// preserved on disk, Bing auto-refresh keeps persisting while veiled), and
// refreshUIEffect splits: ON retracts any live container + paints hosts
// native + one-shot forensic log; OFF rebuilds the wallpaper container in
// place if it was retracted (legacy blur re-apply unchanged). The toggle's
// terminal state now equals the repro's terminal state, background included.
// (2) cardsNeumorphOpacitySliderChanged now updates the % value label live
// (blur-slider pattern: slider -> contentView -> viewWithTag 501); the label
// previously froze at the last cellForRow value for the whole drag. Device
// anchor: the one-shot forensic line "[Task174] neumorph UI canvas active --
// wallpaper layer retracted" prints once per launch when the canvas governs.
// REVISION 17 addendum (Amethyst Task 175, no bump): six-fix device-feedback
// round. (1) ANGLE renderer crash root fix: MC 26.3's RenderPearl pipeline
// cross-compiles GLSL through shaderc to SPIR-V and back through spirv-cross
// into DESKTOP GLSL 330 (it believes the desktop-GL 3.3 facade tinygl4angle
// presents), but the context underneath is ANGLE GLES3 -- the desktop source
// fails with "ERROR: 1:1: '' : syntax error" and the game dies at
// minecraft:pipeline/gui (f484eb7 session forensics). Fix lives inside
// spvc_shim.c: spvc_compiler_compile intercepts desktop-GLSL outputs and
// recompiles the retained SPIR-V words through a second GLSL-backend compiler
// with ES options (GLSL_ES=1, VERSION=300, old-API option setters per the
// impl dylib's real export face) on the SAME context; tinygl4angle's
// ES-passthrough branch (Task173) uploads the ES source verbatim. Gated on
// AMETHYST_RENDERER containing "tinygl4angle" (mg/zink/vgpu untouched) with
// the AME175_ANGLE_ES_REWRITE=0 kill switch. Device anchors:
// "[spvc-shim] Task175 ANGLE ES rewrite: desktop GLSL -> GLSL ES 300" and the
// disappearance of "Couldn't compile vertex shader for pipeline".
// (2) CurseForge downloads + modpack sorting: projectFromCurseForgeProject
// dropped the downloadCount field (every CF card read "0 downloads"; the
// UI reads the Modrinth-style "downloads" key) -- now passed through; and
// loadModpackList never forwarded the sidebar sort/loader filters (mods tab
// always did) -- both sources now honor them. (3) Home avatar round 5: the
// INITIAL home VC (created in setupChildViewControllers) was never written
// into cachedHomeVC, so the FIRST tab-away-and-back allocated a fresh
// instance and re-ran every timing bug Tasks 169/171/172 had fixed (log
// proof: "Task173 home VC created" appearing AFTER the first switch);
// registered now (card layout already did), plus the 0.35s deferred pass
// reloads the profile section before the direct write (crossDissolve
// snapshot defense). (4) Hotbar/touch offsets after resolution changes:
// sendTouchPoint's grabbing path skipped the x resolutionScale factor
// (in-game touch mapping off by 1/resolutionScale whenever resolution !=
// 100%; historical sessions all ran 100% so it never showed); the hotbar
// hit ratio is now a single-writer global ame_windowToPhysRatio
// (updateSavedResolution), with a guiScale 2s-throttled options.txt refresh
// and a one-shot "[HotbarDiag] Task175 geometry snapshot" forensic.
// (5) Legacy Forge (<=1.12.2) modpack installs: the installer URL used the
// unsuffixed maven layout which 404s for old promoted builds (1.8.9-
// 11.15.1.2318 curls 404; the "-1.8.9"-suffixed path is 200) -- the
// placeholder JSON's MissingLoader mainClass then crashed the launch with a
// raw ClassNotFoundException. Fix: suffixed-variant URL candidates for MC
// 1.x minor<=12, plus a launchJVM pre-check that refuses the placeholder
// version with a localized alert (reuses the import-time i18n_str_555
// message) instead of the raw crash. Note: JIT requests do not pop when the
// TXM debugger is already attached ("keeping debugger attached for dyld
// bypass") -- by design, JIT is already enabled. (6) Neumorphism-wallpaper
// coexistence: the Task 174 canvas takeover retracted the wallpaper entirely
// and the user read that as a bug ("wallpaper covered, cannot display");
// retired -- with the switch ON the wallpaper installs normally, cards keep
// the spec surface, and the dual shadows switch to a wallpaper-soft profile
// (AmeNeumorphShadowView.ame_wallpaperSoftProfile: offset/blur scaled to
// ~1/3, opacity 0.45/0.5) so photos read a light float instead of halos;
// no-wallpaper keeps the spec profile. Device anchor (single line):
// the one-shot "[Task175] neumorph UI wallpaper coexist" log.
// REVISION 17 addendum (Task 176, no bump): second device-feedback round on
// the Task175 build (log set 0356a74/3b0307b). (1) ANGLE: the option-based
// ES rewrite fired (log line present) yet ANGLE reported the byte-identical
// pre-fix error -- the shipped impl dylib is spirv-cross 0.65.0 while the
// vendored source is 0.68.0, and the old options API may silently drop
// es/version on the 0.65 binary. The rewrite is now self-verifying (output
// must literally start "#version NNN es") with a textual fallback that swaps
// the version line to "#version 300 es" and injects the precision block
// (ES3 fragment has no default float precision), registered per-context and
// freed at context_destroy; head48 forensics for the first 4 rewrites
// ("[spvc-shim] Task176 ES rewrite via option|textual: head48=...").
// (2) VGPU (legacy-Forge launch crash): gl4es_glGetError+0x80 SIGSEGV with
// glstate == NULL -- the dylib constructor chain (initialize_gl4es ->
// gl_init -> ActivateGLState) never ran before the first GL call ("VGPU:
// Calling load_all()" appears only at that call, not at dlopen). load_all()
// now calls initialize_gl4es() explicitly at its tail (idempotent, pointers
// resolved + context current at that point; anchor: "VGPU: Task176
// initialize_gl4es done"). (3) Right-shift "no effect": the whole event
// chain was healthy (sc=229 x80, Task64 delivery, MC 26.3 key registry is
// scancode-based = 229 matches right.shift) -- the real gap is tap
// semantics: ACTION_UP released the modifier before the letter tap, so
// capitals never happened. Sticky-modifier latch added: modifier taps
// shorter than 0.4s defer the UP (latched); the next non-modifier button
// press auto-releases latched modifiers after dispatch (FCL-style one-tap
// shift; long-press keeps hold semantics). Anchors: "Task176 sticky mod
// latched"/"auto-release after key". (4) JIT wait at the right panel: the
// stikjit:// open now logs its result and shows an immediate guidance
// dialog when no handler answers ("[JIT] [RightPanel] Task176 openURL
// stikjit:// -> 0/1") instead of a blind 120s wait after which iOS had
// already killed the backgrounded app. (5) Multiplayer-menu freeze
// (log.2): no diagnostic survived the hard hang, so a main-thread watchdog
// now probes every 5s (4s semaphore timeout) and logs "[FreezeWatch]
// Task176: main thread unresponsive >= 8s" on two consecutive misses --
// next repro pins whether the hang lives on the UIKit main thread.
// (6) CF resource-pack tab empty: no classId=12 request ever appeared in
// the logs, so the load path now logs entry (api/source/filters) and
// result (count/error) via "[DLForensics] Task176 resourcepack". (7)
// Hotbar: hitbox gains the selected-slot highlight margin (2*guiScale*ratio
// upward; log.1 had y=1482 rejected against barY=1490) and the geometry
// snapshot is now change-triggered (guiScale/ratio/physical size) instead
// of once-per-process. Design note (user question): installing legacy
// (<=1.12.2) Forge modpacks needs no JIT by design -- the old-format
// installer runs natively in Objective-C (ForgeDirect: universal-jar
// extraction + library downloads + version JSON write); only 1.17+
// new-format installers execute processors in a headless JVM and need JIT.

// REVISION 17 addendum (Amethyst Task 177, no bump): neumorphism finalized
// rewrite per the user-provided CSS reference (bigbear-ui neu-white mixin:
// background linear-gradient(145deg,#e6e6e6,#fff); box-shadow N N 2N
// #d6d6d6 / -N -N 2N #fff with N=2px normal / 4px large). Native equivalent
// shipped in AmeNeumorphShadowView: a shadow PAIR (clear layers, offsets
// +/-N, shadowOpacity 1.0, shadowRadius = blur/2; light #d6d6d6/#ffffff,
// dark #1e1e1e/#3a3a3a) BEHIND an opaque CAGradientLayer surface
// (145deg axis start (0.2132,0.0904) end (0.7868,0.9096); light
// #e6e6e6->#ffffff, dark #333333->#2c2c2c) -- the surface occludes the
// shadow pair's inner spill, mirroring CSS box-shadow compositing behind
// the element. Root cause this kills: the Task160/175 transparent shadow
// carriers painted the blurred silhouettes ON TOP of the card interior
// (whole-card tint) and metrics scaled offset/blur to 20/60pt with the
// short side; fixed tiers now: cards 4/8pt, small elements 2/4pt, radius
// scaling unchanged. Transparency retired per the user's "no transparency
// at all": ame_applyNeumorphCardOpacity + cardsNeumorphOpacity + the
// settings slider row + ame_setNeumorphWallpaperSoft/soft profile are
// deleted; cards no longer read uiOpacity/blurIntensity. Device anchor:
// one-shot "[Task177] neumorph UI spec rewrite" log.

// REVISION 17 addendum (Amethyst Task 178, no bump): neumorphism / UI-effect
// settings decoupling per the user's final spec. (1) The neumorphic toggle
// NEVER grays out the other options in either state -- the Task172/173
// graying blocks (contentView.alpha 0.35 + userInteractionEnabled) are gone;
// effect-type / uiOpacity / blur rows stay interactive at all times.
// (2) With the toggle ON, UI effect type (blur/translucent) and blur level
// only affect the wallpaper layer; cards are rendered by the Task177 spec
// pipeline which reads none of them. (3) Card-body opacity slider RESTORED
// (Task170 mechanism): BackgroundManager.cardsNeumorphOpacity
// (defaults background_cards_neumorph_opacity, default 1.0 = Task177 look
// untouched) -> engine ame_applyNeumorphCardOpacity adapted to the three-
// layer engine: the whole AmeNeumorphShadowView (opaque gradient surface +
// shadow pair) fades as ONE composite so the inner-spill occlusion survives
// translucency (no haze returns at partial opacity); host fallback color
// steps aside (clear); labels/icons are sibling subviews and stay fully
// opaque. ame_applyNeumorphSurface re-pins shadowView.alpha = 1.0 so an
// unpaired re-apply fails safe toward the approved opaque look. Settings:
// "Neumorphism Opacity" row (tags 500/501/502, always visible, below the
// toggle; no-wallpaper section0 = 2 rows) + Task174 live percentage label.
// (4) News card corner pin: ame_setNeumorphPinnedCornerRadius (opt-in
// associated flag read by ame_refreshForHostBounds) -- MinecraftNews cards
// keep their explicit 12pt radius instead of the short-side proportional
// ~27pt override ("太圆了"). l10n: background.cards.neumorph.opacity.title
// restored x6 (four main languages 1954 -> 1955). Device anchor: one-shot
// "[Task178] neumorph decoupled: pinned spec cards + card-body opacity
// slider, UI effect options stay interactive" log.

// REVISION 17 addendum (Amethyst Task 179, no bump): eight-symptom device
// feedback round (cc8ced8 logs). (1) ANGLE: the ost desktop-facade context
// (eglBindAPI(EGL_OPENGL_API) + 3.3 Core attribs) never compiled a single
// user shader -- Task175/176 verified the ES300 rewrite reaches ANGLE
// byte-clean (head48 self-check + local harness) yet the error stayed the
// empty-source "ERROR: 1:1: '' : syntax error" in BOTH dialects; the ost
// fork's own internal emulated-library shaders are "#version 300 es"
// compiled through a separate internal path. Fix: gl_init_context now
// creates a REAL ES3 context for tinygl4angle (Task179 ame179_angleEs --
// ES3_BIT config + ES API bind + CLIENT_VERSION=3) while tinygl4angle's
// glGetString spoofs the desktop identity in facade-session-identical
// forms (GL_VERSION "OpenGL ES 3.2.0 (ANGLE...)" -> "3.3.0 (ANGLE...)";
// GLSL "OpenGL ES GLSL ES 3.20 (ANGLE...)" -> spoof then Task173 strip ->
// "3.30 (ANGLE...)", chain unit-tested locally). MC's GL33 caps flow
// through the spoofed strings exactly as in the working facade sessions;
// the Task175/176 ES300 rewrite finally meets a compiler that accepts it.
// (2) vgpu (legacy MC): GetHardwareExtensions' temp-EGL probe died at the
// first NULL egl_* call (LOAD_EGL resolved everything to NULL -- on Apple
// proc_address used bare dlsym(RTLD_NEXT), which finds nothing after a
// late-dlopened vgpu because the host loaded the frameworks long before).
// Fix: build with -DNOEGL (probe on the CURRENT game context; our
// gl_bridge guarantees one before the first GL call), proc_address now
// resolves from the explicit framework handles load_all() keeps open
// (dlclose retired), Exts/vendor/renderer NULL-guarded. (3) CF empty
// resource pages: loader-less project types (resourcepack/shader/datapack/
// world) must never carry modLoaderType (CF returns zero results:
// classId=12&modLoaderType=4 -> totalCount=0, without -> 1274) nor
// Modrinth categories facets (35467 -> 15); request-layer interception in
// ame173_applySortAndLoaderParams + ModrinthAPI, autoApply preselects the
// profile loader only on mod/modpack tabs, and a missing "data" array is
// retried once then surfaced as a real error instead of a silent empty
// list. (4) Version filter extended down to 1.7.10; pre-1.16 minors
// contribute only their last patch (1.15.2/1.14.4/.../1.8.9/1.7.10); the
// 64-entry cap is retired. (5) Right shift: on-screen modifier buttons
// move from latch-until-next-key to TOGGLE semantics (tap = on/off, hold
// = momentary) -- the Task176 auto-release structurally killed
// tap-shift-then-move sneaking. (6) Hotbar misalignment after GUI-scale
// changes: readGuiScaleFromOptions read POJAV_GAME_DIR (the base-instance
// symlink) instead of the ACTUAL instance gameDir (custom_gamedir/...,
// == process CWD after Task97 CwdAlign) -- the refresh always saw raw=0;
// CWD-first now, and ame67_sanitizeOptionsKeybinds receives the resolved
// gameDir via AME67_INSTANCE_GAME_DIR (call moved after gameDir
// resolution in launchJVM). (7) JIT wait from second-level menus:
// ame169_waitForJITCondition excludes suspension gaps (>2s iteration
// intervals) from the 120s budget -- being backgrounded by stikjit:// no
// longer burns the timeout; background-task assertion validity logged.
// (8) AvatarManager crash (user-reported chain): fetchAvatarFromURL
// completion body and reloadProfileSection are now main-thread-guarded
// (double safety on top of Task172's main-thread contract) -- no code
// path can touch UICollectionView/Auto Layout off-main anymore. Device
// anchors: "[TinyGL] Task179 desktop identity: GL_VERSION '...' -> '...'",
// "VGPU: Task179 framework handles:", "[InputDiag] Task179 mod toggle
// ON/OFF", "[JIT] Task179 ...: suspension gap of Ns excluded from
// timeout budget", "[CurseForgeAPI] Task179 search response missing data
// array".
// REVISION 17 addendum (Amethyst Task 180, no bump): dual-slider opacity
// system + account-list neumorph rewrite + account duplication double-guard
// + avatar defense + installer page aligned to the version-card menu.
// (1) Dual sliders per user spec "two bars control every surface 0-100%":
// Background Opacity (background_bg_opacity, default 0.75) governs the
// featureless large backgrounds -- sidebar/content/right-panel containers
// (both root and card layouts via the new ame_applyPanelSurfaceWithRadius:
// opacity: / Flat:opacity: engine primitives), page backgrounds (instance
// editor, wallpaper gallery, download-center sheet), the download top tab
// segments + search bar + source-switch track, settings rows, translucent
// page bases, AND the neumorph card bodies (Task178's dedicated slider
// retired into it; both pipeline hooks ame_applyNeumorphCardOpacity now
// read backgroundOpacity). Button Opacity (background_btn_opacity, default
// 1.0) governs launch/execute-jar/manage-version/download-center buttons,
// the seven right-panel info cards (accent*0.15*coef), menu selected tint,
// download-page functional buttons, NMToast card (engine hook), crash-view
// restart/exit buttons -- background = base color x coefficient, 100% =
// unchanged (fail-safe); icons and text always stay fully opaque (Flat
// paths fade backgroundColor only, neumorph paths fade the shadow host
// view). Legacy uiOpacity (0.6, floor 0.1) and cardsNeumorphOpacity
// retired; four-main-language key count stays 1955.
// (2) Account list rewritten on the raised pipeline
// (applyNeumorphCardEffectToView + pinned 16pt radius + clip release chain
// per layer, cell padding 6->10pt for shadow breathing): toggle ON = full
// Task177 twin-shadow spec (the clipped-shadow artifact is gone), OFF =
// legacy pipeline. Duplication double-guard: BaseAuthenticator.saveChanges
// (the single choke point of every accountId rewrite) migrates the avatar
// and removes the stale <oldAccountId>.json after a successful write (the
// refresh chain renamed accounts without deleting the old file -- the
// duplication root); reloadAccountList dedupes by accountId and skips
// unreadable files. Avatar defense: avatarForAccount:usernameFallback:
// (legacy username-named files and drifted IDs still hit), wired into both
// the home profile card and the right panel; fetch-failure log anchors.
// (3) Installer page aligned to the version-card menu: loader + option rows
// on the raised pipeline (contentView as host), spec text colors, 40pt
// icons, 64pt rows.
// (4) Defaults per user note: Blur effect, background 75%, buttons 100%,
// blur 0% (legacy 100% retired), card layout by default (explicit "vs"
// choice kept), dark appearance default (only never-explicitly-chosen
// devices migrate from auto/light, Task161 discipline). Device anchors:
// "[Task180] account file migrated after accountId drift: X -> Y",
// "[Task180] avatar hit via username fallback", "[Task180] avatar
// migrated", "[Task180] dedup account entry by id", "[Task180] skipping
// unreadable account file".

// REVISION 17 addendum (Task 181, no bump): device-feedback six-symptom
// round on the ab78f50 log set (build afa23a6 / Task 180 IPA). (1) The
// 26.1.2 NeoForge pc=0 crash (hs_err_pid1381, elapsed 1.17s): the early
// display window only registers a WindowSize callback, and
// CallbackBridge_nativeSetInputReady's second branch guarded
// GLFW_invoke_WindowSize but CALLED GLFW_invoke_FramebufferSize -- a NULL
// descriptor BLR, signature pc=0x0 / SEGV_ACCERR / si_addr=0; fixed to
// call the guarded pointer (input_bridge_v3.m). (2) CF detail-page loader
// filter wiped every file: parseCurseForgeDictionary stored loader names
// verbatim ("Fabric") while the predicate compares against
// lowercaseString ("fabric") -- exact containsObject never matched on the
// CF source (Modrinth is natively lowercase, hence unaffected); loaders
// now stored lowercased and LiteLoader prefix added (ModVersion.m). (3)
// Right-Shift dead keybind: the Task67 options.txt canonicalizer force
// reset the seven movement keys on EVERY launch, washing the user's
// key.keyboard.right.shift sneak binding back to left.shift each time;
// the forced reset is now one-shot (marker options.txt.amethyst-keybinds-v1
// beside the sanitized file; delete to re-run) while the dump forensics
// stay (input_bridge_v3.m). (4) Legacy Forge (1.x) SplashProgress
// disabled: its background GL thread races the main thread on the shared
// single context (1.8.9+vgpu session: "Texture creation: Invalid enum" on
// the splash thread, then glCheckFramebufferStatus returned 0 on the main
// thread); ame181_disableLegacyForgeSplash writes config/splash.properties
// enabled=false before JLI_Launch for 1.x Forge ids only (JavaLauncher.m).
// (5) ANGLE pipeline/gui "ERROR: 1:1: '' : syntax error" forensics: the
// 26.3 client jar was decompiled -- GlStateManager.glShaderSource uploads
// a single NUL-terminated UTF-8 segment with length=NULL via
// GL33C.nglShaderSource, and the spvc exit already self-verifies ES300;
// tinygl4angle now logs glShaderSource head48/count/len0 (first 8) and a
// pure-forwarding glCompileShader export logs COMPILE_STATUS + infoLog
// head (first 32) -- if the crash reproduces WITHOUT these lines, MC's
// shader calls resolve outside this dylib (Apple system libGLESv2 / raw
// ANGLE), which is the missing link (tinygl4angle.c). (6) JIT wait
// hang forensics: the success path of ame169_waitForJITCondition was
// fully silent; now logs a wait-begin snapshot (foreground/traced/exn/
// csdbg), a condition-satisfied line with net wait time, and foreground/
// background transitions while waiting; backgroundTimeRemaining's DBL_MAX
// foreground value prints as "fg(n/a)" instead of a 300-digit number
// (utils.m, LauncherRightPanelViewController.m). Device anchors:
// "[Task181] keybind marker present", "[Task181] keybind marker written",
// "Task181: legacy Forge splash disabled", "[tinygl4angle] Task181
// glShaderSource #", "[tinygl4angle] Task181 glCompileShader #",
// "[JIT] Task181 ... wait begin / condition satisfied / app returned to
// FOREGROUND".

// REVISION 17 addendum (Task 182, no bump): three-root-cause round from the
// bc1941b device logs (071647c + a9e60ac uploads). (1) ANGLE pipeline/gui
// namespace split ROOT fix: Task181's instrumentation came back decisive --
// glShaderSource #1 received the legitimate 435-byte "#version 300 es" source
// (Task175 rewrite chain fully working) yet glCompileShader #1 returned
// COMPILE_STATUS=0 with an EMPTY infoLog = the GL_INVALID_OPERATION
// signature of a shader id that does not exist in the compiler's library.
// Mechanism: tinygl4angle's LOOKUP_FUNC resolved gles_ functions via bare
// dlsym(RTLD_NEXT), which on device lands on the SYSTEM /usr/lib/libGLESv2,
// while MC's glCreateShader resolved through dlsym(tinygl_handle)'s export
// closure (self + dependent ANGLE libGLESv2 framework) = the app Frameworks
// copy -- two ANGLE instances, two id namespaces: last round (afa23a6,
// glCompileShader not yet exported) MC compiled on the Frameworks copy where
// the source had never arrived ("ERROR: 1:1: '' : syntax error" = empty
// source); this round Task181's export pulled compilation into the system
// copy where id=1 was invalid (status=0 + empty log). Both rounds' failure
// shapes fully explained. Fix: LOOKUP_FUNC now resolves through
// ame182_resolve (eglGetProcAddress first -- same source as the EGL context,
// then an explicit @rpath/libGLESv2.framework handle, RTLD_NEXT/DEFAULT as
// legacy fallback), and glCreateShader/glDeleteShader are newly exported as
// pure forwarders on the same chain so create/source/compile/query all
// converge on ONE ANGLE (tinygl4angle.c). (2) 1.8.9+vgpu white screen ROOT
// fix: with Task181's splash disable working (crash gone), the next layer
// surfaced -- vgpu's second-pass shader_conv_ rewrite emits "#version 320 es"
// (device dump: NewConvertShader first line, in/out-ified, texelFetch_
// helpers) which needs an ES 3.2 context, but the bridge only ever created
// ES 3.0 (CLIENT_VERSION=3) -- ANGLE rejects 320 es sources as "unsupported
// shader version", every FPE shader dies, the fixed pipeline (1.8.9's main
// render path) outputs nothing = white screen. Fix: gl_init_context's vgpu
// branch now requests EGL 3.2 (MAJOR 3 + MINOR 2; ES3_BIT config covers the
// whole 3.x family), falling back to CLIENT_VERSION=3 with a loud log if
// 3.2 creation fails (= pre-fix behavior). Known leftover: vgpu's
// ConvertShader misplaces injected declarations for MC-native #version 120
// shaders (declarations land inside ftransform()'s body, #version drifts to
// line 3) -- vanilla post-processing effects stay broken (WARN-level, not
// white-screen); upstream vgpu converter quality, left as-is deliberately.
// (3) JIT second-menu hang ROOT fix: Task181's three probes confirmed
// condition-satisfied fires (2.9s, traced=1 exn=1) with NO follow-up logs
// and NO returned-to-FOREGROUND -- the wait succeeded while the app sat in
// the background (background task assertion keeping the loop alive), and
// the success path launched the game from inside
// dismissViewControllerAnimated:completion:, which UIKit never calls when the
// alert's presentation animation was interrupted by the stikjit://
// backgrounding -- the handler is lost = the user's frozen second menu. The
// success case (latestlog.2) had the user return to the foreground first,
// so the same completion fired normally. Fix: all eight completion-wrapped
// branches (RightPanel main-wait + reattach, NavigationController main-wait
// + reattach) now dismiss with completion:nil and run the continuation
// (Task172 liveness recheck + handler, or the timeout retry alert)
// synchronously (LauncherRightPanelViewController.m,
// LauncherNavigationController.m). Device anchors: "[tinygl4angle] Task182
// gles pin: <fn> via eglGetProcAddress/frameworks handle", "[tinygl4angle]
// Task182 glCreateShader(type=..) -> <id> (namespace joined)", "EGLBridge:
// Task182 VGPU requesting ES 3.2 context", and -- absence expected --
// "Task182 VGPU ES 3.2 context creation failed".
//
// REVISION 17 addendum (Task 183, no bump) -- 59d4b48 device-feedback
// four-root-cause round (log set: latestlog.txt=ANGLE 26.3 FO black screen
// with healthy swaps, latestlog.old.txt=1.8.9+vgpu white screen after ES3.2
// fallback, latestlog.1=JIT second-menu hang; all three Commit: 59d4b48 with
// Task182 anchors present = genuinely on the fixed build). (1) ANGLE black
// screen ROOT fix -- the spvc-shim ES rewrite silently skipped 584/782 GLSL
// compiles: MC's resource-reload storm holds up to 392 live spvc contexts at
// once (batch create, deferred destroy) while the rewrite registry only had
// 96 slots; once full, parse records were dropped and those compilers handed
// MC raw DESKTOP GLSL 330, which the ES 3.0 context rejects at line 1
// ("ERROR: 0:1: ...") -> ShaderManager "Failed to load required shader
// programs" -> every pipeline missing -> 58fps of empty frames. Rewrite rate
// by second (98%/11%/79%/2%) is fully anti-correlated with the live-context
// watermark. Fix: registry 96 -> 1024 + oldest-eviction + rate-limited skip
// logs on every silent branch (spvc_shim.c). Two ESSL-content families fixed
// in the same shim, applied after the ES rewrite: (a) MC 26.x OIT fragment
// shaders declare `layout(location=0) out vec4 coeff[N]` and index it with
// loop variables (legal desktop GLSL, ILLEGAL ESSL 300 "array indexes for
// fragment outputs must be constant integral expressions") -- accesses are
// redirected to a plain global scratch array and constant-index copies are
// inserted before main()'s closing brace; (b) clouds.vsh's `uniform
// isamplerBuffer CloudFaces` comes back from spvc with `#extension
// GL_EXT_texture_buffer : require` which ANGLE ES3 does not expose -- the
// extension line is stripped, *samplerBuffer -> *sampler2D, and linear
// texelFetch indices are folded to ivec2((i) & 255, (i) >> 8); tinygl4angle
// gains the matching data-side bridge (glBindTexture GL_TEXTURE_BUFFER ->
// GL_TEXTURE_2D retarget + glTexBuffer -> PBO-backed glTexImage2D at width
// 256) plus a rate-limited desktop-source leak detector in glShaderSource.
// (2) 1.8.9+vgpu white screen ROOT fix (second layer): the ES 3.2 context
// request from Task182 was rejected by the bundled EGL (eglError=0x3004
// BAD_ATTRIBUTE) and fell back to ES 3.0 -- where vgpu's GLSLHeader then
// replaced #version 120 with the HARDCODED new_version ("#version 320 es")
// even though its own testGLSL probe correctly reported only glsl300es --
// FPE shaders rejected as "unsupported shader version", fixed pipeline zero
// output = white screen. Fix: the replaced version now follows the probe
// (320 -> 310 -> 300 es, vgpu src/gl/pack/shaderconv.c). (3) JIT second-menu
// hang (1 of 3 sessions on the same build): the wait chain completed
// normally but the main-queue continuation vanished without a single log;
// the launch chain still had ONE completion dependency left --
// UIKit_launchMinecraftSurfaceVC swapped the root VC inside
// [UIView animateWithDuration:completion:], the same frozen-animation-clock
// family Task182 removed from dismiss. Fix: synchronous root swap with a
// fire-and-forget fade (ios_uikit_bridge.m, both directions), plus
// wait-completed/handler-invoked anchor logs in RightPanel + NavCtrl.
// (4) Right-Shift dead keybind: Task181's one-shot marker stopped future
// washing but never repaired the washed state (device dump: marker present
// AND sneak still at left.shift). Fix: one-time v2 restore -- when the v1
// marker exists (the damage cohort) and sneak sits at the washed default
// (left.shift / numeric 42), it is restored to right.shift / 54; fresh
// installs (no v1) are untouched (input_bridge_v3.m). Device anchors:
// ANGLE session free of "Couldn't compile .. shader for pipeline" spam and
// free of "Task183 DESKTOP source reached GLES upload"; "[spvc-shim] Task183
// ESSL sanitized" on OIT/clouds shaders; "Task183 texbuffer bridge: N bytes
// -> 2D WxH"; "VGPU Task183: GLSLHeader version follows capability probe ->
// #version 300 es" with the FPE storm compiling; "[JIT] [RightPanel] Task183
// wait-completed block entered on main" followed by "[Task183] invoking
// launch handler" and "[SurfaceSwap] Task183 launching SurfaceViewController";
// "[Task183] keybind v2 RESTORE sneak: ... -> key.keyboard.right.shift"
// (or 42 -> 54) exactly once, after which in-game rebinds survive.

// ===== REVISION 17 addendum (Amethyst Task 184, no bump) =====
//
// Task 184 -- user verdict: "先撤销180task的UI效果调整，先修好这两样" (revert
// Task 180's UI-effect adjustments, then actually fix the two things). The
// Task 180 dual-slider opacity system (Background/Button) is RETIRED
// wholesale: the engine opacity-variant primitives
// (ame_applyPanelSurfaceWithRadius:opacity: /
// ame_applyNeumorphSurfaceFlatWithRadius:opacity:) are deleted back to the
// single-signature forms, BackgroundManager returns to the
// uiOpacity (0.6, floor 0.1) + cardsNeumorphOpacity (neumorph card-body
// opacity, default 1.0 = opaque porcelain, Task 178 semantics) key pair
// (background_bg_opacity / background_btn_opacity keys retired), the
// settings page returns to the "Opacity + Neumorphism Opacity" slider rows
// (tags 500/501/502), and the 20+ wiring points (Root sidebar/right-panel,
// Bing gallery, download center/page segments and search bar, RightPanel
// buttons/info cards, Menu selected tint, NMToast, PLCrashView,
// ProfileSettings) return to constant backgrounds. The washed-out
// "white frame with an edge line" pseudo-neumorphism (Task 180's 75%
// background default bleeding through the porcelain cards) is gone.
// NOTE: blurIntensity default returns to 100% (Task 180's 0% default was
// part of the reverted set) -- users can re-adjust in settings.
//
// The installer page ("选择安装方式" -- loader list + Fabric API/OptiFine
// coexistence switch rows + version picker subpage) is REWRITTEN to be
// structurally identical to VersionCardCell (the version-number selection
// list the user approved): outer cell fully transparent INCLUDING the
// iOS-managed inset-grouped system cell background and gray selection
// highlight replaced by empty clear views (AME184ClearTableViewCellChrome,
// applied in init AND prepareForReuse -- the REAL root cause of the user's
// "nailed-down white frame with an edge line" that survived three previous
// rewrites: the raised pipeline was attached to the contentView while the
// system white backgroundView stayed behind it); visuals are carried by an
// inner cardContainer (cornerRadius 12 continuous, 4pt vertical insets)
// with applyNeumorphCardEffectToView attached ONCE in init (honors the
// neumorph toggle: ON = Task 177 gradient porcelain + twin shadows, OFF =
// legacy frosted/flat pipeline); icon container 40x40 rounded-10 brand-tint
// (ModLoaderIconHelper brand color 0.15, same spec as
// createIconBadgeForLoader); name 16 semibold / state 12 spec text colors;
// right chevron 14pt; row height 64 = version-card height.
//
// KEPT from Task 180 (functional fixes, not UI effects): account duplication
// double-guard (saveChanges write-through stale .json cleanup + read-side
// dedup), avatar defense (avatarForAccount:usernameFallback: at BOTH the
// right panel and the home/news profile card -- the news-side call site was
// restored after the wholesale revert), the account-list raised rewrite
// (pinned 16pt radius + clip release), and the card-layout/dark-mode
// defaults.
//
// Verification: verify_task184.py new (39 checks, A installer rewrite /
// B opacity retirement incl. repo-wide residual scan / C avatar dual sites /
// D keepers / E engine-symbol import discipline). Honest re-anchors:
// verify_task180 flipped to the post-revert truth (120 checks), 160 (47/47),
// 162 (68/68), 163 (36/36), 164 (ALL GREEN), 168 (43/43), 170 (34/34),
// 171 (30/30), 173b (32/32), 174 (24/24), 173 (123/123), 177 (A-F green),
// 179 J1 (task179 index 3->4), announcement full-shift family healed for
// the task184@2 insertion (len 23). Docs: announcements task184@2,
// worklog. Device anchors: neumorph cards back to fully opaque porcelain;
// installer page renders the exact version-card look with NO white frame
// behind cards, with the neumorph toggle still honored.

// REVISION 17 addendum (Amethyst Task 185, no bump): five-line round driven by
// the 11e4b63 device feedback (user's four logs all Commit 11e4b63 = the
// Task183 build, plus one other-person's log Commit 59d4b48). (1) Loader list
// "not found for MC > 26", root layer 1 -- Minecraft version numbers lost the
// "1." prefix from 26.x on (26.3, 26.1.2) while three extractor/filter sites
// still assumed it: NeoForge 26.3.x parsed to MC "1.26.3", Forge compound
// "26.3-66.0.5" judged "Unknown" by the ^1\. regex, so the gameVersion filter
// skipped EVERY entry. Fix: shared bidirectional-candidates matcher
// ame185_loaderVersionMatchesGameVersion (utils.h/utils.m; loader side strips
// "-suffix" then drops the last dot component, game side carries original /
// de-"1." / ".0"-completed forms, plus the NeoForge legacy 47.x=1.20.1 and
// 0.<snapshot> fool's-day shapes; form A now falls through to form B so
// pre-release "26.3.0.5-beta" matches game 26.3 -- caught by the new
// task185_matcher_test). Consumers: NeoForgeVersionFetcher.filterVersions,
// ModLoaderInstallViewController's XML filter, both gameVersion filters in
// ForgeInstallViewController's addVersionToList; the NeoForge extractor now
// drops the trailing build component and only prefixes "1." for major <= 25
// (26.3.7 -> 26.3, 26.1.2.71 -> 26.1.2, 21.1.5 -> 1.21.1). Root layer 2 --
// the ModLoader Forge race: the BMCL racing mirror served 2022-era stale
// maven-metadata (newest entry 1.18-38.0.17, ONE version element vs hundreds
// on official) and first-to-arrive-wins let it discard the official result,
// so 26.x matched zero entries. Fix: a payload may only settle the race if it
// PARSES to >0 gameVersion matches; unusable sources hand the chance to the
// other; on the first unusable XML the BMCL per-version JSON endpoint
// (/forge/minecraft/<mc>, verified to carry 26.3 data) races as a third lane;
// all three empty -> honest "no versions" (that MC truly has no Forge).
// (2) Fabric/Quilt list UX: fabric-meta returns ALL ~253 loaders for ANY game
// version (loader is version-agnostic; verified 26.3 and 1.20.1 return the
// identical list, newest first) -- the picker now shows the newest 30 with a
// "__AME185_SHOW_ALL__" sentinel row (packed via the \x1f display convention)
// that expands the cached full list on tap without a refetch. (3) JIT
// second-menu hang, the surviving shape ON the Task183 build: latestlog.2
// logged "condition satisfied after 3.8s" (background, traced=1 exn=1) and
// then NOTHING -- the main-queue continuation never ran, while three sibling
// sessions drained the same queue in background fine; the hang sessions'
// unique environment = ProfileSettings second-level menu alive + pinyin
// keyboard activity. GCD drops no block: the main thread was wedged in
// background. Fix: keyboard dismissal at both invokeAfterJITEnabled entries
// (sendAction:resignFirstResponder) removes the suspect at the source, and
// ame185_dispatchToMainSelfHealing (utils.m) delivers the wait-success
// continuation through three lines of defense -- normal dispatch, re-fire on
// UIApplicationDidBecomeActive (a background-wedged main thread gets unlocked
// by UIKit's activation flow), and a 120s background watchdog that re-dispatches
// when the app is foreground-but-undelivered, with a pinned NOT-delivered
// anchor otherwise; both wait chains in RightPanel + NavCtrl (main and
// JIT26-reattach) now use it. (4) TrollStore JIT "no reaction at all"
// (other person's report): every JIT-enabler openURL outside Task176's
// stikjit branch used completionHandler:nil -- an unhandled
// apple-magnifier:// (stale TrollStore) was completely silent. Fix:
// ame185_openJITEnablerURL:toolLabel: (RightPanel + NavCtrl) logs the receipt
// and shows actionable guidance on failure; the TrollStore auto-branch gets
// the same treatment. (5) Microsoft account "Failed to load account tokens
// from keychain" x5 + no skin (other person's iPad, 59d4b48): three stacked
// causes -- (a) the keychain item is
// kSecAttrAccessibleWhenUnlockedThisDeviceOnly, lost on re-sign (sideload ->
// TrollStore switch), device migration or backup restore while the account
// .json survives in the container: the refresh chain now dedupes the dialog
// per session, explains the cause and tells the user to remove + re-login,
// and tokenDataOfProfile logs the SecItemCopyMatching OSStatus (-25300 vs
// -25308 distinguish lost vs locked); (b) checkMCProfile built profilePicURL
// from username BEFORE username was set, saving a literal "head/(null)" URL
// on first login (log-proven: "RightPanel avatar fetch failed (url=...head/
// (null))") -- username now lands first, and refreshToken repairs the stored
// "(null)" URL in memory; (c) the single avatar mirror api.rms.net.cn was
// DNS-dead in that log -- AvatarManager.ame185_fetchAvatarForAuthData adds a
// three-layer chain (profilePicURL -> crafatar by profileId -> minotar by
// username), consumed by RightPanel + HomeAvatar. Device anchors:
// "[Task185] Forge: XML source won with N matches" or "BMCL per-version JSON
// won"; "[JIT] Task185 self-healing dispatch: refire on foreground" only in
// the wedged-main scenario; "[JIT] [RightPanel|NavCtrl] Task185 openURL
// apple-magnifier:// -> 0" pinpoints a dead TrollStore helper; "[Task185]
// keychain token read failed .. OSStatus -25300"; "[Task185] repaired
// corrupted profilePicURL"; "[AvatarManager] Task185 avatar chain:" hops.

// REVISION 17 addendum (Task 186, no bump): three-line root-cause round on the
// 11e4b63 seven-feedback leftovers. (1) ANGLE black screen, content-layer prime
// suspect hardened: the 26.3 FO session on 11e4b63 (c689d41 latestlog.txt) is
// presentation-healthy (fps=60 swapOK=372, overlay removed on first swap,
// audio/input alive, Task183 shader chain clean -- no "Couldn't compile ...
// for pipeline" spam) yet the screen is pure black = MC drew black content.
// Desktop GL 3.3 glUniformMatrix*fv accepts transpose=GL_TRUE (row-major
// input) while ESSL mandates GL_FALSE -- a violation is GL_INVALID_VALUE and
// the call is DROPPED WHOLESALE: every matrix uniform dies, vertices collapse
// to zero vectors, geometry is culled away and only the clear color remains,
// matching the symptom point for point. tinygl4angle.c never exported the
// matrix family, so those calls fell straight through to ANGLE's ES semantics
// with nobody transposing. Fix: all nine glUniformMatrix{2,3,4}{,x}fv wrappers
// -- transpose=FALSE passes through untouched (zero regression), TRUE is
// locally transposed (row-major -> column-major) and forwarded as FALSE
// (single matrices <= 16 floats use a stack buffer, no malloc on the hot
// path); a rate-limited anchor logs the first TRUE occurrences so the
// installation log either confirms the hit ("[tinygl4angle] Task186 ...
// transpose=TRUE -> locally transposed") or excludes this suspect outright.
// (2) vgpu 1.8.9 white screen -- the Task183 half-fix regression closed: the
// GLSLHeader capability-following rewrite works ("VGPU Task183: GLSLHeader
// version follows capability probe -> #version 300 es" present on device),
// but shader_conv_'s cut-in anchor still located the version line via
// strstr(new_version)="#version 320 es" -- on an ES 3.0 session that misses,
// cut_in_offset collapses to 0, and every cut_in() insert ("out mediump vec4
// FragColor;", the _shadow2D "precision mediump sampler2DShadow;" block, the
// gl_FragData layout-out lines) lands BEFORE the #version line. GLSL requires
// #version to be the first statement, so the directive is voided, the shader
// compiles as ES 1.00, and "'out' : storage qualifier supported in GLSL ES
// 3.00 and above only" + "'sampler2DShadow' : Illegal use of reserved word"
// kill the whole FPE family = white screen (11e4b63 c689d41 latestlog.old.txt
// shows exactly these errors at 0:1/0:2 with the 300es header logged
// alongside). Fix: when the exact new_version miss happens, the anchor now
// follows the actual "#version" line (skips past its newline); only sources
// with no version line at all fall back to offset 0. The 320es exact-match
// path is preserved verbatim. Anchor: "VGPU Task186: cut-in anchor follows
// actual #version line -> offset N". (3) In-game resolution menu dead after
// Task159's per-instance migration: actionAdjustResolution read and wrote the
// GLOBAL video.resolution key while the effective chain
// (SurfaceViewController.updateSavedResolution) resolves the PROFILE
// "resolution" key through [PLProfiles resolveKeyForCurrentProfile:] -- once
// any version-settings save materialized the profile key (first save pins
// it), the in-game menu could never take effect and its checkmark drifted
// from the live value. Fix: the menu now reads the same profile-side resolve
// (0 -> 100 fallback) and writes the current profile's "resolution" key
// (setServerIp-style mutableCopy write-back + save, immediately visible to
// updateSavedResolution on the same in-memory PLProfiles), while the legacy
// global-key write is mirrored for the JavaGUI consumers that still read it.
// Anchor: "[Task186] in-game resolution: profile '<name>' resolution -> N%".
// Verification: matrix transpose math unit test (11 cases incl. 2x3/3x2/2x4/
// 4x2/3x4/4x3 layouts and batch count, ASAN) + cut-in offset unit test (8
// cases: 300es/310es follow, 320es legacy exact path, no-version fallback,
// post-insert first-statement invariant) + a standalone compile harness for
// the new matrix block (9 symbols, -Wall -Wextra clean); verify_task186
// 51/51; cascade 183:50 182:39 181:35 179:61 176 185:63 184:39 160:47 all
// green; task159 verifier healed (parallel-session checkout path hardcoded as
// default -> repo-relative, env override kept; now 48/48); task175 F4/G1/G2
// remain 3 pre-existing drifts (stash-tested identical on HEAD, Task180-era
// opacity-revert announcement anchors, untouched by this round).

// ============================================================================
// Task 187 addendum (b5038d0 triple-log round: 8cca75a ANGLE latestlog.txt +
// vgpu latestlog.old.txt + mg latestlog.1 as the working control; 8cb5e03
// latestlog (1).txt install session; no bump).
//
// (1) vgpu 1.8.9 white screen ROOT CAUSE (third and final layer): the Task186
// cut-in anchor fix fired on device ("VGPU Task186: cut-in anchor follows
// actual #version line -> offset 16/362/83") yet FPE compile errors persisted
// (43 occurrences) in the NEW shape "0:1/0:2 'in' storage qualifier..." +
// "0:3 version directive must occur before anything else" + "ftransform:
// built-in functions cannot be redefined". Byte-exact dump decode: the gl4es
// legacy converter's OWN wrapper inserts (ftransform emulation, attribute/
// varying/uniform declarations) landed BEFORE the #version line -- because
// GetLine(Tmp, N) returns the TOP of the buffer when fewer than N newlines
// exist, and MC 1.8.9's GLSL 120 sources are single-line with no trailing
// newline, while the vgpu GLESFullHeader is only 2 lines ("#version 120\n\n")
// unlike upstream gl4es's multi-line header (version + precision lines) whose
// extra newlines made GetLine(3) always land inside the header. Every wrapper
// insert then anchored at buffer top, splicing declarations before #version;
// GLSL mandates #version as the first statement, the shader misparsed as ES
// 1.00, and the entire FPE family died = white screen. Fix: the header gains
// a third newline (3-line header keeps every wrapper anchor behind #version
// and in the global declaration zone for single-line sources; multi-line
// sources keep upstream behavior, now anchored before the first content line
// which is strictly safer) + string_utils.c GetLine hardening (newline
// exhaustion returns buffer END instead of TOP, never before #version).
// Anchors: "VGPU Task187: short GLSL source (N newlines total)".
//
// (2) ANGLE 26.3 black screen: the transpose suspect is EXCLUDED (RenderPearl
// uploads matrices exclusively through UBOs -- the 26.3 client decompile of
// GlDevice/GlProgram shows zero glUniformMatrix* calls; the Task186 bridge
// anchor never fired in the 8cca75a session). The remaining content-layer
// hypothesis space is now instrumented instead of guessed: probe frames
// (#1-5 + every 200) snapshot clearColor / colorMask / scissor box+enable /
// depth / blend / stencil via ES3-legal read-only queries -- "clearColor red
// but screen black" pins presentation dropping content; "colorMask all
// false" or "scissor tiny" finds the culprit state; "all normal + clearColor
// black" pins genuinely-black MC content (spvc rewrite semantics next).
// Also: RenderPearl's unconditional desktop-only glEnable(0x884F
// GL_TEXTURE_CUBE_MAP_SEAMLESS / 0x8642 GL_PROGRAM_POINT_SIZE) -- proven
// unconditional by the 26.3 GlDevice decompile -- are now accepted as local
// no-ops in tinygl4angle (they were rejected by ES with HIGH debug errors
// logged by MC every session; the working mg control session swallows them
// with zero debug messages).
//
// (3) In-game resolution touch misalignment root cause: Task186's menu fix
// called updateSavedResolution LIVE, which rewrites surface/drawableSize/
// contentsScale and the windowWidth/Height globals -- but MC's window belief
// (told to launchJVM once) is immutable in-process: the EGL surface shrinks
// under a full-size MC and sendTouchPoint's Task175 formula scales touches by
// the new resolutionScale while MC normalizes by the old window = systematic
// 1/ratio offset. Fix: the menu now only persists the preference (both keys)
// and toasts "applies next launch"; the next launchJVM cycle rebuilds
// surface/window/input in the same consistent session. Anchor: "[Task187]
// in-game resolution saved N% -- geometry applies next launch".
//
// (4) "Selected 26.1.2+neoforge but downloaded vanilla 26.3": the loader
// install path's conservative dead-end alert ("install that vanilla in the
// Downloads page first", OK-only) dumped users back into the version list
// sorted by date with 26.3 on top -- the 8cb5e03 session log shows a pure
// 26.3 vanilla download chain with zero NeoForge branch lines. Fix: one-tap
// "Install & Continue" -- ensureVanillaInstalled runs with the user's OWN
// selected version dict (correctness by data flow, not manual navigation),
// then the loader install continues automatically; failure surfaces a real
// error. Anchors: "[DownloadVC] Task187: vanilla ... missing ... offering
// one-tap auto-install" / "one-tap install accepted".
//
// (5) Keychain-lost dialog upgraded to one-tap repair: "Remove & Sign In
// Again" deletes the account (json + keychain residue, same semantics as the
// account-list swipe delete) and opens the account manager login page; the
// launch chain's pendingLaunchAfterLogin auto-continues after sign-in.
//
// (6) TrollStore "stuck at verifying integrity": the verify stage is
// bookkeeping-only by design (SHA1 is enforced per-file at download time)
// yet a device report shows the UI wedged on it; the stage now logs its
// entry with elapsed time and a 30s watchdog force-completes it if any
// upstream path leaves it Running. Anchors: "[MCDL] Task187: verify stage
// entered (elapsed ...)" / "verify stage watchdog fired".
//
// (7) Force landscape: Info.plist's iPhone orientation list dropped Portrait
// (the programmatic request is rejected Code=101 in window mode; a
// landscape-only supported list makes the system present landscape directly;
// iPad was already landscape-only).
//
// (8) iPhone notch/punch-hole: both home layouts (card default + vs
// three-column) add an iPhone-only horizontal safe-area inset to the sidebar
// leading and right-panel trailing margins (helper ame187_iphoneNotchInset;
// iPad returns 0 = zero regression; rotation 180 swaps sides via trait
// change recompute; vertical margins keep the symmetric outerMargin design;
// the game surface stays full-bleed = true full-screen gaming).
//
// Verification: verify_task187 61/61 (A vgpu 7 + B ANGLE 9 + C resolution 6
// + D one-tap 7 + E keychain 7 + F watchdog 4 + G landscape 2 + H notch 7 +
// I bracket gates 12) + task187_vgpu_syntax.sh (GetLine semantics unit test
// + string_utils gcc syntax + header/anchor assertions); re-anchored for the
// intentional semantic flips: verify_task186 C10 (live-apply retired ->
// next-launch semantics, +C10b) + D3 healed self-contained stub headers
// (52/52), verify_task185 F3 (dialog upgraded to action, 63/63), verify_task159
// E1 (l10n baseline 1955 -> 1959, 48/48); cascade 184:39 183:50 +
// task175_syntax_gates ALL PASS.
// ============================================================================

// ============================================================================
// Task 188 addendum (15fddc2 six-log round: ANGLE latestlog.old.txt + vgpu
// latestlog.txt + Forge latestlog.2 + NeoForge latestlog.old.1/.1 + other
// user's 8cb5e03 45k-line log). Six-item fix round:
//
// (1) vgpu white screen, FOURTH layer (wrapper self-poisoning): Task187's
// 3-line header + GetLine END-return fixed the #version-first violation
// (cut-in anchors now land behind #version, "VGPU Task187: short GLSL
// source (3 newlines total)" firing), but the NewConvertShader wrapper
// library prepended to EVERY converted shader (even 436-byte FPE vertex
// shaders) calls native textureGather -- legal only in GLSL ES 3.10+, and
// the capability probe reports 300es=1 310es=0 320es=0. So every shader,
// FPE included, died at 0:25 'textureGather: no matching overloaded
// function found' -> white screen. Fix: texelFetch-based emulation of
// textureGather_/textureGather_Offset_ (base texel floor(P*size-0.5),
// quad order (x,y)(x+1,y)(x+1,y+1)(x,y+1), clamped; comp overload via
// dynamic vec4 subscript, ES 3.00-legal) in pack/shaderconv.c. Anchor:
// zero 'no matching overloaded function found' for textureGather.
//
// (2) Forge 26.1.2 launch crash: java.lang.module.ResolutionException
// "Modules launcher and lwjgl export package com.apple.ios.audio to module
// com.sun.jna.platform" -- JavaApp/Makefile mirrored the launcher's
// com/apple/ios/audio classes + JavaSound services file into lwjgl_lib_*
// (c71dcfa SDL-hook provider mirror era). lwjgl overlay has ZERO references
// to the package; launcher.jar is always on the classpath, so the mirror
// is pure history. Fix: mirror removed -- the package now lives in exactly
// one artifact (launcher.jar) and Forge's modular bootstrap resolves.
//
// (3) NeoForge "missing files": two stacked causes. (a) A stray regular
// file at libraries/net/neoforged/neoforge/26.1.2.109 (name-collides with
// the directory APFS must create) made BOTH the installer-jar extraction
// and the universal download fail -- while the install overall still
// reported "Installation completed successfully". (b) The minecraft-client-
// patched jar is a PROCESSOR OUTPUT (never published to maven; the client
// classifier 404s on purpose on both BMCLAPI and maven.minecraftforge.net)
// -- so pre-processor download failures are undecidable. Fix: utils
// ame188_ensureDirectoryHealed (full ancestor-chain stray-file self-heal)
// wired into both installers' every mkdir site + Step E post-processor
// artifact verification (runtime library list: existence + jar PK magic;
// any miss = explicit install failure with a named list, never silent
// success). Anchors: "[Task188] stray file ... removed" / "Task188:
// post-processor verification FAILED/passed".
//
// (4) Forced landscape, round two: Task187's portrait-drop was ignored on
// iPadOS 27 because the app runs in WINDOW MODE (new iPadOS windowing /
// LiveContainer host), where the system owns geometry and ignores both the
// orientation lists and every code-level override (AppDelegate
// supportedInterfaceOrientationsFor:, scene-level callback, root-VC
// overrides -- all present, all ineffective). Fix: UIRequiresFullScreen=true
// opts out of window mode; the scene geometry request stays as defense in
// depth with its window-mode failure downgraded to a one-time notice.
//
// (5) ANGLE black screen forensics round 2 (adjudication of Task187's kit):
// state snapshots came back ALL-NORMAL + clearColor (0,0,0,0) + 58fps +
// zero shader compile errors -- "genuinely-black content" OR "presentation
// drops content", still undecidable from state alone. Shipped the decisive
// kit: (a) 1x1 center glReadPixels on probe frames (<=3/session, default-FB
// bound only, 4-byte RGBA read avoids the Task75 full-screen CopyBGRA8ToRGBA8
// SIGBUS path) -- nonzero rgb = content present & presentation dropping,
// black = genuinely-black content (spvc rewrite next); (b) GL_ALPHA_BITS/
// DEPTH_BITS + CAMetalLayer pixelFormat/opaque/framebufferOnly logging --
// alpha-bearing default FB + MC's alpha=0 clear + non-opaque composite is
// the premultiplied-black hypothesis; (c) phase-tagged error read after the
// state queries to name the probe query that triggers the per-probe
// 'Invalid pname' (1280) ANGLE debug message (mg sessions: zero).
//
// (6) FCL-style control repository (user feature request): in-app browser
// for community control layouts (CustomControlsViewController long-press
// menu -> 控件仓库), fetching controls/index.json from the launcher repo
// (raw.githubusercontent primary + jsDelivr CDN fallback), validating
// layoutDictionary-schema JSON, saving to controlmap/<id>.json for the
// existing Load menu lifecycle. Seed: controls/ with classic / minimal-fps
// / large-buttons. Anchors: "[ControlRepo] Task188: index loaded/downloading
// layout/saved".
//
// Verification: verify_task188 (this round) + gcc syntax gate on
// pack/shaderconv.c post-emulation.
// ============================================================================

// ============================================================================
// REVISION 17 -- Task 189 addendum (six-log adjudication of c3f4623 +
// six-fix round).
//
// (1) vgpu "blocks render like lines" (1.8.9-forge session): the Task188
// textureGather emulation closed the white screen -- shaders now compile
// clean, fps=30, swapOK thousands, session ran until user quit. The new
// symptom is geometry-level. Static audit (quads->triangles index gen,
// GoUniformMatrix4fv transpose + -1 guard, adjust_vertices, FPE vertex
// attrib bridge, renderlist mode merging) all clean; the ONE hard anomaly
// is MC's own "1282: Invalid operation @ Pre render" firing ~851x (once
// per frame) -- a failing per-frame GL call that 1.8.9 reports but the
// shim layer never surfaces. Shipped forensics (no blind geometry change):
// ame189_census (primitive histogram at glBegin/glDrawArrays/glDrawElements/
// glDrawRangeElements entries, reported every 4096 draws, 3 reports) +
// ame189_afterDraw (first 120 real draws get a post-draw glGetError read;
// hits are logged with full draw params and RE-INJECTED via errorShim so
// MC's own error checks stay intact) + glPolygonMode trip-wire (GL_LINE/
// GL_POINT requests logged, 4 max). Files: src/gl/drawing.c, listdraw.c,
// gl4es.c, gl4es.h. Local gate: scripts/task189_vgpu_syntax.py (extracts
// the two functions verbatim and runs a behavioral mirror; caught a real
// census reset bug pre-merge). Anchors: "VGPU Task189 census #N" /
// "VGPU Task189 post-draw error #N" / "VGPU Task189: glPolygonMode(...)".
//
// (2) ANGLE black screen (26.3 fabric session): Task188's decisive 1x1
// readback NEVER RAN -- readbackDone=0 across all 15 probe frames. Root
// cause: ame_es() dropped the glReadPixels dlsym in the Task75 cleanup
// and the Task146 renderer-side dispatch only re-arms it for Mithril/
// MobileGL-family renderers; ANGLE and vgpu sessions both got NULL.
// Fix: s_es.readPixels dlsym restored in ame_es() (the pinned
// libGLESv2 is the same ANGLE instance those sessions run on; the 1x1
// small-allocation path stays clear of the Task75 SIGBUS). The probe now
// fires on BOTH renderer families -- next log's center-pixel rgba either
// names the presentation layer (non-black) or the content layer (black ->
// spvc rewrite audit). Session facts recorded: layer opaque=1 (weakens
// the premultiplied-alpha theory), only 15 debug messages total, all
// "Invalid pname" 1:1 with our own probe frames.
//
// (3) Forge 26.1.2 launch crash (ResolutionException round 2): Task188
// removed the com/apple/ios/audio mirror but android.util remained
// double-exported -- "Modules lwjgl and launcher export package
// android.util to module logging" (Forge Bootstrap 2.1.7 dies at module
// resolution, exit(1), swapOK=0). The duplicate came from Task156, which
// deliberately compiled the five android/util ArrayMap stubs into the
// lwjgl overlay so GLFW.class's ArrayMap fields resolve through the
// MC-BOOTSTRAP ModuleClassLoader. Fix: the five stubs moved to a lwjgl-
// private package org.lwjgl.ame (byte-identical classes, package
// declaration renamed; keyAt() etc. keep working) and GLFW.java now
// imports org.lwjgl.ame.ArrayMap -- the lwjgl module no longer exports
// android.util at all, which fixes BOTH the split package AND the
// original Task156 visibility (the type now lives in the lwjgl module
// itself). launcher.jar keeps its android.util copy exclusively.
//
// (4) Forced landscape, round three: Task188's UIRequiresFullScreen=true
// proved ineffective under LiveContainer -- the host app's plist owns
// windowing and the guest's declarations are never consulted (geometry
// request still declined Code=101, still window mode). New approach that
// needs no OS cooperation: when the window bounds are portrait (height >
// width * 1.02), SceneDelegate rotates the UIWindow content 90 degrees
// (transform + swapped bounds + centered) -- UI, game and touches (UIKit
// inverse-transform hit testing) all stay consistent, content fills the
// window with no letterbox; landscape windows keep the identity transform
// (zero change). Re-evaluated at willConnect, sceneDidBecomeActive and
// scene:didUpdateCoordinateSpace (window resize / device rotation).
// Escape hatch pref: general.disable_window_rotation_shim.
// Anchors: "[SceneDelegate] Task189: portrait window -> content rotated
// 90deg" / "landscape window transform evaluated (rotated=N)".
//
// (5) Control repository, round two (user: "too hidden -- put it in the
// Downloads tab like FCL, and add acceleration for China"): the repo is
// now the 8th first-class tab of DownloadViewController (segment 控件,
// embedded ControlRepoViewController child VC, no sidebar/no search on
// this tab, searchBar height collapses to 0) alongside the existing
// editor long-press entry. China reachability: the two-URL primary/
// fallback is now a SIX-mirror sticky chain -- ghfast.top, gh-proxy.com,
// fastly.jsdelivr.net, gcore.jsdelivr.net, cdn.jsdelivr.net,
// raw.githubusercontent.com direct -- starting from the last-winning
// mirror (pref controlrepo.mirror_idx), 12s per-mirror timeout, JSON
// validation unchanged (HTML error pages from proxies are rejected).
// Anchors: "[ControlRepo] Task189: mirror #N won/failed/index loaded via
// mirror chain".
//
// (6) Crash triage: the repo-download NSInvalidArgumentException crash
// ("insertObject:atIndex: object cannot be nil" right after "layout
// saved") shows the OS default terminate output, meaning our
// NSSetUncaughtExceptionHandler installed in main.m pre-init was
// overridden (LiveContainer installs its own; last installer wins).
// Re-armed at two late points (AppDelegate scene-configuration +
// SceneDelegate willConnect) so our symbolicated stack + fatal-trace
// writer owns the next crash. Static audit of all 12 insertObject sites
// found no nil-capable path in the repo flow -- the next occurrence will
// self-identify via "[AppDelegate] Task189: uncaught-exception handler
// re-armed" followed by the symbolicated "Uncaught exception:" block.
//
// (7) i18n round one (user: "many hardcoded Chinese strings"): the
// localize() infrastructure is complete (all 1362 existing keys
// registered) -- the debt was (a) 157 mp.* MPLocalized keys never
// registered (every language saw the Chinese fallback) and (b) ~460 raw
// literals. This round: 185 keys registered across en/zh-Hans/zh-CN/
// zh-Hant (mp.* complete + 28 ame189.* for the migrated launcher strings
// -- RightPanel cards, JIT timeout trio, AI safety mode with stable
// safe/ask/yolo pickKeys, uikit_bridge alerts, JavaLauncher import
// warning, LTW renderer warning, utils fallbacks, the new Controls tab
// title). Known skips (next round): AI/* ~310 strings, logic-matched
// literals (isEqualToString against display strings -- VersionCardCell
// release/snapshot, 全部 filters, 新建版本 label), mp variant keys
// (6 keys with context-specific Chinese now map to one generic entry),
// language-picker proper names.
// ============================================================================

// REVISION 18 addendum (Amethyst Task 190, no bump): account card restyled
// isomorphic to the installed-versions page + account long-press menu +
// installer page spacing aligned to the version-number page.
// (1) AME190AccountCardCell (AccountListViewController.m): the account card
// now mirrors VMTileBaseCell/VMVersionCardCell from
// VersionManagerViewController exactly -- 12pt continuous-corner container
// (white 0.08 base + 0.5pt white 0.10 border, accent 1.5pt border + accent
// 0.10 fill + 20pt accent check badge when selected), VMTile shadow spec
// 0.12/6/(0,3) with layoutSubviews shadowPath, and the 0.96 spring
// touch-scale. Per user spec: left icon -> circular avatar (dp:34, same
// slot as the version-page icon container), title = account name in the
// version-page name style (sp:15 semibold label color), gray line =
// account type (sp:11 secondary; the Task136 colored type pill is
// retired), NO right chevron. Card surface runs through the new
// BackgroundManager applyEffectToTableViewCell: -- the Task172 three-stage
// pipeline extracted into a generic ame190_applyCardPipelineToCell: so
// table cells get byte-identical behavior to collection cells in both
// neumorph-switch states (the old applyEffectToCell: is pre-Task172 and
// was NOT reused). Geometry: 4pt top/bottom insets (8pt card gap) + 24pt
// side margins = version page section(16)+item(8) semantics.
// (2) Long-press menu for every account (user spec):
// (person.circle) "Use account" routes into ame190_selectAccountAtIndexPath:
// (the exact former didSelectRowAtIndexPath body -- tap and menu share one
// selection chain), (red/destructive trash) "Delete account" routes into
// ame190_deleteAccountAtIndexPath: (the former commitEditingStyle delete
// branch -- swipe-to-delete still delegates there). Task129b third-party
// multi-profile switch entries stay between the two actions (UUID-
// normalized checkmark, switchToProfile rebind without password); the
// Task130b inline person.2 button + actionSheet is retired (the card has
// no extra controls per user spec; objc/runtime.h import removed with it).
// (3) Installer page spacing (user: "each button's spacing must match the
// version-number page"): inter-loader section header height 10 -> 4, so
// the visible gap between card faces = 4 (card bottom inset) + 4 (header)
// + 4 (card top inset) = 12pt, identical to DownloadViewController's
// minimumLineSpacing 4 + 4/4 insets. Row height 64 and card insets
// unchanged.
// (4) l10n: +2 keys across en/zh-Hans/zh-CN/zh-Hant (account.menu.use /
// account.menu.delete; unique-key count 2155 -> 2157). Cascade re-anchors:
// l10n count gates and the announcement window family (task190@2 inserted,
// all non-pinned indices >= 2 shift +1, total 24), verify_task136 G2/F6/I2
// (installer spacing, type pill -> gray text, account card radius 16 -> 12),
// verify_task137 D3, verify_task130 F (inline button retirement, menu
// consolidation), verify_task184 D (account card pipeline anchors).
// Anchors: account cards render like the installed-versions page in both
// neumorph-switch states; long-press on any account shows Use account /
// Delete account; installer page card gap equals the version-number page.
// ============================================================================

// REVISION 18 addendum (Amethyst Task 191, no bump): six-feedback root-fix
// round on the dde0f82 device logs (four fresh sessions uploaded).
// (1) vgpu block corruption ("blocks like lines", entities fine): the
//     Task189 post-draw probe adjudicated 8/8 hits, all identical --
//     direct-elements mode=GL_TRIANGLES count=6 idxType=USHORT -> 0x0502.
//     That is the QUADS(4-vert)->TRIANGLES(6-index) conversion product (a
//     glstate->scratch CPU pointer) handed straight to gles_glDrawElements;
//     MC's own "@ Pre render 1282" fired 2178x. The control group (immediate
//     entities, listdraw.c's real-EBO list-elements path) never failed --
//     Apple iOS ES rejects client-memory INDEX arrays (vertex client arrays
//     are accepted; direct-arrays stayed green). FIX (vgpu drawing.c):
//     ame191_drawElementsViaEBO uploads the indices into the scratch EBO
//     (gl4es_scratch_indices + glBufferSubData), draws via the intact fpe
//     front-end with a NULL offset under that binding, then restores EBO=0;
//     ES1.1 keeps the legacy direct path. Anchors: site=direct-elements-ebo
//     with 0x0502 gone, "@ Pre render 1282" count zeroed, 1.8.9 block
//     textures restored.
// (2) i18n manual language switch showing raw "i18n_str_N" keys everywhere:
//     en.lproj/Localizable.strings line 2148 carried an UNESCAPED inner
//     quote pair ("Downloaded "%@" -- ...") which terminates the value
//     string early and makes the whole table fail old-style plist parsing;
//     with the system language on Chinese (zh-Hans table intact) the bug
//     was invisible until the user manually picked English. FIX: quotes
//     escaped; localize() gains a zh-Hans last-resort tier on BOTH the
//     override and system paths (any single broken/missing table now falls
//     back to the fullest translation instead of exposing raw keys);
//     scripts/task191_validate_strings.py is a strict Apple-oldstyle-plist
//     tokenizer now guarding all 40+ lproj tables in CI-runnable form.
// (3) Forge 26.1.2 launch crash: ResolutionException "Modules mojang.stubs
//     and launcher export package com.mojang.text2speech to module logging"
//     -- bootstrap 2.1.7 modularizes BOTH launcher.jar and mojang-stubs.jar
//     (the 1.20.1-era ignoreList no longer shields launcher.jar), and both
//     carried the Task158 stub package. FIX (JavaApp/Makefile): launcher.jar
//     no longer carries com/mojang/text2speech (stash-mv around the jar
//     command, restored after so the mojang-stubs cp source survives);
//     mojang-stubs.jar is now the sole owner serving both the module layer
//     and the system classpath (first-wins, it precedes launcher.jar).
// (4) Controls-editor crash ("zooming a control crashes"): the repo-download
//     session (latestlog.1) died in insertObject:atIndex: object-nil right
//     after "layout saved"; the Task189 re-armed uncaught handler never
//     printed (bare-address OS stack). Defense in depth: doAddButton nil
//     guards its four insertObject sites (stale-undo-replay hangover
//     anchor), loadControlFile now clears the undo stack (layout switch is
//     a semantic boundary; old invocations reference dead buttons), and the
//     SceneDelegate willConnect re-arm is now observable ("Task191:
//     uncaught-exception handler re-armed at willConnect") so the next
//     occurrence self-identifies.
// (5) Forced-landscape inverted direction ("portrait then landscape: the
//     orientation stays reversed"): Task189 picked the 90-degree direction
//     from scene.interfaceOrientation, which under LiveContainer's window
//     mode always reports Portrait (decoupled from how the device is
//     actually held) -- wrong sign on hand-swap = a 180-degree flip, and no
//     re-evaluation on device-orientation changes (window geometry is
//     independent in free-window mode). FIX (SceneDelegate): the angle now
//     follows UIDevice physical orientation (LandscapeRight -> +90,
//     LandscapeLeft -> -90, ambiguous -> keep), landscape windows gain a
//     held-orientation baseline with 180-degree flip-follow when the device
//     is swapped, and UIDeviceOrientationDidChangeNotification (with
//     accelerometer generation begun, observer removed on disconnect)
//     triggers re-evaluation. Anchors: "Task191: portrait window ->
//     content rotated +/-Ndeg by device orientation" and "Task191:
//     landscape window flipped=...".
// (6) ANGLE black screen round three (Task188 adjudicated genuinely-black
//     content: center pixel (0,0,0,0), layer opaque=1, 58fps, zero compile
//     errors): the remaining hypothesis space is UBO data never reaching
//     the shaders (RenderPearl is UBO-only; MVP all-zero clips every
//     fragment, leaving the black clear). Shipped: tinygl4angle now
//     explicitly forwards glBindBufferRange/glBindBufferBase/
//     glUniformBlockBinding (previously resolved straight to ANGLE's ES
//     natives) logging the first bindings each -- zero calls = broken bind
//     path; a non-256-aligned offset is tagged "[UNALIGNED-256!]"; the
//     swap probe reads GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT and
//     GL_UNIFORM_BUFFER_BINDING (uboAlign/uboBind in the Task188 fb line;
//     uboBind=0 at swap = MC never binds UBO). The phase-tag noise is also
//     root-fixed: the probe block now clears the error queue on entry, so
//     RenderPearl's own desktop-only-query 1280s no longer masquerade as
//     probe-self errors (15/15 frames of noise in the last log).
// Verification: verify_task191 45/45 (A i18n 3, B vgpu 6, C forge 6,
// D controls 3, E landscape 9, F angle 7, G syntax gates 8, H cascade 3);
// task189_vgpu_syntax 80/80; cascade 188:53, 189:80, 190:59 all green;
// the EBO mirror harness passes (upload bytes == draw bytes, fpe receives
// NULL, EBO unbound after) and the Makefile stash sequence dry-runs clean.
// ============================================================================

// REVISION 18 addendum (Amethyst Task 193, no bump): the launcher app icon
// (Light family) replaced with the user-uploaded grass-block cube artwork
// (repo-root IMG_9288.jpeg, 690x690 -> LANCZOS 1024/152/120). Replaced set =
// AppIcon-Light.appiconset all three appearance slots (universal/dark/tinted,
// same-image x3 exactly as upstream shipped them) + AppIcon-Light60x60@2x
// (iPhone primary per Info.plist CFBundlePrimaryIcon) + AppIcon-Light76x76@2x~ipad
// (iPad primary). Provenance audit archived in verify_task193: ALL 14 icon files
// were byte-identical to upstream herbrine8403/Amethyst-iOS-MyRemastered (Dark+
// Development iconsets and the resources PNGs date to 2022-11-25, Light set to
// 2025-05-29 'Add the final logo', AppLogo-Vector XMP 2025-05-25); per the user's
// >1y rule those stay pristine. Zero code/config changes: Contents.json and
// Info.plist untouched, icons are pure bitmaps referenced by filename only.
// Verification: verify_task193 (A dims 5, B replaced-vs-upstream 5, C untouched
// 9, D config purity 3, E provenance 3, F announcement 2, G source-present 1).
// ============================================================================

// REVISION 18 addendum (Amethyst Tasks 196/197/198/201, no bump -- none of
// these touch the MobileGlues conversion path; MG links glslang directly,
// the shaderc impl/shim chain serves other consumers):
// (1) Task 196 (vgpu 1.8.x block-texture corruption + watchdog hang): device
//     log caught the render thread stuck in GL11.glCallList <- RenderList
//     with the native crash in libvgpu.dylib's gl4es_glCallList (SIGSEGV).
//     Decompiled 1.8.9 GameSettings: useVbo defaults FALSE -> terrain goes
//     through display lists, and gl4es display-list replay corrupts captured
//     vertex data on iOS ES3 (entities use immediate mode, hence fine).
//     Fix: PojavLauncher.launchMinecraft now forces useVbo=true for vgpu
//     sessions before the first options.txt save (on-disk verify after save;
//     1.7.10- has no such key -- write is ignored, display lists remain
//     unsolvable there, use another renderer).
// (2) Task 197 (ANGLE black screen endgame): with Task193 advertising
//     GL_ARB_direct_state_access, MC 26.3 took the DirectStateAccess.Core
//     path and hammered the DEFAULT framebuffer every frame (1547x "Only
//     NONE or BACK are valid draw buffers", 2234 GL errors total) -> wrong
//     render target -> genuinely-black pixels with 58fps swap + audio.
//     Twin of the Task166 MobileGlues DSA-off fix. Fix: tinygl4angle
//     WITHDRAWS the DSA advertisement (extension cache machinery kept;
//     Task192/193 DSA function bodies kept, exported and harmless;
//     AME193_DSA_ADVERTISE=1 re-enables for forensics). MC falls back to
//     DirectStateAccess.Emulated classic bind-then-operate.
// (3) Task 198 (control repo "everything piles up in the corner"): repo seed
//     layouts are v7-format (keycodes array + dynamicX/dynamicY, no static
//     x/y, scaledAt~100) but mis-stamped "version":"1.0", so the loader ran
//     the V1 chain: keycodes replaced with [0] (all buttons unbound),
//     width/height re-divided by scaledAt, then V2 overwrote dynamicX with
//     "0.000000 * ${screen_width}" (static x absent, nil->0) -> every control
//     at top-left + unusable. Fix: convertLayoutIfNecessary rescues the mis-
//     stamp (any mControlDataList button carrying keycodes-array + dynamicX
//     + no static x is impossible for a real V1) by re-stamping version=7
//     and skipping the chain; the three repo seeds + index.json re-stamped
//     to "7" (future downloads correct; already-downloaded copies self-heal
//     on next load).
// (4) Task 201 (Metallum Metal renderer, synced from upstream herbrine8403/
//     Amethyst-iOS-MyRemastered): native Metal backend via -javaagent
//     (com.metallum.agent.MetallumAgent, class 65.0). Ported: metallum_agent.
//     jar -> JavaApp/libs/others/ (payload packs app/libs/), libmetallum.dylib
//     -> Frameworks (picker existence filter; the agent extracts its own
//     runtime copy), libspirv-cross-c-shared.0.impl.dylib replaced with the
//     upstream build (identical 12383-symbol export set incl. the 40 MSL
//     entries -- zero regression verified), shaderc_impl_glue.c gains the
//     glslang_program_map_io step (upstream-shaderc parity; Metallum's
//     MetalCrossShaderCompiler is binding/location-sensitive), renderer
//     table gains the Metal entry at the END (index stability), AMETHYST_
//     METAL=1 env + renderer->auto fallback, --add-opens=java.base/java.lang
//     (agent defineClass), mcMajor>=26 gate for the -javaagent mount (Java 8
//     sessions cannot load class-65 agent bytecode). Deliberately NOT synced:
//     upstream's bare libspvc.dylib / libspirv-cross.dylib /
//     libspirv-cross-c-shared.0.dylib copies (all the same real library) --
//     they would bypass our serializing spvc shim (Task175 family).
// Verification: verify_task196_197_198_201 51/51 (A vgpu 8, B angle 10,
// C controls 9, D metallum 14, E docs/l10n 10); the 2407->2408 l10n baseline
// sweep covers 16 verifiers (19 references); announcement window family
// re-anchored (task196 quad-fixes @ [2], incl. repaying Task193's missed
// re-anchors on 165/167/171/172/174/175/177/178/170/168/173b -- task165 now
// 34/34); survey reports archived under docs/surveys/.
// ============================================================================
// REVISION 18 addendum (Task 202, no bump -- none of this round's changes
//     alter MobileGlues conversion behavior; the dlsym pinning is inert in
//     MobileGlues sessions because libtinygl4angle is not loaded there
//     (NOLOAD self-handle returns NULL) and MobileGlues' own gl* exports
//     are untouched).
// (1) gl4es constructor crash immunity (binary patch, vendored libgl4es_
//     114.dylib): device log e4d704e/latestlog.1 (1.8.9-forge + gl4es)
//     crashed at GetHardwareExtensions+0xf90 -> _platform_strstr because
//     the constructor ran context-less and glGetString(GL_EXTENSIONS)
//     returned NULL (first needle "GL_APPLE_texture_2D_limited_npot").
//     Re-verified by local disassembly: call site 0x1bc2b4 (blr x8 via the
//     globals slot at 0x1e0938), result cached at [x29,#-0xc8]. The Task193
//     context-bootstrap anchors never fired (blind spot now covered by a
//     Task202 entry anchor in egl_bridge). Fix = crash-immunity shim: the
//     blr is redirected to a 32-byte cave stub at 0x6400 that calls the
//     same pointer and substitutes an empty string for NULL (strstr("",
//     needle) == NULL -> every extension check reports "not present", the
//     constructor completes, gl4es falls back to default caps instead of
//     dying). Zero behavior change when a context IS current. Script:
//     scripts/patch_gl4es_ggstr_nullguard.py (fingerprint-gated, idempotent,
//     Makefile-wired next to the Task192 RTLD patch).
// (2) vgpu texture-corruption adjudication instrumentation: the Task193
//     step-attrs probe read GL_ARRAY_BUFFER_BINDING (0x8894) instead of
//     GL_ELEMENT_ARRAY_BUFFER_BINDING (0x8895) -- every eabBefore/eabNow in
//     the device log was the VERTEX binding, not the index binding (the
//     "EBO swapped out" appearance was an artifact). Corrected constant +
//     attribution probes on the texture paths: glTexImage2D (which dispatch
//     branch the atlas grows through, npot-resize vs direct, post-dispatch
//     real error) and glTexSubImage2D (entry vs shrink-transformed params,
//     per-call real error) -- first 8 full + every-120th sample, targeting
//     the "Created: 16x16 textures-atlas" + 424x GL 1282 @ tick-rate
//     symptom cluster.
// (3) Metal first-frame signal: Metallum sessions produce no GL swap and
//     are not the Vulkan displayLink path, so pojavIncrementFpsCounter was
//     never called and the launch overlay waited for a manual cancel.
//     CAMetalLayer nextDrawable is now swizzled (main_hook.m, dispatch_once)
//     to count frames during AMETHYST_METAL sessions while the game runs;
//     the first-frame notification dedup lives in egl_bridge as before.
// (4) GL symbol pinning + eglGetProcAddress wrapper (main_hook.m): gl*/egl*
//     dlsym resolutions prefer libtinygl4angle when loaded (extension
//     cache + desktop-GL completion + version facade apply to every
//     resolution path); the eglGetProcAddress slot additionally gets a
//     logging wrapper. callerIsTinygl (noinline, return-address level 1)
//     keeps tinygl4angle's own fallback dlsym out of the pin (self-lock
//     guard). NULL-resolution forensics upgraded from the Task193 30-cap
//     to a deduped full list ([dlsym] Task202 anchors).
// (5) Input fixes (GitHub issues #1/#2): IME same-text dedup window 80ms
//     -> 20ms (rapid repeat keystrokes were being swallowed as duplicates
//     -- "keyboard only types one character"); two-finger scroll now
//     suppresses cursor movement while the pan gesture is active (async
//     flag clear so the gesture-Ended-before-touchesEnded ordering cannot
//     leak a trailing MOVE), and the tap tolerance grew 5x5 -> 24x24 pt
//     (natural finger drift was eating virtual-mouse clicks).
// (6) Language selector completeness: the launcher previously offered
//     system/zh-Hans/en only; it now enumerates all 54 bundled .lproj
//     tables at runtime (dispatch_once cache + native display names +
//     "partial translation" marker for non-primary tables whose fallback
//     chain shows en/zh-Hans content for missing keys).
// (7) i18n migration round: two mojibake dialog strings in
//     SurfaceViewController (UTF-8-as-Latin-1, context-restored), the AI
//     ask-tool dialog family, the default AI session title, and the
//     Java-dialog bridge's OK/Copy migrated to localize() with 10 new
//     ame202.* keys across the four primary tables (baseline 2408 -> 2418).
// (8) Forge + OptiFine coexistence detection (PojavLauncher.java): Forge
//     sessions with an OptiFine jar in mods/ log a warning anchor (the
//     IForgeVertexFormat CNFE / reflection signature drift family is a
//     mod-side incompatibility; FAQ entry added with the removal guidance).
// FAQ: +2 entries (Metal metallum crash guidance + Forge/OptiFine
//     characterization), 35 -> 37, both copies synced.
// Verification: verify_task202 (52 checks); l10n baseline sweep 2408 ->
//     2418 across anchored verifiers; announcement count 26 -> 27 sweep;
//     regression batch diffed against HEAD (zero new failures).
// REVISION 18 addendum (Task 203, no bump -- launcher-side renderer fixes
//     and diagnostics only; no MobileGlues conversion surface touched).
// Round driven by the 64fdaf2 device-log trio (latestlog.1 ANGLE 26.3
//     still black / latestlog.txt gl4es 1.8.9 SIGILL / latestlog.old vgpu
//     1.8.9 SIGSEGV) plus user reports (FAQ tab zero i18n; Forge 26.1.2 +
//     MobileGlues tiny file dialogs early-display prompt).
// (1) gl4es patch v2 (vtool-proof): the v1 cave shim at 0x6400 was
//     silently ZERO-WIPED by METHOD_CHANGE_PLAT's `vtool -set-build-version`
//     re-serialization (inter-section gaps are not section data; the BL
//     inside __text survived, the cave did not) -- the shipped IPA held
//     BL->zeros = UDF = SIGILL at libgl4es+0x6400, exactly as the device
//     reported. v2 patches BOTH GetHardwareExtensions glGetString call
//     sites (GL_EXTENSIONS @0x1BC2B0 and GL_VENDOR @0x1BDE4C) in-place
//     with ADRP+ADD pointing at the needle cstring's NUL terminator
//     (0x1CE9A2, inside __TEXT,__cstring) -- both writes live in real
//     sections, vtool-proof by construction; zero cave dependency.
// (2) vgpu crash root fix (pin scope): gl_bridge's dlsym_EGL dlopens
//     libtinygl4angle as the EGL source for every non-self-EGL renderer,
//     so tinygl4angle is loaded (dormant) in ALL GL sessions -- the v1
//     pin gate ("loaded => pin") hijacked vgpu sessions' early GL calls
//     to tinygl4angle, so vgpu's lazy load_all() bootstrap never ran and
//     glMultMatrixf died on NULL glstate (device: gl4es_glMultMatrixf+0x2c;
//     two "[tinygl4angle] Task182 gles pin" lines in a vgpu log = the
//     smoking gun). The pin now engages only when AMETHYST_RENDERER names
//     libtinygl4angle (ANGLE sessions), restoring vgpu's bootstrap.
// (3) tinygl4angle diagnostics unlocked: NSLog inside the dylib lands in
//     os_log (invisible in the captured stdout/stderr log) while printf
//     is captured -- 25 anchors converted, invalidating the previous
//     "anchor absent => code path absent" readings (the Task187 no-op
//     demonstrably RAN with its anchor invisible).
// (4) ANGLE black-screen traffic observers: query-family entry logs
//     (glGetString/glGetStringi/glGetIntegerv, first 12) + matrix-upload
//     forwarders (glUniformMatrix4fv/4fv/1iv/1f/2f/3f) + draw-family
//     forwarders (glUseProgram/glDrawElements/glDrawArrays/
//     glDrawElementsInstanced/glDrawArraysInstanced, first 8 + periodic)
//     -- next device log adjudicates whether MC uploads matrices via
//     classic uniforms or never binds UBOs, and whether any geometry is
//     submitted at all.
// (5) FAQ i18n (user report: "issues tab has zero internationalization"):
//     help-faq.json now ships per-language under en/zh-Hant/zh-CN lprojs
//     (full 37-entry English translation + traditional conversion +
//     simplified copy); the loader honors the in-app app_language choice
//     with localize()-style fallback (chosen lang -> en -> zh-Hans base);
//     system-language follows NSBundle's native resolution.
// (6) Forge 26.x early-display shotgun: -Dneoforge.enabledEarlyDisplay=
//     false and -Dforge.disableEarlyDisplay=true added next to the legacy
//     fml.earlyprogresswindow (26.x ignored the old name; the early
//     display's shader init fails on translation layers and its error
//     dialog falls back to a tiny file dialogs console y/n on iOS).
// (7) OptiFine detection false-positive fix: only active mods/*.jar
//     trigger the warning (a user's .jar.disabled rename still matched
//     and scared). FAQ Forge entry documents the tinyfd prompt.
// Verification: verify_task203; Makefile untouched this round (TAB
//     baseline 484 stable); l10n strings baseline unchanged (2418; the
//     FAQ JSONs are not strings tables).
// ============================================================================
// REVISION 18 addendum (Task 204, no bump -- launcher-side renderer fixes
// from the a599782 device logs; zero MobileGlues translation-surface changes):
// (1) gl4es 1.8.9 crash ("glCheckFramebufferStatus returned unknown
//     status:0"): root cause is gl4es's per-wrapper lazy backend resolution
//     dlsym(_gles, name) with _gles/_egl statically = RTLD_NEXT -- from
//     libgl4es the next provider of gl* is the SYSTEM /usr/lib/libGLESv2
//     (shared-cache ANGLE with NO current context -> glCheckFramebuffer-
//     Status returns 0). Same thief as Task36/182's "SYMBOL THEFT".
//     Fix: right after the Task193 bootstrap dlopen, inject the bundled
//     framework handles into gl4es's _egl (exported, dlsym) and _gles
//     (private PEXT symbol -- base+0x1de038 via a layout anchor: exported
//     _egl must sit at base+0x1de040 and _gles still -1), plus
//     set_getprocaddress(our resolver) so proc_address routes gl* through
//     eglGetProcAddress (context-sourced) and the bundled handles, never
//     RTLD_DEFAULT (the thief channel). Constructor keeps the Task203 v2
//     patch (it runs during dlopen, before injection is possible).
// (2) vgpu texture corruption: round-1 theory (alias export gap) partially
//     RETRACTED by CI round 2 -- vgpu_pack's pack.c already DEFINES 286
//     plain-name GL forwarders (void glTexImage2D(...) { _LOAD_GLES
//     gl4es_glTexImage2D(...); }) in the same dylib, so the core family was
//     never actually unexported; the device's [dlsym] NULL #7-#15 came from a
//     secondary consumer with a broken library handle, not MC's caps. The
//     regenerated alias file (scripts/task204_vgpu_gen_aliases.py) now ships
//     952 exports (legacy 944 + 8 genuinely-missing getters), with two
//     CI-lesson guards baked in: (a) preprocessor evaluation of the build's
//     define set (NOX11 NO_GBM NOEGL DEFAULT_ES=3 SHAREDLIB) so the guarded
//     glX* family cannot dangle the link; (b) a plain-name collision guard
//     (an alias for a name any built TU already defines is a duplicate
//     symbol). The corruption itself is re-adjudicated: the first atlas
//     stitch is 16x16 (the missing-texture checkerboard = what the user
//     sees) and the reloaded 512x512 atlas's texsub probes report 0x0502 --
//     BUT GL errors are sticky-queued and the session shows a standing
//     preErr=0x0502 before every draw, so the old probe could not
//     distinguish "this call failed" from "queued residue". All three
//     texture probes (RESIZE/DIRECT/texsub) now PRE-DRAIN the error queue on
//     probe frames: the next device log gives true per-call attribution.
// (3) ANGLE black screen round 2: geometry IS submitted (4000+ instanced
//     quads), caps path healthy, 58fps swaps -- but center pixel is
//     (0,0,0,0) = clearColor: everything renders outside the viewport
//     (identity transform). Task191's UBO-bind observers + Task203's
//     matrix observers: ZERO hits -- MC 26.3 draws 4000 quads without
//     ever binding a UBO or setting a uniform. This round adds the
//     missing data-plane observers (glBufferSubData/glBufferData/
//     glMapBufferRange/glUniform1i/glUniform1iv counted forwarders) to
//     adjudicate Java-side gate vs native-side loss next log.
// (4) Diagnostic hygiene: the Task75/187 geo-probe queried 0x8CA9/
//     0x8CAA (GL_DRAW/READ_FRAMEBUFFER_BINDING) -- this ANGLE ES3 build
//     rejects both with "Invalid pname" (8 debug messages = 8 probe
//     frames, perfect correlation; drawFb/readFb were always the failed
//     0). Switched to 0x8CA6 (GL_FRAMEBUFFER_BINDING, ES2-legal): zero
//     GL error leakage + real data. verify_task75 A6h re-anchored.
// Verification: verify_task204 (new); verify_task203 re-anchored (D
//     group counts the ame204 resolver family); task193_tinygl_syntax
//     green; verify_task75/179 stash-diff zero-new-failures (stale
//     anchors identical on HEAD); derived harness task179_inc resynced.

// REVISION 18 addendum (Amethyst Task 206, no bump): two renderer topics.
// (1) ANGLE 'blocks render transparent' ROOT CAUSE + FIX. Device log
//     7c0a021 latestlog.old (26.3 fabric + ANGLE): after Task205's rename
//     replay the _uniform_00_XX blocks all resolve (idx 0/1/2/...) and the
//     UBO bind chain is live (glUniformBlockBinding + glBindBufferRange
//     firing) -- but _push_constants returns GL_INVALID_INDEX 4294967295
//     206 times. SPIRV-Cross's GLSL backend emits PushConstant-storage
//     blocks as LOOSE uniforms (not a uniform block) unless
//     SPVC_COMPILER_OPTION_GLSL_EMIT_PUSH_CONSTANT_AS_UNIFORM_BUFFER is
//     set -- so glGetUniformBlockIndex can never find it and MC's
//     per-draw data (color/alpha modulation) never binds = transparent
//     blocks. Fix: ame175_compile_es_source now sets the option (enum
//     33 | 0x2000000, pinned against the vendored spirv_cross_c.h) on
//     BOTH option-API paths. Device anchor: '[spvc-shim] Task206:
//     EMIT_PUSH_CONSTANT_AS_UNIFORM_BUFFER enabled' + blockIdx probe
//     _push_constants -> >= 0.
// (2) NG-GL4ES ('Krypton Wrapper', BZLZHH/NG-GL4ES -- the gl4es used by
//     ZalithLauncher 2) ported as the vgpu successor (user-reported 1.8.9
//     material corruption survived two root-cause rounds; upstream claims
//     almost all MC versions run). Vendored at ThirdParty/ZalithLauncher2
//     (dead ZalithLauncher2 submodule de-registered, pin eba819b, zero
//     build references). Build: dep_nggl4es Makefile target, own cmake
//     tree, glslang STATIC from the dep_mg build (15.0.0 + both crash
//     patches; NG's vendored 15.4 headers removed so headers cannot drift
//     from the linked libs; audited: glsl_for_es.cpp only uses stable
//     pre-15.0 APIs), SPIRV-Cross via the prebuilt impl dylib (vendored
//     spirv_cross_c.h byte-identical to the impl's build header). The
//     attributes.h __APPLE__ retirement (AliasExport -> bare prototypes)
//     would leave the plain gl* names unexported -- the Task204
//     two-namespaces corruption disease -- so a generated alias file
//     covers it: scripts/task206_gen_nggl4es_aliases.py, 1293 asm aliases
//     (preprocessor-evaluated union of every AliasExport/A/_D/_D_1/_M/_V/
//     _1 declaration + STUB/GL_GET_MAP/THUNK token-paste families + the
//     NATIVE_FUNCTION_HEAD ARB twins the Apple branch drops; dangling-
//     target and bare-collision guards; idempotent; plus the raw-text
//     passes for string_utils.c's 18 bare alias-attribute helpers and
//     directstate.c's 2 AliasDecl internal aliases -- both families
//     guarded !__APPLE__ in the vendored tree after CI runs
//     36805637724/36806869734; loader.h's NOEGL branch gains the
//     missing LOAD_GLES3_OR_EXT used unguarded by drawing.c/
//     framebuffers.c). Runtime: renderer
//     libnggl4es.dylib appended to rendererCandidates (index-stability
//     rule, after metal), egl_bridge Task206 branch (vgpu-proven flow:
//     LWJGL dlopens with the game context current; NOEGL Task179
//     semantics), JavaLauncher NGG_DIR_PATH -> POJAV_HOME/ngg, VersionMgr
//     short name, AI mapping (nggl4es matched BEFORE gl4es -- substring),
//     l10n key + 2418->2419 unique-key sweep (the +34 raw-line delta is
//     pre-existing duplicate keys since Task202; verifiers count unique),
//     FAQ 38 items + announcements.json 29.
// Verification: verify_task206 (A ANGLE fix, B vendored tree + provenance,
//     C alias generator idempotence/coverage, D Makefile wiring + TAB,
//     E runtime wiring, F l10n/AI/FAQ/announcement, G version.h, H
//     cascade); TAB baselines re-anchored 484 -> 531 (129/135/202/203),
//     payload-line anchor 129-A9, FAQ counts (168/202/203), announcement
//     counts (193/202/203/196-family).
// ============================================================================
// REVISION 18 addendum (Amethyst Task 207, no bump): instance-selection page
//     restyled as iOS Shortcuts-style cards (user innovation brief + two
//     reference screenshots; number yielded to the parallel Task206 NG-GL4ES
//     port). VMVersionCardCell rewritten: vertical card on a unified accent ->
//     darkened-accent diagonal CAGradientLayer (added above the Task172
//     neumorph-surface/blur carriers, below content; view alpha follows
//     cardsNeumorphOpacity so the Task178 opacity slider keeps working),
//     top-left instance icon re-rendered as a WHITE TEMPLATE (original
//     loader/cube artwork preserved, alpha-as-shape so transparent sources
//     stay compatible), top-right translucent ellipsis button = PURE EDIT
//     entry (editProfile no longer implicitly re-selects the profile --
//     Shortcuts semantics: "..." edits, does not run), bottom-left name
//     (sp15 semibold white) + version (sp11 white 75%). Selection = inset
//     accent ring: inset = ellipsis-to-edge inset / 3 (kVMCardEllipsisInset/3,
//     dynamically derived per user spec), 2pt accent border + soft accent
//     glow (readability on the same-hue gradient), corner radius 12 - inset.
//     Legacy per-card isolatedBadge / lastPlayedLabel / selectedBadge /
//     chevron retired (user-picked "pure Shortcuts" four-element card).
//     Versions section density doubled: row height keeps the legacy 84pt
//     single-card slot (kVMVersionRowHeight), columns x2 (iPhone 1->2, iPad
//     2->4 via fractional 0.5/0.25 widths). Tap card = selectProfileNamed:
//     (silent no-op when already current), long-press menu unchanged.
//     Fixed-pt geometry inside the tile (dp 1.3x on iPad would overflow the
//     84pt budget; fonts stay sp with the 1.15 cap); name-icon clearance
//     guard demoted to priority 999. l10n: zero new keys (ellipsis a11y
//     reuses i18n_str_1091). Verify: verify_task207 (new); verify_task91 C2
//     re-anchored (white-direct-write allowance 2 kept: keep-site
//     isolatedBadge -> nameLabel); announcement family re-anchored
//     (193 F / 173 M3 / 190 H / 196-201 E / 202 H / 203 H + the parallel
//     verify_task206 F5 len 29 -> 30).
// ============================================================================
// REVISION 18 addendum (Amethyst Task 208, 2026-10-01, no bump): the
// three-renderer device verdict round (99a61eb upload) -- NG-GL4ES timing
// root fix + ANGLE push-constant block-name root fix + JVM-fatal abort
// pass-through. (Numbering note: the parallel-session UI round took 207;
// this renderer round yielded and renumbered to 208.)
// (1) NG-GL4ES crash + wedged app (latestlog.old, 1.8.9): SIGSEGV in
//     _platform_strstr <- GetHardwareExtensions <- initialize_gl4es <- the
//     dyld dlopen chain reached from pojavInitOpenGLInternal's unified
//     renderer preload -- BEFORE br_init_context, so no EGL context is
//     current and glGetString (resolved through proc_address's __APPLE__
//     branch dlsym(RTLD_NEXT,...) to the SYSTEM /usr/lib/libGLESv2, the
//     Task204 symbol theft) returns NULL, then src/glx/hardext.c
//     strstr(Exts,...) faults. Task206's assumption (LWJGL dlopens after
//     the context is current) was wrong: the unified preload runs first.
//     Wedged-app amplifier: hooked_abort parks the JVM's
//     VMError::report_and_die abort forever (dispatch_group_wait), the
//     Client thread never leaves JNI.invokePP (watchdog samples #1-#5),
//     the user had to reboot iOS. Fix trio: vendored build gains
//     -DNO_INIT_CONSTRUCTOR (upstream's own switch; initialize_gl4es
//     becomes a plain export), egl_bridge.m ame208_nggl4es_boot() hooked
//     at the pojavMakeCurrent tail (post-MakeCurrent = the vgpu
//     lazy-init equivalent moment, pinned by the Task146 make-current
//     ordering in the vgpu session) calls initialize_gl4es() after
//     registering set_getprocaddress (ame204_gl4esProcResolver --
//     proc_address's host-resolver branch outranks the RTLD_NEXT theft
//     channel), plus a hardext.c NULL guard on the extension string
//     (defense in depth; CMakeLists PROVENANCE 10/11).
// (2) ANGLE transparent blocks (latestlog.old.txt, 26.3): Task206's
//     EMIT_PUSH_CONSTANT_AS_UNIFORM_BUFFER option IS applied and the
//     option-path rewrite succeeds (log: "via option"), yet
//     _push_constants still returns GL_INVALID_INDEX while _uniform_00_XX
//     all resolve. Session-local reproduction (SPIRV-Cross a0fba56 built
//     from the pinned submodule source + a hand-encoded MC-shaped SPIR-V,
//     full shim-call mirror) pinned the mechanism:
//     emit_buffer_block_native's block-name collision check -- the
//     push-constant STRUCT is emitted first under the set_name'd name
//     "_push_constants" (registered in resource_names), so the BLOCK
//     falls back to the PC variable's original name ->
//     glGetUniformBlockIndex("_push_constants") can never find it. Fix:
//     spvc_shim.c redirects the PC block rename from the type id to the
//     VARIABLE id (ame208_find_push_constant scans the retained SPIR-V
//     words for the PushConstant OpTypePointer/OpVariable pair) -- the
//     fallback name becomes exactly the query name (repro-verified:
//     layout(std140) uniform _push_constants {...} emitted, SPIR-V 1.0
//     and 1.5 alike).
// (3) vgpu material corruption: unchanged (translation-layer defect,
//     two root-cause rounds exhausted; NG-GL4ES remains the designated
//     successor for legacy versions).
// Device anchors: NG session "[egl_bridge] Task208: NG-GL4ES
//     initialize_gl4es() called post-MakeCurrent (resolver=YES, ...)" +
//     "Initialising Krypton Wrapper" appearing AFTER the Task146
//     make-current line (never before any context exists); ANGLE session
//     "[spvc-shim] Task208: push-constant block rename redirected..." +
//     the Task205 blockIdx probes for _push_constants turning >= 0 +
//     blocks opaque.
// Verification: verify_task208 (A ANGLE redirect + device evidence, B NG
//     timing trio, C abort pass-through, D docs + cascade);
//     verify_task206 43/43 re-confirmed post-edit; task175 syntax gates
//     + bracket balance (egl_bridge/main_hook/spvc_shim) + gcc
//     -fsyntax-only on spvc_shim.c and the vendored hardext.c all clean.
// ============================================================================

// REVISION 18 addendum (Amethyst Task 209, 2026-10-01, no bump): renderer
//     rename + the push-constant red-herring retirement.
// (1) User-ordered rename: the NG-GL4ES entry is now displayed as
//     "Krypton Wrapper (<=26.2)" (upstream boot banner parity, matching the
//     MoltenVK "(26.2+)" convention on the other side of the version line).
//     Surfaces: four main-language Localizable.strings, the (dormant)
//     VersionManager short-name table, the AI reverse-mapping friendly name
//     (new name first, old kept for chat compatibility), and the FAQ
//     renderer entries across all five copies (alias retained: "formerly
//     NG-GL4ES"). Storage key libnggl4es.dylib untouched -- zero migration.
// (2) Red-herring retirement (spvc_shim.c): the Task208 push-constant
//     rename redirect is REMOVED. Device log 88fa3f6 (build 59b4f25) shows
//     the redirect anchor firing 0 times while _push_constants probes stay
//     NOT FOUND x203; decompiling client-263.jar (CFR, task209_decomp)
//     settles both facts: (a) every 26.3 shader (63 core shaders + all
//     includes) contains ZERO push-constant blocks -- MC queries the PC
//     block name unconditionally per pipeline layout, so GL_INVALID_INDEX
//     is the normal desktop-parity outcome, and Task206's option +
//     Task208's redirect were both chasing a target that does not exist;
//     (b) MC's renameDescriptors does DUAL naming (resource.id ->
//     "_push_constants_instance" + base_type_id -> "_push_constants") and
//     MC itself sets EMIT_PUSH_CONSTANT_AS_UNIFORM_BUFFER (0x2000021) on
//     its desktop compiler -- for any future PC-carrying shader the plain
//     replay + option already matches desktop exactly, the redirect would
//     have actively broken the dual naming. The Task205 blockIdx probe
//     stays (it is what exposed the red herring).
// (3) ANGLE transparent blocks (STILL OPEN -- honest status): with the PC
//     theory dead, the 59b4f25 session shows compile chain all green (32
//     shaders COMPILE_STATUS=1, sodium's #version 460 frag survives the
//     option-path ES rewrite), UBO chain healthy (terrain
//     _uniform_00_00..03 resolve + bind), zero GL errors, 60fps -- yet the
//     draw census only ever sampled count=3/6 glyph-sized
//     glDrawArraysInstanced calls because the Task173 BaseVertex family
//     forwarders carry no probes at all (terrain submission is invisible
//     to the census). Task209 instruments four directions in
//     tinygl4angle.c: (a) BaseVertex-family draw census with big-count
//     mandatory sampling; (b) draw-time state snapshots (blend src/dst,
//     depth func, colorMask, drawFb, texture-unit 0-3 bindings) on every
//     sampled draw; (c) texture upload forensics (glTexImage2D/
//     TexSubImage2D internalFormat/format/type/dims -- first 24 + >=1Mpx +
//     every 4096th); (d) terrain ESSL full-source dumps (first two
//     sphericalVertexDistance sources + first two >=3800-byte sources,
//     begin/end markers). Stub gl.h gained the nine enums the state probe
//     needs (values cross-checked against vgpu const.h/gles.h).
// Verification: verify_task209 (A rename surfaces, B redirect retirement,
//     C probe anchors, D docs + cascade incl. the 30->31 announcement
//     re-anchor family); task193 tinygl syntax gate re-run clean; gcc
//     -fsyntax-only on spvc_shim.c clean.
// ============================================================================

// -----------------------------------------------------------------------------
// REVISION 18 addendum (Task 210, no bump)
// -----------------------------------------------------------------------------
// Task 210 -- neumorphism full retirement + instance-card fixes (user freeze).
// [Neumorph] AmeNeumorphShadowView three-layer engine (shadow pair + gradient
//   surface), the AmeNeumorph* palette/metrics, and the ame_applyNeumorph*/
//   removeNeumorphShadow/CardOpacity/PinnedCornerRadius primitives are DELETED.
//   BackgroundManager loses cardsNeumorphEnabled/cardsNeumorphOpacity (defaults
//   keys background_cards_neumorph_enabled/_opacity retired); the wallpaper
//   settings page drops the toggle + opacity slider rows (section collapses to
//   zero rows without wallpaper). Six-language keys background.cards.neumorph.*
//   removed (4 main languages 2419 -> 2417). Kept per user freeze: the flat
//   gray surface (#e0e0e0 / #2c2c2c, renamed AmeCardSurfaceColor) with NO
//   self-drawn shadows; wallpaper blur/translucent pipeline untouched; text
//   palette renamed AmeCardPrimary/SecondaryTextColor (#333333/#888888 light,
//   #f5f5f5/#a0a0a0 dark).
// [Cards] VMVersionCardCell: height 84 -> 104pt (clipped labels at iPad full
//   font scale: content needed 86pt), original-color icons (white-template
//   rendering retired; PNG un-tinted / SF brand color / cube fallback accent),
//   mode-adaptive name/version colors, selection = pure 2pt accent inset border
//   (glow, whole-card tint and the tile-wide press spring-scale all retired),
//   ellipsis button 24 -> 28pt circle with 16pt Black glyph in adaptive
//   labelColor (12% plate). Interaction unchanged: tap = use, ... = edit,
//   long-press menu intact.
// ============================================================================

// -----------------------------------------------------------------------------
// REVISION 18 addendum (Task 211, no bump)
// -----------------------------------------------------------------------------
// Task 211 -- exit-"crash" root fix + CurseForge 403 fix + ANGLE
//   transparent-blocks counterattack + ZL2 classic gl4es port (user asks from
//   the 17c5100 log reading; authored under the dead session's "Task210"
//   numbering, renumbered after the parallel UI round took 210).
// [Exit] MC 26.3's new ClientShutdownWatchdog force-reports a crash whenever
//   the JVM lingers past main(); our bundled metallum_agent.jar (Task201)
//   started metallum-state/metallum-dump WITHOUT setDaemon(true), so every
//   quit inside ~120s of JVM start hung DestroyJavaVM and tripped the
//   watchdog. Bytecode surgery on the jar (scripts/task211_metallum_daemon_
//   patch.java: dup+iconst_1+setDaemon(true) before each premain Thread.start,
//   COMPUTE_MAXS only so StackMapTables stay valid; E2E gate T211Probe):
//   patched = daemon=true + instant exit 0; original control = daemon=false +
//   hang (timeout kill). Device anchor: quit produces NO crash report.
// [CF] The stored runtime key was the compile-time placeholder "((void *)0)"
//   (11 chars, the unset-secret literal; the root KeyViewController pre-filled
//   the RAW macro @CONFIG_CURSEFORGE_API_KEY and save/test wrote it into the
//   runtime preference -- which outranks the Task169-guarded compiled macro).
//   Three layers: CurseForgeAPI getter/isAPIKeyConfigured reject the
//   placeholder family (shared CFAIsGarbageAPIKey / +isPlaceholderAPIKey:),
//   BOTH KeyViewControllers sanitize prefill and gate save/test, and 403s
//   mentioning "API key" surface a readable message instead of the JSON
//   parser's format error. Plus ame211_migrateCfSourceToModrinth (main.m,
//   sentinel general.task211_cf_source_migrated): clears a stored placeholder
//   key and flips keyless devices' seven download_source_* curseforge values
//   to modrinth (user decision: default source Modrinth; CF remains usable
//   via the keyless mirror and can be switched back manually).
// [ANGLE] Task209's four-pronged forensics proved terrain draws submitted
//   healthy yet invisible -- the same symptom family as Android-side
//   Espryt/MobileGlues-ES multidraw silently dropping draws (Task156 family).
//   tinygl4angle.c: glMultiDrawElementsBaseVertex / glMultiDrawArrays /
//   glMultiDrawElements now ALWAYS decompose into per-draw wrapper calls
//   (the Task209 census sees every sub-draw; symbol resolution logs kept),
//   plus two decisive probes: a fullscreen-quad census in glDrawArrays
//   (final-blit visibility; the old probes only sampled the BaseVertex
//   family) and a 5-point in-world readback in gl_bridge.m (center + 4
//   corners at swapIndex >= 900, <= 2 per session, 1x1 independent reads per
//   the Task75 SIGBUS lesson) -- any nonzero pixel => content reached fb0.
// [gl4es] ZL2's CLASSIC gl4es (PojavLauncherTeam branch, gl4es_extra_extra)
//   vendored and built from source as a THIRD gl4es-flavour renderer
//   (holy gl4es prebuilt and Krypton Wrapper NG port untouched).
// [l10n] Krypton Wrapper display name shortened to "Krypton Wrapper (<=26.2)"
//   in the four languages that carry the key. virglrenderer scoped honestly:
//   needs a fresh Mesa build with the virgl driver (the bundled OSMesa has
//   only the socket-name string) -- a separate multi-round project, NOT in
//   this round.
// Verification: verify_task211 + task211_syntax_gate (A tinygl4angle decompose
//   regions + B swap-forensics 5-point block, g++/gcc -fsyntax-only; 10-file
//   bracket balance) + announcement cascade re-anchor (32 -> 33, index +1
//   family) + metallum E2E A/B.
// REVISION 18 addendum (Task 213, no bump): launcher-wide rebrand Air -> Prisma
// (display name, 54-language permission strings, AI prompt/persona, HTTP User-Agent,
// controls-repo author, prefs fallback name, both READMEs) + instance-card parity
// round: height 104 -> 128pt w/ 28pt icon, long-press = direct delete confirm;
// game-directory cells rebuilt isomorphic to instance cards (native-color folder
// icon, size subtitle, xmark delete button tapping straight into the confirm
// dialog, long-press retired); card-layout root gains the missing ShowHelpPage
// observer (help page was unopenable on the default layout since Task 180);
// installer loader-table row height unified with the version table at 50pt;
// account cards rewritten to the installer recipe with doubled (dp:68) avatars;
// memory-limit help dialog rewritten (entitlement explainer + paid-dev-cert
// button -> b23.tv/WtgrPJM); bundle identifier com.air-devs.air ->
// com.air-devs.prisma across plist/entitlements/Makefile/CI/os_log/keychain.
// ============================================================================
// -----------------------------------------------------------------------------
// REVISION 18 addendum (Task 212, no bump)
// -----------------------------------------------------------------------------
// [ANGLE] The 99d8122e device log adjudicated the Task211 probes: the MultiDraw
//   decompose IS engaged (drawcount 2-14 -> per-draw) yet blocks remain
//   transparent, and BOTH decisive probes fired ZERO times -- the 5-point
//   readback was gated at swapIndex >= 900 while the whole session ran ~810
//   swaps (90 short of the gate!), and the fsq census watched glDrawArrays
//   while MC 26.3's final composite actually draws via glDrawArraysInstanced
//   (log-proven: mode=4 count=6 inst=1 fullscreen pairs, #4000+ in-world).
//   Task212 evidence kit: (a) 5-point gate lowered to rounds at swapIndex
//   240/480/720 (<= 3 per session), (b) instanced fsq census with draw-state
//   snapshots for the first 4 candidates, (c) a terrain mega-draw landing
//   probe -- after any glDrawElementsInstancedBaseVertex with count >= 100000
//   (the log's recurring 222534-vertex chunk-target draws), a 1x1 center
//   readback from the current framebuffer: nonzero rgb => terrain landed in
//   the chunk target (look downstream at compositing), black => draw dropped,
//   nonzero rgb with alpha=0 => the alpha path is broken (SRC_ALPHA blending
//   renders terrain invisible). <= 2 per session, 1x1 independent reads.
// [CF] Sandbox-verified the keyless MCIM mirror directly: gameVersion /
//   modLoaderType / sortField / searchFilter all honoured (4681 hits for
//   26.3, 4188 for 26.3+fabric), but one transient empty response was
//   reproduced (same query succeeded on retry). Task212: transient network
//   errors and empty bodies now auto-retry once (was: only 5xx); the filter
//   chain gains anchor logs (source switch + reload print tab/source/version/
//   loader/sort) so the next device log reconciles "what the UI picked" vs
//   "what the request sent"; the version-tab picker popover anchor no longer
//   binds to a button inside the hidden sidebar container. A display-layer
//   lesson is recorded: "[m" sequences in tool output can be eaten as ANSI
//   reset remnants -- the suspected "sgView dismiss];" source corruption was
//   a phantom (bytes are "[msgView dismiss];", hex 5b6d); always verify with
//   byte-level hex before trusting a corruption verdict.
// [RENDERERS] User-ordered naming and retirement: the ZL2 classic gl4es is
//   now displayed EXACTLY as "gl4es(<=26.2)" (settings picker, version
//   manager short name, AI mapping, FAQ x5 copies), and holy gl4es
//   (libgl4es_114.dylib, prebuilt) is RETIRED entirely per the user's order:
//   dylib deleted, renderer table entry removed, its Task192/193/202/204
//   constructor-bootstrap chain retired with it (the successor needs no
//   pre-dlopen scaffolding: NO_INIT_CONSTRUCTOR + ame211_gl4eszl2_boot),
//   Makefile binary-patch invocations dropped, and stored selections
//   (global video.renderer + per-profile renderer) migrate one-shot to
//   libgl4eszl2.dylib (ame212_migrateHolyGl4es, main.m, before
//   PLProfiles updateCurrent). l10n key count stays 2418: the
//   preference.title.renderer.debug.gl4es key was removed from every
//   language while preference.title.renderer.debug.virgl (the upcoming
//   renderer's display string "VirGLRenderer(<=26.2)") took its place in
//   the four full languages -- a deliberate net-zero swap that keeps the
//   whole 2418-count verifier family untouched.
// [VIRGL] The port is STARTED (user-ordered; "VirGLRenderer(<=26.2)").
//   Architecture from ZL2's own integration: guest = Mesa 21.2 virgl build
//   (PojavLauncherTeam/mesa branch 21.2-virgl, osmesa+virgl, llvm off),
//   server = virglrenderer vtest (PojavLauncherTeam fork; both repos ship
//   ios-aarch64 meson cross files + ios.yml recipes), host GL = ANGLE ES3
//   context on our EGL window surface. Multi-round delivery begins this
//   task; the display name is already reserved in l10n.
// Verification: verify_task212 + syntax gates (task193 tinygl real-source
//   gate, task103 swap gate REPAIRED this round -- it had been stale-failing
//   since br_get_current/ame139 entered osm_swap_buffers; stubs added) +
//   bracket-balance (Task212-touched files, HEAD-parity confirmed).
// ============================================================================
// ---------------------------------------------------------------------------
// REVISION 18->19 bump addendum (Task 214, launcher side only)
// ---------------------------------------------------------------------------
// (1) The bump itself: the Task212/213 eight-item brief explicitly ordered a
//   REVISION bump for the Air -> Prisma rebrand round ("REVISION bump, after
//   Task 210 it is 18"); the delivery round shipped the rename without it.
//   Caught and paid here: 18 -> 19. Rationale: bundle identifier, URL scheme,
//   os_log subsystems, keychain service and 54-language permission strings
//   all changed identity -- the cache epoch follows the app identity.
// (2) Launcher-side five-fix round on the Task213 build (all UI, no MG surface
//   beyond the epoch): (a) mem_help.button l10n key was missing from ALL six
//   languages so the paid-dev-cert alert button rendered as the raw key name
//   -- key added everywhere (en/km "Paid Developer Certificate", zh-CN/Hans
//   付费开发者证书, zh-Hant 付費開發者證書, ja 有料開発者証明書);
//   (b) the add-directory card's green 1pt border retired per user order
//   (green plus icon + green 0.08 tint kept, border back to the 0.5pt default);
//   (c) instance + game-directory card corner radius 12 -> 16pt continuous
//   (user: "corners read a touch too straight"; quick-action tiles and
//   renderer cells deliberately stay 12);
//   (d) THE selection bug root-caused: the selection ring is a plain UIView
//   added AFTER the ellipsis/xmark buttons (higher sibling order), so on a
//   selected card its transparent body swallowed every touch -- hitTest
//   returned the ring, touchUpInside never reached the buttons. That is why
//   only UNSELECTED cards were editable. Fix: userInteractionEnabled = NO on
//   both rings (VMVersionCardCell + VMGameDirCell); card taps still work
//   (touch bubbles to the collection view), buttons now receive their events;
//   (e) game-menu overlay stats label (FPS/MEM) shrank to a fixed 130pt and
//   tail-truncated long memory strings ("MEM: 328..."): now shrink-to-fit
//   (adjustsFontSizeToFitWidth, minimumScaleFactor 0.5) per user order --
//   shrink, never ellipsize.

// REVISION 19 addendum (Task 215, no bump): VirGLRenderer(≤26.2) lands --
// ported from ZalithLauncher2 onto our ANGLE infrastructure (the round the
// user ordered with the renderer named exactly VirGLRenderer(≤26.2); task
// number yielded to the parallel UI round that took 214). Guest =
// libOSMesaVirgl.dylib (Mesa 25.0.7, CI-downloaded tarball +
// patches/mesa-215-osmesa-virgl.patch: osmesa_create_screen honors
// GALLIUM_DRIVER=virgl via virgl_vtest_winsys_wrap(null_sw_create()) +
// virgl_create_screen(), because upstream osmesa hardcodes swrast; the
// libdrm-dependent DRM winsys is gated off so darwin/iOS configures clean,
// and darwin symbol visibility switches to default or the whole
// gl*/OSMesa* export set would be swallowed). Server = libvtestserver.dylib
// (vendored virglrenderer 1.3.0, whose upstream vtest_server.c already
// exports vtest_main and carries --no-loop-or-fork/--use-gles with no epoll
// anywhere; only vtest_shm.c needed a memfd->mkstemp fallback) statically
// linking vendored libepoxy (patched to dlopen our ANGLE frameworks under
// __ENVIRONMENT_IPHONE_OS__). New Natives/ctxbridges/virgl_server.m owns the
// bootstrap: POJAV_HOME/.virgl_test socket + VTEST_SOCKET_NAME /
// GALLIUM_DRIVER=virgl env, a raw-ANGLE 1x1 pbuffer ES3 host context, and a
// detached 16MB-stack server thread entering vtest_main with an explicit
// --socket-path. egl_bridge's VirGL branch sits BEFORE the libOSMesa prefix
// branch (zink) that would otherwise swallow libOSMesaVirgl.dylib and reuses
// set_osm_bridge_tbl, so the present path is the battle-tested zink chain
// (glReadPixels authoritative readback; server-side vtest_swap_buffers
// remains a documented follow-up if the socket transfer shows in the frame
// budget). JavaLauncher logs the active renderer and excludes virgl from the
// zink env block; the AI mapping puts the virgl match ahead of the osmesa
// substring match for the same swallow reason. CI gains
// meson/ninja/bison(>2.3, keg-only PATH injection)/mako. Same round, ANGLE
// "transparent blocks": tinygl4angle.c now intercepts glClearDepth (records
// the value) and glClear -- DEPTH bit + value ~1.0 first triggers an explicit
// glClearBufferfv(GL_DEPTH) (MobileGlues Mode2, zero shader deps) before the
// regular clear, auto-on with AME_TINYGL4_DEPTH_CLEAR_FIX=0 to disable; this
// targets the documented ANGLE-Metal depth-clear silent failure and runs
// orthogonally to Task 212's probe kit (both read out in the next device
// log). Missing virgl dylibs degrade gracefully: the renderer picker hides
// entries whose file is absent.
// ============================================================================
// ============================================================================
// REVISION 22 addendum (Task 222, no bump -- upstream sync + 19-item list
// optimization round; launcher-side + lifecycle only, zero renderer touch).
// Upstream sync (herbrine8403/Amethyst-iOS-MyRemastered 10-05): (1) d76301816
// lifecycle fix ported -- pauseGameIfNeed criterion widened from isGrabbing
// (SDL3 constant 0 = no-op) to liveSession triple (isGrabbing || isInputReady
// || g_sdlWindow), sceneWillResignActive pauses immediately, didBecomeActive
// runs the ported Amethyst_EnforceSDL3Presentation presentation-enforcement
// family (SDL empty-UIWindow black cover / GameSurfaceView hidden / SDL metal
// layer opaque) + new CallbackBridge_resumeGameIfNeed window-size re-announce
// (fixes background->foreground freeze/black on zink/mg/all renderers; the
// Task56 geometry retry's landscape early-return that skipped the FG chain
// was rewritten to if-not-landscape). (2) Terracotta multiplayer fully
// restored [MP-RESTORE]: lazy-init design (startup path never creates
// TerracottaManager / terracotta_ios_start / ZeroTier node -- first entry
// into the multiplayer page does), CMakeLists recompiled (ZT six files +
// Terracotta four + TERRACOTTA_LIB link + ZT framework vars), upstream FCL
// rebuild of TerracottaViewController + LanPortDetector (auto LAN port
// detection: log tailing + verified local scan), container-mode close via
// ShowHomePage notification + floating close FAB, game-side PageSheet entry.
// 19-item list closures: version-string build-hash strip in parseVersionId
// ("26.2-db6fa7a3" -> "26.2", TouchController/Sodium/FabricAPI Modrinth
// matching), export multithreading (batched parallel read + serial zip write,
// 64MB/128-file bounded memory), About-page stagger entrance + right-panel
// card press feedback, openURLGlobal folder branch rerouted to in-app
// FileListViewController (bare-path NSURL failure root fix), IME marked-text
// guard (StopTextInput resign skipped during composition), README restructure
// (Chinese-default README.md + English via README_EN.md, QQ group & donation
// pinned at top), welcome wizard 7th zl2-style intro step (feature rows +
// community card + stagger), About-page donation section (Afdian button +
// bundled WeChat reward code with long-press save), launch overlay progress
// (five-stage timeline labels + indeterminate shimmer bar + elapsed timer).
// i18n +45 keys x4 languages (terracotta 21 incl. 2068-2070 remapped to
// 2091-2093 to avoid the Task220 account-dialog key collision, donate 7,
// wizard intro 12, launch stages 5). Fleet key-count baselines re-anchored
// 2520 -> 2565 across 129-142/217-219.
// ============================================================================

// REVISION 22 addendum (Task 223, no bump): the 25-item checklist round.
// Render: virgl_server EGLint int32_t (arm64 64-bit typedef misaligned
// ANGLE's 32-bit attribute pairs), tinygl4angle image2D precision gate
// (ES 3.00 illegality), render-thread park-at-swap for backgrounded GPU
// work (zink black-out + MG wedge share the BackgroundExecutionNotPermitted
// root), JIT alert animated:NO + ame185 unconditional redispatch.
// Data: isolation migration from the live gameDir (modpack clients kept
// their mods), export pipeline (parallel read -> serial write + threaded
// zip, second-level entry riding the version-download progress system),
// FolderBrowserViewController replacing the .json-only picker.
// UI: welcome overhaul (Bing/preset wallpaper, luminance-adaptive text
// inversion, zl2 grey-circle focus intro, coach marks), directional
// sidebar transitions, TouchController install-time config + dedicated
// refresh notification, IME stop-resign debounce (250ms + composition
// guard), About-page Discord + GitHub Star CTA, README restructure.
// Accounts: inline action menus (MS rename/skin, offline Steve/Alex).
// Upstream 2-week review (item 24): memory triple-port (Task173
// authoritative-path 1024-floor removal, dual-entitlement auto ratio,
// memorystatus-gated clamp bypass + 256MB floor), AI session page
// PAGE-GLASS call, CI macos-15 + Xcode 26 preference (iOS 26 SDK liquid
// glass) with runner-default fallback and SDKPATH pinning. Evaluated and
// declined with reasons: upstream's 10-04 metallum_agent.jar still ships
// non-daemon monitor threads (E2E probe: daemon=false on both -- would
// reintroduce the Task 211 exit-"crash"), LWJGL 3.4.3 API adaptation
// (this tree ships LWJGL 333/341 only), NG-GL4ES/Krypton renderer (not
// vendored here), MetalFX config write (the four settings toggles no
// longer exist in either tree post air-full merge), TrackedTextField
// preventUnexpectedResign (our Task222 composition guard + Task223
// debounce cover the same symptom with this fork's resign-site
// inventory). i18n +41 keys x4 languages; fleet baselines re-anchored
// 2565 -> 2606 and announcement tail windows shifted for the 43rd entry.
//
// Task 223 port block (second wave, 10-06 session -- item 24 continuation,
// upstream 09-19..10-06 window re-triaged after the Task 222 overlap was
// accounted for; four ports, all launcher-side):
// (1) 63add943c Forge/NeoForge early-window crash, both hunks: the library
//     filter now exempts org.lwjgl:lwjgl-glfw + lwjgl-natives from the
//     blanket org.lwjgl skip (fmlearlywindow needs lwjgl-glfw on the
//     classpath or NoClassDefFoundError: org/lwjgl/glfw/GLFW exit(1)),
//     and JavaGUIViewController drops setenv(POJAV_SKIP_JNI_GLFW) for
//     unsetenv -- input_bridge_v3 tests mere existence via getenv, so the
//     variable suppressed the GLFW JNI bridge the same window depends on.
//     Same lineage already device-verified upstream.
// (2) 3a2116c05 (Flux-ported p1 quartet): isConnectivityError(NSError*)
//     util in utils.m + MicrosoftAuthenticator offline detection switched
//     from NSURLErrorDataNotAllowed-only to the util (airplane-mode
//     NotConnectedToInternet previously fell into the failure branch);
//     asm-all 5.0.4 jar rewrite now strips the inherited "size" (it
//     belonged to the replaced artifact, guaranteeing checksum failure);
//     ControlJoystick + ControllerInput direction gates && -> || (a pure
//     axis push has one zero component, so requiring both non-zero
//     misread the four cardinal directions as center).
// (3) f05ec3842 safe half only: -XX:SoftRefLRUPolicyMSPerMB=250 (soft
//     refs survive 250ms/MB of pressure instead of being flushed at the
//     first GC -- measurably fewer class reload stalls on 4GB devices).
//     The same commit's -Xss1m was REJECTED: this tree's -Xss32M is the
//     device-proven root fix for MC 26.3 RenderPearl->shaderc(glslang)
//     deep-recursion SIGSEGV (662d6e2 logs); reverting to 1m would
//     reintroduce that crash.
// (4) f05ec3842 missing piece: stikjit:// openURL completion handler in
//     DownloadViewController now surfaces a localized failure dialog
//     (launcher.jit.stikjit_unhandled) instead of silently spinning to
//     the 120s timeout when StikDebug is uninstalled/the scheme is
//     unregistered.
// Declined this wave: upstream 340adedaa TrackedTextField rewrite (our
// item-10 resign-site debounce + composition guard already cover it while
// preserving legit dismissals), glScissor recursion guard (their private
// wrapper, not in this tree), upstream zh-Hans key sync (2605/2605 parity
// verified against this tree's superset), auto_ram entitlement (path
// retired here by the Task173 authoritative-memory rework), NG-GL4ES UAF
// + Krypton renderer (renderer not vendored), FSR1 family + MetalFX (our
// divergent implementations predate and cover them), and everything
// carrying a "Source: Prisma" attribution (bidirectional sync -- already
// in this tree). i18n +1 port key (2606 total) x4 languages.
// ============================================================================
// Task 225 addendum (no REVISION bump -- launcher-side only, zero MobileGlues
// ABI/config surface): 14-item feedback round on the run-658 build (a763f223 +
// 02a3fe1 log sets). (1) VirGL crash root: TMPDIR resolves to the SHARED /tmp
// under LiveContainer where bind(AF_UNIX) is EPERM ("Failed to setup socket.:
// Operation not permitted" -> vtest_main exit(1) kills the process); fix =
// candidate-chain socket dir with a disposable probe socket (NSTemporaryDirectory
// -> TMPDIR -> POJAV_HOME -> /tmp), and the vendored vtest_server.c socket-error
// path now returns instead of exit(1) (bootstrap poll times out -> Zink divert).
// (2) "ANGLE errors on non-SDL" verdict: renderer chain was HEALTHY (37 swaps,
// depth-format remap active); the actual death was java.nio NoSuchFileException
// on a missing assets object -> launch-time asset-integrity heal (index JSON ->
// per-object stat -> serial re-download, 20s/300-object budget). (3) Right-shift
// regression root: the Task224 isolation re-layout created a fresh gameDir whose
// missing one-shot marker let the Task67 canonical WASHER re-run and wash sneak
// back to left.shift (marker-present-but-washed in the logs); fix = wash retired
// permanently (dump-only) + one-shot v3 restore for the v2 cohort + markers ride
// the isolation migration. (4) SDL keyboard open/close loop: per-character
// UIAsyncTextInput session teardown vs the Task224 heal watcher re-arming
// first-responder; fix = upstream preventUnexpectedResign port (TrackedTextField
// refuses non-voluntary resigns; explicit dismissals wrapped). (5) Liquid Glass:
// nesting crash (UIVisualEffectView inside UIVisualEffectView from the cardTarget
// adoption loop) + black surfaces (UIGlassEffect does not render reliably in
// old-SDK processes -- composite blur+sheen base now) both fixed. (6) Isolation
// upstream-alignment: explicit choice sheet (migrate/enable-only), main-migration-
// first ordering (legacy leftovers only fill gaps), and PCL-style directory-shape
// sniffing shared by ModService/ModsManager/JavaLauncher (mods installs auto-
// target versions/<id>/game when it already holds mods/saves; badge shows the
// sniffed state and links to version settings). (7) In-game "open folder" no-op
// on 26.3: CTCDesktopPeer natives were only registered for the Java 8 cacio
// package -- the com/github 17/21/25 fallback is now registered (clipboard
// precedent), routing java.awt.Desktop opens into the in-app FolderBrowser.
// (8) Export destination alert vanishing: the 1.5s auto-dismiss of the progress
// page tore down the alert presented above it -- guarded + one reschedule.
// (9) Welcome: intro features rewritten as Prisma-UNIQUE advantages (renderer
// matrix + device-level tuning, deep input chain, data safety, parallel export,
// appearance system, deep diagnostics) and the ANCHORED zl2 coach marks
// (sidebar/content/launch, real UI rects) restored between wizard-dismiss and
// the About page. (10) Settings appearance rows inlined (interface slider 85-125,
// TEXT slider 85-130 -- fonts now scale independently via prisma.text_scale,
// dynamic-contrast toggle prisma.text_auto_contrast with the BackgroundManager
// color funnel respecting it); the standalone zoom editor retired; the four
// preference.detail.* keys added (raw-key-name display root-caused to missing
// detail keys). (11) First-content-placement now fades in on both layouts.
// Fleet: verify_task225 68/68; l10n baseline swept 2606->2696 across the
// verifier family; tinygl GL_DEPTH_COMPONENT local define fixes the task193
// standalone-compile gate (real CI builds resolve it via the gl4es headers).
// ============================================================================
// Task 226 addendum (no REVISION bump -- launcher-side + one vendored jar
// swap, zero MobileGlues ABI/config surface): 18-item feedback round on the
// 91ff52e9 build (00b4d4b6 + 20c8d642 log sets). (1) VirGL final divert: the
// socket probe chain worked (/tmp bind EPERM -> NO candidate) but the doomed
// server thread still started and libvtestserver's residual SIGSEGV->exit(1)
// path (fatal trace #02 OUTLINED_FUNCTION_0) surfaced a crash dialog; when NO
// candidate dir allows unix bind the bootstrap now returns -2 instantly (no
// EGL host context, no server thread, no 15s wait -- Zink divert in-place,
// residual crash paths unreachable). (2) Right-Shift + keyboard open/close
// loop, one root cause: executebtn_up's isToggleOn re-fire block double-fired
// every tap for modifier AND special keys (2 DOWN + 0/1 UP per physical tap
// -- device log shows key=344 down:up = 2:1, MC key-state cache corrupted;
// SPECIALBTN_KEYBOARD became dismissing+become flurries). The re-fire block
// now only applies to plain keys; Task179 owns modifier pairing, special-key
// semantics fire exactly once. (3) CTCDesktopPeer on Java 17/21/25: the cacio
// 1.18 class is a pure STUB (open(File) throws "Action not supported") with
// NO openFile/openUri methods -- the Task225 RegisterNatives raised a pending
// NoSuchMethodError that killed the Render thread; the jar's class is now
// replaced by an ECJ-compiled bridge (public static native openFile/openUri
// + full DesktopPeer funnel: open/edit/print(File)->openFile,
// mail/browse(URI)->openUri, isSupported OPEN/BROWSE/EDIT/PRINT/MAIL) and
// the native registration checks its return code + clears pending
// exceptions. (4) Isolation migration counts printed giant NEGATIVE numbers:
// @(moved) NSNumber objects passed to %ld formats read as tagged pointers;
// all three call sites now pass (long) scalars. (5) Upstream-data
// recognition: init_setupMultiDir no longer deletes a legacy REAL
// "Library/Application Support/minecraft" directory -- it migrates the
// contents into instances/<name> (tracked items + leftovers, never
// overwriting), archives the empty shell, then symlinks; existing symlinks
// re-point to the current instance. (6) Backup round-trip: the export walker
// no longer skips root-level Library/ wholesale (only Library/Caches) --
// legacy-layout game data (saves/mods/options.txt) now lands in backups and
// imports restore it. (7) The assets heal no longer skips icons/minecraft.icns
// (f0065754... = the "Couldn't set icon" NoSuchFileException users read as
// an error; Mac-spoofed MC loads it at window init). (8) Mod installs and
// the game now share ONE directory resolver: DownloadVC.currentInstanceMods
// Path delegates to ModService.ensureModsFolderForProfile (Task225 sniffing
// included) -- no more installing to shared while the game runs isolated.
// (9) Translucent mode black wallpaper: the per-VC systemBackgroundColor
// paint layer (pure black in dark mode, stacking to near-opaque) removed --
// page roots go clearColor in both modes, translucency lives in the card
// pipeline. (10) Liquid Glass: base material upgraded to
// SystemUltraThinMaterial (dark-mode cards no longer read as black), a 14%
// systemBackground tint layer keeps no-wallpaper glass readable, glass layer
// teardown covers the tint, and the style-switch re-apply defers one runloop
// tick (pick-dismissal transition no longer races the full re-apply -- the
// flash-quit on switching styles). (11) The floating gear now edge-snaps
// horizontally on drag end (video-player style, spring animation). (12) JIT
// intermittent "not responding": one silent auto-retry of the enabler URL +
// a fresh wait budget before the timeout dialog (per user-initiated launch).
// (13) Settings-from-right-panel navigation defers one runloop tick so the
// 0.38s spring transition renders on a free main thread (the settings-page
// build previously froze through the whole animation window). (14) Coach
// marks: coachmarks.next/done keys existed nowhere (buttons showed raw key
// names) -- added with 2 new marks (downloads/deps + versions/isolation),
// 12 keys x4 languages. (15) Appearance section retired: interface
// style/ui_scale/text_scale rows moved INTO Launcher Settings (general);
// text_auto_contrast row removed -- dynamic inversion replaced by the
// always-on white-fill black-stroke global font (NSStrokeWidth -2.6) with
// soft shadow on wallpaper-backed labels. (16) Issue #10 (PCL2CE-style):
// after a Modrinth mod download completes, its version's REQUIRED
// dependencies resolve to the latest game/loader-compatible builds and a
// confirm sheet offers one-tap sequential download into the same mods dir
// (version_file/{sha1} lookup; failures degrade silently). Fleet: l10n
// baseline swept 2696->2708; verify_task225 re-anchored to the Task226
// superseded states (UltraThin material, contrast retirement, general
// branch); task89's E1 scope pin allows JavaApp/ for the jar swap.
// ============================================================================
