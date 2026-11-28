# Perceptual color toning attribution

Negs' perceptual Color Harmonizer adapts the color model, RYB hue geometry,
and harmony-node weighting from darktable's Color Harmonizer module:

- <https://github.com/darktable-org/darktable/blob/master/src/iop/colorharmonizer.c>
- <https://github.com/darktable-org/darktable/blob/master/dev-doc/iop/colorharmonizer/business_logic.md>

darktable is distributed under the GNU General Public License, version 3. This
implementation is modified for Negs' output color spaces and display pipeline;
it uses Negs' prepared decode/encode tables and applies a tonal UCS JCH hue
transition with gamut mapping. The applicable license is in the repository's
`LICENSE` file.
