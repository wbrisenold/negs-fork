//! Perceptual split toning for the display-referred post pass.
//!
//! Adapted from darktable's Color Harmonizer, Copyright (C) 2026 darktable
//! developers, distributed under GPL-3.0-or-later. See
//! `docs/color-harmonizer-attribution.md` for source references and changes.
//!
//! The color model and harmony-node behavior adapt darktable's GPL-3.0 Color
//! Harmonizer and UCS JCH conversions to Negs' output color spaces. The tone
//! pair is prepared once per post processor; the pixel path converts to UCS
//! JCH, applies a smooth shadow-to-highlight tone, and converts back.

use crate::post::{ColorHarmonyRule, ColorSeparationParams};
use spektrafilm_math::colorspace::{self, RgbColourspace, SRGB};
use std::sync::OnceLock;

const TAU: f32 = std::f32::consts::TAU;
const PI: f32 = std::f32::consts::PI;
const L_STAR_RANGE: f32 = 2.098883786377;
const L_STAR_UPPER_LIMIT: f32 = 2.09885;
const Y_HUE_KNOTS: [f32; 7] = [0.0, 1.0 / 3.0, 0.472, 0.611, 0.715, 5.0 / 6.0, 1.0];
const X_HUE_KNOTS: [f32; 7] = [
    0.0,
    1.0 / 6.0,
    2.0 / 6.0,
    3.0 / 6.0,
    4.0 / 6.0,
    5.0 / 6.0,
    1.0,
];
const HUE_LUT_SIZE: usize = 720;

#[derive(Clone)]
pub(crate) struct ColorHarmonizer {
    output_to_xyz_d65: [[f32; 3]; 3],
    xyz_d65_to_output: [[f32; 3]; 3],
    harmony_nodes: [f32; 4],
    node_count: usize,
}

impl ColorHarmonizer {
    pub(crate) fn new(
        params: ColorSeparationParams,
        output_space: &'static RgbColourspace,
        decode: &[f32],
    ) -> Self {
        let d65_adaptation =
            colorspace::bradford_matrix(output_space.whitepoint_xyz, SRGB.whitepoint_xyz);
        let output_to_xyz_d65 = mat_f32(colorspace::mat3_mul3_f64(
            &d65_adaptation,
            &output_space.rgb_to_xyz,
        ));
        let xyz_d65_to_output = mat_f32(colorspace::mat3_inverse(&matrix_f64(output_to_xyz_d65)));
        let mut this = Self {
            output_to_xyz_d65,
            xyz_d65_to_output,
            harmony_nodes: [0.0; 4],
            node_count: 0,
        };
        if params.strength <= 0.0 {
            return this;
        }

        let target_jch = this.encoded_hue_to_jch(params.target_hue, decode);
        let target_hue = (target_jch[2] + PI) / TAU;
        let forward = hue_lut();
        let node_hues = if params.color_wash
            || params.harmony_rule == ColorHarmonyRule::Monochromatic
        {
            let mut nodes = [0.0; 4];
            nodes[0] = target_hue;
            this.node_count = 1;
            nodes
        } else if params.harmony_rule == ColorHarmonyRule::Manual {
            let mut nodes = [0.0; 4];
            nodes[0] = target_hue;
            nodes[1] = (this.encoded_hue_to_jch(params.complementary_hue, decode)[2] + PI) / TAU;
            this.node_count = 2;
            nodes
        } else {
            let anchor_ryb = ucs_to_ryb(forward, target_hue);
            let offsets: &[f32] = match params.harmony_rule {
                ColorHarmonyRule::Analogous => &[-1.0 / 12.0, 0.0, 1.0 / 12.0],
                ColorHarmonyRule::Complementary => &[0.0, 6.0 / 12.0],
                ColorHarmonyRule::SplitComplementary => &[0.0, 5.0 / 12.0, 7.0 / 12.0],
                ColorHarmonyRule::Triadic => &[0.0, 4.0 / 12.0, 8.0 / 12.0],
                ColorHarmonyRule::Tetradic => &[-1.0 / 12.0, 1.0 / 12.0, 5.0 / 12.0, 7.0 / 12.0],
                ColorHarmonyRule::Square => &[0.0, 3.0 / 12.0, 6.0 / 12.0, 9.0 / 12.0],
                ColorHarmonyRule::Manual | ColorHarmonyRule::Monochromatic => unreachable!(),
            };
            this.node_count = offsets.len();
            let mut nodes = [0.0; 4];
            for (index, offset) in offsets.iter().enumerate() {
                nodes[index] = ryb_to_ucs(forward, (anchor_ryb + offset).rem_euclid(1.0));
            }
            nodes
        };
        for (index, hue) in node_hues.iter().take(this.node_count).enumerate() {
            this.harmony_nodes[index] = hue * TAU - PI;
        }
        this
    }

