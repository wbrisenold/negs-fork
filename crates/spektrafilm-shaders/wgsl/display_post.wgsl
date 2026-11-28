// Post adjustments in the display pass: `PostProcess::apply_rgb`
// (crates/spektrafilm-core/src/post.rs) with the same tables and the same
// f32 arithmetic, so a presented frame matches the CPU's adjusted scan.
// Appended to the display shaders, which declare `post` (a `Post`) and
// `post_tables` (decode, encode and tone, `POST_LUT` values each) at their
// own bindings.

const POST_LUT: u32 = 4096u;

struct Post {
    on: u32,
    encoded: u32,
    saturation: f32,
    color_strength: f32,
    luma: vec4<f32>,
    color: vec4<f32>,
    color_flags: vec4<f32>,
    output_to_xyz_d65: array<vec4<f32>, 3>,
    xyz_d65_to_output: array<vec4<f32>, 3>,
    harmony_nodes: vec4<f32>,
    harmony_meta: vec4<u32>,
    film_compression: vec4<f32>,
    film_expand: vec4<f32>,
    skin: vec4<f32>,
    skin_flags: vec4<f32>,
    relight_flags: vec4<f32>,
    relight_positions: array<vec4<f32>, 3>,
    relight_colors: array<vec4<f32>, 3>,
}

fn post_rgb_to_hsv(c: vec3<f32>) -> vec3<f32> {
    let hi = max(c.r, max(c.g, c.b));
    let lo = min(c.r, min(c.g, c.b));
    let d = hi - lo;
    var h = 0.0;
    if d > 1e-8 {
        if hi == c.r { h = 60.0 * ((c.g - c.b) / d - floor((c.g - c.b) / d / 6.0) * 6.0); }
        else if hi == c.g { h = 60.0 * ((c.b - c.r) / d + 2.0); }
        else { h = 60.0 * ((c.r - c.g) / d + 4.0); }
    }
    return vec3<f32>(h, select(0.0, d / hi, hi > 1e-8), hi);
}

fn post_matrix_rgb(matrix: array<vec4<f32>, 3>, rgb: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(dot(matrix[0].xyz, rgb), dot(matrix[1].xyz, rgb), dot(matrix[2].xyz, rgb));
}

const UCS_L_STAR_RANGE: f32 = 2.0988838;
const UCS_L_STAR_UPPER: f32 = 2.09885;

fn post_y_to_l_star(y: f32) -> f32 {
    let y_hat = pow(max(y, 0.0), 0.63165134);
    return UCS_L_STAR_RANGE * y_hat / (y_hat + 1.1242677);
}

fn post_xyz_to_jch(xyz: vec3<f32>) -> vec3<f32> {
    let safe_xyz = max(xyz, vec3<f32>(0.0));
    let total = safe_xyz.x + safe_xyz.y + safe_xyz.z;
    var xy = vec2<f32>(0.3127, 0.3290);
    if total > 0.0 { xy = safe_xyz.xy / total; }
    let uvd = vec3<f32>(
        -0.783941 * xy.x + 0.27751298 * xy.y + 0.15383658,
         0.74527353 * xy.x - 0.20537587 * xy.y - 0.16547838,
         0.3187073 * xy.x + 2.167437 * xy.y + 0.29132056);
    let divisor = select(-max(abs(uvd.z), 1e-30), max(abs(uvd.z), 1e-30), uvd.z >= 0.0);
    let u = uvd.x / divisor;
    let v = uvd.y / divisor;
    let us = 1.3965623 * u / (abs(u) + 1.4921736);
    let vs = 1.4513954 * v / (abs(v) + 1.5248864);
    let up = -1.1249839 * us - 0.9804837 * vs;
    let vp = 1.8632332 * us + 1.9718531 * vs;
    let ls = post_y_to_l_star(safe_xyz.y);
    let lw = post_y_to_l_star(1.0);
    let m2 = up * up + vp * vp;
    return vec3<f32>(ls / lw,
        15.932994 * pow(ls, 0.65239975) * pow(m2, 0.6007557) / lw,
        atan2(vp, up));
}

