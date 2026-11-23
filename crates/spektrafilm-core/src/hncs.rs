//! A smooth, global HNCS-style lightness approximation.
//!
//! The upstream photo recipe uses 8×8 CLAHE. That local, resolution-dependent
//! step produced visible mottling in flat studio backdrops, so Negs keeps the
//! gamma lift and film shoulder but applies them globally. This is deliberately
//! an approximation, not Hasselblad's proprietary color rendering or a
//! pixel-exact port of the upstream CLAHE look.

use rayon::prelude::*;
use spektrafilm_math::{
    colorspace::{self, RgbColourspace},
    image::ImageBuf,
    precision::{from_f64, to_f64},
};

const LAB_EPSILON: f64 = 216.0 / 24_389.0;
const LAB_KAPPA: f64 = 24_389.0 / 27.0;
const REFERENCE_TILE_GRID: usize = 8;
const REFERENCE_CLIP_LIMIT: f64 = 1.25;

/// Apply the smooth HNCS-style lightness curve in the selected output space.
/// The transform is global and scale-independent: matching output luminance
/// changes all pixels by the same curve, without analyzing neighboring tiles.
pub fn apply(
    image: &mut ImageBuf,
    output_space: &str,
    encoded: bool,
    settings: &crate::post::HncsParams,
) {
    let space = RgbColourspace::output(output_space);
    let xyz_to_rgb = colorspace::mat3_inverse(&space.rgb_to_xyz);
    let white = space.whitepoint_xyz;

    // The image is RGB triplets. If it is malformed, leave it intact.
    if image.width == 0
        || image.height == 0
        || (image.width as usize)
            .checked_mul(image.height as usize)
            .and_then(|pixels| pixels.checked_mul(3))
            != Some(image.data.len())
    {
        return;
    }

    image.data.par_chunks_exact_mut(3).for_each(|pixel| {
        let mut rgb = [0.0; 3];
        for channel in 0..3 {
            let value = to_f64(pixel[channel]).clamp(0.0, 1.0);
            rgb[channel] = if encoded {
                space.cctf.decode(value)
            } else {
                value
            };
        }

        let xyz = colorspace::mat3_vec_f64(&space.rgb_to_xyz, rgb);
        let fx = lab_f(xyz[0] / white[0]);
        let fy = lab_f(xyz[1] / white[1]);
        let fz = lab_f(xyz[2] / white[2]);
        let l_star = ((116.0 * fy - 16.0) / 100.0).clamp(0.0, 1.0);
        let a = 500.0 * (fx - fy);
        let b = 200.0 * (fy - fz);
        // Match the reference recipe's exposure lift and smooth film shoulder
        // without quantizing Lab a/b or introducing tile-local contrast.
        let lifted = l_star.powf(0.8);
        let target_l =
            protect_hncs_lift(l_star, film_curve(lifted), a, b, settings.skin_protection) * 100.0;
        let target_fy = (target_l + 16.0) / 116.0;
        let target_fx = target_fy + a / 500.0;
        let target_fz = target_fy - b / 200.0;
        let target_xyz = [
            white[0] * lab_f_inverse(target_fx),
            white[1] * lab_f_inverse(target_fy),
            white[2] * lab_f_inverse(target_fz),
        ];
        let output = lab_to_gamut_rgb(target_xyz, a, b, target_l, &xyz_to_rgb, white);

        for channel in 0..3 {
            let linear = output[channel].clamp(0.0, 1.0);
            let value = if encoded {
                space.cctf.encode(linear)
            } else {
                linear
            };
            pixel[channel] = from_f64(value);
        }
    });
}