    pub(crate) fn output_to_xyz_d65(&self) -> [[f32; 4]; 3] {
        rows4(self.output_to_xyz_d65)
    }

    pub(crate) fn xyz_d65_to_output(&self) -> [[f32; 4]; 3] {
        rows4(self.xyz_d65_to_output)
    }

    pub(crate) fn nodes(&self) -> [f32; 4] {
        self.harmony_nodes
    }

    pub(crate) fn node_count(&self) -> u32 {
        self.node_count as u32
    }

    pub(crate) fn apply(
        &self,
        encoded_rgb: [f32; 3],
        p: ColorSeparationParams,
        decode: &[f32],
        encode: &[f32],
    ) -> [f32; 3] {
        if p.strength <= 0.0 || self.node_count == 0 {
            return encoded_rgb;
        }
        let linear_output = encoded_rgb.map(|v| lookup(decode, v));
        let xyz = mat_vec(self.output_to_xyz_d65, linear_output);
        let mut jch = xyz_d65_to_jch(xyz);
        let chroma = jch[1];
        if chroma <= 1.0e-7 {
            return encoded_rgb;
        }

        let hsv_saturation = rgb_saturation(encoded_rgb);
        let neutral = p.neutral_protection.clamp(0.0, 100.0) / 100.0;
        let chroma_protection = chroma / (chroma + neutral.powi(3) * 0.03 + 1.0e-5);
        let saturation_mask = ((hsv_saturation - p.target_saturation.clamp(0.0, 100.0) / 100.0)
            / 0.35)
            .clamp(0.0, 1.0);
        let strength = p.strength.clamp(0.0, 100.0) / 100.0;
        let transition_width = 0.08 + p.method.clamp(0.0, 100.0) / 100.0 * 0.52;
        let pivot = (0.5 + p.luminance_mask.clamp(-100.0, 100.0) / 200.0).clamp(0.1, 0.9);
        let highlight_mix = smoothstep(
            pivot - transition_width * 0.5,
            pivot + transition_width * 0.5,
            jch[0],
        );
        let shadow_hue = self.harmony_nodes[0];
        let highlight_hue = self.harmony_nodes[self.node_count - 1];
        let toned_hue = shadow_hue + hue_delta(shadow_hue, highlight_hue) * highlight_mix;
        let amount = strength * chroma_protection * saturation_mask;
        let hue_shift = hue_delta(jch[2], toned_hue) * amount;
        if hue_shift.abs() < 1.0e-7 {
            return encoded_rgb;
        }
        jch[2] = (jch[2] + hue_shift + PI).rem_euclid(TAU) - PI;
        let mapped = self.gamut_map(jch);
        mapped.map(|v| lookup(encode, v.clamp(0.0, 1.0).sqrt()))
    }

    fn encoded_hue_to_jch(&self, hue: f32, decode: &[f32]) -> [f32; 3] {
        let encoded = hsv_to_rgb(hue, 0.8, 0.72);
        let linear = encoded.map(|v| lookup(decode, v));
        xyz_d65_to_jch(mat_vec(self.output_to_xyz_d65, linear))
    }

    fn gamut_map(&self, jch: [f32; 3]) -> [f32; 3] {
        let candidate = mat_vec(self.xyz_d65_to_output, jch_to_xyz_d65(jch));
        if in_gamut(candidate) {
            return candidate;
        }
        let mut low = 0.0;
        let mut high = jch[1];
        let mut grey = jch;
        grey[1] = 0.0;
        let mut best = mat_vec(self.xyz_d65_to_output, jch_to_xyz_d65(grey));
        for _ in 0..8 {
            let mid = (low + high) * 0.5;
            let mut test = jch;
            test[1] = mid;
            let rgb = mat_vec(self.xyz_d65_to_output, jch_to_xyz_d65(test));
            if in_gamut(rgb) {
                low = mid;
                best = rgb;
            } else {
                high = mid;
            }
        }
        best
    }
}