fn post_jch_to_xyz(jch: vec3<f32>) -> vec3<f32> {
    let lw = post_y_to_l_star(1.0);
    let ls = clamp(jch.x * lw, 0.0, UCS_L_STAR_UPPER);
    var m = 0.0;
    if ls != 0.0 { m = pow(max(jch.y * lw / (15.932994 * pow(ls, 0.65239975)), 0.0), 0.83228505); }
    let up = m * cos(jch.z);
    let vp = m * sin(jch.z);
    let us = -5.0375224 * up - 2.5048563 * vp;
    let vs = 4.7600293 * up + 2.874013 * vp;
    let u = -1.4921736 * us / (abs(us) - 1.3965623);
    let v = -1.5248864 * vs / (abs(vs) - 1.4513955);
    let xd = 0.16717148 * u + 0.1412998 * v - 0.008015313;
    let yd = -0.15095909 * u - 0.15518506 * v - 0.008433124;
    let zd = 0.94025475 * u + v - 0.025632596;
    let divisor = select(-max(abs(zd), 1e-30), max(abs(zd), 1e-30), zd >= 0.0);
    let x = xd / divisor;
    let y = yd / divisor;
    let luminance = pow(max(1.1242677 * ls / (UCS_L_STAR_RANGE - ls), 0.0), 1.5831518);
    if abs(y) <= 1e-30 { return vec3<f32>(0.0, luminance, 0.0); }
    return vec3<f32>(luminance * x / y, luminance, luminance * (1.0 - x - y) / y);
}

fn post_hue_delta(hue_a: f32, hue_b: f32) -> f32 {
    return atan2(sin(hue_b - hue_a), cos(hue_b - hue_a));
}

fn post_hue_distance(hue_a: f32, hue_b: f32) -> f32 {
    let difference = abs(hue_a - hue_b);
    return min(difference, 360.0 - difference);
}

fn post_is_in_gamut(rgb: vec3<f32>) -> bool {
    return all(rgb >= vec3<f32>(0.0)) && all(rgb <= vec3<f32>(1.0));
}

fn post_color_separation(rgb: vec3<f32>) -> vec3<f32> {
    let node_count = min(post.harmony_meta.x, 4u);
    if post.color_strength <= 0.0 || node_count == 0u { return rgb; }
    let linear_output = vec3<f32>(post_lookup(0u, rgb.r), post_lookup(0u, rgb.g), post_lookup(0u, rgb.b));
    let xyz = post_matrix_rgb(post.output_to_xyz_d65, linear_output);
    var jch = post_xyz_to_jch(xyz);
    let chroma = jch.y;
    if chroma <= 1e-7 { return rgb; }
    let hsv = post_rgb_to_hsv(rgb);
    let neutral = clamp(post.color_flags.x, 0.0, 1.0);
    let chroma_protection = chroma / (chroma + neutral * neutral * neutral * 0.03 + 1e-5);
    let saturation_mask = clamp((hsv.y - clamp(post.color.z, 0.0, 1.0)) / 0.35, 0.0, 1.0);
    let transition_width = 0.08 + clamp(post.color_flags.y, 0.0, 1.0) * 0.52;
    let pivot = clamp(0.5 + post.color.w * 0.5, 0.1, 0.9);
    let highlight_mix = smoothstep(pivot - transition_width * 0.5,
                                   pivot + transition_width * 0.5, jch.x);
    let shadow_hue = post.harmony_nodes[0];
    let highlight_hue = post.harmony_nodes[node_count - 1u];
    let toned_hue = shadow_hue + post_hue_delta(shadow_hue, highlight_hue) * highlight_mix;
    let amount = post.color_strength * chroma_protection * saturation_mask;
    let hue_shift = post_hue_delta(jch.z, toned_hue) * amount;
    if abs(hue_shift) < 1e-7 { return rgb; }
    jch.z = (jch.z + hue_shift + 3.14159265359) % 6.28318530718 - 3.14159265359;
    let candidate = post_matrix_rgb(post.xyz_d65_to_output, post_jch_to_xyz(jch));
    var mapped = candidate;
    if !post_is_in_gamut(candidate) {
        var low = 0.0;
        var high = chroma;
        var neutral_jch = jch;
        neutral_jch.y = 0.0;
        mapped = post_matrix_rgb(post.xyz_d65_to_output, post_jch_to_xyz(neutral_jch));
        for (var iteration = 0; iteration < 8; iteration++) {
            let mid = (low + high) * 0.5;
            var test_jch = jch;
            test_jch.y = mid;
            let rgb_mid = post_matrix_rgb(post.xyz_d65_to_output, post_jch_to_xyz(test_jch));
            if post_is_in_gamut(rgb_mid) {
                low = mid;
                mapped = rgb_mid;
            } else {
                high = mid;
            }
        }
    }
    let output = clamp(mapped, vec3<f32>(0.0), vec3<f32>(1.0));
    return vec3<f32>(post_lookup(1u, sqrt(output.r)), post_lookup(1u, sqrt(output.g)), post_lookup(1u, sqrt(output.b)));
}

