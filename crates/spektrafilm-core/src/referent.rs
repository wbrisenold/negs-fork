//! Referent LogC3/AWG3 LUT color adaptation for scene-linear input.
//!
//! The shipped Referent LUT is a full display rendering transform. Applying
//! its output before Negs' film model stacks two tone-rendering stages. To
//! borrow its color mapping at the input instead, evaluate the LUT in its
//! intended LogC3/AWG3 space, decode the Rec.709 result, then restore the
//! source scene luminance. This keeps the LUT's hue/chroma mapping while
//! leaving exposure and highlight/shadow roll-off to the Negs pipeline.

use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock},
};

use rayon::prelude::*;
use spektrafilm_gpu::Lut3D;
use spektrafilm_math::{
    colorspace::{self, RgbColourspace},
    image::ImageBuf,
    lut::trilinear_3d,
    precision::{from_f32, to_f32},
};

const SRGB_TO_AWG3: [[f32; 3]; 3] = [
    [0.631_362_1, 0.270_812_36, 0.097_915_89],
    [0.036_753_58, 0.793_071_75, 0.170_135_22],
    [0.017_339_19, 0.148_795_57, 0.833_812_4],
];
static CUBE_CACHE: OnceLock<Mutex<HashMap<PathBuf, (u64, u128, Arc<Lut3D>)>>> = OnceLock::new();
type NeutralToneCurve = Vec<(f32, f32)>; // (scene-linear neutral Y, BT.1886-linear output Y)
static TONE_CACHE: OnceLock<Mutex<HashMap<usize, (Arc<Lut3D>, Arc<NeutralToneCurve>)>>> =
    OnceLock::new();

/// Parse a .cube file, normalizing its conventional red-fastest row order to
/// the core interpolator's red-major layout. Domain remaps are deliberately
/// rejected: the selected Referent LUT uses the standard [0, 1] domain.
pub fn load_cube(path: &Path) -> Result<Arc<Lut3D>, String> {
    let metadata = fs::metadata(path)
        .map_err(|e| format!("Cannot read Referent LUT {}: {e}", path.display()))?;
    let modified = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |time| time.as_nanos());
    let cache = CUBE_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some((len, stamp, lut)) = cache.lock().unwrap_or_else(|p| p.into_inner()).get(path)
        && *len == metadata.len()
        && *stamp == modified
    {
        return Ok(lut.clone());
    }
    let text = fs::read_to_string(path)
        .map_err(|e| format!("Cannot read Referent LUT {}: {e}", path.display()))?;
    let mut size = None;
    let mut domain_min = [0.0f32; 3];
    let mut domain_max = [1.0f32; 3];
    let mut values = Vec::<[f32; 3]>::new();
    for line in text.lines() {
        let line = line.split('#').next().unwrap_or("").trim();
        if line.is_empty() || line.starts_with("TITLE") {
            continue;
        }
        if let Some(rest) = line.strip_prefix("DOMAIN_MIN") {
            domain_min = parse_triplet(rest, "DOMAIN_MIN")?;
            continue;
        }
        if let Some(rest) = line.strip_prefix("DOMAIN_MAX") {
            domain_max = parse_triplet(rest, "DOMAIN_MAX")?;
            continue;
        }
        if let Some(rest) = line.strip_prefix("LUT_3D_SIZE") {
            let n: usize = rest
                .trim()
                .parse()
                .map_err(|_| "Invalid LUT_3D_SIZE".to_owned())?;
            if !(2..=129).contains(&n) {
                return Err(format!("Unsupported 3D LUT size: {n}"));
            }
            size = Some(n);
            continue;
        }
        if line.starts_with("LUT_1D_SIZE") {
            return Err("Referent input requires a 3D .cube LUT".into());
        }
        let mut parts = line.split_whitespace();
        let Some(r) = parts.next() else { continue };
        let (Ok(r), Some(g), Some(b)) = (r.parse::<f32>(), parts.next(), parts.next()) else {
            return Err(format!("Invalid LUT data row: {line}"));
        };
        let (Ok(g), Ok(b)) = (g.parse::<f32>(), b.parse::<f32>()) else {
            return Err(format!("Invalid LUT data row: {line}"));
        };
        if parts.next().is_some() || !r.is_finite() || !g.is_finite() || !b.is_finite() {
            return Err(format!("Invalid LUT data row: {line}"));
        }
        values.push([r, g, b]);
    }
    if domain_min != [0.0; 3] || domain_max != [1.0; 3] {
        return Err("Referent input requires a .cube LUT with a [0, 1] domain".into());
    }
    let n = size.ok_or("Missing LUT_3D_SIZE")?;
    if values.len() != n * n * n {
        return Err(format!(
            "Expected {} LUT entries, found {}",
            n * n * n,
            values.len()
        ));
    }
    let mut data = vec![0.0; values.len() * 3];
    // .cube rows enumerate red fastest; Lut3D indexes blue fastest.
    for b in 0..n {
        for g in 0..n {
            for r in 0..n {
                let src = (b * n * n + g * n + r) * 3;
                let dst = (r * n * n + g * n + b) * 3;
                data[dst..dst + 3].copy_from_slice(&values[src / 3]);
            }
        }
    }
    let lut = Arc::new(Lut3D {
        size: n as u32,
        data,
    });
    cache
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .insert(path.to_path_buf(), (metadata.len(), modified, lut.clone()));
    Ok(lut)
}