fn hue_lut() -> &'static [f32] {
    static LUT: OnceLock<Vec<f32>> = OnceLock::new();
    LUT.get_or_init(|| {
        let xyz_to_srgb = mat_f32(SRGB.xyz_to_rgb);
        (0..HUE_LUT_SIZE)
            .map(|index| {
                let hue = index as f32 / HUE_LUT_SIZE as f32 * TAU - PI;
                let xyz = jch_to_xyz_d65([0.5, 0.2, hue]);
                let rgb = mat_vec(xyz_to_srgb, xyz).map(|v| v.clamp(0.0, 1.0));
                let rgb_hue = rgb_to_hue(rgb);
                rgb_hue_to_ryb(rgb_hue)
            })
            .collect()
    })
}

fn ucs_to_ryb(lut: &[f32], hue: f32) -> f32 {
    let position = hue.rem_euclid(1.0) * lut.len() as f32;
    let i0 = position as usize % lut.len();
    let i1 = (i0 + 1) % lut.len();
    hue_lerp(lut[i0], lut[i1], position.fract())
}

fn ryb_to_ucs(lut: &[f32], hue: f32) -> f32 {
    let target = hue.rem_euclid(1.0);
    let nearest = lut
        .iter()
        .enumerate()
        .min_by(|(_, a), (_, b)| {
            circular_distance(**a, target).total_cmp(&circular_distance(**b, target))
        })
        .map(|(index, _)| index)
        .unwrap_or(0);
    nearest as f32 / lut.len() as f32
}

fn rgb_hue_to_ryb(hue: f32) -> f32 {
    piecewise(hue.rem_euclid(1.0), &X_HUE_KNOTS, &Y_HUE_KNOTS)
}

fn piecewise(value: f32, x: &[f32; 7], y: &[f32; 7]) -> f32 {
    for i in 0..6 {
        if value <= x[i + 1] {
            let t = (value - x[i]) / (x[i + 1] - x[i]);
            return y[i] + t * (y[i + 1] - y[i]);
        }
    }
    1.0
}

fn hue_lerp(a: f32, b: f32, t: f32) -> f32 {
    let delta = hue_delta(a * TAU, b * TAU) / TAU;
    (a + t * delta).rem_euclid(1.0)
}

fn circular_distance(a: f32, b: f32) -> f32 {
    let delta = (a - b).rem_euclid(1.0);
    delta.min(1.0 - delta)
}

fn hue_delta(from: f32, to: f32) -> f32 {
    let delta = to - from;
    delta.sin().atan2(delta.cos())
}

