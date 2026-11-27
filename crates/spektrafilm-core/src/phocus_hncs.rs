//! Data access for the recovered Phocus HNCS camera profiles.
//!
//! This module deliberately stops at validated profile data and matrix
//! construction. Phocus applies its correction before later RAW stages, and
//! the recovered CPID is not yet joined to the decoder's camera identity.
//! Do not treat this as a complete Phocus rendering implementation.

use std::{collections::BTreeMap, fs, path::Path, sync::OnceLock};

use serde::Deserialize;
use thiserror::Error;

const WB_LOCUS_CSV: &str = include_str!("../data/phocus_wb_locus.csv");

#[derive(Debug, Error)]
pub enum ProfileLoadError {
    #[error("could not read HNCS profile {path}: {source}")]
    Read {
        path: String,
        source: std::io::Error,
    },
    #[error("could not parse HNCS profile {path}: {source}")]
    Parse {
        path: String,
        source: serde_json::Error,
    },
    #[error("HNCS profile {path} has an invalid runtime array: {array}")]
    InvalidArray { path: String, array: String },
    #[error("HNCS profile directory has no JSON profiles: {0}")]
    EmptyDirectory(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Illuminant {
    Flash,
    Tungsten,
    Dng,
}

#[derive(Debug, Clone)]
pub struct PhocusProfile {
    pub source_file: String,
    pub cpids: Vec<u32>,
    pub version: Option<String>,
    pub temperature_anchors_kelvin: BTreeMap<String, f64>,
    pub chroma_bounds: Option<[f64; 4]>, // Cb start/end, Cr start/end
    pub div_factor: Option<f64>,
    /// False for older profiles whose array scaling was not established.
    pub arrays_runtime_scaled: bool,
    arrays: BTreeMap<String, Vec<f64>>,
}

#[derive(Debug, Clone, Default)]
pub struct PhocusProfileSet {
    profiles: Vec<PhocusProfile>,
}

#[derive(Deserialize)]
struct ProfileDocument {
    source_file: String,
    #[serde(default)]
    cpids: Vec<String>,
    #[serde(default)]
    metadata: BTreeMap<String, serde_json::Value>,
    #[serde(default)]
    arrays: BTreeMap<String, RuntimeArray>,
}

#[derive(Deserialize)]
struct RuntimeArray {
    #[serde(default)]
    runtime_values: Vec<f64>,
    #[serde(default)]
    stored_values: Vec<f64>,
}

impl PhocusProfileSet {
    /// Load the extracted `runtime_profiles` directory. Profile data stays
    /// outside the application bundle; callers choose where the research
    /// extraction is installed.
    pub fn load_dir(path: &Path) -> Result<Self, ProfileLoadError> {
        let mut files = fs::read_dir(path)
            .map_err(|source| ProfileLoadError::Read {
                path: path.display().to_string(),
                source,
            })?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|file| file.extension().is_some_and(|ext| ext == "json"))
            .collect::<Vec<_>>();
        files.sort();
        if files.is_empty() {
            return Err(ProfileLoadError::EmptyDirectory(path.display().to_string()));
        }

        let mut profiles = Vec::with_capacity(files.len());
        for file in files {
            let filename = file.display().to_string();
            let source = fs::read_to_string(&file).map_err(|source| ProfileLoadError::Read {
                path: filename.clone(),
                source,
            })?;
            let doc: ProfileDocument =
                serde_json::from_str(&source).map_err(|source| ProfileLoadError::Parse {
                    path: filename.clone(),
                    source,
                })?;
            let cpids = doc
                .cpids
                .iter()
                .map(|cpid| parse_cpid(cpid))
                .collect::<Option<Vec<_>>>()
                .ok_or_else(|| ProfileLoadError::InvalidArray {
                    path: filename.clone(),
                    array: "CPID".to_owned(),
                })?;
            let mut arrays = BTreeMap::new();
            let mut arrays_runtime_scaled = true;
            for (name, array) in doc.arrays {
                let (values, is_runtime_scaled) = if !array.runtime_values.is_empty() {
                    (array.runtime_values, true)
                } else {
                    (array.stored_values, false)
                };
                if values.is_empty() {
                    return Err(ProfileLoadError::InvalidArray {
                        path: filename,
                        array: name,
                    });
                }
                arrays_runtime_scaled &= is_runtime_scaled;
                arrays.insert(name, values);
            }
            let temperature_anchors_kelvin = ["tf", "tt", "tlt", "th"]
                .into_iter()
                .filter_map(|key| {
                    doc.metadata
                        .get(key)
                        .and_then(serde_json::Value::as_f64)
                        .map(|value| (key.to_owned(), value))
                })
                .collect();
            let bounds = ["CbS", "CbE", "CrS", "CrE"]
                .map(|key| doc.metadata.get(key).and_then(serde_json::Value::as_f64));
            let chroma_bounds = bounds
                .iter()
                .all(Option::is_some)
                .then(|| bounds.map(Option::unwrap));
            let div_factor = doc
                .metadata
                .get("DivFactor")
                .and_then(serde_json::Value::as_f64);
            let version = doc
                .metadata
                .get("Version")
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned);
            profiles.push(PhocusProfile {
                source_file: doc.source_file,
                cpids,
                version,
                temperature_anchors_kelvin,
                chroma_bounds,
                div_factor,
                arrays_runtime_scaled,
                arrays,
            });
        }
        Ok(Self { profiles })
    }

