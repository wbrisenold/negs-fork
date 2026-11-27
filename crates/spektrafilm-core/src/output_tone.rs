//! Optional SDR output tone transforms.
//!
//! ACES SDR Hill fit adapted from TheRealMJP/BakingLab's `ACES.hlsl`.
//! Original code by MJP and David Neubelt, based on Stephen Hill's fit.
//! Copyright (c) 2016 MJP. MIT licensed; see the retained notice below.

use rayon::prelude::*;
use spektrafilm_math::colorspace::{self, RgbColourspace};
use spektrafilm_math::image::ImageBuf;
use spektrafilm_math::precision::{from_f64, to_f64};

/// Apply a display tone transform to an image in its declared output space.
/// The Hill fit is defined for linear Rec.709/sRGB primaries, so wide-gamut
/// outputs are converted through that working space and converted back.
pub fn apply_aces_sdr_hill_fit(image: &mut ImageBuf, encoded: bool, output_space: &str) {
    let source = RgbColourspace::output(output_space);
    let srgb = RgbColourspace::output("sRGB");
    let to_srgb = colorspace::icc_rgb_to_rgb(source, srgb);
    let from_srgb = colorspace::icc_rgb_to_rgb(srgb, source);
    image.data.par_chunks_exact_mut(3).for_each(|pixel| {
        let mut linear: [f64; 3] = std::array::from_fn(|i| {
            let value = to_f64(pixel[i]);
            if encoded {
                source.cctf.decode(value)
            } else {
                value
            }
        });
        linear = colorspace::mat3_vec_f64(&to_srgb, linear);
        linear = aces_sdr_hill_fit(linear);
        linear = colorspace::mat3_vec_f64(&from_srgb, linear);
        for i in 0..3 {
            let value = linear[i].clamp(0.0, 1.0);
            pixel[i] = from_f64(if encoded {
                source.cctf.encode(value)
            } else {
                value
            });
        }
    });
}

/// MJP's ACES fitted RRT + SDR ODT transform, for linear Rec.709/sRGB input
/// and output. The matrix and rational fit are the published MIT version.
pub fn aces_sdr_hill_fit(rgb: [f64; 3]) -> [f64; 3] {
    const INPUT: [[f64; 3]; 3] = [
        [0.59719, 0.35458, 0.04823],
        [0.07600, 0.90834, 0.01566],
        [0.02840, 0.13383, 0.83777],
    ];
    const OUTPUT: [[f64; 3]; 3] = [
        [1.60475, -0.53108, -0.07367],
        [-0.10208, 1.10813, -0.00605],
        [-0.00327, -0.07276, 1.07602],
    ];
    let ap1 = colorspace::mat3_vec_f64(&INPUT, rgb);
    let fit = ap1.map(|v| {
        let a = v * (v + 0.0245786) - 0.000090537;
        let b = v * (0.983729 * v + 0.4329510) + 0.238081;
        a / b
    });
    colorspace::mat3_vec_f64(&OUTPUT, fit).map(|v| v.clamp(0.0, 1.0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hill_fit_maps_neutral_white_to_a_bounded_sdr_value() {
        let white = aces_sdr_hill_fit([1.0; 3]);
        assert!(white.iter().all(|v| (0.6190..=0.6193).contains(v)));
    }

    #[test]
    fn hill_fit_rolls_off_highlights_and_preserves_neutrality() {
        let mid = aces_sdr_hill_fit([0.18; 3]);
        let bright = aces_sdr_hill_fit([4.0; 3]);
        assert!(mid[0] < bright[0] && bright[0] < 1.0);
        assert!((bright[0] - bright[1]).abs() < 1e-5);
        assert!((bright[1] - bright[2]).abs() < 1e-5);
    }

    #[test]
    fn encoded_srgb_round_trips_through_the_fit() {
        let mut image = ImageBuf::from_data(1, 1, vec![0.5, 0.25, 0.75]);
        apply_aces_sdr_hill_fit(&mut image, true, "sRGB");
        assert!(image.data.iter().all(|v| (0.0..=1.0).contains(&to_f64(*v))));
    }
}

// MIT License
// Copyright (c) 2016 MJP
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