fn parse_triplet(rest: &str, name: &str) -> Result<[f32; 3], String> {
    let values: Result<Vec<f32>, _> = rest.split_whitespace().map(str::parse).collect();
    let values = values.map_err(|_| format!("Invalid {name}"))?;
    let [a, b, c]: [f32; 3] = values.try_into().map_err(|_| format!("Invalid {name}"))?;
    if !a.is_finite() || !b.is_finite() || !c.is_finite() {
        return Err(format!("Invalid {name}"));
    }
    Ok([a, b, c])
}

/// Apply Referent's color remapping while removing its neutral-axis tone
/// response from a scene-linear sRGB image.
///
/// `exposure_ev` chooses the LUT's chromatic response at the same exposure
/// used by the film pipeline; it is not baked into the returned pixels. The
/// The tone curve is measured from the LUT's neutral axis in BT.1886-linear
/// light, then inverted per pixel. This is exact for neutral tones; for colored
/// pixels it preserves Referent's hue-dependent luma changes as part of its
/// color mapping instead of forcing every pixel back to source luma.
pub fn apply_color_only(image: &ImageBuf, lut: &Arc<Lut3D>, exposure_ev: f64) -> ImageBuf {
    let gain = 2.0f64.powf(exposure_ev) as f32;
    let tone = neutral_tone_curve(lut);
    let mut output = image.clone();
    output.par_pixels_mut().for_each(|px| {
        let source = [to_f32(px[0]), to_f32(px[1]), to_f32(px[2])];
        let exposed = [source[0] * gain, source[1] * gain, source[2] * gain];
        let awg = [
            SRGB_TO_AWG3[0][0] * exposed[0]
                + SRGB_TO_AWG3[0][1] * exposed[1]
                + SRGB_TO_AWG3[0][2] * exposed[2],
            SRGB_TO_AWG3[1][0] * exposed[0]
                + SRGB_TO_AWG3[1][1] * exposed[1]
                + SRGB_TO_AWG3[1][2] * exposed[2],
            SRGB_TO_AWG3[2][0] * exposed[0]
                + SRGB_TO_AWG3[2][1] * exposed[1]
                + SRGB_TO_AWG3[2][2] * exposed[2],
        ];
        let logc = awg.map(logc3_encode_ei800);
        let rendered = trilinear_3d(&lut.data, lut.size as usize, logc[0], logc[1], logc[2]);
        // Referent writes an SDR display-referred Rec.709 image. To remove
        // that display rendering before Negs' film stage, invert the
        // BT.1886 display EOTF (gamma 2.4), not the BT.709 scene-light OETF.
        // The latter shifts the LUT's RGB ratios and therefore its color.
        let display_linear = rendered.map(|v| v.max(0.0).powf(2.4));
        // Undo the LUT's measured neutral-axis tone response, rather than
        // substituting source luma (which also erases legitimate LUT luma
        // changes for colored pixels).
        let rendered_y =
            0.2126 * display_linear[0] + 0.7152 * display_linear[1] + 0.0722 * display_linear[2];
        if rendered_y <= 1e-6 || !rendered_y.is_finite() {
            return;
        }
        let recovered_y = invert_neutral_tone(&tone, rendered_y);
        let scale = recovered_y / rendered_y;
        for c in 0..3 {
            // Remove LUT luminance/tone response and restore original scene
            // light. Undo the exposure used only to choose the LUT sample.
            px[c] = from_f32((display_linear[c] * scale / gain).max(0.0));
        }
    });
    output
}