fn post_rgb_to_hsl(rgb: vec3<f32>) -> vec3<f32> {
    let hi = max(rgb.r, max(rgb.g, rgb.b));
    let lo = min(rgb.r, min(rgb.g, rgb.b));
    let d = hi - lo;
    let l = (hi + lo) * 0.5;
    if d <= 1e-6 { return vec3<f32>(0.0, 0.0, l); }
    var h = 0.0;
    if hi == rgb.r { h = (rgb.g - rgb.b) / d; }
    else if hi == rgb.g { h = (rgb.b - rgb.r) / d + 2.0; }
    else { h = (rgb.r - rgb.g) / d + 4.0; }
    h = h * 60.0;
    if h < 0.0 { h += 360.0; }
    let s = select(d / max(2.0 - hi - lo, 1e-6), d / max(hi + lo, 1e-6), l < 0.5);
    return vec3<f32>(h, s, l);
}

fn post_hsl_to_rgb(hsl: vec3<f32>) -> vec3<f32> {
    let c = (1.0 - abs(2.0 * hsl.z - 1.0)) * hsl.y;
    let sector = hsl.x / 60.0;
    let x = c * (1.0 - abs((sector - 2.0 * floor(sector / 2.0)) - 1.0));
    let m = hsl.z - c * 0.5;
    var rgb = vec3<f32>(c, x, 0.0);
    if sector >= 1.0 && sector < 2.0 { rgb = vec3<f32>(x, c, 0.0); }
    else if sector >= 2.0 && sector < 3.0 { rgb = vec3<f32>(0.0, c, x); }
    else if sector >= 3.0 && sector < 4.0 { rgb = vec3<f32>(0.0, x, c); }
    else if sector >= 4.0 && sector < 5.0 { rgb = vec3<f32>(x, 0.0, c); }
    else if sector >= 5.0 { rgb = vec3<f32>(c, 0.0, x); }
    return clamp(rgb + vec3<f32>(m), vec3<f32>(0.0), vec3<f32>(1.0));
}

fn post_skin_shaper(rgb: vec3<f32>) -> vec3<f32> {
    let hsl = post_rgb_to_hsl(rgb);
    let target_hue = (20.0 - clamp(post.skin.w, -30.0, 30.0) + 360.0) % 360.0;
    let hue_width = clamp(post.skin_flags.x, 15.0, 65.0);
    let hue_distance = post_hue_distance(hsl.x, target_hue);
    let hue_mask = exp(-(hue_distance * hue_distance) / (hue_width * hue_width));
    let luma_width = 0.4 * clamp(post.skin_flags.z, 0.25, 1.75);
    let luma_distance = abs(hsl.z - clamp(post.skin_flags.y, 0.0, 1.0));
    let luma_mask = exp(-(luma_distance * luma_distance) / (luma_width * luma_width));
    let mask = hue_mask * luma_mask;

    let dens = -clamp(post.skin.y, -1.0, 1.0);
    let sat = clamp(post.skin.x, -1.0, 0.999);
    let red = vec3<f32>(1.0 + dens, -sat + dens, -sat + dens);
    let green = vec3<f32>(-sat + dens, 1.0 + dens, -sat + dens);
    let blue = vec3<f32>(-sat + dens, -sat + dens, 1.0 + dens);
    let cyan_dens = dens * 0.8;
    let magenta_dens = dens * 0.8;
    let yellow_dens = dens * 0.6;
    let cyan = vec3<f32>(-sat + cyan_dens, 1.0 + cyan_dens, 1.0 + cyan_dens);
    let magenta = vec3<f32>(1.0 + magenta_dens, -sat + magenta_dens, 1.0 + magenta_dens);
    let yellow = vec3<f32>(1.0 + yellow_dens, 1.0 + yellow_dens, -sat + yellow_dens);
    var adjusted = vec3<f32>(0.0);
    if rgb.r > rgb.g {
        if rgb.g > rgb.b {
            adjusted = rgb.r * red + rgb.g * (yellow - red) + rgb.b * (vec3<f32>(1.0) - yellow);
        } else if rgb.r > rgb.b {
            adjusted = rgb.r * red + rgb.g * (vec3<f32>(1.0) - magenta) + rgb.b * (magenta - red);
        } else {
            adjusted = rgb.r * (magenta - blue) + rgb.g * (vec3<f32>(1.0) - magenta) + rgb.b * blue;
        }
    } else if rgb.b > rgb.g {
        adjusted = rgb.r * (vec3<f32>(1.0) - cyan) + rgb.g * (cyan - blue) + rgb.b * blue;
    } else if rgb.b > rgb.r {
        adjusted = rgb.r * (vec3<f32>(1.0) - cyan) + rgb.g * green + rgb.b * (cyan - green);
    } else {
        adjusted = rgb.r * (yellow - green) + rgb.g * green + rgb.b * (vec3<f32>(1.0) - yellow);
    }
    var shaped_hsl = post_rgb_to_hsl(clamp(adjusted, vec3<f32>(0.0), vec3<f32>(1.0)));
    shaped_hsl.x = (shaped_hsl.x - clamp(post.skin.z, -60.0, 60.0) + 360.0) % 360.0;
    let shaped = post_hsl_to_rgb(shaped_hsl);
    var base = rgb;
    if post.skin_flags.w > 0.5 {
        let y = dot(rgb, vec3<f32>(0.2126, 0.7152, 0.0722));
        base = vec3<f32>(y * 0.1 + 0.18);
    }
    return clamp(mix(base, shaped, mask), vec3<f32>(0.0), vec3<f32>(1.0));
}