/// Reference-style HNCS path: 8-bit exposure LUT, 8×8 CLAHE, then film LUT.
/// LUT values truncate to u8 like NumPy's `astype(np.uint8)` upstream.
/// Color conversion is a Rust approximation, not a bit-exact OpenCV port.
pub fn apply_reference(
    image: &mut ImageBuf,
    output_space: &str,
    encoded: bool,
    settings: &crate::post::HncsParams,
) {
    let source = RgbColourspace::output(output_space);
    let srgb = RgbColourspace::output("sRGB");
    let srgb_xyz_to_rgb = colorspace::mat3_inverse(&srgb.rgb_to_xyz);
    let srgb_white = srgb.whitepoint_xyz;
    let to_srgb = colorspace::icc_rgb_to_rgb(source, srgb);
    let from_srgb = colorspace::icc_rgb_to_rgb(srgb, source);
    let (w, h) = (image.width as usize, image.height as usize);
    if w == 0 || h == 0 || w.checked_mul(h).and_then(|n| n.checked_mul(3)) != Some(image.data.len())
    {
        return;
    }

    let mut lab = vec![[0u8; 3]; w * h];
    lab.par_iter_mut()
        .zip(image.data.par_chunks_exact(3))
        .for_each(|(out, pixel)| {
            let rgb = [0, 1, 2].map(|i| {
                let value = to_f64(pixel[i]);
                if encoded {
                    source.cctf.decode(value)
                } else {
                    value
                }
            });
            let linear = colorspace::mat3_vec_f64(&to_srgb, rgb);
            let rgb = linear.map(|value| srgb.cctf.encode(value).clamp(0.0, 1.0));
            *out = rgb_to_lab8(rgb);
        });

    let original_lightness: Vec<u8> = lab.par_iter().map(|pixel| pixel[0]).collect();
    let mut lightness = original_lightness.clone();
    lightness.par_iter_mut().for_each(|value| {
        *value = ((*value as f64 / 255.0).powf(0.8) * 255.0).clamp(0.0, 255.0) as u8;
    });
    let lifted = lightness.clone();
    clahe_reference(&mut lightness, w, h);
    lightness
        .par_iter_mut()
        .zip(lifted.par_iter())
        .for_each(|(local, lifted)| {
            let clahe = *lifted as f64 / 255.0
                + (*local as f64 / 255.0 - *lifted as f64 / 255.0)
                    * (settings.clahe_strength.clamp(0.0, 100.0) / 100.0) as f64;
            *local = (film_curve(clahe) * 255.0).round().clamp(0.0, 255.0) as u8;
        });

    image
        .data
        .par_chunks_exact_mut(3)
        .zip(lab.par_iter().zip(lightness.par_iter()))
        .for_each(|(output_pixel, (pixel, light))| {
            let original_l = pixel[0] as f64 / 255.0;
            let a = pixel[1] as f64 - 128.0;
            let b = pixel[2] as f64 - 128.0;
            let target_l = protect_hncs_lift(
                original_l,
                *light as f64 / 255.0,
                a,
                b,
                settings.skin_protection,
            );
            let linear =
                lab_to_gamut_rgb_srgb(target_l * 100.0, a, b, &srgb_xyz_to_rgb, srgb_white);
            let output = colorspace::mat3_vec_f64(&from_srgb, linear);
            for channel in 0..3 {
                output_pixel[channel] = from_f64(if encoded {
                    source.cctf.encode(output[channel])
                } else {
                    output[channel]
                });
            }
        });
}