/// Apply the full LogC3/AWG3-to-BT.1886 Referent transform to a finished
/// linear scan. This is the actual display transform, with no tone extraction.
pub fn apply_output_transform(image: &mut ImageBuf, lut: &Arc<Lut3D>, linear_input_space: &str) {
    let input = RgbColourspace::input(linear_input_space);
    let srgb = RgbColourspace::output("sRGB");
    let rec709_to_input = colorspace::icc_rgb_to_rgb(srgb, input);
    let input_to_srgb = colorspace::icc_rgb_to_rgb(input, srgb);
    image.par_pixels_mut().for_each(|px| {
        let linear_srgb = colorspace::mat3_vec_f64(
            &input_to_srgb,
            [
                to_f32(px[0]) as f64,
                to_f32(px[1]) as f64,
                to_f32(px[2]) as f64,
            ],
        );
        let awg3 = [
            SRGB_TO_AWG3[0][0] as f64 * linear_srgb[0]
                + SRGB_TO_AWG3[0][1] as f64 * linear_srgb[1]
                + SRGB_TO_AWG3[0][2] as f64 * linear_srgb[2],
            SRGB_TO_AWG3[1][0] as f64 * linear_srgb[0]
                + SRGB_TO_AWG3[1][1] as f64 * linear_srgb[1]
                + SRGB_TO_AWG3[1][2] as f64 * linear_srgb[2],
            SRGB_TO_AWG3[2][0] as f64 * linear_srgb[0]
                + SRGB_TO_AWG3[2][1] as f64 * linear_srgb[1]
                + SRGB_TO_AWG3[2][2] as f64 * linear_srgb[2],
        ];
        let logc = awg3.map(|v| logc3_encode_ei800(v as f32));
        let display = trilinear_3d(&lut.data, lut.size as usize, logc[0], logc[1], logc[2]);
        let linear709 = display.map(|v| v.max(0.0).powf(2.4) as f64);
        let linear_input = colorspace::mat3_vec_f64(&rec709_to_input, linear709);
        for c in 0..3 {
            px[c] = from_f32(linear_input[c] as f32);
        }
    });
}

/// Measure the actual LUT response to neutral LogC3 samples. A strong Arc in
/// the cache value keeps pointer keys unique while their curves are retained.
fn neutral_tone_curve(lut: &Arc<Lut3D>) -> Arc<NeutralToneCurve> {
    let cache = TONE_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let key = Arc::as_ptr(lut) as usize;
    if let Some((_, curve)) = cache.lock().unwrap_or_else(|p| p.into_inner()).get(&key) {
        return curve.clone();
    }
    const SAMPLES: usize = 4096;
    let mut curve = Vec::with_capacity(SAMPLES + 1);
    let mut monotone_y = 0.0f32;
    for i in 0..=SAMPLES {
        let code = i as f32 / SAMPLES as f32;
        let scene_y = logc3_decode_ei800(code).max(0.0);
        let output = trilinear_3d(&lut.data, lut.size as usize, code, code, code);
        let output_y = 0.2126 * output[0].max(0.0).powf(2.4)
            + 0.7152 * output[1].max(0.0).powf(2.4)
            + 0.0722 * output[2].max(0.0).powf(2.4);
        // A neutral tone curve must be invertible. Remove only numerical or
        // LUT-quantization reversals; retain its measured endpoints and shape.
        monotone_y = monotone_y.max(output_y);
        curve.push((scene_y, monotone_y));
    }
    let curve = Arc::new(curve);
    let mut entries = cache.lock().unwrap_or_else(|p| p.into_inner());
    if entries.len() >= 4 {
        entries.clear();
    }
    entries.insert(key, (lut.clone(), curve.clone()));
    curve
}

/// Invert the sampled monotone neutral-axis tone response by linear
/// interpolation between adjacent LUT-derived measurements.
fn invert_neutral_tone(curve: &[(f32, f32)], output_y: f32) -> f32 {
    let Some(&(first_x, first_y)) = curve.first() else {
        return output_y;
    };
    let Some(&(last_x, last_y)) = curve.last() else {
        return output_y;
    };
    if output_y <= first_y {
        return first_x;
    }
    if output_y >= last_y {
        return last_x;
    }
    let upper = curve
        .partition_point(|&(_, y)| y < output_y)
        .min(curve.len() - 1);
    let (x0, y0) = curve[upper - 1];
    let (x1, y1) = curve[upper];
    if y1 <= y0 {
        x1
    } else {
        x0 + (x1 - x0) * ((output_y - y0) / (y1 - y0))
    }
}

#[inline]
fn logc3_encode_ei800(x: f32) -> f32 {
    const CUT: f32 = 0.010_591;
    if x > CUT {
        0.247_190 * (5.555_556 * x + 0.052_272).log10() + 0.385_537
    } else {
        5.367_655 * x + 0.092_809
    }
}

#[inline]
fn logc3_decode_ei800(x: f32) -> f32 {
    const CUT_CODE: f32 = 0.149_658;
    if x > CUT_CODE {
        ((10.0f32).powf((x - 0.385_537) / 0.247_190) - 0.052_272) / 5.555_556
    } else {
        (x - 0.092_809) / 5.367_655
    }
}
