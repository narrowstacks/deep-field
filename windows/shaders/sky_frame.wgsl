// ---------- per-frame: sky color ---------- (ShaderSky.swift)

// Background sky with its occasional phenomena, for sky scalars `sky`, quantized star id
// `idq` and sky direction `dir`. `far` = the wormhole's other universe.
fn skyColor(sky: vec4<f32>, idq: u32, dir: vec3<f32>, far: bool) -> vec3<f32> {
    var col = vec3<f32>(0.0);
    let bright = sky.x;
    let tint = sky.y;
    let id = f32(idq) / 4096.0;
    if (bright > 0.0) {
        if (tint > 1.0) {
            col = mix(Pal.galaxy.rgb, Pal.starCool.rgb, 0.5 * (tint - 1.0)) * bright;
        } else {
            col = mix(Pal.starWarm.rgb, Pal.starCool.rgb, tint) * bright;
            if (id > 0.0) {
                // occasional twinkle: each star rolls the dice every ~5 s (at speed 1)
                let tt = F.time * F.twinkleSpeed;
                let slotPos = tt * 0.2 + id * 97.0;
                let roll = hash13(vec3<f32>(id * 1000.0, floor(slotPos), 7.0));
                if (roll > 1.0 - 0.06 * F.twinkle) {
                    let env = sin(3.14159 * fract(slotPos));
                    let flick = 0.5 + 0.5 * sin(tt * 23.0 + id * 61.0) * sin(tt * 9.0 + id * 17.0);
                    col *= 1.0 + env * env * (1.0 + 3.0 * flick) * F.twinkleBrightness;
                }
                if (F.pulsars > 0.5 && fract(id * 7919.0) < 0.004) {
                    col *= 0.25 + 3.5 * pow(0.5 + 0.5 * sin(F.time * 5.71 + id * 10.0), 12.0);
                }
            }
        }
    }
    if (far) {
        col += (Pal.farA.rgb * pow(max(sky.z, 0.0), 1.5) * 0.55 + Pal.farB.rgb * pow(max(sky.w, 0.0), 1.5) * 0.5) * F.skyBrightness;
        if (E.farSn.w > 0.0) {
            let c = length(dir - E.farSn.xyz);
            let hot = mix(vec3<f32>(0.75, 0.88, 1.0), vec3<f32>(1.0, 0.5, 0.25), E.farSnParams.y);
            col += hot * (E.farSn.w * exp(-sq(c / 0.05)) + E.farSnParams.x * exp(-c / 0.15));
        }
        return col;
    }
    col += (Pal.nebulaA.rgb * sky.z * 0.02 + Pal.nebulaB.rgb * sky.w * 0.012) * F.skyBrightness;

    // sky events live in sky-direction space, so lensing applies to them like everything else
    let pa = F.pixelAngle;
    if (E.snDir.w > 0.0) {
        let Sd = E.snDir.xyz;
        let dd = dir - Sd;
        let c = length(dd);
        let core = E.snDir.w * exp(-sq(c / (1.3 * pa)));
        let halo = E.snParams.x * (exp(-c / (4.0 * pa)) + 0.15 * exp(-c / (14.0 * pa)));
        let hot = mix(vec3<f32>(0.70, 0.85, 1.00), vec3<f32>(1.00, 0.45, 0.20), E.snParams.w);
        var light = hot * (core + halo);
        let echoR = E.snParams.y;
        let echoW = (1.6 + 0.04 * echoR / pa) * pa;      // the echo thickens as it spreads
        if (c < 30.0 * pa || (E.snParams.z > 0.0 && abs(c - echoR) < 6.0 * echoW)) {
            // the flash's own sky plane: x, y in pixels from the supernova
            let t1 = normalize(cross(Sd, vec3<f32>(0.31, 0.92, 0.22)));
            let t2 = cross(Sd, t1);
            let xy = vec2<f32>(dot(dd, t1), dot(dd, t2)) / pa;
            // four faint diffraction spikes while it is at its brightest
            let ax = abs(vec2<f32>(xy.x + xy.y, xy.x - xy.y)) * 0.7071;
            let spikes = (exp(-ax.x / 0.6) * exp(-ax.y / 7.0) + exp(-ax.y / 0.6) * exp(-ax.x / 7.0));
            light += hot * spikes * E.snDir.w * 0.05;
            if (E.snParams.z > 0.0) {
                // Light echoes: the flash lighting up sheets of dust as it sweeps through them.
                // The dust is fixed on the sky, so the expanding rings brighten and fade in
                // patches as they cross it. A second, fainter sheet lags behind the first.
                let dust = fbm(vec3<f32>(xy / 22.0, 3.0));
                let dust2 = fbm(vec3<f32>(xy / 15.0, 11.0));
                let patch1 = smoothstep(0.4, 0.72, dust);
                let patch2 = smoothstep(0.45, 0.8, dust2);
                let ring1 = exp(-sq((c - echoR) / echoW));
                let ring2 = exp(-sq((c - echoR * 0.62) / (echoW * 0.8)));
                let echo = E.snParams.z * (ring1 * (0.12 + 1.5 * patch1) + ring2 * patch2 * 0.7);
                // inner edges are lit by the bluer early light, outer edges by the redder tail
                let echoCol = mix(vec3<f32>(0.62, 0.62, 1.00), vec3<f32>(0.95, 0.55, 0.85), saturate((c - echoR) / echoW * 0.5 + 0.5));
                light += echoCol * echo;
            }
        }
        col += light;
    }
    if (E.cometHead.w > 0.0) {
        // A comet passing: green coma, a straight blue ion tail, and a broader, fainter, curved
        // dust tail peeling off to one side.
        let Hd = E.cometHead.xyz;
        let seg = E.cometTail.xyz - Hd;
        let segLen2 = dot(seg, seg);
        let tt = saturate(dot(dir - Hd, seg) / segLen2);
        let dh = length(dir - Hd);
        let hw = E.cometTail.w;
        if (dh < sqrt(segLen2) * 1.5 + hw * 8.0) {
            let dseg = length(dir - (Hd + seg * tt));
            let w = hw * (0.8 + tt * 3.0);
            let streak = 0.75 + 0.25 * sin(tt * 40.0 - F.time * 0.3);
            let ion = exp(-sq(dseg / w)) * pow(1.0 - tt, 2.2) * streak;
            let side = cross(Hd, seg);
            let bend = side * (0.35 / max(length(side), 1e-6)) * sqrt(segLen2);
            let dustPt = Hd + seg * (tt * 0.8) + bend * tt * tt;
            let dd = length(dir - dustPt);
            let dustT = exp(-sq(dd / (hw * (1.0 + tt * 9.0)))) * sq(1.0 - tt);
            let head = exp(-sq(dh / (hw * 1.1)));
            let coma = exp(-dh / (hw * 2.5));
            col += E.cometHead.w * (vec3<f32>(0.85, 1.00, 0.95) * head * 2.0 + vec3<f32>(0.45, 0.95, 0.65) * coma * 0.35
                                  + vec3<f32>(0.35, 0.65, 1.00) * ion * 0.7 + vec3<f32>(1.00, 0.85, 0.60) * dustT * 0.45);
        }
    }
    return col;
}

// The sky color at pixel p, seen along dir (the Metal SKY(p, dir, far) macro).
fn SKY(p: vec2<u32>, dir: vec3<f32>, far: bool) -> vec3<f32> {
    return skyColor(readTex(skyTex, p), readId(p), dir, far);
}
