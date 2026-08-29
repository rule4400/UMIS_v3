# Adobe XMP integration fixtures

These five small media files are unchanged copies of `samples/testfiles/BlueSquare.*` from Adobe's
XMP Toolkit SDK at pinned commit `581c41213ddcee1fbc72cbb532531102a6617a25` (`v2025.03`):

| File | SHA-256 |
| --- | --- |
| `BlueSquare.jpg` | `1e1cdf92904b5da35302c2655e5f7a2ea68d6bf8d9b3922225e3f2a17ba3bb6b` |
| `BlueSquare.mov` | `5ed717029e3f35b3a4d03ec3e4e915cd174b138ac29f6a7e5010d1fd3cdabf6e` |
| `BlueSquare.png` | `495616612acf66e55bf3e9aa940cb5ede7091ff6c6443a8522acf8470b58bce9` |
| `BlueSquare.psd` | `b046c30f65bd6ae78ea90660d746027e2416ecfe89eb6f0cd7a76bc5b4dae12e` |
| `BlueSquare.tif` | `f8581f2303d88a155d4f60bf21088e8058141d5ba368dfceabfe2ae00c0f19d1` |

Immutable upstream directory:
<https://github.com/adobe/XMP-Toolkit-SDK/tree/581c41213ddcee1fbc72cbb532531102a6617a25/samples/testfiles>

They are redistributed under the Adobe SDK's BSD 3-Clause license, copied verbatim at
`Vendor/AdobeXMP/Licenses/Adobe-XMP-Toolkit-SDK-LICENSE`. Tests always copy a fixture into a unique
temporary directory before mutation; the checked-in originals are never written in place.