fn post_film_expand(rgb: vec3<f32>) -> vec3<f32> {
    let black = clamp(post.film_expand.x, -0.20, 0.30);
    let white = clamp(post.film_expand.y, 0.30, 1.20);
    let span = max(white - black, 0.000001);
    let amount = post.film_expand.w;
    if post.film_expand.z > 0.5 {
        let expanded = clamp((rgb - vec3<f32>(black)) / span, vec3<f32>(0.0), vec3<f32>(1.0));
        return mix(rgb, expanded, vec3<f32>(amount));
    }
    let y = dot(rgb, post.luma.xyz);
    let y2 = clamp((y - black) / span, 0.0, 1.0);
    let expanded = select(vec3<f32>(y2), clamp(rgb * y2 / max(y, 1e-8), vec3<f32>(0.0), vec3<f32>(1.0)), y > 1e-8);
    return mix(rgb, expanded, vec3<f32>(amount));
}

fn post_film_compression(rgb: vec3<f32>) -> vec3<f32> {
    let impact = post.film_compression.x;
    let y = dot(rgb, post.luma.xyz);
    let start = clamp(post.film_compression.y, 0.50, 1.20);
    let range = max(post.film_compression.z * 0.5, 0.01);
    let compressed = select(y, start + range * (1.0 - exp(-(y - start) / range)), y > start);
    let target_luma = mix(y, compressed, impact);
    let density = 1.0 + clamp(post.film_compression.w, 0.0, 1.0) * impact;
    let adjusted = clamp(vec3<f32>(target_luma) + (rgb - vec3<f32>(y)) * (target_luma / max(y, 1e-8)) * density,
                         vec3<f32>(0.0), vec3<f32>(1.0));
    return select(rgb, adjusted, y > 1e-8);
}

// `lookup` in post.rs: linear interpolation in table `t` (0 decode,
// 1 encode, 2 tone), sampled on [0, 1].
fn post_lookup(t: u32, x: f32) -> f32 {
    let at = clamp(x, 0.0, 1.0) * f32(POST_LUT - 1u);
    let i = min(u32(at), POST_LUT - 2u);
    let f = at - f32(i);
    let a = post_tables[t * POST_LUT + i];
    let b = post_tables[t * POST_LUT + i + 1u];
    return a + (b - a) * f;
}

