#ifndef UMIS_XMP_BRIDGE_H
#define UMIS_XMP_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

#define UMIS_XMP_BRIDGE_ABI_VERSION 3u
#define UMIS_XMP_RECOVERY_LEAF_CAPACITY 128u

#if defined(__GNUC__)
#define UMIS_XMP_EXPORT __attribute__((visibility("default")))
#else
#define UMIS_XMP_EXPORT
#endif

/// A fixed-width status is part of the C ABI. Adobe's macOS libraries require the bridge
/// translation unit to use `-fshort-enums`; exposing a C enum here would therefore give Swift and
/// the compiled bridge different return-value ABIs. Keep the public type explicitly 32-bit.
typedef uint32_t UMISXMPStatus;
enum {
    UMIS_XMP_STATUS_OK = 0,
    UMIS_XMP_STATUS_INVALID_ARGUMENT = 1,
    UMIS_XMP_STATUS_INVALID_RATING = 2,
    UMIS_XMP_STATUS_INITIALIZATION_FAILED = 3,
    UMIS_XMP_STATUS_FILE_NOT_FOUND = 4,
    UMIS_XMP_STATUS_SYMLINK_REJECTED = 5,
    UMIS_XMP_STATUS_NOT_REGULAR_FILE = 6,
    UMIS_XMP_STATUS_HARD_LINK_REJECTED = 7,
    UMIS_XMP_STATUS_CONCURRENT_MODIFICATION = 8,
    UMIS_XMP_STATUS_NO_SMART_HANDLER = 9,
    UMIS_XMP_STATUS_EMBEDDED_UPDATE_UNAVAILABLE = 10,
    UMIS_XMP_STATUS_SAFE_UPDATE_UNAVAILABLE = 11,
    UMIS_XMP_STATUS_READ_ONLY = 12,
    UMIS_XMP_STATUS_NO_SPACE = 13,
    UMIS_XMP_STATUS_MALFORMED_XMP = 14,
    UMIS_XMP_STATUS_VERIFICATION_FAILED = 15,
    UMIS_XMP_STATUS_IO_ERROR = 16,
    UMIS_XMP_STATUS_XMP_ERROR = 17,
    UMIS_XMP_STATUS_INTERNAL_ERROR = 18
};

typedef struct UMISXMPFileIdentity {
    uint64_t device;
    uint64_t inode;
    int64_t byte_size;
    int64_t modified_seconds;
    int64_t modified_nanoseconds;
} UMISXMPFileIdentity;

typedef struct UMISXMPProbeResult {
    uint32_t abi_version;
    uint32_t xmp_file_format;
    uint32_t handler_flags;
    uint8_t has_smart_handler;
    uint8_t can_read_embedded_xmp;
    uint8_t can_put_embedded_xmp;
    uint8_t supports_safe_update;
    uint8_t handler_uses_sidecar;
    uint8_t handler_owns_file;
    uint8_t reserved[2];
    UMISXMPFileIdentity identity;
} UMISXMPProbeResult;

typedef struct UMISXMPRatingResult {
    int32_t rating;
    uint8_t has_explicit_rating;
    uint8_t has_pending_recovery;
    uint8_t reserved[2];
    UMISXMPFileIdentity identity;
    uint64_t recovery_token;
    char recovery_directory_leaf[UMIS_XMP_RECOVERY_LEAF_CAPACITY];
} UMISXMPRatingResult;

typedef struct UMISXMPRecoveryFinalizeResult {
    uint32_t abi_version;
    uint8_t cleanup_completed;
    uint8_t original_backup_retained;
    uint8_t cleanup_incomplete;
    uint8_t reserved;
    char recovery_directory_leaf[UMIS_XMP_RECOVERY_LEAF_CAPACITY];
} UMISXMPRecoveryFinalizeResult;

/// Initializes Adobe XMPCore and XMPFiles once for the lifetime of the process.
/// Every function also calls this lazily, so callers do not have to call it separately.
UMIS_XMP_EXPORT UMISXMPStatus umis_xmp_initialize(
    char *error_message,
    size_t error_message_capacity
);

/// Probes the smart handler selected by Adobe XMPFiles. Packet scanning is deliberately disabled:
/// UMIS only performs embedded writes through a registered format handler.
UMIS_XMP_EXPORT UMISXMPStatus umis_xmp_probe_file(
    const char *utf8_path,
    const UMISXMPFileIdentity *expected_identity,
    UMISXMPProbeResult *result,
    char *error_message,
    size_t error_message_capacity
);

/// Reads xmp:Rating through the selected smart handler. Missing Rating is returned as zero with
/// has_explicit_rating set to zero. The file identity is checked before and after parsing.
UMIS_XMP_EXPORT UMISXMPStatus umis_xmp_read_embedded_rating(
    const char *utf8_path,
    const UMISXMPFileIdentity *expected_identity,
    UMISXMPRatingResult *result,
    char *error_message,
    size_t error_message_capacity
);

/// Descriptor-capability variants. `parent_directory_fd` is borrowed for the duration of the call
/// and `utf8_leaf_name` must be exactly one non-dot path component. The bridge duplicates the
/// directory descriptor, opens the media with openat/O_NOFOLLOW, and never derives mutation
/// authority from a display pathname. Safe-update temporary files and the atomic replacement stay
/// within that held directory capability.
UMIS_XMP_EXPORT UMISXMPStatus umis_xmp_probe_file_at(
    int32_t parent_directory_fd,
    const char *utf8_leaf_name,
    const UMISXMPFileIdentity *expected_identity,
    UMISXMPProbeResult *result,
    char *error_message,
    size_t error_message_capacity
);

UMIS_XMP_EXPORT UMISXMPStatus umis_xmp_read_embedded_rating_at(
    int32_t parent_directory_fd,
    const char *utf8_leaf_name,
    const UMISXMPFileIdentity *expected_identity,
    UMISXMPRatingResult *result,
    char *error_message,
    size_t error_message_capacity
);

UMIS_XMP_EXPORT UMISXMPStatus umis_xmp_write_embedded_rating_at(
    int32_t parent_directory_fd,
    const char *utf8_leaf_name,
    const UMISXMPFileIdentity *expected_identity,
    int32_t rating,
    UMISXMPRatingResult *result,
    char *error_message,
    size_t error_message_capacity
);

/// Completes the second phase of a descriptor-capability safe update. The write call leaves the
/// old inode and a small manifest in a cryptographically named, mode-0700 recovery directory. The
/// Swift/Core caller must independently read back the committed rating, then call this function
/// with `upper_readback_verified=1`. A changed target/recovery witness never triggers cleanup: the
/// recovery directory is retained and reported in `result`. The recovery token is process-local,
/// single-use, and does not grant filesystem authority without the same parent directory FD.
UMIS_XMP_EXPORT UMISXMPStatus umis_xmp_finalize_recovery_at(
    int32_t parent_directory_fd,
    const char *utf8_leaf_name,
    const UMISXMPFileIdentity *expected_committed_identity,
    uint64_t recovery_token,
    uint8_t upper_readback_verified,
    UMISXMPRecoveryFinalizeResult *result,
    char *error_message,
    size_t error_message_capacity
);

#if defined(__cplusplus)
}
#endif

#endif