    pub fn profiles(&self) -> &[PhocusProfile] {
        &self.profiles
    }

    /// CPID values are the packed numeric keys observed in Phocus' dispatch.
    pub fn by_cpid(&self, cpid: u32) -> Option<&PhocusProfile> {
        self.profiles
            .iter()
            .find(|profile| profile.cpids.contains(&cpid))
    }
}

impl PhocusProfile {
    pub fn matrix(&self, illuminant: Illuminant) -> Option<[[f64; 3]; 3]> {
        let key = match illuminant {
            Illuminant::Flash | Illuminant::Dng => "mf",
            Illuminant::Tungsten => "mt",
        };
        matrix_from(self.arrays.get(key)?)
    }

    pub fn neutral(&self, illuminant: Illuminant) -> Option<[f64; 3]> {
        let key = match illuminant {
            Illuminant::Flash | Illuminant::Dng => "vf",
            Illuminant::Tungsten => "vt",
        };
        self.arrays.get(key)?.as_slice().try_into().ok()
    }

    /// Return the observed matrix operation: scale each matrix column by its
    /// matching neutral coefficient, then invert. DNG selects the flash
    /// matrix and neutral in the recovered Phocus selector.
    pub fn neutralized_inverse_matrix(&self, illuminant: Illuminant) -> Option<[[f64; 3]; 3]> {
        let matrix = self.matrix(illuminant)?;
        let neutral = self.neutral(illuminant)?;
        let scaled = std::array::from_fn(|row| {
            std::array::from_fn(|column| matrix[row][column] * neutral[column])
        });
        invert3(scaled)
    }

    /// The profile LUT's two channels per node, in recovered runtime scaling.
    /// The grid order and coordinates are exposed without interpolation; the
    /// Phocus `Scaled2DLUT` sampling/interpolation rules are not reproduced.
    pub fn lut(&self, illuminant: Illuminant, reproduction: bool) -> Option<&[f64]> {
        let key = match (illuminant, reproduction) {
            (Illuminant::Flash | Illuminant::Dng, false) => "LUTTableFlashStd",
            (Illuminant::Flash | Illuminant::Dng, true) => "LUTTableFlashRepro",
            (Illuminant::Tungsten, false) => "LUTTableTSStd",
            (Illuminant::Tungsten, true) => "LUTTableTSRepro",
        };
        self.arrays.get(key).map(Vec::as_slice)
    }
}

/// Interpolate the recovered global WB locus at Kelvin by linear interpolation
/// in mired. This returns Phocus' three stored locus terms, not RGB gains;
/// deriving gains still requires the camera/filter matrix and tint equations.
pub fn white_balance_locus(kelvin: f64) -> Option<[f64; 3]> {
    if !kelvin.is_finite() || kelvin <= 0.0 {
        return None;
    }
    let mired = 1_000_000.0 / kelvin;
    static ROWS: OnceLock<Vec<[f64; 4]>> = OnceLock::new();
    let rows = ROWS.get_or_init(|| {
        WB_LOCUS_CSV
            .lines()
            .skip(1)
            .filter_map(|line| {
                let mut values = line.split(',').map(str::parse::<f64>);
                Some([
                    values.next()?.ok()?,
                    values.next()?.ok()?,
                    values.next()?.ok()?,
                    values.next()?.ok()?,
                ])
            })
            .collect()
    });
    let first = *rows.first()?;
    let last = *rows.last()?;
    if mired <= first[0] {
        return Some([first[1], first[2], first[3]]);
    }
    if mired >= last[0] {
        return Some([last[1], last[2], last[3]]);
    }
    for pair in rows.windows(2) {
        if mired <= pair[1][0] {
            let t = (mired - pair[0][0]) / (pair[1][0] - pair[0][0]);
            return Some(std::array::from_fn(|i| {
                pair[0][i + 1] + t * (pair[1][i + 1] - pair[0][i + 1])
            }));
        }
    }
    None
}

fn parse_cpid(value: &str) -> Option<u32> {
    let value = value.strip_prefix("0x").unwrap_or(value);
    u32::from_str_radix(value, 16).ok()
}

fn matrix_from(values: &[f64]) -> Option<[[f64; 3]; 3]> {
    (values.len() == 9)
        .then(|| std::array::from_fn(|row| std::array::from_fn(|column| values[row * 3 + column])))
}

fn invert3(m: [[f64; 3]; 3]) -> Option<[[f64; 3]; 3]> {
    let [a, b, c] = m[0];
    let [d, e, f] = m[1];
    let [g, h, i] = m[2];
    let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if !det.is_finite() || det.abs() < f64::EPSILON {
        return None;
    }
    let inv = 1.0 / det;
    Some([
        [
            (e * i - f * h) * inv,
            (c * h - b * i) * inv,
            (b * f - c * e) * inv,
        ],
        [
            (f * g - d * i) * inv,
            (a * i - c * g) * inv,
            (c * d - a * f) * inv,
        ],
        [
            (d * h - e * g) * inv,
            (b * g - a * h) * inv,
            (a * e - b * d) * inv,
        ],
    ])
}
