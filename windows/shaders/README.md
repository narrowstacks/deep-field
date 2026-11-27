# WGSL shaders

Ports of the Metal source in `Sources/DeepField/Rendering/Shaders`, one `.wgsl` file per area,
joined into modules by `src/shader.rs` (WGSL doesn't need declarations before use, but keep the
same order as the Metal files anyway). `deepfield --check-shaders` parses and validates every
module with naga and points at the file and line of an error; run it after every change.

Modules:

- **bake**: `common`, `bake_bindings`, `sky_common`, `sky_bake`, `bake`. The ray bake kernels and the sky pass.
- **frame**: `common`, `frame_bindings`, `output`, `sky_common`, `sky_frame`, `planets`, then one file per scene. Every scene's fragment shader.
- **bloom**: `common`, `bloom`.

A function needed in both bake and frame goes in a binding-free shared file (`common`,
`sky_common`).

## Translating MSL to WGSL

Keep the port line for line: same names (camelCase, as in the Metal), same constants, same order
of operations, same comments (they explain the physics). Never use the em dash character.

- **Uniforms and buffers are globals.** The Metal functions take `constant FrameParams& F`,
  `constant Events& E`, `constant Palette& Pal`, `constant SceneParams& S`, `constant Galaxy& G`,
  `constant Planet* planets`, `constant Star* stars`, `constant Light* lights` and, in the bake,
  `constant BakeParams& P` / `constant SceneParams& T`. In WGSL drop those parameters and use the
  globals of the same name declared in `frame_bindings.wgsl` / `bake_bindings.wgsl`. Keep count
  parameters (`int count`, `int lightCount`).
- **Textures** are globals too (`hitA`, `skyTex`, `dirTex`, `idTex`...). `tex.read(p)` is
  `readTex(tex, p)` in the frame module (a `textureLoad` helper), `idTex.read(p).r` is
  `readId(p)`. In the bake, `tex.write(v, gid)` is `textureStore(tex, vec2<i32>(gid), v)`;
  `dirTex` is rg32float, so store a `vec4<f32>` (only .xy kept). `SKY(p, dir, far)` is a function.
- **Entry points.** `fragment float4 xFragment(FRAME_INPUTS)` becomes
  `@fragment fn xFragment(in: VOut) -> @location(0) vec4<f32>`; `uint2(in.pos.xy)` is
  `vec2<u32>(in.pos.xy)` (same top-left origin). Kernels become
  `@compute @workgroup_size(8, 8) fn name(@builtin(global_invocation_id) gid3: vec3<u32>)` with
  `let gid = gid3.xy;` and must bounds-check against `P.width` / `P.height`.
- **Parameters are immutable.** If the Metal assigns to a parameter, rename it `x_in` and start
  with `var x = x_in;`. `let` for values that never change, `var` otherwise.
- **`thread T&` out parameters** become `ptr<function, T>`: declare `name: ptr<function, f32>`,
  write `*name = ...`, call with `&local` (the local must be a `var`).
- **No implicit conversions or splats.** `float(i)` is `f32(i)`, `int(x)` is `i32(x)`. Builtins
  with mixed scalar and vector arguments need explicit splats: `max(v, vec3<f32>(0.0))`,
  `pow(v, vec3<f32>(2.2))`, `clamp(v, vec3(0.0), vec3(1.0))`, `step(vec3(e), v)`,
  `smoothstep(vec3(a), vec3(b), v)`, `mix(a, b, t)` is fine with scalar t only when a and b are
  vectors of floats (WGSL allows `mix(vec, vec, f32)`), `min`/`max`/`clamp` need matching types.
  Vector times scalar and vector plus scalar are fine.
- **No ternary.** `c ? a : b` is `select(b, a, c)` (note the order). Both sides are evaluated,
  so when a side is expensive or unsafe (texture reads at a computed index, divisions that could
  blow up into a NaN that still propagates) use an `if` instead.
- **`if`, `for`, `while` bodies need braces.** `for (int i = 0; i < n; i++)` is
  `for (var i = 0; i < n; i++)`. `switch` cases need braces and have no fallthrough.
- **Squares:** write `sq(x)` for every `pow(x, 2.0)`; a negative base makes `pow` undefined
  (NaN on D3D12), and the Metal compiler had been folding those into `x * x`. Keep the base of
  any other `pow` non-negative (wrap it in `max(..., 0.0)` if it could go below zero).
- **Renames:** `rsqrt` is `inverseSqrt`, `fmod(a, b)` is `a - b * trunc(a / b)` (WGSL `%` on
  floats does the same), `M_PI_F` is `PI`, `length_squared(v)` is `dot(v, v)`,
  `as_type<uint>(x)` is `bitcast<u32>(x)`, `discard_fragment()` is `discard`, `dfdx` is `dpdx`,
  `fast::` / `precise::` prefixes drop, `half` is `f32`. Swizzle assignment (`v.xz = ...`) isn't
  allowed: rebuild the vector.
- **Arrays:** `float a[4] = {...}` is `var a = array<f32, 4>(...)`. Global `constant float X = 1;`
  is `const X: f32 = 1.0;` (`constant int` is `const X: i32`).
- **Structs** declare fields as `name: type,` and can be returned and passed by value.
- **Overloads don't exist.** Two Metal functions with the same name and different parameter
  types need different names; rename the less common one with a type suffix.
- **Reserved words** can't be names: rename `out`/`ref`/`self`/`target`/`filter`/`sample`
  /`module`/`type`/`common`/`meta`/`match`/`final`/`fn`/`let`/`var`/`loop`/`override` and friends
  with a suffix (`res`, `outv`, `sampleV`). naga reports them. (`in` is fine as a parameter
  name, as in the entry points.)
- **Derivatives and implicit-LOD sampling** must be in uniform control flow; use
  `textureSampleLevel(t, s, uv, 0.0)` instead of `textureSample` inside branches.
