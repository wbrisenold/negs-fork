//! RAW import white balance. See docs/raw-white-balance.md for upstream
//! provenance and the differences between LibRaw and rawler development.

use anyhow::{Result, bail, ensure};
use rawler::{RawImage, imgop::develop::Intermediate};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use spektrafilm_math::image::ImageBuf;
use std::sync::OnceLock;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RawWhiteBalanceMode {
    #[default]
    AsShot,
    Daylight,
    Tungsten,
    Custom,
    /// Camera-specific raw gains from Darktable's camera WB table.
    CameraPreset,
}

impl RawWhiteBalanceMode {
    pub const ALL: [Self; 4] = [Self::AsShot, Self::Daylight, Self::Tungsten, Self::Custom];

    /// Stable command-line spelling, matching the serialized mode.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AsShot => "as_shot",
            Self::Daylight => "daylight",
            Self::Tungsten => "tungsten",
            Self::Custom => "custom",
            Self::CameraPreset => "camera_preset",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::AsShot => "As shot",
            Self::Daylight => "Daylight",
            Self::Tungsten => "Tungsten (2850 K)",
            Self::Custom => "Custom",
            Self::CameraPreset => "Camera preset",
        }
    }
}

/// Legacy preset enum retained so existing sidecars keep their original values.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CanonR5WhiteBalancePreset {
    #[default]
    Daylight,
    Shade,
    Cloudy,
    Tungsten,
    CoolWhiteFluorescent,
    Flash,
}

impl CanonR5WhiteBalancePreset {
    pub const ALL: [Self; 6] = [
        Self::Daylight,
        Self::Shade,
        Self::Cloudy,
        Self::Tungsten,
        Self::CoolWhiteFluorescent,
        Self::Flash,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Self::Daylight => "Daylight",
            Self::Shade => "Shade",
            Self::Cloudy => "Cloudy",
            Self::Tungsten => "Tungsten",
            Self::CoolWhiteFluorescent => "Cool White Fluorescent",
            Self::Flash => "Flash",
        }
    }

    fn darktable_name(self) -> &'static str {
        self.label()
    }
}

/// Chromatic adaptation used by the temperature correction in RAW white balance.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RawWhiteBalanceMethod {
    /// CAT16 cone-response adaptation.
    #[default]
    Cat16,
    /// CAT02 cone-response adaptation (for older edits and comparison).
    Cat02,
    /// Direct diagonal scaling of linear CIE XYZ channels.
    XyzScaling,
}

impl RawWhiteBalanceMethod {
    pub const ALL: [Self; 3] = [Self::Cat16, Self::Cat02, Self::XyzScaling];

    pub fn label(self) -> &'static str {
        match self {
            Self::Cat16 => "CAT16",
            Self::Cat02 => "CAT02",
            Self::XyzScaling => "XYZ Scaling",
        }
    }
}

/// Settings shared by preview and export. Inactive temperature/tint values
/// are retained for the UI but are ignored unless the mode is Custom.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct RawWhiteBalance {
    pub mode: RawWhiteBalanceMode,
    pub temperature: f64,
    pub tint: f64,
    pub method: RawWhiteBalanceMethod,
    #[serde(default)]
    pub camera_preset: CanonR5WhiteBalancePreset,
    /// One-based index into this camera's Darktable presets; zero uses the
    /// legacy EOS R5 enum value so old sidecars keep their exact behavior.
    #[serde(default)]
    pub camera_preset_index: u16,
    #[serde(default)]
    pub camera_tuning: f64,
}

impl Default for RawWhiteBalance {
    fn default() -> Self {
        Self {
            mode: RawWhiteBalanceMode::AsShot,
            temperature: 5500.0,
            tint: 1.0,
            method: RawWhiteBalanceMethod::default(),
            camera_preset: CanonR5WhiteBalancePreset::default(),
            camera_preset_index: 0,
            camera_tuning: 0.0,
        }
    }
}