fn smoothstep(edge0: f32, edge1: f32, value: f32) -> f32 {
    let t = ((value - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

fn xyz_d65_to_jch(mut xyz: [f32; 3]) -> [f32; 3] {
    xyz = xyz.map(|v| v.max(0.0));
    let sum = xyz[0] + xyz[1] + xyz[2];
    let (x, y) = if sum > 0.0 {
        (xyz[0] / sum, xyz[1] / sum)
    } else {
        (SRGB.whitepoint_xy[0] as f32, SRGB.whitepoint_xy[1] as f32)
    };
    let luminance = xyz[1];
    let uvd = [
        -0.783941 * x + 0.27751298 * y + 0.15383658,
        0.74527353 * x - 0.20537587 * y - 0.16547838,
        0.3187073 * x + 2.167437 * y + 0.29132056,
    ];
    let divisor = uvd[2].signum() * uvd[2].abs().max(f32::MIN_POSITIVE);
    let u = uvd[0] / divisor;
    let v = uvd[1] / divisor;
    let u_star = 1.3965623 * u / (u.abs() + 1.4921736);
    let v_star = 1.4513954 * v / (v.abs() + 1.5248864);
    let u_prime = -1.1249839 * u_star - 0.9804837 * v_star;
    let v_prime = 1.8632332 * u_star + 1.9718531 * v_star;
    let l_star = y_to_l_star(luminance);
    let l_white = y_to_l_star(1.0);
    let m2 = u_prime * u_prime + v_prime * v_prime;
    [
        l_star / l_white,
        15.932994 * l_star.powf(0.65239975) * m2.powf(0.6007557) / l_white,
        v_prime.atan2(u_prime),
    ]
}

fn jch_to_xyz_d65(jch: [f32; 3]) -> [f32; 3] {
    let l_white = y_to_l_star(1.0);
    let l_star = (jch[0] * l_white).clamp(0.0, L_STAR_UPPER_LIMIT);
    let m = if l_star != 0.0 {
        (jch[1] * l_white / (15.932994 * l_star.powf(0.65239975))).powf(0.83228505)
    } else {
        0.0
    };
    let u_prime = m * jch[2].cos();
    let v_prime = m * jch[2].sin();
    let u_star = -5.0375224 * u_prime - 2.5048563 * v_prime;
    let v_star = 4.7600293 * u_prime + 2.874013 * v_prime;
    let u = -1.4921736 * u_star / (u_star.abs() - 1.3965623);
    let v = -1.5248864 * v_star / (v_star.abs() - 1.4513955);
    let x_d = 0.16717148 * u + 0.1412998 * v - 0.008015313;
    let y_d = -0.15095909 * u - 0.15518506 * v - 0.008433124;
    let z_d = 0.94025475 * u + v - 0.025632596;
    let divisor = z_d.signum() * z_d.abs().max(f32::MIN_POSITIVE);
    let x = x_d / divisor;
    let y = y_d / divisor;
    let luminance = ((1.1242677 * l_star / (L_STAR_RANGE - l_star)).max(0.0)).powf(1.5831518);
    if y.abs() <= f32::MIN_POSITIVE {
        [0.0, luminance, 0.0]
    } else {
        [luminance * x / y, luminance, luminance * (1.0 - x - y) / y]
    }
}

fn y_to_l_star(y: f32) -> f32 {
    let y_hat = y.max(0.0).powf(0.63165134);
    L_STAR_RANGE * y_hat / (y_hat + 1.1242677)
}

fn rgb_to_hue(rgb: [f32; 3]) -> f32 {
    let high = rgb[0].max(rgb[1]).max(rgb[2]);
    let low = rgb[0].min(rgb[1]).min(rgb[2]);
    let delta = high - low;
    if delta <= 1.0e-8 {
        return 0.0;
    }
    let hue = if high == rgb[0] {
        ((rgb[1] - rgb[2]) / delta).rem_euclid(6.0)
    } else if high == rgb[1] {
        (rgb[2] - rgb[0]) / delta + 2.0
    } else {
        (rgb[0] - rgb[1]) / delta + 4.0
    };
    (hue / 6.0).rem_euclid(1.0)
}

fn rgb_saturation(rgb: [f32; 3]) -> f32 {
    let high = rgb[0].max(rgb[1]).max(rgb[2]);
    let low = rgb[0].min(rgb[1]).min(rgb[2]);
    if high <= 1.0e-8 {
        0.0
    } else {
        (high - low) / high
    }
}

fn hsv_to_rgb(hue: f32, saturation: f32, value: f32) -> [f32; 3] {
    let h = hue.rem_euclid(360.0);
    let chroma = value * saturation;
    let x = chroma * (1.0 - ((h / 60.0).rem_euclid(2.0) - 1.0).abs());
    let m = value - chroma;
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
    rgb.map(|channel| channel + m)
}

fn mat_f32(matrix: [[f64; 3]; 3]) -> [[f32; 3]; 3] {
    matrix.map(|row| row.map(|value| value as f32))
}

fn matrix_f64(matrix: [[f32; 3]; 3]) -> [[f64; 3]; 3] {
    matrix.map(|row| row.map(f64::from))
}

fn rows4(matrix: [[f32; 3]; 3]) -> [[f32; 4]; 3] {
    matrix.map(|row| [row[0], row[1], row[2], 0.0])
}

fn mat_vec(matrix: [[f32; 3]; 3], v: [f32; 3]) -> [f32; 3] {
    matrix.map(|row| row[0] * v[0] + row[1] * v[1] + row[2] * v[2])
}

fn lookup(table: &[f32], x: f32) -> f32 {
    let t = x.clamp(0.0, 1.0) * (table.len() - 1) as f32;
    let i = (t as usize).min(table.len() - 2);
    let f = t - i as f32;
    table[i] + (table[i + 1] - table[i]) * f
}

fn in_gamut(rgb: [f32; 3]) -> bool {
    rgb.iter().all(|channel| (0.0..=1.0).contains(channel))
}
