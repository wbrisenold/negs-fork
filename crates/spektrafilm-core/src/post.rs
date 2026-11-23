//! Post adjustments: finishing edits on the scanned photograph, as an editor
//! would make them to a lab scan. They run on the scan clipped to [0, 1]
//! (`pipeline::clip_to_display`), as an integer file holds it, so they shape
//! the tones the film produced but cannot recover a clipped highlight; that
//! belongs to camera and print exposure.
//!
//! Pixels are decoded with the output space's own transfer function and
//! luminance is that space's Y, so the same settings make the same change in
//! every output space. Tones are shaped on that luminance in sRGB-encoded
//! (perceptual) space, and each pixel keeps its colour ratios, so contrast
//! doesn't shift the film's hues.
//!
//! The arithmetic is f32 even in the f64 build: the tables already limit
//! accuracy to about 2e-7, far below a 16-bit output step, and the f64
//! build's purpose, parity with the Python reference, doesn't cover Post.
use base64::Engine as _;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use spektrafilm_math::colorspace::{self, RgbColourspace};
use spektrafilm_math::image::ImageBuf;
use spektrafilm_math::precision::{from_f32, to_f32};

/// Each control runs from -100 to 100; 0 leaves the photograph unchanged.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct PostParams {
    /// Lifts or darkens the midtones, keeping black and white.
    #[serde(default)]
    pub brightness: f32,
    /// An S-curve about middle grey.
    #[serde(default)]
    pub contrast: f32,
    /// Moves the white point: up clips the brightest tones to white, down dims white.
    #[serde(default)]
    pub whites: f32,
    /// Moves the black point: down crushes the darkest tones, up lifts black.
    #[serde(default)]
    pub blacks: f32,
    /// Scales colourfulness at constant luminance; -100 is monochrome.
    #[serde(default)]
    pub saturation: f32,
    /// Inferred color separation controls; the original DCTL source is opaque.
    #[serde(default)]
    pub color_separation: ColorSeparationParams,
    /// Mono Shaper style skin hue and luminance shaping controls.
    #[serde(default)]
    pub skin_shaper: SkinShaperParams,
    /// ME deSatch cone-space density controls from SpektraFilm Studio.
    #[serde(default)]
    pub color_density: ColorDensityParams,
    /// Controls for the optional HNCS finishing transform.
    #[serde(default)]
    pub hncs: HncsParams,
    /// PNG-encoded grayscale background mask, base64 encoded for sidecar portability.
    #[serde(default)]
    pub background_mask_png_base64: String,
    /// What Vision selected when it generated the saved mask.
    #[serde(default = "default_background_mask_selection")]
    pub background_mask_selection: String,
    /// Independent AI selections, each with its own adjustments.
    #[serde(default)]
    pub background_masks: Vec<BackgroundMaskLayer>,
    #[serde(default)]
    pub background_exposure_ev: f32,
    #[serde(default)]
    pub background_temperature: f32,
    #[serde(default)]
    pub background_tint: f32,
    #[serde(default)]
    pub background_saturation: f32,
    #[serde(default)]
    pub film_compression: FilmCompressionParams,
    #[serde(default)]
    pub film_expand: FilmExpandParams,
    /// Three editable soft lights in the developed image. Positions are normalized.
    #[serde(default)]
    pub relight: RelightParams,
}

/// Deterministic, model-free soft-light controls, ported from the MIT
/// ComfyUI-ReLight radial falloff/compositing approach.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RelightParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "default_relight_strength")]
    pub strength: f32,
    #[serde(default = "default_relight_lights")]
    pub lights: [RelightLight; 3],
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct RelightLight {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "default_light_x")]
    pub x: f32,
    #[serde(default = "default_light_y")]
    pub y: f32,
    #[serde(default = "default_light_radius")]
    pub radius: f32,
    #[serde(default)]
    pub intensity: f32,
    #[serde(default = "default_light_color")]
    pub color: [f32; 3],
}

fn default_light_x() -> f32 {
    0.5
}
fn default_light_y() -> f32 {
    0.5
}
fn default_light_radius() -> f32 {
    0.45
}
fn default_light_color() -> [f32; 3] {
    [1.0, 0.82, 0.66]
}
fn default_relight_strength() -> f32 {
    1.0
}
fn default_relight_lights() -> [RelightLight; 3] {
    [RelightLight::default(); 3]
}

impl Default for RelightLight {
    fn default() -> Self {
        Self {
            enabled: false,
            x: 0.5,
            y: 0.5,
            radius: 0.45,
            intensity: 0.0,
            color: default_light_color(),
        }
    }
}

impl Default for RelightParams {
    fn default() -> Self {
        Self {
            enabled: false,
            strength: 1.0,
            lights: default_relight_lights(),
        }
    }
}

