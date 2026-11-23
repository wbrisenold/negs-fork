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

fn post_hsv_to_rgb(hsv: vec3<f32>) -> vec3<f32> {
    let h = hsv.x;
    let c = hsv.z * hsv.y;
    let x = c * (1.0 - abs((h / 60.0 - 2.0 * floor(h / 120.0)) - 1.0));
    let m = hsv.z - c;
    var rgb = vec3<f32>(c, x, 0.0);
    if h >= 60.0 && h < 120.0 { rgb = vec3<f32>(x, c, 0.0); }
    else if h >= 120.0 && h < 180.0 { rgb = vec3<f32>(0.0, c, x); }
    else if h >= 180.0 && h < 240.0 { rgb = vec3<f32>(0.0, x, c); }
    else if h >= 240.0 && h < 300.0 { rgb = vec3<f32>(x, 0.0, c); }
    else if h >= 300.0 { rgb = vec3<f32>(c, 0.0, x); }
    return clamp(rgb + vec3<f32>(m), vec3<f32>(0.0), vec3<f32>(1.0));
}

fn post_hue_distance(a: f32, b: f32) -> f32 {
    let d = abs(a - b);
    return min(d, 360.0 - d);
}

fn post_color_separation(rgb: vec3<f32>) -> vec3<f32> {
    if post.color_strength <= 0.0 { return rgb; }
    var hsv = post_rgb_to_hsv(rgb);
    let protection = max(1.0 - post.color_flags.x, min(hsv.y / 0.18, 1.0));
    let sat_mask = clamp((hsv.y - post.color.z) / 0.35, 0.0, 1.0);
    let lum_center = clamp(0.5 + post.color.w, 0.0, 1.0);
    let lum_mask = clamp(1.0 - abs(hsv.z - lum_center) / 0.5, 0.0, 1.0);
    let target = exp(-0.5 * pow(post_hue_distance(hsv.x, post.color.x) / 55.0, 2.0));
    let complement = exp(-0.5 * pow(post_hue_distance(hsv.x, post.color.y) / 55.0, 2.0));
    let amount = post.color_strength * protection * sat_mask * (0.35 + 0.65 * lum_mask);
    let method = post.color_flags.y;
    let hue_pull = select(target - complement, target, post.color_flags.z > 0.5);
    let delta = post_hue_distance(post.color.x, post.color.y);
    let signed_delta = select(delta, -delta, ((post.color.x - post.color.y) - 360.0 * floor((post.color.x - post.color.y) / 360.0)) > 180.0);
    hsv.x = (hsv.x + hue_pull * amount * (1.0 - method) * signed_delta * 0.18 + 360.0) % 360.0;
    hsv.y = clamp(hsv.y + (target + complement) * amount * method * 0.35, 0.0, 1.0);
    return post_hsv_to_rgb(hsv);
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
    let target = mix(y, compressed, impact);
    let density = 1.0 + clamp(post.film_compression.w, 0.0, 1.0) * impact;
    let adjusted = clamp(vec3<f32>(target) + (rgb - vec3<f32>(y)) * (target / max(y, 1e-8)) * density,
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