fn smoothstep(edge0: f64, edge1: f64, x: f64) -> f64 {
    let t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// Back off the upward HNCS lift on warm, chromatic bright tones and highlights.
fn protect_hncs_lift(original_l: f64, target_l: f64, a: f64, b: f64, amount: f32) -> f64 {
    let chroma = a.hypot(b);
    let hue = b.atan2(a).to_degrees();
    let hue_distance = (hue - 48.0).abs().min(360.0 - (hue - 48.0).abs());
    let warm_hue = (1.0 - (hue_distance / 48.0).clamp(0.0, 1.0)).powi(2);
    let skin = smoothstep(5.0, 16.0, chroma) * warm_hue * smoothstep(0.35, 0.72, original_l);
    let highlight = smoothstep(0.78, 0.98, original_l) * 0.55;
    let protection =
        (skin.max(highlight) * (amount.clamp(0.0, 100.0) as f64 / 100.0)).clamp(0.0, 1.0);
    if target_l > original_l {
        target_l - (target_l - original_l) * protection
    } else {
        target_l
    }
}

fn lab_to_gamut_rgb(
    target_xyz: [f64; 3],
    a: f64,
    b: f64,
    l_star: f64,
    xyz_to_rgb: &[[f64; 3]; 3],
    white: [f64; 3],
) -> [f64; 3] {
    let fy = (l_star + 16.0) / 116.0;
    let convert = |scale: f64| {
        let fx = fy + (a * scale) / 500.0;
        let fz = fy - (b * scale) / 200.0;
        colorspace::mat3_vec_f64(
            xyz_to_rgb,
            [
                white[0] * lab_f_inverse(fx),
                white[1] * lab_f_inverse(fy),
                white[2] * lab_f_inverse(fz),
            ],
        )
    };
    let output = colorspace::mat3_vec_f64(xyz_to_rgb, target_xyz);
    if output.iter().all(|v| (0.0..=1.0).contains(v)) {
        return output;
    }
    let (mut low, mut high) = (0.0, 1.0);
    for _ in 0..12 {
        let mid = (low + high) * 0.5;
        if convert(mid).iter().all(|v| (0.0..=1.0).contains(v)) {
            low = mid;
        } else {
            high = mid;
        }
    }
    convert(low).map(|v| v.clamp(0.0, 1.0))
}

fn lab_to_gamut_rgb_srgb(
    l_star: f64,
    a: f64,
    b: f64,
    xyz_to_rgb: &[[f64; 3]; 3],
    white: [f64; 3],
) -> [f64; 3] {
    let fy = (l_star + 16.0) / 116.0;
    let convert = |scale: f64| {
        let fx = fy + a * scale / 500.0;
        let fz = fy - b * scale / 200.0;
        colorspace::mat3_vec_f64(
            xyz_to_rgb,
            [
                white[0] * lab_f_inverse(fx),
                white[1] * lab_f_inverse(fy),
                white[2] * lab_f_inverse(fz),
            ],
        )
    };
    let output = convert(1.0);
    if output.iter().all(|v| (0.0..=1.0).contains(v)) {
        return output;
    }
    let mut low = 0.0;
    let mut high = 1.0;
    for _ in 0..12 {
        let mid = (low + high) * 0.5;
        if convert(mid).iter().all(|v| (0.0..=1.0).contains(v)) {
            low = mid;
        } else {
            high = mid;
        }
    }
    convert(low).map(|v| v.clamp(0.0, 1.0))
}

fn clahe_reference(image: &mut [u8], width: usize, height: usize) {
    let tile_w = width.div_ceil(REFERENCE_TILE_GRID).max(1);
    let tile_h = height.div_ceil(REFERENCE_TILE_GRID).max(1);
    let padded_w = tile_w * REFERENCE_TILE_GRID;
    let padded_h = tile_h * REFERENCE_TILE_GRID;
    let mut padded = vec![0u8; padded_w * padded_h];
    padded
        .par_chunks_mut(padded_w)
        .enumerate()
        .for_each(|(y, row)| {
            let sy = reflect101(y, height);
            for (x, value) in row.iter_mut().enumerate() {
                *value = image[sy * width + reflect101(x, width)];
            }
        });

    let tile_area = tile_w * tile_h;
    let limit = ((REFERENCE_CLIP_LIMIT * tile_area as f64 / 256.0).floor() as u32).max(1);
    let mut maps = vec![[0u8; 256]; REFERENCE_TILE_GRID * REFERENCE_TILE_GRID];
    maps.par_iter_mut().enumerate().for_each(|(tile, map)| {
        let ty = tile / REFERENCE_TILE_GRID;
        let tx = tile % REFERENCE_TILE_GRID;
        let mut histogram = [0u32; 256];
        for y in ty * tile_h..(ty + 1) * tile_h {
            for x in tx * tile_w..(tx + 1) * tile_w {
                histogram[padded[y * padded_w + x] as usize] += 1;
            }
        }
        let mut excess = 0u32;
        for count in &mut histogram {
            if *count > limit {
                excess += *count - limit;
                *count = limit;
            }
        }
        let batch = excess / 256;
        let residual = excess - batch * 256;
        for count in &mut histogram {
            *count += batch;
        }
        if residual > 0 {
            let step = (256 / residual as usize).max(1);
            let mut index = 0;
            let mut left = residual;
            while index < 256 && left > 0 {
                histogram[index] += 1;
                index += step;
                left -= 1;
            }
        }
        let mut cdf = 0u32;
        for (index, count) in histogram.iter().enumerate() {
            cdf += count;
            map[index] = ((cdf * 255 + tile_area as u32 / 2) / tile_area as u32).min(255) as u8;
        }
    });

    image.par_iter_mut().enumerate().for_each(|(index, value)| {
        let y = index / width;
        let x = index % width;
        let tyf = (y as f64 / tile_h as f64 - 0.5).clamp(0.0, (REFERENCE_TILE_GRID - 1) as f64);
        let ty0 = tyf.floor() as usize;
        let ty1 = (ty0 + 1).min(REFERENCE_TILE_GRID - 1);
        let fy = tyf - ty0 as f64;
        let txf = (x as f64 / tile_w as f64 - 0.5).clamp(0.0, (REFERENCE_TILE_GRID - 1) as f64);
        let tx0 = txf.floor() as usize;
        let tx1 = (tx0 + 1).min(REFERENCE_TILE_GRID - 1);
        let fx = txf - tx0 as f64;
        let level = *value as usize;
        let a = maps[ty0 * REFERENCE_TILE_GRID + tx0][level] as f64;
        let b = maps[ty0 * REFERENCE_TILE_GRID + tx1][level] as f64;
        let c = maps[ty1 * REFERENCE_TILE_GRID + tx0][level] as f64;
        let d = maps[ty1 * REFERENCE_TILE_GRID + tx1][level] as f64;
        let top = a + (b - a) * fx;
        let bottom = c + (d - c) * fx;
        *value = (top + (bottom - top) * fy).round().clamp(0.0, 255.0) as u8;
    });
}

fn reflect101(value: usize, size: usize) -> usize {
    if size <= 1 {
        return 0;
    }
    let period = 2 * size - 2;
    let p = value % period;
    if p < size { p } else { period - p }
}

fn rgb_to_lab8(rgb: [f64; 3]) -> [u8; 3] {
    let srgb = RgbColourspace::output("sRGB");
    let [r, g, b] = rgb.map(|value| srgb.cctf.decode(value));
    let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047;
    let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b;
    let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883;
    let f = |value: f64| {
        if value > LAB_EPSILON {
            value.cbrt()
        } else {
            (LAB_KAPPA * value + 16.0) / 116.0
        }
    };
    let (fx, fy, fz) = (f(x), f(y), f(z));
    [
        ((116.0 * fy - 16.0).clamp(0.0, 100.0) * 255.0 / 100.0).round() as u8,
        (500.0 * (fx - fy) + 128.0).round().clamp(0.0, 255.0) as u8,
        (200.0 * (fy - fz) + 128.0).round().clamp(0.0, 255.0) as u8,
    ]
}

/// CIE Lab's piecewise forward function.
#[inline]
fn lab_f(value: f64) -> f64 {
    if value > LAB_EPSILON {
        value.cbrt()
    } else {
        (LAB_KAPPA * value + 16.0) / 116.0
    }
}

/// CIE Lab's piecewise inverse function.
#[inline]
fn lab_f_inverse(f: f64) -> f64 {
    let f3 = f * f * f;
    if f3 > LAB_EPSILON {
        f3
    } else {
        (116.0 * f - 16.0) / LAB_KAPPA
    }
}

/// The reference HNCS approximation's toe-free smooth shoulder:
/// identity through 0.5, then smoothstep to white.
#[inline]
fn film_curve(x: f64) -> f64 {
    let x = x.clamp(0.0, 1.0);
    if x <= 0.5 {
        x
    } else {
        let t = (x - 0.5) * 2.0;
        0.5 + (t * t * (3.0 - 2.0 * t)) * 0.5
    }
}

#[cfg(test)]
mod tests {
    use super::apply;
    use spektrafilm_math::{
        image::ImageBuf,
        precision::{from_f64, to_f64},
    };

    #[test]
    fn smooth_look_is_independent_of_neighboring_tiles() {
        let mut image = ImageBuf::new(32, 32);
        for y in 0..32 {
            for x in 0..32 {
                let value = if x < 16 && y < 16 { 0.8 } else { 0.35 };
                let index = image.idx(x, y, 0);
                image.data[index..index + 3].fill(from_f64(value));
            }
        }

        apply(
            &mut image,
            "sRGB",
            false,
            &crate::post::HncsParams::default(),
        );

        // Both pixels began with identical RGB. A global tone curve must give
        // them identical output even though their surrounding regions differ.
        let a = image.get(0, 31).map(to_f64);
        let b = image.get(31, 0).map(to_f64);
        for channel in 0..3 {
            assert!((a[channel] - b[channel]).abs() < 1e-7);
            assert!(a[channel].is_finite());
        }
    }
}
