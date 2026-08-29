# Embedded XMP safety and compatibility boundaries

## Adobe safe-update condition

UMIS always closes an embedded write with `kXMPFiles_UpdateSafely`. The condition implemented by Adobe v2025.03 is not limited to the `kXMPFiles_AllowsSafeUpdate` bit. In the pinned [`XMPFiles/source/XMPFiles.cpp`](https://github.com/adobe/XMP-Toolkit-SDK/blob/581c41213ddcee1fbc72cbb532531102a6617a25/XMPFiles/source/XMPFiles.cpp#L1230-L1334), `XMPFiles::CloseFile` accepts safe update when:

```text
(handlerFlags & kXMPFiles_AllowsSafeUpdate) ||
!(handlerFlags & kXMPFiles_HandlerOwnsFile)
```

This distinction matters for normal local handlers such as JPEG, TIFF, and MPEG-4: a handler that does not own the file can use Adobe's common crash-safe path even without setting `kXMPFiles_AllowsSafeUpdate` itself.

For that common path Adobe derives a temporary file. It either asks a rewriting handler to populate the temporary file or copies the original into it and updates the copy, then calls `AbsorbTemp()` to replace the original. A handler that owns the file is responsible for its own update path and must explicitly advertise `kXMPFiles_AllowsSafeUpdate`. The bridge mirrors exactly this official predicate before requesting the safe close; it does not weaken it or infer support from an extension.

"Safe update" reduces partial-write risk but is not a transactional guarantee across power loss, filesystem faults, external concurrent writers, insufficient space, or a handler defect. UMIS adds the checks below and reports failure instead of claiming success when verification cannot be completed.

## ABI v3 capability boundary

The application uses the ABI-v3 descriptor-capability entry points. They take a borrowed open
parent-directory descriptor plus exactly one leaf name. The display pathname is diagnostic and
never grants mutation authority. The exported ABI contains path-based probe/read compatibility
functions, but intentionally contains no path-authorized mutation function. The only embedded-XMP
mutation entry point is `umis_xmp_write_embedded_rating_at`; its recovery token can be consumed only
by `umis_xmp_finalize_recovery_at` with the same parent-directory capability and target leaf.

The public status type is fixed-width `uint32_t`. This is a compatibility requirement, not merely a
style choice: Adobe's static macOS build and the bridge translation unit use `-fshort-enums`, so a C
enum return type could otherwise have a different width at the Swift boundary.

The bridge adds the following controls around Adobe's update:

- accepts ratings only in the Adobe-compatible integral range `-1...5` (`-1` means Adobe's “Rejected”, `0` unrated, `1...5` stars);
- requires the caller's expected identity `(device, inode, byte size, modification seconds, modification nanoseconds)`;
- duplicates and validates the directory descriptor, opens the leaf with `openat` plus `O_NOFOLLOW`, and rejects symbolic links, non-regular files, and hard-linked files for both capability reads and writes;
- compares the descriptor and directory-entry identity before opening, immediately before `PutXMP`, immediately before `CloseFile`, and after the commit;
- opens Adobe through the static-build-only official `SXMPFiles::OpenFile(XMP_IO *)` API, with an explicit allowlisted format hint, `OpenUseSmartHandler`, and `OpenStrictly`; Adobe never receives or reconstructs a mutation pathname;
- requests only Adobe smart handlers and rejects handlers marked as sidecar or folder-based for the embedded-write API;
- loads the existing XMP object instead of constructing a replacement packet and requests only an `xmp:Rating` change through `SetProperty_Int`; the selected Adobe handler can still perform format-required reconciliation or layout changes;
- requires `CanPutXMP` and the official safe-update predicate before committing;
- implements Adobe's `XMP_IO` contract with complete reads/writes, bounded seek/truncate behavior, and nested `DeriveTemp` support. Every replacement is created with `openat(O_CREAT|O_EXCL|O_NOFOLLOW)` as a fresh mode-`0600` file inside the recovery directory; before it can become visible as media, current metadata is copied from the exact held source descriptor;
- copies mode, ACLs, xattrs, and timestamps descriptor-to-descriptor with `fcopyfile(COPYFILE_METADATA)` immediately before commit. A primary-file ctime witness detects intervening filesystem-metadata changes, so an operation-start snapshot is not blindly replayed over a concurrent Finder tag/ACL change;
- commits a safe-update temp with `renameatx_np(RENAME_SWAP)`, verifies both directions of the swap (new target equals the held temp and the recovery leaf equals the expected original), and does not attempt a path rollback or unlink after an ambiguous swap result;
- performs `F_FULLFSYNC` with `fsync` fallback on the committed descriptor and held directories, then reopens by the same parent descriptor and leaf through the smart handler and verifies that the explicit embedded `xmp:Rating` equals the requested value;
- returns the post-write identity so the caller must use the new value for the next mutation;
- catches `XMP_Error`, standard C++ exceptions, allocation failures, and unknown C++ exceptions before they can cross the C ABI.

## Two-phase recovery and cleanup states

An ABI-v3 descriptor write is not complete when Adobe's `CloseFile` returns. It follows this
mandatory two-phase protocol:

1. Before Adobe derives its first safe-update temporary, the bridge creates a cryptographically
   random sibling recovery directory, opens it descriptor-relatively, forces mode `0700`, and
   durably writes an `O_EXCL` mode-`0600` `manifest.pending.json`.
2. Every fresh replacement partial starts mode `0600`. `fcopyfile(COPYFILE_METADATA)` may then give
   a candidate the source file's mode, ACLs, xattrs, and timestamps before promotion. The private
   `0700` directory remains the access boundary. The old original is moved into that directory by
   `RENAME_SWAP` as the same inode, so its original metadata and permission mode are preserved.
3. Once the committed target and all recovery artifacts have been rebound to held descriptors and
   full witnesses, the bridge durably writes mode-`0600` `manifest.sealed.json`, synchronizes the
   committed file, recovery directory, and parent, and returns a process-local single-use token.
4. Swift/Core independently reopens the target using the same parent FD and leaf, verifies the
   post-write identity and explicit `xmp:Rating`, and consumes every nonzero token on both success
   and failure paths. It passes `upper_readback_verified=1` only after that independent readback.
5. The finalizer revalidates the target, directory, manifests, and every descriptor/leaf witness
   before each namespace deletion. It deletes noncritical nested/replacement artifacts first and
   the old original last. After unlinking the old original, it durably creates mode-`0600`
   `manifest.cleanup.json` with state `committedOriginalRemoved`. It removes sealed and pending
   manifests before removing this cleanup-state manifest last, so any intermediate residue keeps
   the most accurate recovery state visible to the inspector until the directory is emptied.

This ordering distinguishes two materially different outcomes. If an old-original artifact is
still linked, Core returns a structured recovery-retained error and no later asset in the rating
batch is attempted. If the old original has been proven unlinked but a cleanup manifest, another
non-original residue, or the empty directory cannot be removed, the committed rating may be
returned with a warning and `recoveryAttentionRequired`; the batch still stops and requires a fresh
root inspection. `manifest.cleanup.json` deliberately contains the committed witness but no
restorable original, so `MetadataRecoveryInspector` can report that distinction after a crash.
The inspector checks cleanup, sealed, legacy, and pending manifests in that order and never repairs
or deletes recovery material automatically.

Any failed witness, readback, synchronization, or cleanup precondition leaves the remaining private
directory and durable manifest for inspection. A crash before sealing can therefore leave only the
pending manifest and partial artifacts; a crash after the original-last boundary can leave the
cleanup manifest. Neither state is silently classified as a successful, fully cleaned transaction.

macOS 13 has no public operation equivalent to Linux `unlinkat(..., AT_EMPTY_PATH)` that unlinks the
exact inode held by an open FD. `unlinkat` is necessarily leaf-based. UMIS therefore never deletes a
name merely because a preceding `stat` matched: it keeps the descriptor open, validates descriptor
and leaf witnesses immediately before deletion, verifies `st_nlink` afterwards, and retains data on
any mismatch. This prevents UMIS from intentionally unlinking an observed unrelated inode but does
not make a leaf-based unlink cryptographically race-free against a malicious same-UID process.

## App and Core safeguards

A held parent descriptor can remain valid after another process moves that directory outside the
approved archive root. The app therefore owns the root capability, walks every ancestor with
`openat(..., O_NOFOLLOW)`, rejects hard links and nested mount/device changes, and revalidates
root/volume/asset identity before and after each Core call. The C bridge deliberately cannot infer
that higher-level archive boundary from a parent descriptor alone.

Before a rating batch, `MetadataRecoveryInspector.prepareWriteTree` takes a nonblocking exclusive
advisory `flock` on the frozen root and scans the recovery namespace exactly once in O(N) tree time.
Only a complete clean scan issues a short-lived authorization containing the scanned parent
directory identities; each asset then performs an O(1) parent check. Dirty or truncated scans do
not authorize writes. Any write/verification failure or cleanup warning invalidates the batch
authorization, stops the remainder, and forces a new full-root preflight on the next action. The
lock is cooperative, not a mandatory filesystem namespace lock.

The app also wraps the complete capability-bound write and durable readback in one
`NSFileCoordinator` operation. Embedded XMP uses a normal write intent because it updates the same
logical document; Finder color uses `contentIndependentMetadataOnly`; sidecar operations coordinate
the media read intent and the resolved existing-or-new sidecar write intent together. UMIS does not
use `.forReplacing` merely because its implementation happens to use a temporary plus atomic swap.
The URL supplied to the accessor must still equal the frozen capability path, and the route/
sidecar plan is recomputed inside the accessor; UMIS never follows a coordinator-supplied move.

Finder color mutation does not use a reconstructed pathname or `/dev/fd` URL metadata writer. Core
reads and writes exactly the held file descriptor's 32-byte `com.apple.FinderInfo` with
`fgetxattr`/`fsetxattr`, changes only mask `0x000E`, calls `fsync`, and reads the same descriptor back.
All other FinderInfo bytes and the independent `_kMDItemUserTags` named-tag xattr are preserved.

The supported threat model includes UMIS processes cooperating through the app-wide writer gate and
root `flock`, plus ordinary `NSFilePresenter`-aware applications cooperating through
`NSFileCoordinator`. It excludes a malicious same-UID process that enumerates a random private
recovery directory and replaces a leaf in the interval between its last identity check and
`unlinkat`. Preventing that attack absolutely would require retaining one full original per update
indefinitely, which is outside the application's capacity and performance requirements. External
deletion after a verified durable commit is likewise a later external action, not a failed UMIS
commit.

## Format policy

UMISCore's current policy asks this bridge to attempt embedded XMP for these candidates:

- still images: JPEG (`.jpg`, `.jpeg`), TIFF (`.tif`, `.tiff`), DNG, PSD, PNG, GIF;
- ISO base media candidates: MOV, MP4, M4V, M4A.

Each candidate is still runtime-probed. Embedded write is available only if the actual bytes are accepted by an Adobe smart handler, the selected handler is neither sidecar nor folder-based, `CanPutXMP` succeeds, and safe update is available. A matching suffix alone is never a success guarantee. Corrupt, unusual, encrypted, unsupported-codec/container, or handler-incompatible files can be rejected.

UMIS deliberately uses an XMP sidecar fallback for:

- manufacturer camera RAW formats other than DNG;
- HEIC/HEIF;
- MXF and R3D;
- unknown or otherwise unsupported formats;
- MOV/MP4/M4V/M4A when embedded rewrite would be unsafe for the configured file-size or free-space limits, or when an existing UMIS compatibility sidecar has already been selected.

Manufacturer RAW uses the conventional same-stem `.xmp` form under a strict naming policy. If two manufacturer RAW files in one directory would own the same stem-based sidecar (for example `A001.CR3` and `A001.NEF`), UMIS refuses both read and write instead of silently sharing a rating. On a case-sensitive volume it probes every bounded ASCII-case spelling of every allowlisted RAW extension with descriptor-relative `fstatat`; it never performs a directory-size-dependent enumeration. The probe is repeated around sidecar access so a newly introduced collision fails closed. HEIC, MXF, R3D, unknown formats, and large/disk-constrained dynamic media use an appended-name sidecar such as `clip.mov.xmp`; this avoids silently colliding with a same-stem RAW/JPEG pair. The bridge itself never manufactures a sidecar: its embedded API returns an unavailable/error status and UMISCore owns the explicit fallback decision.

The app-facing sidecar route is descriptor-relative as well: UMISCore resolves only the strict
sidecar leaf within the held parent, rejects symlink/hardlink/non-regular media and sidecars, reads
with `openat`, creates temps with `O_EXCL`, and commits with `RENAME_EXCL` for a new packet or a
verified `RENAME_SWAP` for replacement. File data and the parent directory are synchronized before
success is returned. Existing mode, ACLs, and unrelated xattrs are copied through held descriptors.

Sidecar fallback stores standards-shaped XMP and preserves the original media bytes, but it is described in the UI as a compatibility fallback rather than as verified universal Adobe interoperability for every nonstandard media type. File movement must keep the media and sidecar together. Adobe application behavior for a particular extension/version must be validated with representative production files before making a stronger compatibility claim.

## Large video and space policy

Adobe's safe path may need a temporary file comparable in size to the original. For dynamic media, UMISCore therefore performs a capacity preflight and uses a compatibility sidecar when the file meets the configured large-file threshold, the volume is not suitable for a local embedded rewrite, available capacity cannot be established, or capacity is less than the media size plus the configured reserve.

This preflight is risk reduction, not a promise that a rewrite will fit: filesystem metadata, copy-on-write behavior, quotas, concurrent disk use, and handler-specific expansion can change actual demand. The C bridge maps `ENOSPC`/quota failures to a no-space result and only reports success after readback verification and durability synchronization.

## Scope outside the bridge

UMISCore and the app UI enforce additional workflow restrictions that are intentionally not encoded in this reusable C ABI, including prohibition of rating mutation while a latest verified receipt is attached, fail-closed local/internal/non-ejectable/non-removable/read-write volume evidence, root/ancestor/mount identity, operation-wide mutual exclusion, media-pipeline quiescence, recovery authorization, `NSFileCoordinator`, exact-FD Finder color updates, and user-visible fallback/recovery warnings. Callers must not bypass those higher-level gates by invoking the C bridge directly.