fn default_background_mask_selection() -> String {
    "background".to_owned()
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct BackgroundMaskLayer {
    #[serde(default)]
    pub id: String,
    #[serde(default = "default_background_mask_selection")]
    pub selection: String,
    #[serde(default)]
    pub mask_png_base64: String,
    #[serde(default)]
    pub exposure_ev: f32,
    #[serde(default)]
    pub temperature: f32,
    #[serde(default)]
    pub tint: f32,
    #[serde(default)]
    pub saturation: f32,
    /// LaMa's repaired crop, kept as an editable patch in this mask layer.
    #[serde(default)]
    pub inpaint_patch_png_base64: String,
    /// Normalized top-left x, y, width, height in the source frame.
    #[serde(default)]
    pub inpaint_bounds: [f32; 4],
    /// Colour space used to develop the input given to LaMa.
    #[serde(default)]
    pub inpaint_color_space: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct HncsParams {
    #[serde(default = "default_hncs_clahe_strength")]
    pub clahe_strength: f32,
    #[serde(default = "default_hncs_skin_protection")]
    pub skin_protection: f32,
}

fn default_hncs_clahe_strength() -> f32 {
    55.0
}
fn default_hncs_skin_protection() -> f32 {
    55.0
}

impl Default for HncsParams {
    fn default() -> Self {
        Self {
            clahe_strength: 55.0,
            skin_protection: 55.0,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct ColorDensityParams {
    #[serde(default)]
    pub master: f32,
    #[serde(default)]
    pub red: f32,
    #[serde(default)]
    pub yellow: f32,
    #[serde(default)]
    pub green: f32,
    #[serde(default)]
    pub cyan: f32,
    #[serde(default)]
    pub blue: f32,
    #[serde(default)]
    pub magenta: f32,
}

impl ColorDensityParams {
    pub fn is_identity(self) -> bool {
        self.master == 0.0
            && self.red == 0.0
            && self.yellow == 0.0
            && self.green == 0.0
            && self.cyan == 0.0
            && self.blue == 0.0
            && self.magenta == 0.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct FilmCompressionParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub impact: f32,
    #[serde(default = "compression_white_default")]
    pub white_point: f32,
    #[serde(default = "compression_range_default")]
    pub range: f32,
    #[serde(default)]
    pub color_density: f32,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct FilmExpandParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub blacks: f32,
    #[serde(default)]
    pub whites: f32,
    #[serde(default = "expand_mode_default")]
    pub mode: FilmExpandMode,
    #[serde(default = "expand_impact_default")]
    pub impact: f32,
}

fn compression_white_default() -> f32 {
    100.0
}
fn compression_range_default() -> f32 {
    50.0
}
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub enum FilmExpandMode {
    #[default]
    Luminance,
    #[serde(rename = "RGB")]
    Rgb,
}

fn expand_mode_default() -> FilmExpandMode {
    FilmExpandMode::Luminance
}
fn expand_impact_default() -> f32 {
    1.0
}

impl Default for FilmCompressionParams {
    fn default() -> Self {
        Self {
            enabled: false,
            impact: 0.0,
            white_point: 100.0,
            range: 50.0,
            color_density: 50.0,
        }
    }
}
impl Default for FilmExpandParams {
    fn default() -> Self {
        Self {
            enabled: false,
            blacks: 0.0,
            whites: 100.0,
            mode: expand_mode_default(),
            impact: 1.0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct ColorSeparationParams {
    #[serde(default)]
    pub strength: f32,
    #[serde(default = "default_target_hue")]
    pub target_hue: f32,
    #[serde(default = "default_complementary_hue")]
    pub complementary_hue: f32,
    #[serde(default = "default_target_saturation")]
    pub target_saturation: f32,
    #[serde(default)]
    pub luminance_mask: f32,
    #[serde(default)]
    pub neutral_protection: f32,
    #[serde(default)]
    pub method: f32,
    #[serde(default)]
    pub color_wash: bool,
}

/// Skin shaper controls shared by the CPU post pass and resident display shader.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct SkinShaperParams {
    #[serde(default)]
    pub global_sat: f32,
    #[serde(default)]
    pub global_dens: f32,
    #[serde(default)]
    pub hue_rotate: f32,
    #[serde(default)]
    pub hue_center: f32,
    #[serde(default = "default_skin_hue_range")]
    pub hue_range: f32,
    #[serde(default = "default_skin_luma_center")]
    pub sigmoid_shift: f32,
    #[serde(default = "default_skin_luma_range")]
    pub bellcurve_width: f32,
    #[serde(default)]
    pub phighlighter: bool,
}

fn default_skin_hue_range() -> f32 {
    40.0
}
fn default_skin_luma_center() -> f32 {
    0.5
}
fn default_skin_luma_range() -> f32 {
    1.0
}

impl Default for SkinShaperParams {
    fn default() -> Self {
        Self {
            global_sat: 0.0,
            global_dens: 0.0,
            hue_rotate: 0.0,
            hue_center: 0.0,
            hue_range: 40.0,
            sigmoid_shift: 0.5,
            bellcurve_width: 1.0,
            phighlighter: false,
        }
    }
}

impl SkinShaperParams {
    fn is_identity(self) -> bool {
        self.global_sat == 0.0
            && self.global_dens == 0.0
            && self.hue_rotate == 0.0
            && !self.phighlighter
    }
}

fn default_target_hue() -> f32 {
    35.0
}
fn default_complementary_hue() -> f32 {
    215.0
}
fn default_target_saturation() -> f32 {
    20.0
}

fn density_control(value: f32) -> f32 {
    value.clamp(-1.0, 0.0)
}

/// GPL-3.0 adaptation of ME_Desatch.dctl's RGB→cone→RGB transfer. Keep its
/// spherical radius, hue, and polar coordinate intact; only density radius
/// changes. See docs/ME_Desatch_NOTICE.md.
fn apply_color_density(rgb: [f32; 3], settings: ColorDensityParams) -> [f32; 3] {
    const TAU: f32 = std::f32::consts::TAU;
    const HUE_RADIUS: f32 = 0.1666;
    let rtr = rgb[0] * 0.81649658 - rgb[1] * 0.40824829 - rgb[2] * 0.40824829;
    let rtg = rgb[1] * 0.70710678 - rgb[2] * 0.70710678;
    let rtb = (rgb[0] + rgb[1] + rgb[2]) * 0.57735027;
    let theta = rtg.atan2(rtr).rem_euclid(TAU);
    let phi = (rtr.hypot(rtg)).atan2(rtb);
    let hue = theta / TAU;
    let polar = phi * 1.0467733744265997;
    let mut factor = 1.0 + density_control(settings.master) * polar;
    for (center, raw) in [
        (0.0, settings.red),
        (0.1666, settings.yellow),
        (0.3330, settings.green),
        (0.4999, settings.cyan),
        (0.6660, settings.blue),
        (0.8333, settings.magenta),
    ] {
        let direct = (hue - center).abs();
        let distance = if center == 0.0 {
            direct.min(1.0 - direct)
        } else {
            direct
        };
        if raw != 0.0 && distance <= HUE_RADIUS {
            factor *= 1.0 + density_control(raw) * (1.0 - distance / HUE_RADIUS) * polar;
        }
    }
    let sat_magnitude = |theta: f32, phi: f32| {
        let base_phi = 0.61547971_f32;
        let corner_phi = 0.78539816_f32;
        let hue_coef1 = 1.0 / (2.0 - corner_phi / base_phi);
        let sector = theta.rem_euclid(std::f32::consts::FRAC_PI_3);
        let hue_coef2 =
            2.0 * phi * ((2.0 * std::f32::consts::PI / 3.0) - sector).sin() / 1.7320508075688;
        let hue_magnitude = ((3.0 * theta + std::f32::consts::PI).cos().acos()
            / (std::f32::consts::PI * hue_coef1)
            + (corner_phi / base_phi - 1.0))
            * hue_coef2;
        (hue_magnitude + base_phi).sin()
    };
    let radius = rtr.hypot(rtg).hypot(rtb) * sat_magnitude(theta, phi) * factor;
    let phi = polar / 1.0467733744265997;
    let spherical_radius =
        radius / sat_magnitude(theta, phi).abs().max(1.0e-12) * sat_magnitude(theta, phi).signum();
    let sin_phi = phi.sin();
    let x = spherical_radius * sin_phi * theta.cos();
    let y = spherical_radius * sin_phi * theta.sin();
    let z = spherical_radius * phi.cos();
    [
        x * 0.81649658 + z * 0.57735027,
        x * -0.40824829 + y * 0.70710678 + z * 0.57735027,
        x * -0.40824829 - y * 0.70710678 + z * 0.57735027,
    ]
    .map(|v| v.clamp(0.0, 1.0))
}

impl Default for ColorSeparationParams {
    fn default() -> Self {
        Self {
            strength: 0.0,
            target_hue: 35.0,
            complementary_hue: 215.0,
            target_saturation: 20.0,
            luminance_mask: 0.0,
            neutral_protection: 70.0,
            method: 50.0,
            color_wash: false,
        }
    }
}

impl PostParams {
    pub fn is_identity(&self) -> bool {
        self.brightness == 0.0
            && self.contrast == 0.0
            && self.whites == 0.0
            && self.blacks == 0.0
            && self.saturation == 0.0
            && self.color_separation.strength == 0.0
            && self.skin_shaper.is_identity()
            && self.color_density.is_identity()
            && (self.background_mask_png_base64.is_empty()
                || (self.background_exposure_ev == 0.0
                    && self.background_temperature == 0.0
                    && self.background_tint == 0.0
                    && self.background_saturation == 0.0))
            && self.background_masks.iter().all(|mask| {
                mask.exposure_ev == 0.0
                    && mask.temperature == 0.0
                    && mask.tint == 0.0
                    && mask.saturation == 0.0
                    && mask.inpaint_patch_png_base64.is_empty()
            })
            && !self.relight.enabled
            && !self.film_compression.enabled
            && !self.film_expand.enabled
    }
}

fn hue_distance(a: f32, b: f32) -> f32 {
    let d = (a - b).rem_euclid(360.0);
    d.min(360.0 - d)
}

fn rgb_to_hsv(c: [f32; 3]) -> [f32; 3] {
    let max = c[0].max(c[1]).max(c[2]);
    let min = c[0].min(c[1]).min(c[2]);
    let d = max - min;
    let h = if d <= 1e-8 {
        0.0
    } else if max == c[0] {
        60.0 * ((c[1] - c[2]) / d).rem_euclid(6.0)
    } else if max == c[1] {
        60.0 * ((c[2] - c[0]) / d + 2.0)
    } else {
        60.0 * ((c[0] - c[1]) / d + 4.0)
    };
    [h, if max <= 1e-8 { 0.0 } else { d / max }, max]
}

fn hsv_to_rgb(hsv: [f32; 3]) -> [f32; 3] {
    let [h, s, v] = hsv;
    let chroma = v * s;
    let x = chroma * (1.0 - ((h / 60.0).rem_euclid(2.0) - 1.0).abs());
    let m = v - chroma;
    let rgb = if h < 60.0 {
        [chroma, x, 0.0]
    } else if h < 120.0 {
        [x, chroma, 0.0]
    } else if h < 180.0 {
        [0.0, chroma, x]
    } else if h < 240.0 {
        [0.0, x, chroma]
    } else if h < 300.0 {
        [x, 0.0, chroma]
    } else {
        [chroma, 0.0, x]
    };
    rgb.map(|v| (v + m).clamp(0.0, 1.0))
}

/// Independent approximation of the published control set: isolate the
/// chosen and complementary hue bands, then move them apart or wash toward
/// the selected hue. It is not a reconstruction of the unavailable DCTL.
fn apply_color_separation(rgb: [f32; 3], p: ColorSeparationParams) -> [f32; 3] {
    if p.strength <= 0.0 {
        return rgb;
    }
    let mut hsv = rgb_to_hsv(rgb);
    let sat = hsv[1];
    let protection = (1.0 - p.neutral_protection.clamp(0.0, 100.0) / 100.0)
        .max(sat / 0.18)
        .min(1.0);
    let sat_mask = ((sat - p.target_saturation.clamp(0.0, 100.0) / 100.0) / 0.35).clamp(0.0, 1.0);
    let lum_center = (0.5 + p.luminance_mask.clamp(-100.0, 100.0) / 200.0).clamp(0.0, 1.0);
    let lum_mask = (1.0 - (hsv[2] - lum_center).abs() / 0.5).clamp(0.0, 1.0);
    let target = (-0.5 * (hue_distance(hsv[0], p.target_hue) / 55.0).powi(2)).exp();
    let complement = (-0.5 * (hue_distance(hsv[0], p.complementary_hue) / 55.0).powi(2)).exp();
    let amount =
        p.strength.clamp(0.0, 100.0) / 100.0 * protection * sat_mask * (0.35 + 0.65 * lum_mask);
    let method = p.method.clamp(0.0, 100.0) / 100.0;
    let hue_pull = if p.color_wash {
        target
    } else {
        target - complement
    };
    let hue_delta = hue_distance(p.target_hue, p.complementary_hue);
    let hue_delta = if ((p.target_hue - p.complementary_hue).rem_euclid(360.0)) > 180.0 {
        -hue_delta
    } else {
        hue_delta
    };
    hsv[0] = (hsv[0] + hue_pull * amount * (1.0 - method) * hue_delta * 0.18).rem_euclid(360.0);
    hsv[1] = (hsv[1] + (target + complement) * amount * method * 0.35).clamp(0.0, 1.0);
    hsv_to_rgb(hsv)
}

fn rgb_to_hsl(rgb: [f32; 3]) -> [f32; 3] {
    let max = rgb[0].max(rgb[1]).max(rgb[2]);
    let min = rgb[0].min(rgb[1]).min(rgb[2]);
    let delta = max - min;
    let lightness = (max + min) * 0.5;
    if delta <= 1e-6 {
        return [0.0, 0.0, lightness];
    }
    let saturation = if lightness < 0.5 {
        delta / (max + min).max(1e-6)
    } else {
        delta / (2.0 - max - min).max(1e-6)
    };
    let mut hue = if max == rgb[0] {
        (rgb[1] - rgb[2]) / delta
    } else if max == rgb[1] {
        2.0 + (rgb[2] - rgb[0]) / delta
    } else {
        4.0 + (rgb[0] - rgb[1]) / delta
    };
    hue *= 60.0;
    if hue < 0.0 {
        hue += 360.0;
    }
    [hue, saturation, lightness]
}

fn hsl_to_rgb(hsl: [f32; 3]) -> [f32; 3] {
    let [hue, saturation, lightness] = hsl;
    let chroma = (1.0 - (2.0 * lightness - 1.0).abs()) * saturation;
    let sector = hue / 60.0;
    let x = chroma * (1.0 - (sector.rem_euclid(2.0) - 1.0).abs());
    let match_value = lightness - chroma * 0.5;
    let rgb = if sector < 1.0 {
        [chroma, x, 0.0]
    } else if sector < 2.0 {
        [x, chroma, 0.0]
    } else if sector < 3.0 {
        [0.0, chroma, x]
    } else if sector < 4.0 {
        [0.0, x, chroma]
    } else if sector < 5.0 {
        [x, 0.0, chroma]
    } else {
        [chroma, 0.0, x]
    };
    rgb.map(|v| (v + match_value).clamp(0.0, 1.0))
}

/// Skin shaping is one display-referred stage: the hue and luminance masks,
/// six-color density map, saturation, hue rotation and highlight view travel
/// together through this small parameter interface.
fn apply_skin_shaper(rgb: [f32; 3], p: SkinShaperParams) -> [f32; 3] {
    let hsl = rgb_to_hsl(rgb);
    let target_hue = (20.0 - p.hue_center.clamp(-30.0, 30.0)).rem_euclid(360.0);
    let hue_distance = hue_distance(hsl[0], target_hue);
    let hue_width = p.hue_range.clamp(15.0, 65.0).max(1e-6);
    let hue_mask = (-(hue_distance * hue_distance) / (hue_width * hue_width)).exp();
    let luma_width = (0.4 * p.bellcurve_width.clamp(0.25, 1.75)).max(1e-6);
    let luma_distance = (hsl[2] - p.sigmoid_shift.clamp(0.0, 1.0)).abs();
    let luma_mask = (-(luma_distance * luma_distance) / (luma_width * luma_width)).exp();
    let mask = hue_mask * luma_mask;

    let global_density = -p.global_dens.clamp(-1.0, 1.0);
    let sat = p.global_sat.clamp(-1.0, 0.999);
    let red = [
        1.0 + global_density,
        -sat + global_density,
        -sat + global_density,
    ];
    let green = [
        -sat + global_density,
        1.0 + global_density,
        -sat + global_density,
    ];
    let blue = [
        -sat + global_density,
        -sat + global_density,
        1.0 + global_density,
    ];
    let cyan_density = global_density * 0.8;
    let magenta_density = global_density * 0.8;
    let yellow_density = global_density * 0.6;
    let cyan = [-sat + cyan_density, 1.0 + cyan_density, 1.0 + cyan_density];
    let magenta = [
        1.0 + magenta_density,
        -sat + magenta_density,
        1.0 + magenta_density,
    ];
    let yellow = [
        1.0 + yellow_density,
        1.0 + yellow_density,
        -sat + yellow_density,
    ];
    let adjusted: [f32; 3] = if rgb[0] > rgb[1] {
        if rgb[1] > rgb[2] {
            std::array::from_fn(|i| {
                rgb[0] * red[i] + rgb[1] * (yellow[i] - red[i]) + rgb[2] * (1.0 - yellow[i])
            })
        } else if rgb[0] > rgb[2] {
            std::array::from_fn(|i| {
                rgb[0] * red[i] + rgb[1] * (1.0 - magenta[i]) + rgb[2] * (magenta[i] - red[i])
            })
        } else {
            std::array::from_fn(|i| {
                rgb[0] * (magenta[i] - blue[i]) + rgb[1] * (1.0 - magenta[i]) + rgb[2] * blue[i]
            })
        }
    } else if rgb[2] > rgb[1] {
        std::array::from_fn(|i| {
            rgb[0] * (1.0 - cyan[i]) + rgb[1] * (cyan[i] - blue[i]) + rgb[2] * blue[i]
        })
    } else if rgb[2] > rgb[0] {
        std::array::from_fn(|i| {
            rgb[0] * (1.0 - cyan[i]) + rgb[1] * green[i] + rgb[2] * (cyan[i] - green[i])
        })
    } else {
        std::array::from_fn(|i| {
            rgb[0] * (yellow[i] - green[i]) + rgb[1] * green[i] + rgb[2] * (1.0 - yellow[i])
        })
    };
    let mut shaped_hsl = rgb_to_hsl(adjusted.map(|v| v.clamp(0.0, 1.0)));
    shaped_hsl[0] = (shaped_hsl[0] - p.hue_rotate.clamp(-60.0, 60.0)).rem_euclid(360.0);
    let shaped = hsl_to_rgb(shaped_hsl);
    let base = if p.phighlighter {
        let luminance = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
        [luminance * 0.1 + 0.18; 3]
    } else {
        rgb
    };
    std::array::from_fn(|i| (base[i] + (shaped[i] - base[i]) * mask).clamp(0.0, 1.0))
}

/// sRGB-encoded middle grey (18% reflectance), the contrast pivot.
const PIVOT: f64 = 0.461_356;
/// How far Whites and Blacks at ±100 move their end point.
const LEVELS_RANGE: f64 = 0.15;
const LUT_SIZE: usize = 4096;

/// Luminance weights of an output colour space: the Y row of its RGB → XYZ
/// matrix. Unknown names fall back to sRGB, as the scan's output does.
fn luminance_weights(color_space: &str) -> [f32; 3] {
    RgbColourspace::output(color_space).rgb_to_xyz[1].map(|v| v as f32)
}

fn srgb_encode(x: f64) -> f64 {
    if x <= 0.003_130_8 {
        12.92 * x
    } else {
        1.055 * x.powf(1.0 / 2.4) - 0.055
    }
}

fn srgb_decode(x: f64) -> f64 {
    if x <= 0.040_45 {
        x / 12.92
    } else {
        ((x + 0.055) / 1.055).powf(2.4)
    }
}

/// An output space's transfer function, with sRGB's exactly as before.
struct Transfer(&'static RgbColourspace);

impl Transfer {
    fn decode(&self, v: f64) -> f64 {
        if self.0.name == "sRGB" {
            srgb_decode(v)
        } else {
            self.0.cctf.decode(v)
        }
    }
    fn encode(&self, v: f64) -> f64 {
        if self.0.name == "sRGB" {
            srgb_encode(v)
        } else {
            self.0.cctf.encode(v)
        }
    }
}

/// The tone curve on encoded luminance, [0, 1] → [0, 1], non-decreasing.
fn tone(params: &PostParams, mut e: f64) -> f64 {
    // Brightness: a rational curve with finite slope at both ends, so lifting
    // the midtones doesn't amplify the grain in the deepest shadows.
    let k = 2f64.powf(1.25 * params.brightness as f64 / 100.0);
    e = k * e / (1.0 + (k - 1.0) * e);
    // Contrast: blend toward (or away from) a quadratic S-curve that keeps
    // black and white. The slope at the pivot is 1 + a, so a ≥ -0.75 keeps
    // the curve rising.
    let c = params.contrast as f64 / 100.0;
    let a = if c < 0.0 { 0.75 * c } else { c };
    let s = if e < PIVOT {
        PIVOT * (e / PIVOT).powi(2)
    } else {
        1.0 - (1.0 - PIVOT) * ((1.0 - e) / (1.0 - PIVOT)).powi(2)
    };
    e += a * (s - e);
    // Whites and blacks: levels on the end points.
    let black = -LEVELS_RANGE * params.blacks as f64 / 100.0;
    let white = 1.0 - LEVELS_RANGE * params.whites as f64 / 100.0;
    ((e - black) / (white - black)).clamp(0.0, 1.0)
}

/// Linear interpolation in a table sampled on [0, 1].
fn lookup(table: &[f32], x: f32) -> f32 {
    let t = x.clamp(0.0, 1.0) * (table.len() - 1) as f32;
    let i = (t as usize).min(table.len() - 2);
    let f = t - i as f32;
    table[i] + (table[i + 1] - table[i]) * f
}

/// Post adjustments prepared for per-pixel use. Every curve is tabulated, so
/// applying them costs a few lookups per pixel.
pub struct PostProcess {
    saturation: f32,
    /// The output space's luminance weights.
    luma: [f32; 3],
    /// Whether pixels arrive, and leave, encoded with the output space's
    /// transfer function rather than linear.
    encoded: bool,
    /// Encoded → linear.
    decode: Vec<f32>,
    /// Linear → encoded, sampled on √x for resolution near black.
    encode: Vec<f32>,
    /// Linear luminance → adjusted linear luminance, sampled on √Y.
    tone: Vec<f32>,
    color_separation: ColorSeparationParams,
    skin_shaper: SkinShaperParams,
    color_density: ColorDensityParams,
    film_compression: FilmCompressionParams,
    film_expand: FilmExpandParams,
    background_masks: Vec<BackgroundMaskData>,
    relight: RelightParams,
}

struct BackgroundMaskData {
    mask: image::GrayImage,
    adjustment: [f32; 4],
    inpaint: Option<InpaintData>,
}

struct InpaintData {
    patch: image::RgbImage,
    bounds: [f32; 4],
    source_space: &'static RgbColourspace,
    target_space: &'static RgbColourspace,
    to_target: Option<[[f64; 3]; 3]>,
}

/// Bilinearly sample a repaired crop at the output pixel's normalized source
/// coordinate. The repair is stored in the mask layer so every render path
/// applies it at the same stage and resolution.
fn sample_inpaint(
    data: &InpaintData,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    encoded: bool,
) -> Option<[f32; 3]> {
    let [bx, by, bw, bh] = data.bounds;
    if ![bx, by, bw, bh].iter().all(|v| v.is_finite()) || bw <= 0.0 || bh <= 0.0 {
        return None;
    }
    let u = (x as f32 + 0.5) / width.max(1) as f32;
    let v = (y as f32 + 0.5) / height.max(1) as f32;
    let lx = (u - bx) / bw;
    let ly = (v - by) / bh;
    if !(0.0..=1.0).contains(&lx) || !(0.0..=1.0).contains(&ly) {
        return None;
    }
    let patch = &data.patch;
    let gx = (lx * patch.width() as f32 - 0.5).clamp(0.0, (patch.width() - 1) as f32);
    let gy = (ly * patch.height() as f32 - 0.5).clamp(0.0, (patch.height() - 1) as f32);
    let x0 = gx.floor() as u32;
    let y0 = gy.floor() as u32;
    let x1 = (x0 + 1).min(patch.width() - 1);
    let y1 = (y0 + 1).min(patch.height() - 1);
    let fx = gx - x0 as f32;
    let fy = gy - y0 as f32;
    let rgb: [f64; 3] = std::array::from_fn(|c| {
        let p00 = patch.get_pixel(x0, y0)[c] as f32 / 255.0;
        let p10 = patch.get_pixel(x1, y0)[c] as f32 / 255.0;
        let p01 = patch.get_pixel(x0, y1)[c] as f32 / 255.0;
        let p11 = patch.get_pixel(x1, y1)[c] as f32 / 255.0;
        let top = p00 + (p10 - p00) * fx;
        let bottom = p01 + (p11 - p01) * fx;
        f64::from(top + (bottom - top) * fy)
    });
    let linear = rgb.map(|channel| data.source_space.cctf.decode(channel));
    let converted = data
        .to_target
        .as_ref()
        .map_or(linear, |matrix| colorspace::mat3_vec_f64(matrix, linear));
    Some(converted.map(|channel| {
        let value = if encoded {
            data.target_space.cctf.encode(channel)
        } else {
            channel
        };
        value.clamp(0.0, 1.0) as f32
    }))
}

impl PostProcess {
    /// `encoded` and `color_space` describe the scan's output, as
    /// `io.output_cctf_encoding` and `io.output_color_space`.
    pub fn new(params: &PostParams, encoded: bool, color_space: &str) -> Self {
        let space = Transfer(RgbColourspace::output(color_space));
        let samples = |f: &dyn Fn(f64) -> f64| -> Vec<f32> {
            (0..LUT_SIZE)
                .map(|i| f(i as f64 / (LUT_SIZE - 1) as f64) as f32)
                .collect()
        };
        let decode_mask = |encoded: &str| {
            base64::engine::general_purpose::STANDARD
                .decode(encoded)
                .ok()
                .and_then(|png| {
                    image::load_from_memory_with_format(&png, image::ImageFormat::Png).ok()
                })
                .map(|mask| mask.to_luma8())
                .filter(|mask| mask.width() > 0 && mask.height() > 0)
                .map(|mask| {
                    let longest = mask.width().max(mask.height());
                    if longest > 4096 {
                        let scale = 4096.0 / longest as f32;
                        image::imageops::resize(
                            &mask,
                            ((mask.width() as f32 * scale).round() as u32).max(1),
                            ((mask.height() as f32 * scale).round() as u32).max(1),
                            image::imageops::FilterType::Triangle,
                        )
                    } else {
                        mask
                    }
                })
        };
        let target_space = RgbColourspace::output(color_space);
        let decode_patch = |layer: &BackgroundMaskLayer| {
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(&layer.inpaint_patch_png_base64)
                .ok()?;
            let patch = image::load_from_memory_with_format(&bytes, image::ImageFormat::Png)
                .ok()?
                .to_rgb8();
            if patch.width() == 0 || patch.height() == 0 {
                return None;
            }
            let source_space = if layer.inpaint_color_space.is_empty() {
                target_space
            } else {
                RgbColourspace::find(&layer.inpaint_color_space).unwrap_or(target_space)
            };
            let to_target = (source_space.name != target_space.name)
                .then(|| colorspace::icc_rgb_to_rgb(source_space, target_space));
            Some(InpaintData {
                patch,
                bounds: layer.inpaint_bounds,
                source_space,
                target_space,
                to_target,
            })
        };
        let mut background_masks: Vec<_> = params
            .background_masks
            .iter()
            .filter_map(|layer| {
                decode_mask(&layer.mask_png_base64).map(|mask| BackgroundMaskData {
                    mask,
                    adjustment: [
                        layer.exposure_ev,
                        layer.temperature,
                        layer.tint,
                        layer.saturation,
                    ],
                    inpaint: decode_patch(layer),
                })
            })
            .collect();
        // Read pre-layer sidecars without changing their established behavior.
        if background_masks.is_empty() {
            if let Some(mask) = decode_mask(&params.background_mask_png_base64) {
                background_masks.push(BackgroundMaskData {
                    mask,
                    adjustment: [
                        params.background_exposure_ev,
                        params.background_temperature,
                        params.background_tint,
                        params.background_saturation,
                    ],
                    inpaint: None,
                });
            }
        }
        Self {
            saturation: params.saturation / 100.0,
            luma: luminance_weights(color_space),
            encoded,
            decode: samples(&|v| space.decode(v)),
            encode: samples(&|s| space.encode(s * s)),
            tone: samples(&|s| srgb_decode(tone(params, srgb_encode(s * s)))),
            color_separation: params.color_separation,
            skin_shaper: params.skin_shaper,
            color_density: params.color_density,
            film_compression: params.film_compression,
            film_expand: params.film_expand,
            background_masks,
            relight: params.relight.clone(),
        }
    }

    /// Adjusts one pixel. Input channels are expected in [0, 1], clipped like
    /// a display; so is the result.
    pub fn apply_rgb(&self, rgb: [f32; 3]) -> [f32; 3] {
        self.apply_rgb_without_position(rgb)
    }

    fn apply_relight(
        &self,
        rgb: [f32; 3],
        x: usize,
        y: usize,
        width: usize,
        height: usize,
    ) -> [f32; 3] {
        if !self.relight.enabled || self.relight.strength <= 0.0 {
            return rgb;
        }
        let mut out = if self.encoded {
            rgb.map(|v| lookup(&self.decode, v))
        } else {
            rgb
        };
        let min_dim = width.min(height).max(1) as f32;
        let point = [
            (x as f32 + 0.5) / width.max(1) as f32,
            (y as f32 + 0.5) / height.max(1) as f32,
        ];
        for light in self.relight.lights {
            if !light.enabled || light.intensity == 0.0 {
                continue;
            }
            let dx = (point[0] - light.x.clamp(0.0, 1.0)) * width as f32 / min_dim;
            let dy = (point[1] - light.y.clamp(0.0, 1.0)) * height as f32 / min_dim;
            let r = (dx * dx + dy * dy).sqrt() / light.radius.clamp(0.02, 1.5);
            let falloff = (1.0 - r).clamp(0.0, 1.0);
            let amount = falloff
                * falloff
                * light.intensity.clamp(-1.0, 1.0)
                * self.relight.strength.clamp(0.0, 1.0);
            for c in 0..3 {
                let color = light.color[c].clamp(0.0, 1.0);
                out[c] = if amount >= 0.0 {
                    out[c] + (1.0 - out[c]) * color * amount
                } else {
                    out[c] * (1.0 + amount * color)
                }
                .clamp(0.0, 1.0);
            }
        }
        if self.encoded {
            out.map(|v| lookup(&self.encode, v.sqrt()))
        } else {
            out
        }
    }

    /// Applies the finishing adjustments in the output color space.
    fn apply_rgb_without_position(&self, rgb: [f32; 3]) -> [f32; 3] {
        let mut c = if self.encoded {
            rgb.map(|v| lookup(&self.decode, v))
        } else {
            rgb.map(|v| v.clamp(0.0, 1.0))
        };
        let y = self.luma[0] * c[0] + self.luma[1] * c[1] + self.luma[2] * c[2];
        let y2 = lookup(&self.tone, y.max(0.0).sqrt());
        if y <= 1e-9 {
            c = [y2; 3];
        } else {
            c = c.map(|v| v * (y2 / y));
            // Above white, give up saturation rather than luminance or hue.
            let max = c[0].max(c[1]).max(c[2]);
            if max > 1.0 {
                let k = (1.0 - y2) / (max - y2);
                c = c.map(|v| y2 + (v - y2) * k);
            }
        }
        let mut f = 1.0 + self.saturation;
        if f > 1.0 {
            // Stop at the gamut boundary, keeping the hue.
            for v in c {
                let d = v - y2;
                if d > 0.0 {
                    f = f.min((1.0 - y2) / d);
                } else if d < 0.0 {
                    f = f.min(y2 / -d);
                }
            }
        }
        c = c.map(|v| (y2 + (v - y2) * f).clamp(0.0, 1.0));
        // Hue is a perceptual control selected from the displayed scan. Run
        // the hue-band operation in the output's encoded RGB space so its
        // angle matches the hue seen in the image and in the picker. The
        // surrounding tone work stays linear and the separation result is
        // decoded before returning to the rest of the pipeline.
        if (self.film_expand.enabled && self.film_expand.impact > 0.0)
            || (self.film_compression.enabled && self.film_compression.impact > 0.0)
            || self.color_separation.strength > 0.0
            || !self.skin_shaper.is_identity()
            || !self.color_density.is_identity()
        {
            let mut display = c.map(|v| lookup(&self.encode, v.max(0.0).sqrt()));
            if self.film_expand.enabled && self.film_expand.impact > 0.0 {
                let p = &self.film_expand;
                let black = p.blacks.clamp(-20.0, 30.0) / 100.0;
                let white = p.whites.clamp(30.0, 120.0) / 100.0;
                let span = (white - black).max(1e-6);
                let amount = p.impact.clamp(0.0, 1.0);
                let expanded = if p.mode == FilmExpandMode::Rgb {
                    display.map(|v| ((v - black) / span).clamp(0.0, 1.0))
                } else {
                    let y = self.luma[0] * display[0]
                        + self.luma[1] * display[1]
                        + self.luma[2] * display[2];
                    let y2 = ((y - black) / span).clamp(0.0, 1.0);
                    if y <= 1e-8 {
                        [y2; 3]
                    } else {
                        display.map(|v| (v * y2 / y).clamp(0.0, 1.0))
                    }
                };
                display = std::array::from_fn(|i| display[i] + (expanded[i] - display[i]) * amount);
            }
            if self.film_compression.enabled && self.film_compression.impact > 0.0 {
                let p = self.film_compression;
                let y = self.luma[0] * display[0]
                    + self.luma[1] * display[1]
                    + self.luma[2] * display[2];
                let start = p.white_point.clamp(50.0, 120.0) / 100.0;
                let range = (p.range.clamp(0.0, 100.0) / 100.0 * 0.5).max(0.01);
                let compressed = if y <= start {
                    y
                } else {
                    start + range * (1.0 - (-(y - start) / range).exp())
                };
                let amount = p.impact.clamp(0.0, 100.0) / 100.0;
                let target = y + (compressed - y) * amount;
                if y > 1e-8 {
                    let density = 1.0 + p.color_density.clamp(0.0, 100.0) / 100.0 * amount;
                    display =
                        display.map(|v| (target + (v - y) * target / y * density).clamp(0.0, 1.0));
                }
            }
            if self.color_separation.strength > 0.0 {
                display = apply_color_separation(display, self.color_separation);
            }
            if !self.skin_shaper.is_identity() {
                display = apply_skin_shaper(display, self.skin_shaper);
            }
            if !self.color_density.is_identity() {
                display = apply_color_density(display, self.color_density);
            }
            c = display.map(|v| lookup(&self.decode, v));
        }
        if self.encoded {
            c.map(|v| lookup(&self.encode, v.sqrt()))
        } else {
            c
        }
    }

    /// Applies the preview/export pixel adjustments and samples every saved
    /// selection at this source-image coordinate.
    pub fn apply_rgb_at(
        &self,
        rgb: [f32; 3],
        x: usize,
        y: usize,
        width: usize,
        height: usize,
    ) -> [f32; 3] {
        let mut out = self.apply_rgb_without_position(rgb);
        out = self.apply_relight(out, x, y, width, height);
        for layer in &self.background_masks {
            let mx = (x * layer.mask.width() as usize / width.max(1))
                .min(layer.mask.width() as usize - 1);
            let my = (y * layer.mask.height() as usize / height.max(1))
                .min(layer.mask.height() as usize - 1);
            let amount = layer.mask.get_pixel(mx as u32, my as u32)[0] as f32 / 255.0;
            if let Some(inpaint) = &layer.inpaint {
                if amount > 0.0 {
                    if let Some(repaired) =
                        sample_inpaint(inpaint, x, y, width, height, self.encoded)
                    {
                        out =
                            std::array::from_fn(|c| out[c] * (1.0 - amount) + repaired[c] * amount);
                    }
                }
            }
            if layer.adjustment.iter().any(|value| *value != 0.0) {
                out = self.apply_background(out, amount, layer.adjustment);
            }
        }
        out
    }

    /// These adjustments for the GPU display pass, which applies them as
    /// [`Self::apply_rgb`] does.
    pub fn display(&self) -> spektrafilm_gpu::DisplayPost {
        spektrafilm_gpu::DisplayPost {
            luma: self.luma,
            saturation: self.saturation,
            encoded: self.encoded,
            decode: self.decode.clone(),
            encode: self.encode.clone(),
            tone: self.tone.clone(),
            color_separation: spektrafilm_gpu::DisplayColorSeparation {
                strength: self.color_separation.strength,
                target_hue: self.color_separation.target_hue,
                complementary_hue: self.color_separation.complementary_hue,
                target_saturation: self.color_separation.target_saturation,
                luminance_mask: self.color_separation.luminance_mask,
                neutral_protection: self.color_separation.neutral_protection,
                method: self.color_separation.method,
                color_wash: self.color_separation.color_wash,
            },
            skin_shaper: spektrafilm_gpu::DisplaySkinShaper {
                global_sat: self.skin_shaper.global_sat,
                global_dens: self.skin_shaper.global_dens,
                hue_rotate: self.skin_shaper.hue_rotate,
                hue_center: self.skin_shaper.hue_center,
                hue_range: self.skin_shaper.hue_range,
                sigmoid_shift: self.skin_shaper.sigmoid_shift,
                bellcurve_width: self.skin_shaper.bellcurve_width,
                phighlighter: self.skin_shaper.phighlighter,
            },
            film_compression: spektrafilm_gpu::DisplayFilmCompression {
                enabled: self.film_compression.enabled,
                impact: if self.film_compression.enabled {
                    self.film_compression.impact / 100.0
                } else {
                    0.0
                },
                white_point: self.film_compression.white_point / 100.0,
                range: self.film_compression.range / 100.0,
                color_density: self.film_compression.color_density / 100.0,
            },
            film_expand: spektrafilm_gpu::DisplayFilmExpand {
                enabled: self.film_expand.enabled,
                blacks: self.film_expand.blacks / 100.0,
                whites: self.film_expand.whites / 100.0,
                rgb_mode: self.film_expand.mode == FilmExpandMode::Rgb,
                impact: if self.film_expand.enabled {
                    self.film_expand.impact
                } else {
                    0.0
                },
            },
            relight_enabled: self.relight.enabled,
            relight_strength: self.relight.strength,
            relight_lights: self
                .relight
                .lights
                .map(|light| spektrafilm_gpu::DisplayRelightLight {
                    enabled: light.enabled,
                    x: light.x,
                    y: light.y,
                    radius: light.radius,
                    intensity: light.intensity,
                    color: light.color,
                }),
        }
    }

    pub fn apply(&self, image: &mut ImageBuf) {
        let width = image.width as usize;
        let height = image.height as usize;
        image
            .data
            .par_chunks_exact_mut(3)
            .enumerate()
            .for_each(|(index, px)| {
                let out = self.apply_rgb_at(
                    [to_f32(px[0]), to_f32(px[1]), to_f32(px[2])],
                    index % width.max(1),
                    index / width.max(1),
                    width,
                    height,
                );
                px[0] = from_f32(out[0]);
                px[1] = from_f32(out[1]);
                px[2] = from_f32(out[2]);
            });
    }

    fn apply_background(&self, rgb: [f32; 3], mask: f32, adjustment: [f32; 4]) -> [f32; 3] {
        if mask <= 0.0 {
            return rgb;
        }
        let [exposure, temperature, tint, saturation] = adjustment;
        let mut linear = if self.encoded {
            rgb.map(|v| lookup(&self.decode, v))
        } else {
            rgb
        };
        let warm = temperature.clamp(-100.0, 100.0) / 100.0 * 0.18 * mask;
        let green = tint.clamp(-100.0, 100.0) / 100.0 * 0.12 * mask;
        linear[0] *= 1.0 + warm;
        linear[1] *= 1.0 + green;
        linear[2] *= 1.0 - warm;
        let y = (self.luma[0] * linear[0] + self.luma[1] * linear[1] + self.luma[2] * linear[2])
            .max(0.0);
        let sat = 1.0 + saturation.clamp(-100.0, 100.0) / 100.0 * mask;
        linear = linear.map(|channel| (y + (channel - y) * sat).max(0.0));
        let exposure = 2.0f32.powf(exposure.clamp(-5.0, 5.0) * mask);
        linear = linear.map(|channel| (channel * exposure).clamp(0.0, 1.0));
        if self.encoded {
            linear.map(|v| lookup(&self.encode, v.sqrt()))
        } else {
            linear
        }
    }

    pub fn applied(&self, image: &ImageBuf) -> ImageBuf {
        let mut image = image.clone();
        self.apply(&mut image);
        image
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(f: impl FnOnce(&mut PostParams)) -> PostParams {
        let mut p = PostParams::default();
        f(&mut p);
        p
    }

    #[test]
    fn neutral_settings_keep_the_photograph() {
        let post = PostProcess::new(&PostParams::default(), true, "sRGB");
        for rgb in [
            [0.0, 0.0, 0.0],
            [1.0, 1.0, 1.0],
            [0.2, 0.5, 0.9],
            [0.8, 0.1, 0.3],
        ] {
            let out = post.apply_rgb(rgb);
            for c in 0..3 {
                assert!((out[c] - rgb[c]).abs() < 2e-4, "{rgb:?} -> {out:?}");
            }
        }
    }

    #[test]
    fn each_background_mask_slider_only_changes_its_own_selection() {
        let encode_mask = |pixels: Vec<u8>| {
            let mask = image::GrayImage::from_raw(2, 1, pixels).unwrap();
            let mut png = std::io::Cursor::new(Vec::new());
            image::DynamicImage::ImageLuma8(mask)
                .write_to(&mut png, image::ImageFormat::Png)
                .unwrap();
            base64::engine::general_purpose::STANDARD.encode(png.into_inner())
        };
        let edit = params(|p| {
            p.background_masks = vec![
                BackgroundMaskLayer {
                    id: "left".into(),
                    selection: "subject".into(),
                    mask_png_base64: encode_mask(vec![255, 0]),
                    exposure_ev: 1.0,
                    ..Default::default()
                },
                BackgroundMaskLayer {
                    id: "right".into(),
                    selection: "people".into(),
                    mask_png_base64: encode_mask(vec![0, 255]),
                    exposure_ev: 2.0,
                    ..Default::default()
                },
            ];
        });
        let mut image =
            ImageBuf::from_data(2, 1, vec![0.1f32; 6].into_iter().map(from_f32).collect());
        PostProcess::new(&edit, false, "sRGB").apply(&mut image);
        let values: Vec<f32> = image.data.iter().copied().map(to_f32).collect();
        assert!(
            (values[0] - 0.2).abs() < 0.002,
            "left selection: {values:?}"
        );
        assert!(
            (values[3] - 0.4).abs() < 0.002,
            "right selection: {values:?}"
        );
    }

    #[test]
    fn tone_curves_rise_and_keep_their_ends() {
        for (b, c) in [
            (100.0, 0.0),
            (-100.0, 0.0),
            (0.0, 100.0),
            (0.0, -100.0),
            (60.0, -40.0),
        ] {
            let p = params(|p| {
                p.brightness = b;
                p.contrast = c;
            });
            assert!(tone(&p, 0.0).abs() < 1e-12 && (tone(&p, 1.0) - 1.0).abs() < 1e-12);
            let values: Vec<f64> = (0..=100).map(|i| tone(&p, i as f64 / 100.0)).collect();
            assert!(values.windows(2).all(|w| w[1] >= w[0]), "b {b} c {c}");
        }
        assert!(tone(&params(|p| p.brightness = 50.0), PIVOT) > PIVOT);
        assert!(tone(&params(|p| p.contrast = 50.0), 0.3) < 0.3);
        assert!(tone(&params(|p| p.contrast = 50.0), 0.7) > 0.7);
    }

    #[test]
    fn whites_and_blacks_move_the_end_points() {
        assert_eq!(tone(&params(|p| p.whites = 100.0), 1.0 - LEVELS_RANGE), 1.0);
        assert!(tone(&params(|p| p.whites = -100.0), 1.0) < 0.9);
        assert_eq!(tone(&params(|p| p.blacks = -100.0), LEVELS_RANGE), 0.0);
        assert!(tone(&params(|p| p.blacks = 100.0), 0.0) > 0.1);
    }

    #[test]
    fn saturation_keeps_luminance_and_greys() {
        let luma = |c: [f32; 3]| 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
        let mono = PostProcess::new(&params(|p| p.saturation = -100.0), false, "sRGB");
        let out = mono.apply_rgb([0.6, 0.2, 0.1]);
        assert!((out[0] - out[1]).abs() < 1e-6 && (out[1] - out[2]).abs() < 1e-6);
        assert!((luma(out) - luma([0.6, 0.2, 0.1])).abs() < 1e-3);
        let vivid = PostProcess::new(&params(|p| p.saturation = 100.0), false, "sRGB");
        assert_eq!(
            vivid.apply_rgb([0.4, 0.4, 0.4]).map(|v| (v * 1e4).round()),
            [4000.0; 3]
        );
        let out = vivid.apply_rgb([0.9, 0.3, 0.1]);
        assert!(out.iter().all(|v| (0.0..=1.0).contains(v)));
        assert!((luma(out) - luma([0.9, 0.3, 0.1])).abs() < 1e-3);
        assert!(out[0] - out[2] > 0.8);
    }

    #[test]
    fn brightening_a_bright_colour_stays_in_gamut() {
        let post = PostProcess::new(
            &params(|p| {
                p.brightness = 100.0;
                p.whites = 100.0;
            }),
            true,
            "sRGB",
        );
        let out = post.apply_rgb([1.0, 0.9, 0.2]);
        assert!(out.iter().all(|v| (0.0..=1.0).contains(v)), "{out:?}");
    }

    #[test]
    fn luminance_follows_the_output_space() {
        let prophoto = RgbColourspace::output("ProPhoto RGB").rgb_to_xyz[1].map(|v| v as f32);
        let mono = PostProcess::new(&params(|p| p.saturation = -100.0), false, "ProPhoto RGB");
        for (rgb, y) in [
            ([1.0, 0.0, 0.0], prophoto[0]),
            ([0.0, 0.0, 1.0], prophoto[2]),
        ] {
            let out = mono.apply_rgb(rgb);
            assert!(
                out.iter().all(|v| (v - y).abs() < 1e-4),
                "{rgb:?} -> {out:?}, want {y}"
            );
        }
        assert_eq!(luminance_weights("unknown"), luminance_weights("sRGB"));
    }

    /// The same settings change a colour the same way whatever space it is
    /// encoded in: adjust in sRGB, or in ProPhoto RGB and convert.
    #[test]
    fn adjustments_agree_across_output_spaces() {
        use crate::stages::scanning::convert_output;
        // Tone only: a saturation boost stops at each space's own gamut
        // boundary, which is the point of a wider output space.
        let edit = params(|p| {
            p.brightness = 30.0;
            p.contrast = 25.0;
            p.whites = -10.0;
        });
        let colours = [
            [0.8f32, 0.3, 0.2],
            [0.2, 0.5, 0.7],
            [0.46, 0.46, 0.46],
            [0.9, 0.85, 0.1],
            [0.05, 0.04, 0.03],
        ];
        let srgb = ImageBuf::from_data(
            5,
            1,
            colours.iter().flatten().map(|&v| from_f32(v)).collect(),
        );
        let mut prophoto = srgb.clone();
        convert_output(&mut prophoto, "sRGB", "ProPhoto RGB", true);
        let a = PostProcess::new(&edit, true, "sRGB").applied(&srgb);
        let mut b = PostProcess::new(&edit, true, "ProPhoto RGB").applied(&prophoto);
        convert_output(&mut b, "ProPhoto RGB", "sRGB", true);
        for (x, y) in a.data.iter().zip(&b.data) {
            // f32 tables and arithmetic, and two conversions.
            assert!(
                (to_f32(*x) - to_f32(*y)).abs() < 2e-3,
                "{:?} vs {:?}",
                a.data,
                b.data
            );
        }
    }
}