impl RawWhiteBalance {
    /// What the decoder uses: the temperature and tint only in Custom mode.
    /// Two settings with the same effective value decode identically.
    pub fn effective(self) -> Self {
        if matches!(
            self.mode,
            RawWhiteBalanceMode::Custom | RawWhiteBalanceMode::CameraPreset
        ) {
            self
        } else {
            Self {
                mode: self.mode,
                ..Self::default()
            }
        }
    }

    pub fn validate(self) -> Result<()> {
        if self.mode == RawWhiteBalanceMode::Custom {
            ensure!(
                self.temperature.is_finite() && (1667.0..=25000.0).contains(&self.temperature),
                "RAW WB temperature must be between 1667 and 25000 K"
            );
            ensure!(
                self.tint.is_finite() && self.tint > 0.0 && self.tint <= 4.0,
                "RAW WB tint must be greater than 0 and at most 4"
            );
        }
        if self.mode == RawWhiteBalanceMode::CameraPreset {
            ensure!(
                self.camera_tuning.is_finite()
                    && (-9.0..=9.0).contains(&self.camera_tuning)
                    && self.camera_tuning.fract() == 0.0,
                "Camera WB fine tuning must be an integer between -9 and +9"
            );
        }
        Ok(())
    }

    fn adjustment(self) -> Option<(f64, f64)> {
        match self.mode {
            RawWhiteBalanceMode::AsShot | RawWhiteBalanceMode::Daylight => None,
            RawWhiteBalanceMode::Tungsten => Some((2850.0, 1.0)),
            RawWhiteBalanceMode::Custom => Some((self.temperature, self.tint)),
            RawWhiteBalanceMode::CameraPreset => None,
        }
    }
}