// A scan pixel, NaN-free and clipped to [0, 1], adjusted; in the scan's
// encoding, clipped too.
fn post_relight(rgb: vec3<f32>, pixel: vec2<f32>, size: vec2<f32>) -> vec3<f32> {
    if post.relight_flags.x < 0.5 || post.relight_flags.y <= 0.0 { return rgb; }
    let min_dim = max(min(size.x, size.y), 1.0);
    var out = rgb;
    if post.encoded == 1u {
        out = vec3<f32>(post_lookup(0u, rgb.r), post_lookup(0u, rgb.g), post_lookup(0u, rgb.b));
    }
    for (var i = 0u; i < 3u; i++) {
        let p = post.relight_positions[i];
        let c = post.relight_colors[i];
        if c.w < 0.5 || p.w == 0.0 { continue; }
        let d = (pixel / size - p.xy) * size / min_dim;
        let falloff = clamp(1.0 - length(d) / clamp(p.z, 0.02, 1.5), 0.0, 1.0);
        let amount = falloff * falloff * clamp(p.w, -1.0, 1.0) * clamp(post.relight_flags.y, 0.0, 1.0);
        for (var channel = 0u; channel < 3u; channel++) {
            if amount >= 0.0 {
                out[channel] = out[channel] + (1.0 - out[channel]) * c[channel] * amount;
            } else {
                out[channel] = out[channel] * (1.0 + amount * c[channel]);
            }
        }
    }
    out = clamp(out, vec3<f32>(0.0), vec3<f32>(1.0));
    if post.encoded == 1u {
        out = vec3<f32>(post_lookup(1u, sqrt(out.r)), post_lookup(1u, sqrt(out.g)), post_lookup(1u, sqrt(out.b)));
    }
    return out;
}

fn post_rgb(rgb: vec3<f32>, pixel: vec2<f32>, size: vec2<f32>) -> vec3<f32> {
    if post.on == 0u {
        return rgb;
    }
    var c = rgb;
    if post.encoded == 1u {
        c = vec3<f32>(post_lookup(0u, c.r), post_lookup(0u, c.g), post_lookup(0u, c.b));
    }
    let y = post.luma.r * c.r + post.luma.g * c.g + post.luma.b * c.b;
    let y2 = post_lookup(2u, sqrt(max(y, 0.0)));
    if y <= 1e-9 {
        c = vec3<f32>(y2);
    } else {
        c = c * (y2 / y);
        // Above white, give up saturation rather than luminance or hue.
        let top = max(c.r, max(c.g, c.b));
        if top > 1.0 {
            let k = (1.0 - y2) / (top - y2);
            c = y2 + (c - y2) * k;
        }
    }
    var f = 1.0 + post.saturation;
    if f > 1.0 {
        // Stop at the gamut boundary, keeping the hue.
        for (var i = 0u; i < 3u; i++) {
            let d = c[i] - y2;
            if d > 0.0 {
                f = min(f, (1.0 - y2) / d);
            } else if d < 0.0 {
                f = min(f, y2 / -d);
            }
        }
    }
    c = clamp(y2 + (c - y2) * f, vec3<f32>(0.0), vec3<f32>(1.0));
    // Hue selection is perceptual/display-referred, matching the visible
    // image and picker. Keep tone work linear; encode only around this stage.
    if post.film_expand.w > 0.0 || post.film_compression.x > 0.0 || post.color_strength > 0.0
        || post.skin.x != 0.0 || post.skin.y != 0.0 || post.skin.z != 0.0 || post.skin_flags.w > 0.5 {
        var display = vec3<f32>(post_lookup(1u, sqrt(max(c.r, 0.0))),
                                post_lookup(1u, sqrt(max(c.g, 0.0))),
                                post_lookup(1u, sqrt(max(c.b, 0.0))));
        if post.film_expand.w > 0.0 { display = post_film_expand(display); }
        if post.film_compression.x > 0.0 { display = post_film_compression(display); }
        if post.color_strength > 0.0 { display = post_color_separation(display); }
        if post.skin.x != 0.0 || post.skin.y != 0.0 || post.skin.z != 0.0 || post.skin_flags.w > 0.5 {
            display = post_skin_shaper(display);
        }
        c = vec3<f32>(post_lookup(0u, display.r), post_lookup(0u, display.g), post_lookup(0u, display.b));
    }
    if post.encoded == 1u {
        c = vec3<f32>(post_lookup(1u, sqrt(c.r)), post_lookup(1u, sqrt(c.g)), post_lookup(1u, sqrt(c.b)));
    }
    return post_relight(c, pixel + vec2<f32>(0.5), size);
}