/// Leave As-shot entirely untouched (including rawler's missing-WB fallback).
/// Custom also retains the camera's recorded WB multipliers as its baseline;
/// its temperature/tint controls are then a correction from that baseline.
/// Daylight and Tungsten start with a camera-matrix-derived daylight develop.
pub(crate) fn prepare(raw: &mut RawImage, settings: RawWhiteBalance) -> Result<()> {
    settings.validate()?;
    if settings.mode == RawWhiteBalanceMode::CameraPreset {
        if is_monochrome(raw) {
            return Ok(());
        }
        raw.wb_coeffs = darktable_camera_coefficients(
            &raw.make,
            &raw.model,
            settings.camera_preset,
            settings.camera_preset_index,
            settings.camera_tuning as i8,
        )?;
        return Ok(());
    }
    if matches!(
        settings.mode,
        RawWhiteBalanceMode::AsShot | RawWhiteBalanceMode::Custom
    ) || is_monochrome(raw)
    {
        return Ok(());
    }
    use rawler::imgop::{chromatic_adaption::adapt_bradford, xyz::Illuminant};
    // Match RawDevelop's matrix preference and illuminant adaptation exactly.
    let (illuminant, mut matrix) = raw
        .color_matrix_find_first([
            Illuminant::D65,
            Illuminant::A,
            Illuminant::B,
            Illuminant::C,
            Illuminant::D50,
            Illuminant::D55,
            Illuminant::D75,
            Illuminant::Daylight,
            Illuminant::Flash,
        ])
        .ok_or_else(|| {
            anyhow::anyhow!("RAW has no usable camera matrix for daylight white balance")
        })?;
    if illuminant != Illuminant::D65 {
        ensure!(
            matrix.len() == 9,
            "RAW WB requires a 3-channel matrix for non-D65 calibration"
        );
        let m = std::array::from_fn(|i| std::array::from_fn(|j| matrix[i * 3 + j]));
        matrix = adapt_bradford(&illuminant, &Illuminant::D65, &m)
            .as_flattened()
            .to_vec();
    }
    raw.wb_coeffs = daylight_coefficients(&matrix)?;
    Ok(())
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DarktableCameraWhiteBalance {
    pub maker: String,
    pub model: String,
    pub presets: Vec<DarktableCameraWhiteBalancePreset>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DarktableCameraWhiteBalancePreset {
    pub index: u16,
    pub name: String,
    pub tunings: Vec<DarktableCameraWhiteBalanceTuning>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DarktableCameraWhiteBalanceTuning {
    pub tuning: i8,
    pub channels: [f32; 4],
}

#[derive(Deserialize)]
struct DarktableWbDatabase {
    wb_presets: Vec<DarktableWbMaker>,
}
#[derive(Deserialize)]
struct DarktableWbMaker {
    maker: String,
    models: Vec<DarktableWbModel>,
}
#[derive(Deserialize)]
struct DarktableWbModel {
    model: String,
    presets: Vec<DarktableCameraWhiteBalanceTuningRow>,
}
#[derive(Clone, Deserialize)]
struct DarktableCameraWhiteBalanceTuningRow {
    name: String,
    #[serde(default)]
    tuning: i8,
    channels: [f32; 4],
}

fn darktable_wb_database() -> &'static DarktableWbDatabase {
    static DATA: OnceLock<DarktableWbDatabase> = OnceLock::new();
    let data = DATA.get_or_init(|| {
        serde_json::from_str(include_str!("darktable_wb_presets.json"))
            .expect("bundled Darktable camera WB data is valid")
    });
    data
}

/// Darktable camera WB entries matched from the RAW's TIFF make/model tags.
/// EOS R5 C intentionally uses Darktable's EOS R5 entry, as requested.
pub fn darktable_camera_white_balance(
    make: &str,
    model: &str,
) -> Option<DarktableCameraWhiteBalance> {
    let makers = darktable_wb_database();
    let maker_key = compact(make);
    let maker = makers.wb_presets.iter().find(|entry| {
        let key = compact(&entry.maker);
        maker_key.starts_with(&key) || key.starts_with(&maker_key)
    })?;
    let model_key = normalize_camera_model(make, model, &maker.maker);
    let alias_key = if model_key == "eosr5c" || model_key == "r5c" {
        "eosr5"
    } else {
        &model_key
    };
    let camera = maker
        .models
        .iter()
        .find(|entry| compact(&entry.model) == alias_key)?;
    let mut grouped: std::collections::BTreeMap<String, Vec<DarktableCameraWhiteBalanceTuning>> =
        std::collections::BTreeMap::new();
    for row in &camera.presets {
        grouped
            .entry(row.name.clone())
            .or_default()
            .push(DarktableCameraWhiteBalanceTuning {
                tuning: row.tuning,
                channels: [
                    row.channels[0],
                    row.channels[1],
                    row.channels[2],
                    if row.channels[3] > 0.0 {
                        row.channels[3]
                    } else {
                        row.channels[1]
                    },
                ],
            });
    }
    Some(DarktableCameraWhiteBalance {
        maker: maker.maker.clone(),
        model: camera.model.clone(),
        presets: grouped
            .into_iter()
            .enumerate()
            .map(|(index, (name, mut tunings))| {
                tunings.sort_by_key(|entry| entry.tuning);
                DarktableCameraWhiteBalancePreset {
                    index: index as u16,
                    name,
                    tunings,
                }
            })
            .collect(),
    })
}

fn darktable_camera_coefficients(
    make: &str,
    model: &str,
    legacy_preset: CanonR5WhiteBalancePreset,
    preset_index: u16,
    tuning: i8,
) -> Result<[f32; 4]> {
    ensure!(
        (-9..=9).contains(&tuning),
        "Camera WB fine tuning must be between -9 and +9"
    );
    let camera = darktable_camera_white_balance(make, model)
        .ok_or_else(|| anyhow::anyhow!("Darktable has no WB presets for camera {make} {model}"))?;
    let preset_name = if preset_index > 0 {
        camera
            .presets
            .get(usize::from(preset_index - 1))
            .map(|preset| preset.name.as_str())
            .ok_or_else(|| anyhow::anyhow!("Unknown Darktable WB preset index {preset_index}"))?
    } else {
        legacy_preset.darktable_name()
    };
    let key = compact(preset_name);
    let preset = camera
        .presets
        .iter()
        .find(|row| compact(&row.name) == key)
        .ok_or_else(|| {
            anyhow::anyhow!("Darktable {} has no {preset_name} WB preset", camera.model)
        })?;
    let tuning_min = preset
        .tunings
        .iter()
        .map(|row| row.tuning)
        .min()
        .unwrap_or(0);
    let tuning_max = preset
        .tunings
        .iter()
        .map(|row| row.tuning)
        .max()
        .unwrap_or(0);
    // Some camera entries expose preset gains without any fine-tuning rows.
    // Treat stale/non-supported tuning values as the nearest recorded value
    // instead of failing RAW development.
    let tuning = tuning.clamp(tuning_min, tuning_max);
    let channels = if let Some(exact) = preset.tunings.iter().find(|row| row.tuning == tuning) {
        exact.channels
    } else {
        let lower = preset
            .tunings
            .iter()
            .filter(|row| row.tuning < tuning)
            .max_by_key(|row| row.tuning);
        let upper = preset
            .tunings
            .iter()
            .filter(|row| row.tuning > tuning)
            .min_by_key(|row| row.tuning);
        match (lower, upper) {
            (Some(a), Some(b)) => {
                let t = f32::from(tuning - a.tuning) / f32::from(b.tuning - a.tuning);
                std::array::from_fn(|i| a.channels[i] + (b.channels[i] - a.channels[i]) * t)
            }
            _ => anyhow::bail!(
                "Darktable {} {preset_name} has no tuning value {tuning}",
                camera.model
            ),
        }
    };
    // Darktable writes zero for Canon's unused fourth coefficient; rawler
    // expects the second green CFA channel to carry G1's neutral gain.
    Ok([
        channels[0],
        channels[1],
        channels[2],
        if channels[3] > 0.0 {
            channels[3]
        } else {
            channels[1]
        },
    ])
}

fn compact(value: &str) -> String {
    value
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

fn normalize_camera_model(make: &str, model: &str, table_maker: &str) -> String {
    let mut key = compact(model);
    for prefix in [compact(make), compact(table_maker)] {
        if key.starts_with(&prefix) {
            key.drain(..prefix.len());
        }
    }
    key
}

pub(crate) fn is_monochrome(raw: &RawImage) -> bool {
    // Monochrome DNGs can be tagged LinearRaw with one sample per pixel,
    // which rawler's is_monochrome() (BlackIsZero only) doesn't recognize.
    raw.is_monochrome()
        || (raw.cpp == 1
            && !matches!(
                raw.photometric,
                rawler::rawimage::RawPhotometricInterpretation::Cfa(_)
            ))
}

fn daylight_coefficients(matrix: &[f32]) -> Result<[f32; 4]> {
    ensure!(
        matches!(matrix.len(), 9 | 12),
        "RAW WB requires a 3- or 4-channel XYZ-to-camera matrix"
    );
    let white = whitepoint(6504.0);
    let mut response = [0.0; 4];
    for (i, row) in matrix.chunks_exact(3).enumerate() {
        response[i] = row
            .iter()
            .zip(white)
            .map(|(&m, w)| f64::from(m) * w)
            .sum::<f64>();
        ensure!(
            response[i].is_finite() && response[i] > 0.0,
            "RAW camera matrix gives an invalid daylight response for channel {i}"
        );
    }
    if matrix.len() == 9 {
        response[3] = response[1];
    }
    let wb = response.map(|v| (response[1] / v) as f32);
    ensure!(
        wb.iter().all(|v| v.is_finite() && *v > 0.0),
        "Invalid RAW daylight coefficients"
    );
    Ok(wb)
}

type Matrix = [[f64; 3]; 3];
const IDENTITY: Matrix = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]];
const CAT02: Matrix = [
    [0.7328, 0.4296, -0.1624],
    [-0.7036, 1.6975, 0.0061],
    [0.0030, 0.0136, 0.9834],
];
const SRGB_TO_XYZ: Matrix = [
    [0.4124, 0.3576, 0.1805],
    [0.2126, 0.7152, 0.0722],
    [0.0193, 0.1192, 0.9505],
];
const ACES_TO_XYZ: Matrix = [
    [0.9525523959, 0.0, 0.0000936786],
    [0.3439664498, 0.7281660966, -0.0721325464],
    [0.0, 0.0, 1.0088251844],
];

fn mv(m: Matrix, v: [f64; 3]) -> [f64; 3] {
    m.map(|r| r.iter().zip(v).map(|(a, b)| a * b).sum())
}

fn mm(a: Matrix, b: Matrix) -> Matrix {
    std::array::from_fn(|i| std::array::from_fn(|j| (0..3).map(|k| a[i][k] * b[k][j]).sum()))
}

fn inverse(m: Matrix) -> Matrix {
    let c: Matrix = std::array::from_fn(|i| {
        std::array::from_fn(|j| {
            m[(i + 1) % 3][(j + 1) % 3] * m[(i + 2) % 3][(j + 2) % 3]
                - m[(i + 1) % 3][(j + 2) % 3] * m[(i + 2) % 3][(j + 1) % 3]
        })
    });
    let det: f64 = (0..3).map(|j| m[0][j] * c[0][j]).sum();
    std::array::from_fn(|i| std::array::from_fn(|j| c[j][i] / det))
}

/// CIE daylight locus >=4000 K; Kang 2002 Planckian locus below, as upstream.
fn whitepoint(t: f64) -> [f64; 3] {
    let x = if t >= 4000.0 {
        if t <= 7000.0 {
            -4.607e9 / t.powi(3) + 2.9678e6 / t.powi(2) + 99.11 / t + 0.244063
        } else {
            -2.0064e9 / t.powi(3) + 1.9018e6 / t.powi(2) + 247.48 / t + 0.237040
        }
    } else {
        -0.2661239e9 / t.powi(3) - 0.2343589e6 / t.powi(2) + 0.8776956e3 / t + 0.179910
    };
    let y = if t >= 4000.0 {
        -3.0 * x * x + 2.87 * x - 0.275
    } else if t <= 2222.0 {
        -1.1063814 * x.powi(3) - 1.34811020 * x.powi(2) + 2.18555832 * x - 0.20219683
    } else {
        -0.9549476 * x.powi(3) - 1.37418593 * x.powi(2) + 2.09137015 * x - 0.16748867
    };
    [x / y, 1.0, (1.0 - x - y) / y]
}

fn adaptation(source: [f64; 3], target: [f64; 3], method: RawWhiteBalanceMethod) -> Matrix {
    if source == target {
        return IDENTITY;
    }
    if method == RawWhiteBalanceMethod::XyzScaling {
        let mut scale = IDENTITY;
        for i in 0..3 {
            scale[i][i] = target[i] / source[i];
        }
        return scale;
    }
    if method == RawWhiteBalanceMethod::Cat16 {
        return spektrafilm_math::colorspace::chromatic_adaptation_matrix_cat16_f64(source, target);
    }
    let s = mv(CAT02, source);
    let t = mv(CAT02, target);
    let mut scale = IDENTITY;
    for i in 0..3 {
        scale[i][i] = t[i] / s[i];
    }
    mm(inverse(CAT02), mm(scale, CAT02))
}

fn adjustment_matrix(temperature: f64, tint: f64, method: RawWhiteBalanceMethod) -> Matrix {
    if temperature == 6504.0 && tint == 1.0 {
        return IDENTITY;
    }
    let temperature_adjust = adaptation(whitepoint(temperature), whitepoint(6504.0), method);
    // Work in ACES2065-1 (D60). Move linear sRGB (D65) into the same space,
    // apply the selected CAT and ACES green tint,
    // then return to sRGB using the same selected adaptation method.
    let d65 = [0.3127 / 0.3290, 1.0, (1.0 - 0.3127 - 0.3290) / 0.3290];
    let d60 = [0.32168 / 0.33767, 1.0, (1.0 - 0.32168 - 0.33767) / 0.33767];
    let to_aces_xyz = adaptation(d65, d60, method);
    let mut tint_scale = IDENTITY;
    tint_scale[1][1] = tint;
    let tint_xyz = mm(ACES_TO_XYZ, mm(tint_scale, inverse(ACES_TO_XYZ)));
    mm(
        inverse(SRGB_TO_XYZ),
        mm(
            inverse(to_aces_xyz),
            mm(
                tint_xyz,
                mm(temperature_adjust, mm(to_aces_xyz, SRGB_TO_XYZ)),
            ),
        ),
    )
}

/// Temperature/tint candidate selected from the RAW-developed source using
/// RawTherapee's spectral-reference ITCWB approach. The compact reference
/// table is generated from its 429 measured reflectance spectra.
#[derive(Clone, Copy, Debug)]
pub struct ItcwbEstimate {
    pub temperature: f64,
    pub tint: f64,
    pub confidence: f64,
}

const ITCWB_REFERENCES: &[u8] = include_bytes!("itcwb_reference_xy.bin");

fn reference_xy() -> Vec<[f64; 2]> {
    let count = u32::from_le_bytes(ITCWB_REFERENCES[0..4].try_into().unwrap()) as usize;
    (0..count)
        .map(|i| {
            let offset = 4 + i * 8;
            [
                f32::from_le_bytes(ITCWB_REFERENCES[offset..offset + 4].try_into().unwrap()) as f64,
                f32::from_le_bytes(ITCWB_REFERENCES[offset + 4..offset + 8].try_into().unwrap())
                    as f64,
            ]
        })
        .collect()
}

/// Estimate a RAW white balance from the linear, camera-matrix-developed RGB
/// image. This ports ITCWB's spectral-reference/candidate-search strategy;
/// it intentionally returns an error for low-information or near-monochrome
/// frames instead of silently falling back to gray-world.
pub fn estimate_itcwb(image: &ImageBuf) -> Result<ItcwbEstimate> {
    estimate_itcwb_with_method(image, RawWhiteBalanceMethod::Cat16)
}

/// Estimate RAW white balance using the same adaptation method that will be
/// used when the selected temperature/tint is applied to the developed image.
pub fn estimate_itcwb_with_method(
    image: &ImageBuf,
    method: RawWhiteBalanceMethod,
) -> Result<ItcwbEstimate> {
    ensure!(
        image.width > 0 && image.height > 0,
        "ITCWB needs a non-empty image"
    );
    let stride = ((image.pixel_count() / 256).max(1)) * 3;
    let mut samples = Vec::with_capacity(256);
    for pixel in image.data.chunks_exact(3).step_by(stride / 3) {
        let rgb = [pixel[0] as f64, pixel[1] as f64, pixel[2] as f64];
        let y = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
        if !y.is_finite() || !(0.015..0.95).contains(&y) {
            continue;
        }
        let max = rgb[0].max(rgb[1]).max(rgb[2]);
        let min = rgb[0].min(rgb[1]).min(rgb[2]);
        if max - min < y * 0.035 {
            continue;
        }
        samples.push(rgb);
    }
    ensure!(
        samples.len() >= 12,
        "ITCWB found too little usable color; try a frame with more varied, well-exposed colors"
    );

    let references = reference_xy();
    ensure!(
        references.len() == 429,
        "ITCWB spectral reference table is incomplete"
    );
    let score = |temperature: f64, tint: f64| -> f64 {
        let matrix = adjustment_matrix(temperature, tint, method);
        let mut total_error = 0.0;
        let mut total_weight = 0.0;
        for rgb in &samples {
            let corrected = mv(matrix, *rgb);
            let xyz = [
                0.4124564 * corrected[0] + 0.3575761 * corrected[1] + 0.1804375 * corrected[2],
                0.2126729 * corrected[0] + 0.7151522 * corrected[1] + 0.0721750 * corrected[2],
                0.0193339 * corrected[0] + 0.1191920 * corrected[1] + 0.9503041 * corrected[2],
            ];
            let sum = xyz.iter().sum::<f64>();
            if !sum.is_finite() || sum <= 1e-9 {
                continue;
            }
            let xy = [xyz[0] / sum, xyz[1] / sum];
            let saturation =
                ((max3(corrected) - min3(corrected)) / xyz[1].max(1e-6)).clamp(0.0, 2.0);
            let weight = saturation.min(0.5) as f64;
            if weight < 0.025 {
                continue;
            }
            let nearest = references
                .iter()
                .map(|r| {
                    let dx = xy[0] - r[0];
                    let dy = xy[1] - r[1];
                    dx * dx + dy * dy
                })
                .fold(f64::INFINITY, f64::min);
            total_error += nearest * weight;
            total_weight += weight;
        }
        if total_weight == 0.0 {
            f64::INFINITY
        } else {
            (total_error / total_weight).sqrt()
        }
    };

    let mut best = (f64::INFINITY, 6504.0, 1.0);
    for temperature in (2000..=12000).step_by(250) {
        for tint_step in -6..=6 {
            let tint = 1.0 + tint_step as f64 * 0.05;
            let candidate = score(temperature as f64, tint);
            if candidate < best.0 {
                best = (candidate, temperature as f64, tint);
            }
        }
    }
    let coarse = best.0;
    let low_t = (best.1 - 500.0).max(1667.0) as i32;
    let high_t = (best.1 + 500.0).min(12500.0) as i32;
    let low_g = (best.2 - 0.10).max(0.70);
    let high_g = (best.2 + 0.10).min(1.30);
    for temperature in (low_t..=high_t).step_by(50) {
        for tint_step in 0..=20 {
            let tint = low_g + (high_g - low_g) * tint_step as f64 / 20.0;
            let candidate = score(temperature as f64, tint);
            if candidate < best.0 {
                best = (candidate, temperature as f64, tint);
            }
        }
    }
    ensure!(
        best.0.is_finite(),
        "ITCWB could not find a reliable color match"
    );
    Ok(ItcwbEstimate {
        temperature: best.1,
        tint: best.2,
        confidence: (1.0 - best.0 / coarse.max(1e-6)).clamp(0.0, 1.0),
    })
}

fn max3(v: [f64; 3]) -> f64 {
    v[0].max(v[1]).max(v[2])
}
fn min3(v: [f64; 3]) -> f64 {
    v[0].min(v[1]).min(v[2])
}

/// Apply the corrected upstream post-development WB before the loader's
/// final negative clamp. A monochrome sensor has no chromatic balance.
pub(crate) fn finish(
    image: &mut Intermediate,
    settings: RawWhiteBalance,
    monochrome: bool,
) -> Result<()> {
    if monochrome {
        return Ok(());
    }
    let Some((temperature, tint)) = settings.adjustment() else {
        return Ok(());
    };
    if temperature == 6504.0 && tint == 1.0 {
        return Ok(());
    }
    let matrix = adjustment_matrix(temperature, tint, settings.method);
    match image {
        Intermediate::ThreeColor(pixels) => pixels.data.par_iter_mut().for_each(|p| {
            *p = mv(matrix, p.map(f64::from)).map(|v| v as f32);
        }),
        Intermediate::Monochrome(_) => {}
        Intermediate::FourColor(_) => bail!("RAW WB expected calibrated RGB output"),
    }
    Ok(())
}

/// Apply the same backend-independent adaptation to Apple's D65 linear RGB.
pub(crate) fn finish_rgb(
    rgb: &mut [f32],
    settings: RawWhiteBalance,
    monochrome: bool,
) -> Result<()> {
    settings.validate()?;
    if monochrome {
        return Ok(());
    }
    let Some((temperature, tint)) = settings.adjustment() else {
        return Ok(());
    };
    if temperature == 6504.0 && tint == 1.0 {
        return Ok(());
    }
    let matrix = adjustment_matrix(temperature, tint, settings.method);
    rgb.par_chunks_exact_mut(3).for_each(|p| {
        let out = mv(matrix, [f64::from(p[0]), f64::from(p[1]), f64::from(p[2])]);
        for (v, result) in p.iter_mut().zip(out) {
            *v = result as f32;
        }
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xyz_scaling_is_a_direct_diagonal_transform_in_xyz() {
        let source = [0.96422, 1.0, 0.82521];
        let target = [0.95047, 1.0, 1.08883];
        let matrix = adaptation(source, target, RawWhiteBalanceMethod::XyzScaling);
        for channel in 0..3 {
            assert!((matrix[channel][channel] - target[channel] / source[channel]).abs() < 1e-12);
            for other in 0..3 {
                if other != channel {
                    assert_eq!(matrix[channel][other], 0.0);
                }
            }
        }
        let mapped_white = mv(matrix, source);
        for (actual, expected) in mapped_white.into_iter().zip(target) {
            assert!((actual - expected).abs() < 1e-12);
        }
    }

    #[test]
    fn modes_and_validation() {
        let mut wb = RawWhiteBalance::default();
        assert_eq!(wb.mode, RawWhiteBalanceMode::AsShot);
        assert_eq!(wb.adjustment(), None);
        wb.mode = RawWhiteBalanceMode::Daylight;
        assert_eq!(wb.adjustment(), None);
        wb.mode = RawWhiteBalanceMode::Tungsten;
        wb.temperature = f64::NAN; // inactive controls are ignored
        wb.tint = -1.0;
        assert_eq!(wb.adjustment(), Some((2850.0, 1.0)));
        assert!(wb.validate().is_ok());
        wb.mode = RawWhiteBalanceMode::Custom;
        assert!(wb.validate().is_err());
        for temperature in [1667.0, 5500.0, 25000.0] {
            wb.temperature = temperature;
            wb.tint = 1.0;
            assert!(wb.validate().is_ok());
        }
        for tint in [0.0, -1.0, f64::INFINITY, f64::NAN, 4.01] {
            wb.tint = tint;
            assert!(wb.validate().is_err());
        }
        wb.tint = 1.0;
        for temperature in [0.0, 1666.0, 25001.0, f64::INFINITY, f64::NAN] {
            wb.temperature = temperature;
            assert!(wb.validate().is_err());
        }
    }

    #[test]
    fn daylight_coefficients_project_white_and_normalize_green() {
        let m = [0.5, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.75];
        let wb = daylight_coefficients(&m).unwrap();
        let white = whitepoint(6504.0);
        assert!((f64::from(wb[0]) * 0.5 * white[0] - 1.0).abs() < 1e-7);
        assert_eq!(wb[1], 1.0);
        assert!((f64::from(wb[2]) * 0.75 * white[2] - 1.0).abs() < 1e-7);
        assert_eq!(wb[3], wb[1]);
        let mut four = m.to_vec();
        four.extend_from_slice(&[0.0, 0.5, 0.0]);
        assert_eq!(daylight_coefficients(&four).unwrap()[3], 2.0);
        assert!(daylight_coefficients(&[0.0; 9]).is_err());
        assert!(daylight_coefficients(&[f32::NAN; 9]).is_err());
        assert!(daylight_coefficients(&[1.0; 6]).is_err());
    }

    #[test]
    fn whitepoints_and_adjustment_match_colour_science_reference() {
        // colour 0.4.x: CCT_to_xy(Kang 2002 / CIE Illuminant D Series),
        // xy_to_XYZ. Reference generated independently in Python.
        for (t, expected) in [
            (2850.0, [1.09784235, 1.0, 0.35530371]),
            (6504.0, [0.95015469, 1.0, 1.08825907]),
        ] {
            for (a, b) in whitepoint(t).into_iter().zip(expected) {
                assert!((a - b).abs() < 1e-8);
            }
        }
        // sRGB -> ACES; upstream's Von Kries/CAT02 XYZ adaptation
        // (3200 -> 6504 K); ACES green * .85; ACES -> sRGB.
        let matrix = adjustment_matrix(3200.0, 0.85, RawWhiteBalanceMethod::Cat02);
        for (input, expected) in [
            ([0.12, 0.18, 0.09], [0.05512882, 0.16371677, 0.25686877]),
            ([0.25, 0.05, 0.14], [0.19382519, 0.04054611, 0.35510906]),
        ] {
            for (a, b) in mv(matrix, input).into_iter().zip(expected) {
                // colour uses rounded published sRGB forward/inverse matrices;
                // here the inverse is computed, so allow their rounding error.
                assert!((a - b).abs() < 3e-5, "{a} != {b}");
            }
        }
        assert_eq!(
            adjustment_matrix(6504.0, 1.0, RawWhiteBalanceMethod::Cat02),
            IDENTITY
        );
        let warm = mv(
            adjustment_matrix(2850.0, 1.0, RawWhiteBalanceMethod::Cat02),
            [0.2; 3],
        );
        assert!(warm[2] > warm[0]); // tungsten WB cools a daylight image
    }
}
