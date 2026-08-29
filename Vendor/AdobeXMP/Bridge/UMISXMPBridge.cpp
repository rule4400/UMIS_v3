#include "UMISXMPBridge.h"

#include <copyfile.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <exception>
#include <limits>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#define TXMP_STRING_TYPE std::string
#define XMP_INCLUDE_XMPFILES 1
#include "public/include/XMP.incl_cpp"
#include "public/include/XMP.hpp"

#ifndef XMP_Throw
#define XMP_Throw(message, identifier) throw XMP_Error((identifier), (message))
#endif

namespace {

std::once_flag gInitializationOnce;
std::mutex gToolkitMutex;
bool gInitializationSucceeded = false;
std::string gInitializationError;

void clearError(char *message, size_t capacity) {
    if (message != nullptr && capacity > 0) message[0] = '\0';
}

void setError(char *message, size_t capacity, const std::string &value) {
    if (message == nullptr || capacity == 0) return;
    const size_t count = std::min(capacity - 1, value.size());
    memcpy(message, value.data(), count);
    message[count] = '\0';
}

std::string errnoMessage(const char *operation, const char *path, int errorNumber = errno) {
    std::string message(operation);
    message += " failed";
    if (path != nullptr) {
        message += " for ";
        message += path;
    }
    message += ": ";
    message += strerror(errorNumber);
    return message;
}

UMISXMPStatus statusForErrno(int errorNumber) {
    switch (errorNumber) {
        case ENOENT: return UMIS_XMP_STATUS_FILE_NOT_FOUND;
        case EACCES:
        case EPERM:
        case EROFS: return UMIS_XMP_STATUS_READ_ONLY;
        case ENOSPC:
        case EDQUOT: return UMIS_XMP_STATUS_NO_SPACE;
        case ELOOP: return UMIS_XMP_STATUS_SYMLINK_REJECTED;
        default: return UMIS_XMP_STATUS_IO_ERROR;
    }
}

UMISXMPFileIdentity identityFromStat(const struct stat &value) {
    UMISXMPFileIdentity result{};
    result.device = static_cast<uint64_t>(value.st_dev);
    result.inode = static_cast<uint64_t>(value.st_ino);
    result.byte_size = static_cast<int64_t>(value.st_size);
    result.modified_seconds = static_cast<int64_t>(value.st_mtimespec.tv_sec);
    result.modified_nanoseconds = static_cast<int64_t>(value.st_mtimespec.tv_nsec);
    return result;
}

bool identitiesEqual(const UMISXMPFileIdentity &lhs, const UMISXMPFileIdentity &rhs) {
    return lhs.device == rhs.device
        && lhs.inode == rhs.inode
        && lhs.byte_size == rhs.byte_size
        && lhs.modified_seconds == rhs.modified_seconds
        && lhs.modified_nanoseconds == rhs.modified_nanoseconds;
}

struct FileSystemWitness {
    uint64_t device;
    uint64_t inode;
    int64_t byteSize;
    int64_t modifiedSeconds;
    int64_t modifiedNanoseconds;
    int64_t changedSeconds;
    int64_t changedNanoseconds;
    uint64_t linkCount;
    mode_t mode;
};

bool validLeafName(const char *leaf);

FileSystemWitness witnessFromStat(const struct stat &value) {
    return FileSystemWitness{
        static_cast<uint64_t>(value.st_dev),
        static_cast<uint64_t>(value.st_ino),
        static_cast<int64_t>(value.st_size),
        static_cast<int64_t>(value.st_mtimespec.tv_sec),
        static_cast<int64_t>(value.st_mtimespec.tv_nsec),
        static_cast<int64_t>(value.st_ctimespec.tv_sec),
        static_cast<int64_t>(value.st_ctimespec.tv_nsec),
        static_cast<uint64_t>(value.st_nlink),
        value.st_mode
    };
}

bool witnessesEqual(const FileSystemWitness &lhs, const FileSystemWitness &rhs) {
    return lhs.device == rhs.device
        && lhs.inode == rhs.inode
        && lhs.byteSize == rhs.byteSize
        && lhs.modifiedSeconds == rhs.modifiedSeconds
        && lhs.modifiedNanoseconds == rhs.modifiedNanoseconds
        && lhs.changedSeconds == rhs.changedSeconds
        && lhs.changedNanoseconds == rhs.changedNanoseconds
        && lhs.linkCount == rhs.linkCount
        && lhs.mode == rhs.mode;
}

bool witnessesSameObjectAndContent(const FileSystemWitness &lhs, const FileSystemWitness &rhs) {
    // A successful rename/swap updates ctime on APFS even though the inode, bytes and filesystem
    // metadata are unchanged. Use this only for the immediate post-rename comparison, then capture
    // a new full witness (including ctime) for every later recovery/readback decision.
    return lhs.device == rhs.device
        && lhs.inode == rhs.inode
        && lhs.byteSize == rhs.byteSize
        && lhs.modifiedSeconds == rhs.modifiedSeconds
        && lhs.modifiedNanoseconds == rhs.modifiedNanoseconds
        && lhs.linkCount == rhs.linkCount
        && lhs.mode == rhs.mode;
}

bool descriptorWitness(int descriptor, FileSystemWitness *witness, bool requireRegularSingleLink) {
    if (descriptor < 0 || witness == nullptr) return false;
    struct stat value{};
    if (fstat(descriptor, &value) != 0) return false;
    if (requireRegularSingleLink && (!S_ISREG(value.st_mode) || value.st_nlink != 1)) return false;
    *witness = witnessFromStat(value);
    return true;
}

bool leafWitness(
    int parentDescriptor,
    const char *leaf,
    FileSystemWitness *witness,
    bool requireRegularSingleLink
) {
    if (parentDescriptor < 0 || !validLeafName(leaf) || witness == nullptr) return false;
    struct stat value{};
    if (fstatat(parentDescriptor, leaf, &value, AT_SYMLINK_NOFOLLOW) != 0) return false;
    if (requireRegularSingleLink && (!S_ISREG(value.st_mode) || value.st_nlink != 1)) return false;
    *witness = witnessFromStat(value);
    return true;
}

class ScopedDescriptor {
public:
    explicit ScopedDescriptor(int value = -1) : value_(value) {}
    ScopedDescriptor(const ScopedDescriptor &) = delete;
    ScopedDescriptor &operator=(const ScopedDescriptor &) = delete;
    ~ScopedDescriptor() {
        if (value_ >= 0) close(value_);
    }

    int get() const { return value_; }

private:
    int value_;
};

bool validLeafName(const char *leaf) {
    if (leaf == nullptr || leaf[0] == '\0') return false;
    if (strcmp(leaf, ".") == 0 || strcmp(leaf, "..") == 0) return false;
    return strchr(leaf, '/') == nullptr && strlen(leaf) <= NAME_MAX;
}

UMISXMPStatus captureIdentityAt(
    int parentDescriptor,
    const char *leaf,
    UMISXMPFileIdentity *identity,
    char *errorMessage,
    size_t errorCapacity,
    bool rejectHardLinks
) {
    if (parentDescriptor < 0 || !validLeafName(leaf) || identity == nullptr) {
        setError(errorMessage, errorCapacity, "A directory descriptor and one valid leaf name are required");
        return UMIS_XMP_STATUS_INVALID_ARGUMENT;
    }
    struct stat parentStatus{};
    if (fstat(parentDescriptor, &parentStatus) != 0) {
        const int code = errno;
        setError(errorMessage, errorCapacity, errnoMessage("fstat parent capability", leaf, code));
        return statusForErrno(code);
    }
    if (!S_ISDIR(parentStatus.st_mode)) {
        setError(errorMessage, errorCapacity, "The supplied parent capability is not a directory");
        return UMIS_XMP_STATUS_INVALID_ARGUMENT;
    }
    struct stat value{};
    if (fstatat(parentDescriptor, leaf, &value, AT_SYMLINK_NOFOLLOW) != 0) {
        const int code = errno;
        setError(errorMessage, errorCapacity, errnoMessage("fstatat capability target", leaf, code));
        return statusForErrno(code);
    }
    if (S_ISLNK(value.st_mode)) {
        setError(errorMessage, errorCapacity, std::string("Symbolic links are not accepted: ") + leaf);
        return UMIS_XMP_STATUS_SYMLINK_REJECTED;
    }
    if (!S_ISREG(value.st_mode)) {
        setError(errorMessage, errorCapacity, std::string("Capability target is not a regular file: ") + leaf);
        return UMIS_XMP_STATUS_NOT_REGULAR_FILE;
    }
    if (rejectHardLinks && value.st_nlink != 1) {
        setError(errorMessage, errorCapacity, std::string("Hard-linked files are not modified: ") + leaf);
        return UMIS_XMP_STATUS_HARD_LINK_REJECTED;
    }
    *identity = identityFromStat(value);
    return UMIS_XMP_STATUS_OK;
}

UMISXMPStatus requireExpectedIdentityAt(
    int parentDescriptor,
    const char *leaf,
    const UMISXMPFileIdentity *expected,
    UMISXMPFileIdentity *current,
    char *errorMessage,
    size_t errorCapacity,
    bool rejectHardLinks
) {
    if (expected == nullptr) {
        setError(errorMessage, errorCapacity, "An expected file identity is required");
        return UMIS_XMP_STATUS_INVALID_ARGUMENT;
    }
    const UMISXMPStatus status = captureIdentityAt(
        parentDescriptor,
        leaf,
        current,
        errorMessage,
        errorCapacity,
        rejectHardLinks
    );
    if (status != UMIS_XMP_STATUS_OK) return status;
    if (!identitiesEqual(*expected, *current)) {
        setError(errorMessage, errorCapacity, std::string("Capability target identity changed: ") + leaf);
        return UMIS_XMP_STATUS_CONCURRENT_MODIFICATION;
    }
    return UMIS_XMP_STATUS_OK;
}

XMP_FileFormat formatHintForLeaf(const char *leaf) {
    if (!validLeafName(leaf)) return kXMP_UnknownFile;
    std::string name(leaf);
    const std::string::size_type dot = name.find_last_of('.');
    if (dot == std::string::npos || dot + 1 >= name.size()) return kXMP_UnknownFile;
    std::string extension = name.substr(dot + 1);
    std::transform(extension.begin(), extension.end(), extension.begin(), [](unsigned char value) {
        return static_cast<char>(tolower(value));
    });
    if (extension == "jpg" || extension == "jpeg") return kXMP_JPEGFile;
    if (extension == "tif" || extension == "tiff" || extension == "dng") return kXMP_TIFFFile;
    if (extension == "gif") return kXMP_GIFFile;
    if (extension == "png") return kXMP_PNGFile;
    if (extension == "psd") return kXMP_PhotoshopFile;
    if (extension == "mov") return kXMP_MOVFile;
    if (extension == "mp4" || extension == "m4v" || extension == "m4a") return kXMP_MPEG4File;
    return kXMP_UnknownFile;
}

bool synchronizeDescriptor(int descriptor) {
    int result = fcntl(descriptor, F_FULLFSYNC);
    if (result != 0 && (errno == EINVAL || errno == ENOTSUP)) {
        do {
            result = fsync(descriptor);
        } while (result != 0 && errno == EINTR);
    }
    return result == 0;
}

bool writeAllToDescriptor(int descriptor, const void *bytes, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        const ssize_t amount = write(
            descriptor,
            static_cast<const unsigned char *>(bytes) + offset,
            count - offset
        );
        if (amount < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (amount == 0) return false;
        offset += static_cast<size_t>(amount);
    }
    return true;
}

std::string randomRecoveryComponent(const char *prefix, const char *suffix) {
    std::array<unsigned char, 16> randomBytes{};
    arc4random_buf(randomBytes.data(), randomBytes.size());
    char encoded[33]{};
    for (size_t index = 0; index < randomBytes.size(); ++index) {
        snprintf(encoded + (index * 2), 3, "%02x", randomBytes[index]);
    }
    std::string result(prefix);
    result += encoded;
    result += suffix;
    return result;
}

std::string jsonEscaped(const char *raw) {
    std::string result;
    if (raw == nullptr) return result;
    for (const unsigned char value : std::string(raw)) {
        switch (value) {
            case '\"': result += "\\\""; break;
            case '\\': result += "\\\\"; break;
            case '\b': result += "\\b"; break;
            case '\f': result += "\\f"; break;
            case '\n': result += "\\n"; break;
            case '\r': result += "\\r"; break;
            case '\t': result += "\\t"; break;
            default:
                if (value < 0x20) {
                    char escaped[7]{};
                    snprintf(escaped, sizeof(escaped), "\\u%04x", value);
                    result += escaped;
                } else {
                    result.push_back(static_cast<char>(value));
                }
        }
    }
    return result;
}

class RecoveryContext {
public:
    struct Artifact {
        std::string leaf;
        int descriptor;
        FileSystemWitness witness;
        bool criticalOriginal;
    };

    static std::shared_ptr<RecoveryContext> Create(
        int borrowedParentDescriptor,
        const char *targetLeaf,
        int originalDescriptor,
        const UMISXMPFileIdentity &originalIdentity
    ) {
        std::shared_ptr<RecoveryContext> context(new RecoveryContext());
        context->parentDescriptor_ = fcntl(borrowedParentDescriptor, F_DUPFD_CLOEXEC, 0);
        if (context->parentDescriptor_ < 0) {
            XMP_Throw("Unable to duplicate recovery parent capability", kXMPErr_ExternalFailure);
        }
        struct stat parentStatus{};
        if (fstat(context->parentDescriptor_, &parentStatus) != 0 || !S_ISDIR(parentStatus.st_mode)) {
            XMP_Throw("Recovery parent capability is not a directory", kXMPErr_FilePathNotAFile);
        }
        context->parentDevice_ = static_cast<uint64_t>(parentStatus.st_dev);
        context->parentInode_ = static_cast<uint64_t>(parentStatus.st_ino);
        context->targetLeaf_ = targetLeaf == nullptr ? "" : targetLeaf;
        if (!descriptorWitness(originalDescriptor, &context->originalWitness_, true)
            || !identitiesEqual(identityFromWitness(context->originalWitness_), originalIdentity)) {
            XMP_Throw("Original XMP recovery witness changed", kXMPErr_ExternalFailure);
        }

        for (int attempt = 0; attempt < 128; ++attempt) {
            context->directoryLeaf_ = randomRecoveryComponent(".umis-xmp-recovery-", "");
            if (mkdirat(
                    context->parentDescriptor_,
                    context->directoryLeaf_.c_str(),
                    S_IRWXU
                ) == 0) {
                break;
            }
            if (errno != EEXIST) {
                XMP_Throw("Unable to create private XMP recovery directory", kXMPErr_WriteError);
            }
            context->directoryLeaf_.clear();
        }
        if (context->directoryLeaf_.empty()) {
            XMP_Throw("Unable to allocate a unique XMP recovery directory", kXMPErr_WriteError);
        }
        context->directoryDescriptor_ = openat(
            context->parentDescriptor_,
            context->directoryLeaf_.c_str(),
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        );
        if (context->directoryDescriptor_ < 0) {
            XMP_Throw("Unable to open private XMP recovery directory", kXMPErr_ExternalFailure);
        }
        if (fchmod(context->directoryDescriptor_, S_IRWXU) != 0) {
            XMP_Throw("Unable to restrict XMP recovery directory permissions", kXMPErr_WriteError);
        }
        if (!context->refreshDirectoryWitness(true)) {
            XMP_Throw("Private XMP recovery directory identity is invalid", kXMPErr_ExternalFailure);
        }

        context->pendingManifestDescriptor_ = openat(
            context->directoryDescriptor_,
            "manifest.pending.json",
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        );
        if (context->pendingManifestDescriptor_ < 0) {
            XMP_Throw("Unable to create XMP recovery manifest", kXMPErr_WriteError);
        }
        const std::string manifest = context->makePendingManifest();
        if (!writeAllToDescriptor(
                context->pendingManifestDescriptor_,
                manifest.data(),
                manifest.size()
            )
            || !synchronizeDescriptor(context->pendingManifestDescriptor_)
            || !context->bindPendingManifest()) {
            XMP_Throw("Unable to durably write XMP recovery manifest", kXMPErr_WriteError);
        }
        if (!synchronizeDescriptor(context->directoryDescriptor_)
            || !synchronizeDescriptor(context->parentDescriptor_)
            || !context->refreshDirectoryWitness(true)) {
            XMP_Throw("Unable to synchronize XMP recovery directory", kXMPErr_WriteError);
        }
        return context;
    }

    RecoveryContext(const RecoveryContext &) = delete;
    RecoveryContext &operator=(const RecoveryContext &) = delete;

    ~RecoveryContext() {
        for (Artifact &artifact : artifacts_) {
            if (artifact.descriptor >= 0) close(artifact.descriptor);
        }
        if (cleanupManifestDescriptor_ >= 0) close(cleanupManifestDescriptor_);
        if (sealedManifestDescriptor_ >= 0) close(sealedManifestDescriptor_);
        if (pendingManifestDescriptor_ >= 0) close(pendingManifestDescriptor_);
        if (directoryDescriptor_ >= 0) close(directoryDescriptor_);
        if (parentDescriptor_ >= 0) close(parentDescriptor_);
    }

    int directoryDescriptor() const { return directoryDescriptor_; }
    const std::string &directoryLeaf() const { return directoryLeaf_; }

    int createReplacement(std::string *leaf) {
        if (leaf == nullptr) XMP_Throw("A replacement leaf output is required", kXMPErr_BadParam);
        for (int attempt = 0; attempt < 128; ++attempt) {
            const std::string candidate = randomRecoveryComponent("replacement-", ".partial");
            const int descriptor = openat(
                directoryDescriptor_,
                candidate.c_str(),
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            );
            if (descriptor >= 0) {
                *leaf = candidate;
                return descriptor;
            }
            if (errno != EEXIST) {
                XMP_Throw("Unable to create private anchored XMP replacement", kXMPErr_WriteError);
            }
        }
        XMP_Throw("Unable to allocate private anchored XMP replacement", kXMPErr_WriteError);
    }

    bool bindArtifact(const std::string &leaf, int descriptor, bool criticalOriginal) {
        if (!validLeafName(leaf.c_str()) || descriptor < 0) return false;
        FileSystemWitness descriptorValue{};
        FileSystemWitness leafValue{};
        if (!descriptorWitness(descriptor, &descriptorValue, true)
            || !leafWitness(directoryDescriptor_, leaf.c_str(), &leafValue, true)
            || !witnessesEqual(descriptorValue, leafValue)) {
            return false;
        }
        const int duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0);
        if (duplicate < 0) return false;
        for (Artifact &artifact : artifacts_) {
            if (artifact.leaf == leaf) {
                close(artifact.descriptor);
                artifact = Artifact{leaf, duplicate, descriptorValue, criticalOriginal};
                return true;
            }
        }
        artifacts_.push_back(Artifact{leaf, duplicate, descriptorValue, criticalOriginal});
        return true;
    }

    bool sealCommittedTarget(int targetDescriptor, const char *targetLeaf) {
        if (targetLeaf == nullptr || targetLeaf_ != targetLeaf) return false;
        FileSystemWitness descriptorValue{};
        FileSystemWitness leafValue{};
        if (!descriptorWitness(targetDescriptor, &descriptorValue, true)
            || !leafWitness(parentDescriptor_, targetLeaf, &leafValue, true)
            || !witnessesEqual(descriptorValue, leafValue)) {
            return false;
        }
        for (Artifact &artifact : artifacts_) {
            FileSystemWitness held{};
            FileSystemWitness named{};
            if (!descriptorWitness(artifact.descriptor, &held, true)
                || !leafWitness(directoryDescriptor_, artifact.leaf.c_str(), &named, true)
                || !witnessesEqual(held, named)) {
                return false;
            }
            artifact.witness = held;
        }
        committedTargetWitness_ = descriptorValue;
        const std::string sealedManifest = makeSealedManifest();
        sealedManifestDescriptor_ = openat(
            directoryDescriptor_,
            "manifest.sealed.json",
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        );
        if (sealedManifestDescriptor_ < 0
            || !writeAllToDescriptor(
                sealedManifestDescriptor_,
                sealedManifest.data(),
                sealedManifest.size()
            )
            || !synchronizeDescriptor(sealedManifestDescriptor_)
            || !bindSealedManifest()
            || !validatePendingManifest()
            || !synchronizeDescriptor(targetDescriptor)
            || !synchronizeDescriptor(directoryDescriptor_)
            || !synchronizeDescriptor(parentDescriptor_)
            || !refreshDirectoryWitness(true)) {
            return false;
        }
        sealed_ = true;
        return true;
    }

    bool finalizeAfterUpperReadback(
        int borrowedParentDescriptor,
        const char *targetLeaf,
        const UMISXMPFileIdentity &expectedCommittedIdentity,
        bool upperReadbackVerified,
        bool *originalBackupRetained,
        bool *cleanupIncomplete,
        std::string *warning
    ) {
        const auto retain = [&](const std::string &reason) {
            bool criticalStillLinked = false;
            for (const Artifact &artifact : artifacts_) {
                if (!artifact.criticalOriginal) continue;
                struct stat value{};
                if (fstat(artifact.descriptor, &value) == 0 && value.st_nlink > 0) {
                    criticalStillLinked = true;
                }
            }
            if (originalBackupRetained != nullptr) *originalBackupRetained = criticalStillLinked;
            if (cleanupIncomplete != nullptr) *cleanupIncomplete = true;
            if (warning != nullptr) {
                *warning = reason;
                if (criticalStillLinked) {
                    *warning += "; original recovery data was retained in " + directoryLeaf_;
                } else {
                    *warning += "; the original backup is no longer linked, but cleanup residue remains in "
                        + directoryLeaf_;
                }
            }
            return false;
        };
        if (originalBackupRetained != nullptr) *originalBackupRetained = false;
        if (cleanupIncomplete != nullptr) *cleanupIncomplete = false;
        if (!upperReadbackVerified) {
            return retain("Upper-layer XMP readback was not verified");
        }
        if (!sealed_ || borrowedParentDescriptor < 0 || targetLeaf == nullptr || targetLeaf_ != targetLeaf) {
            return retain("Recovery transaction was not sealed for this target");
        }
        struct stat borrowedParentStatus{};
        if (fstat(borrowedParentDescriptor, &borrowedParentStatus) != 0
            || !S_ISDIR(borrowedParentStatus.st_mode)
            || static_cast<uint64_t>(borrowedParentStatus.st_dev) != parentDevice_
            || static_cast<uint64_t>(borrowedParentStatus.st_ino) != parentInode_) {
            return retain("Recovery parent capability changed");
        }
        ScopedDescriptor target(openat(
            borrowedParentDescriptor,
            targetLeaf,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        ));
        FileSystemWitness targetDescriptorWitness{};
        FileSystemWitness targetLeafWitness{};
        if (target.get() < 0
            || !descriptorWitness(target.get(), &targetDescriptorWitness, true)
            || !leafWitness(borrowedParentDescriptor, targetLeaf, &targetLeafWitness, true)
            || !witnessesEqual(targetDescriptorWitness, targetLeafWitness)
            || !witnessesEqual(targetDescriptorWitness, committedTargetWitness_)
            || !identitiesEqual(identityFromWitness(targetDescriptorWitness), expectedCommittedIdentity)) {
            return retain("Committed target identity changed before recovery cleanup");
        }
        if (!validateRecoveryDirectoryBinding()
            || !validateAllArtifacts()
            || !validatePendingManifest()
            || !validateSealedManifest()) {
            return retain("Private recovery content changed before cleanup");
        }

        std::stable_sort(
            artifacts_.begin(),
            artifacts_.end(),
            [](const Artifact &lhs, const Artifact &rhs) {
                return !lhs.criticalOriginal && rhs.criticalOriginal;
            }
        );
        bool removedCriticalOriginal = false;
        for (Artifact &artifact : artifacts_) {
            if (!validateCommittedTarget(target.get(), expectedCommittedIdentity)
                || !validateRecoveryDirectoryBinding()
                || !validateArtifact(artifact)) {
                return retain("Recovery cleanup precondition changed");
            }
            if (unlinkat(directoryDescriptor_, artifact.leaf.c_str(), 0) != 0) {
                return retain("Unable to remove a verified private recovery artifact");
            }
            struct stat after{};
            if (fstat(artifact.descriptor, &after) != 0 || after.st_nlink != 0) {
                return retain("Recovery artifact unlink could not be verified");
            }
            if (!synchronizeDescriptor(directoryDescriptor_) || !refreshDirectoryWitness(true)) {
                return retain("Recovery directory could not be synchronized during cleanup");
            }
            if (artifact.criticalOriginal) removedCriticalOriginal = true;
        }
        if (removedCriticalOriginal && !createAndBindCleanupManifest()) {
            return retain("Unable to record that the original recovery inode was removed");
        }
        if (!validateCommittedTarget(target.get(), expectedCommittedIdentity)
            || !validateRecoveryDirectoryBinding()
            || !validatePendingManifest()
            || !validateSealedManifest()
            || !validateCleanupManifest()) {
            return retain("Recovery manifest cleanup precondition changed");
        }
        // Keep the cleanup-state manifest linked until every older manifest is gone. The
        // inspector gives this manifest priority because it truthfully records that the old
        // original has already been unlinked. Removing it first could leave a sealed/pending
        // manifest after a crash and falsely imply that the original backup is recoverable.
        if (!validateCommittedTarget(target.get(), expectedCommittedIdentity)
            || !validateRecoveryDirectoryBinding()
            || !validatePendingManifest()
            || !validateSealedManifest()
            || !validateCleanupManifest()) {
            return retain("Sealed recovery manifest cleanup precondition changed");
        }
        if (unlinkat(directoryDescriptor_, "manifest.sealed.json", 0) != 0) {
            return retain("Unable to remove the verified sealed recovery manifest");
        }
        struct stat sealedManifestAfter{};
        if (fstat(sealedManifestDescriptor_, &sealedManifestAfter) != 0
            || sealedManifestAfter.st_nlink != 0) {
            return retain("Sealed recovery manifest unlink could not be verified");
        }
        if (!synchronizeDescriptor(directoryDescriptor_) || !refreshDirectoryWitness(true)) {
            return retain("Recovery directory could not be synchronized after sealed manifest cleanup");
        }
        if (!validateCommittedTarget(target.get(), expectedCommittedIdentity)
            || !validateRecoveryDirectoryBinding()
            || !validatePendingManifest()
            || !validateCleanupManifest()) {
            return retain("Pending recovery manifest cleanup precondition changed");
        }
        if (unlinkat(directoryDescriptor_, "manifest.pending.json", 0) != 0) {
            return retain("Unable to remove the verified pending recovery manifest");
        }
        struct stat pendingManifestAfter{};
        if (fstat(pendingManifestDescriptor_, &pendingManifestAfter) != 0
            || pendingManifestAfter.st_nlink != 0) {
            return retain("Pending recovery manifest unlink could not be verified");
        }
        if (!synchronizeDescriptor(directoryDescriptor_) || !refreshDirectoryWitness(true)) {
            return retain("Recovery directory could not be synchronized after pending manifest cleanup");
        }
        if (cleanupManifestDescriptor_ >= 0) {
            if (!validateCommittedTarget(target.get(), expectedCommittedIdentity)
                || !validateRecoveryDirectoryBinding()
                || !validateCleanupManifest()) {
                return retain("Cleanup-state manifest cleanup precondition changed");
            }
            if (unlinkat(directoryDescriptor_, "manifest.cleanup.json", 0) != 0) {
                return retain("Unable to remove the verified cleanup-state manifest");
            }
            struct stat cleanupManifestAfter{};
            if (fstat(cleanupManifestDescriptor_, &cleanupManifestAfter) != 0
                || cleanupManifestAfter.st_nlink != 0) {
                return retain("Cleanup-state manifest unlink could not be verified");
            }
            close(cleanupManifestDescriptor_);
            cleanupManifestDescriptor_ = -1;
            if (!synchronizeDescriptor(directoryDescriptor_) || !refreshDirectoryWitness(true)) {
                return retain("Recovery directory could not be synchronized after cleanup-state manifest removal");
            }
        }
        if (!validateCommittedTarget(target.get(), expectedCommittedIdentity)
            || !validateRecoveryDirectoryBinding()) {
            return retain("Recovery directory identity changed before removal");
        }
        if (unlinkat(parentDescriptor_, directoryLeaf_.c_str(), AT_REMOVEDIR) != 0) {
            return retain("Unable to remove the empty recovery directory");
        }
        struct stat directoryAfter{};
        struct stat namedDirectoryAfter{};
        errno = 0;
        const int namedDirectoryLookup = fstatat(
            parentDescriptor_,
            directoryLeaf_.c_str(),
            &namedDirectoryAfter,
            AT_SYMLINK_NOFOLLOW
        );
        const int namedDirectoryError = errno;
        if (fstat(directoryDescriptor_, &directoryAfter) != 0
            || static_cast<uint64_t>(directoryAfter.st_dev) != directoryWitness_.device
            || static_cast<uint64_t>(directoryAfter.st_ino) != directoryWitness_.inode
            || namedDirectoryLookup == 0
            || namedDirectoryError != ENOENT) {
            return retain("Recovery directory removal could not be verified");
        }
        if (!synchronizeDescriptor(parentDescriptor_)) {
            return retain("Recovery parent directory could not be synchronized");
        }
        if (warning != nullptr) warning->clear();
        if (originalBackupRetained != nullptr) *originalBackupRetained = false;
        if (cleanupIncomplete != nullptr) *cleanupIncomplete = false;
        return true;
    }

private:
    RecoveryContext()
        : parentDescriptor_(-1),
          directoryDescriptor_(-1),
          pendingManifestDescriptor_(-1),
          sealedManifestDescriptor_(-1),
          cleanupManifestDescriptor_(-1),
          parentDevice_(0),
          parentInode_(0),
          sealed_(false) {}

    static UMISXMPFileIdentity identityFromWitness(const FileSystemWitness &value) {
        UMISXMPFileIdentity result{};
        result.device = value.device;
        result.inode = value.inode;
        result.byte_size = value.byteSize;
        result.modified_seconds = value.modifiedSeconds;
        result.modified_nanoseconds = value.modifiedNanoseconds;
        return result;
    }

    static void appendWitnessJSON(std::string *json, const FileSystemWitness &value) {
        *json += "{\"device\":" + std::to_string(value.device);
        *json += ",\"inode\":" + std::to_string(value.inode);
        *json += ",\"byteSize\":" + std::to_string(value.byteSize);
        *json += ",\"modifiedSeconds\":" + std::to_string(value.modifiedSeconds);
        *json += ",\"modifiedNanoseconds\":" + std::to_string(value.modifiedNanoseconds);
        *json += ",\"changedSeconds\":" + std::to_string(value.changedSeconds);
        *json += ",\"changedNanoseconds\":" + std::to_string(value.changedNanoseconds);
        *json += ",\"mode\":" + std::to_string(static_cast<uint64_t>(value.mode));
        *json += ",\"linkCount\":" + std::to_string(value.linkCount) + "}";
    }

    std::string makePendingManifest() const {
        std::string manifest = "{\"schemaVersion\":1,\"kind\":\"embeddedXMP\",\"targetLeaf\":\"";
        manifest += jsonEscaped(targetLeaf_.c_str());
        manifest += "\",\"original\":";
        appendWitnessJSON(&manifest, originalWitness_);
        manifest += ",\"createdUnixSeconds\":" + std::to_string(static_cast<long long>(time(nullptr)));
        manifest += ",\"state\":\"pendingCommit\"}\n";
        return manifest;
    }

    std::string makeSealedManifest() const {
        std::string manifest = "{\"schemaVersion\":1,\"kind\":\"embeddedXMP\",\"targetLeaf\":\"";
        manifest += jsonEscaped(targetLeaf_.c_str());
        manifest += "\",\"original\":";
        appendWitnessJSON(&manifest, originalWitness_);
        manifest += ",\"committed\":";
        appendWitnessJSON(&manifest, committedTargetWitness_);
        manifest += ",\"artifacts\":[";
        for (size_t index = 0; index < artifacts_.size(); ++index) {
            if (index != 0) manifest += ",";
            manifest += "{\"leaf\":\"" + jsonEscaped(artifacts_[index].leaf.c_str()) + "\",\"criticalOriginal\":";
            manifest += artifacts_[index].criticalOriginal ? "true" : "false";
            manifest += ",\"witness\":";
            appendWitnessJSON(&manifest, artifacts_[index].witness);
            manifest += "}";
        }
        manifest += "],\"createdUnixSeconds\":" + std::to_string(static_cast<long long>(time(nullptr)));
        manifest += ",\"state\":\"awaitingUpperReadback\"}\n";
        return manifest;
    }

    std::string makeCleanupManifest() const {
        std::string manifest = "{\"schemaVersion\":1,\"kind\":\"embeddedXMP\",\"targetLeaf\":\"";
        manifest += jsonEscaped(targetLeaf_.c_str());
        manifest += "\",\"committed\":";
        appendWitnessJSON(&manifest, committedTargetWitness_);
        manifest += ",\"artifacts\":[],\"createdUnixSeconds\":"
            + std::to_string(static_cast<long long>(time(nullptr)));
        manifest += ",\"state\":\"committedOriginalRemoved\"}\n";
        return manifest;
    }

    bool bindPendingManifest() {
        FileSystemWitness descriptorValue{};
        FileSystemWitness leafValue{};
        if (!descriptorWitness(pendingManifestDescriptor_, &descriptorValue, true)
            || !leafWitness(directoryDescriptor_, "manifest.pending.json", &leafValue, true)
            || !witnessesEqual(descriptorValue, leafValue)) {
            return false;
        }
        pendingManifestWitness_ = descriptorValue;
        return true;
    }

    bool bindSealedManifest() {
        FileSystemWitness descriptorValue{};
        FileSystemWitness leafValue{};
        if (!descriptorWitness(sealedManifestDescriptor_, &descriptorValue, true)
            || !leafWitness(directoryDescriptor_, "manifest.sealed.json", &leafValue, true)
            || !witnessesEqual(descriptorValue, leafValue)) {
            return false;
        }
        sealedManifestWitness_ = descriptorValue;
        return true;
    }

    bool createAndBindCleanupManifest() {
        cleanupManifestDescriptor_ = openat(
            directoryDescriptor_,
            "manifest.cleanup.json",
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        );
        if (cleanupManifestDescriptor_ < 0) return false;
        const std::string manifest = makeCleanupManifest();
        if (!writeAllToDescriptor(
                cleanupManifestDescriptor_,
                manifest.data(),
                manifest.size()
            )
            || !synchronizeDescriptor(cleanupManifestDescriptor_)) {
            return false;
        }
        FileSystemWitness descriptorValue{};
        FileSystemWitness leafValue{};
        if (!descriptorWitness(cleanupManifestDescriptor_, &descriptorValue, true)
            || !leafWitness(directoryDescriptor_, "manifest.cleanup.json", &leafValue, true)
            || !witnessesEqual(descriptorValue, leafValue)
            || !synchronizeDescriptor(directoryDescriptor_)
            || !refreshDirectoryWitness(true)) {
            return false;
        }
        cleanupManifestWitness_ = descriptorValue;
        return true;
    }

    bool validatePendingManifest() const {
        FileSystemWitness descriptorValue{};
        FileSystemWitness leafValue{};
        return descriptorWitness(pendingManifestDescriptor_, &descriptorValue, true)
            && leafWitness(directoryDescriptor_, "manifest.pending.json", &leafValue, true)
            && witnessesEqual(descriptorValue, leafValue)
            && witnessesEqual(descriptorValue, pendingManifestWitness_);
    }

    bool validateSealedManifest() const {
        FileSystemWitness descriptorValue{};
        FileSystemWitness leafValue{};
        return descriptorWitness(sealedManifestDescriptor_, &descriptorValue, true)
            && leafWitness(directoryDescriptor_, "manifest.sealed.json", &leafValue, true)
            && witnessesEqual(descriptorValue, leafValue)
            && witnessesEqual(descriptorValue, sealedManifestWitness_);
    }

    bool validateCleanupManifest() const {
        if (cleanupManifestDescriptor_ < 0) return true;
        FileSystemWitness descriptorValue{};
        FileSystemWitness leafValue{};
        return descriptorWitness(cleanupManifestDescriptor_, &descriptorValue, true)
            && leafWitness(directoryDescriptor_, "manifest.cleanup.json", &leafValue, true)
            && witnessesEqual(descriptorValue, leafValue)
            && witnessesEqual(descriptorValue, cleanupManifestWitness_);
    }

    bool refreshDirectoryWitness(bool requireParentBinding) {
        FileSystemWitness descriptorValue{};
        FileSystemWitness leafValue{};
        if (!descriptorWitness(directoryDescriptor_, &descriptorValue, false)
            || !S_ISDIR(descriptorValue.mode)
            || (descriptorValue.mode & ACCESSPERMS) != S_IRWXU) {
            return false;
        }
        if (requireParentBinding) {
            if (!leafWitness(parentDescriptor_, directoryLeaf_.c_str(), &leafValue, false)
                || !S_ISDIR(leafValue.mode)
                || !witnessesEqual(descriptorValue, leafValue)) {
                return false;
            }
        }
        directoryWitness_ = descriptorValue;
        return true;
    }

    bool validateRecoveryDirectoryBinding() const {
        FileSystemWitness descriptorValue{};
        FileSystemWitness leafValue{};
        return descriptorWitness(directoryDescriptor_, &descriptorValue, false)
            && S_ISDIR(descriptorValue.mode)
            && leafWitness(parentDescriptor_, directoryLeaf_.c_str(), &leafValue, false)
            && S_ISDIR(leafValue.mode)
            && witnessesEqual(descriptorValue, leafValue)
            && witnessesEqual(descriptorValue, directoryWitness_);
    }

    bool validateArtifact(const Artifact &artifact) const {
        FileSystemWitness descriptorValue{};
        FileSystemWitness leafValue{};
        return descriptorWitness(artifact.descriptor, &descriptorValue, true)
            && leafWitness(directoryDescriptor_, artifact.leaf.c_str(), &leafValue, true)
            && witnessesEqual(descriptorValue, leafValue)
            && witnessesEqual(descriptorValue, artifact.witness);
    }

    bool validateAllArtifacts() const {
        for (const Artifact &artifact : artifacts_) {
            if (!validateArtifact(artifact)) return false;
        }
        return true;
    }

    bool validateCommittedTarget(
        int targetDescriptor,
        const UMISXMPFileIdentity &expectedCommittedIdentity
    ) const {
        FileSystemWitness descriptorValue{};
        FileSystemWitness leafValue{};
        return descriptorWitness(targetDescriptor, &descriptorValue, true)
            && leafWitness(parentDescriptor_, targetLeaf_.c_str(), &leafValue, true)
            && witnessesEqual(descriptorValue, leafValue)
            && witnessesEqual(descriptorValue, committedTargetWitness_)
            && identitiesEqual(identityFromWitness(descriptorValue), expectedCommittedIdentity);
    }

    int parentDescriptor_;
    int directoryDescriptor_;
    int pendingManifestDescriptor_;
    int sealedManifestDescriptor_;
    int cleanupManifestDescriptor_;
    uint64_t parentDevice_;
    uint64_t parentInode_;
    std::string targetLeaf_;
    std::string directoryLeaf_;
    FileSystemWitness originalWitness_{};
    FileSystemWitness directoryWitness_{};
    FileSystemWitness pendingManifestWitness_{};
    FileSystemWitness sealedManifestWitness_{};
    FileSystemWitness cleanupManifestWitness_{};
    FileSystemWitness committedTargetWitness_{};
    std::vector<Artifact> artifacts_;
    bool sealed_;
};

std::mutex gRecoveryMutex;
std::unordered_map<uint64_t, std::shared_ptr<RecoveryContext>> gPendingRecoveries;

uint64_t registerPendingRecovery(const std::shared_ptr<RecoveryContext> &context) {
    if (!context) return 0;
    std::lock_guard<std::mutex> lock(gRecoveryMutex);
    for (int attempt = 0; attempt < 128; ++attempt) {
        uint64_t token = 0;
        arc4random_buf(&token, sizeof(token));
        if (token != 0 && gPendingRecoveries.find(token) == gPendingRecoveries.end()) {
            gPendingRecoveries.emplace(token, context);
            return token;
        }
    }
    return 0;
}

std::shared_ptr<RecoveryContext> takePendingRecovery(uint64_t token) {
    std::lock_guard<std::mutex> lock(gRecoveryMutex);
    const auto found = gPendingRecoveries.find(token);
    if (found == gPendingRecoveries.end()) return nullptr;
    std::shared_ptr<RecoveryContext> context = found->second;
    gPendingRecoveries.erase(found);
    return context;
}

class AnchoredXMPIO final : public XMP_IO {
public:
    AnchoredXMPIO(
        int borrowedParentDescriptor,
        const char *leaf,
        bool readOnly,
        const UMISXMPFileIdentity &expectedIdentity
    )
        : parentDescriptor_(-1),
          descriptor_(-1),
          leaf_(leaf == nullptr ? "" : leaf),
          readOnly_(readOnly),
          isTemporary_(false),
          inRecoveryDirectory_(false),
          derivedTemporary_(nullptr),
          recoveryContext_(nullptr),
          expectedIdentity_(expectedIdentity),
          expectedChangeTime_{} {
        if (borrowedParentDescriptor < 0 || !validLeafName(leaf)) {
            XMP_Throw("Invalid parent descriptor or leaf name", kXMPErr_BadParam);
        }
        parentDescriptor_ = fcntl(borrowedParentDescriptor, F_DUPFD_CLOEXEC, 0);
        if (parentDescriptor_ < 0) {
            XMP_Throw("Unable to duplicate parent directory descriptor", kXMPErr_ExternalFailure);
        }
        struct stat parentStatus{};
        if (fstat(parentDescriptor_, &parentStatus) != 0 || !S_ISDIR(parentStatus.st_mode)) {
            close(parentDescriptor_);
            parentDescriptor_ = -1;
            XMP_Throw("Parent descriptor is not an open directory", kXMPErr_FilePathNotAFile);
        }
        const int flags = (readOnly_ ? O_RDONLY : O_RDWR) | O_CLOEXEC | O_NOFOLLOW;
        descriptor_ = openat(parentDescriptor_, leaf_.c_str(), flags);
        if (descriptor_ < 0) {
            close(parentDescriptor_);
            parentDescriptor_ = -1;
            XMP_Throw("Unable to open the capability target", kXMPErr_FilePermission);
        }
        if (!descriptorMatches(expectedIdentity_, true) || !leafMatches(expectedIdentity_, true)) {
            close(descriptor_);
            descriptor_ = -1;
            close(parentDescriptor_);
            parentDescriptor_ = -1;
            XMP_Throw("Capability identity changed while opening XMP I/O", kXMPErr_ExternalFailure);
        }
        refreshExpectedChangeTimeOrThrow();
        if (lseek(descriptor_, 0, SEEK_SET) < 0) {
            close(descriptor_);
            descriptor_ = -1;
            close(parentDescriptor_);
            parentDescriptor_ = -1;
            XMP_Throw("Unable to rewind capability target", kXMPErr_ExternalFailure);
        }
    }

    ~AnchoredXMPIO() override {
        try {
            DeleteTemp();
        } catch (...) {
        }
        // Never unlink a temporary name from a destructor. macOS has no public exact-FD unlink;
        // a name can be replaced after an identity check and before unlinkat. Failed transactions
        // are deliberately retained under the private recovery directory and its durable manifest.
        if (descriptor_ >= 0) close(descriptor_);
        if (parentDescriptor_ >= 0) close(parentDescriptor_);
    }

    XMP_Uns32 Read(void *buffer, XMP_Uns32 count, bool readAll = false) override {
        XMP_Uns32 total = 0;
        while (total < count) {
            const ssize_t amount = read(
                descriptor_,
                static_cast<unsigned char *>(buffer) + total,
                static_cast<size_t>(count - total)
            );
            if (amount < 0) {
                if (errno == EINTR) continue;
                XMP_Throw("Descriptor-backed XMP read failed", kXMPErr_ReadError);
            }
            if (amount == 0) break;
            total += static_cast<XMP_Uns32>(amount);
            if (!readAll) break;
        }
        if (readAll && total != count) {
            XMP_Throw("Descriptor-backed XMP read reached EOF", kXMPErr_ReadError);
        }
        return total;
    }

    void Write(const void *buffer, XMP_Uns32 count) override {
        if (readOnly_) XMP_Throw("Descriptor-backed XMP I/O is read-only", kXMPErr_FilePermission);
        size_t offset = 0;
        while (offset < count) {
            const ssize_t amount = write(
                descriptor_,
                static_cast<const unsigned char *>(buffer) + offset,
                static_cast<size_t>(count) - offset
            );
            if (amount < 0) {
                if (errno == EINTR) continue;
                if (errno == ENOSPC || errno == EDQUOT) {
                    XMP_Throw("Descriptor-backed XMP write has no space", kXMPErr_DiskSpace);
                }
                XMP_Throw("Descriptor-backed XMP write failed", kXMPErr_WriteError);
            }
            if (amount == 0) XMP_Throw("Descriptor-backed XMP write made no progress", kXMPErr_WriteError);
            offset += static_cast<size_t>(amount);
        }
    }

    XMP_Int64 Seek(XMP_Int64 offset, SeekMode mode) override {
        int origin = SEEK_SET;
        if (mode == kXMP_SeekFromCurrent) origin = SEEK_CUR;
        if (mode == kXMP_SeekFromEnd) origin = SEEK_END;

        const off_t current = lseek(descriptor_, 0, SEEK_CUR);
        const off_t length = currentLength();
        if (current < 0 || length < 0) XMP_Throw("Unable to inspect XMP I/O offset", kXMPErr_ExternalFailure);
        __int128 requested = offset;
        if (origin == SEEK_CUR) requested += current;
        if (origin == SEEK_END) requested += length;
        if (requested < 0 || requested > std::numeric_limits<off_t>::max()) {
            XMP_Throw("XMP I/O seek is outside the supported range", kXMPErr_BadParam);
        }
        const off_t absolute = static_cast<off_t>(requested);
        if (absolute > length) {
            if (readOnly_) XMP_Throw("Read-only XMP seek exceeds EOF", kXMPErr_ReadError);
            if (ftruncate(descriptor_, absolute) != 0) {
                if (errno == ENOSPC || errno == EDQUOT) {
                    XMP_Throw("XMP seek extension has no space", kXMPErr_DiskSpace);
                }
                XMP_Throw("Unable to extend XMP I/O", kXMPErr_WriteError);
            }
        }
        if (lseek(descriptor_, absolute, SEEK_SET) != absolute) {
            XMP_Throw("Descriptor-backed XMP seek failed", kXMPErr_ExternalFailure);
        }
        return static_cast<XMP_Int64>(absolute);
    }

    XMP_Int64 Length() override {
        const off_t length = currentLength();
        if (length < 0) XMP_Throw("Unable to read descriptor-backed XMP length", kXMPErr_ReadError);
        return static_cast<XMP_Int64>(length);
    }

    void Truncate(XMP_Int64 length) override {
        if (readOnly_) XMP_Throw("Descriptor-backed XMP I/O is read-only", kXMPErr_FilePermission);
        const off_t currentSize = currentLength();
        if (length < 0 || length > currentSize || length > std::numeric_limits<off_t>::max()) {
            XMP_Throw("Invalid descriptor-backed XMP truncate length", kXMPErr_BadParam);
        }
        if (ftruncate(descriptor_, static_cast<off_t>(length)) != 0) {
            XMP_Throw("Descriptor-backed XMP truncate failed", kXMPErr_WriteError);
        }
        const off_t current = lseek(descriptor_, 0, SEEK_CUR);
        if (current > length && lseek(descriptor_, static_cast<off_t>(length), SEEK_SET) < 0) {
            XMP_Throw("Unable to restore XMP offset after truncate", kXMPErr_ExternalFailure);
        }
    }

    XMP_IO *DeriveTemp() override {
        if (derivedTemporary_ != nullptr) return derivedTemporary_;
        if (readOnly_) XMP_Throw("Cannot derive XMP temp from read-only I/O", kXMPErr_FilePermission);
        UMISXMPFileIdentity currentOwnerIdentity{};
        if (!currentIdentity(&currentOwnerIdentity, true)) {
            XMP_Throw("Capability target changed before deriving XMP temp", kXMPErr_ExternalFailure);
        }
        // The primary media identity remains bound to the caller's scan-time fingerprint. A nested
        // temporary is expected to grow before a handler derives another temp, so it may refresh
        // only its own size/mtime after proving that fd and leaf still denote the same inode.
        if (!isTemporary_ && !identitiesEqual(currentOwnerIdentity, expectedIdentity_)) {
            XMP_Throw("Primary capability identity changed before deriving XMP temp", kXMPErr_ExternalFailure);
        }
        if (!isTemporary_ && !changeTimeMatchesExpected()) {
            XMP_Throw("Primary capability metadata changed before deriving XMP temp", kXMPErr_ExternalFailure);
        }
        expectedIdentity_ = currentOwnerIdentity;
        if (isTemporary_) refreshExpectedChangeTimeOrThrow();

        if (!recoveryContext_) {
            recoveryContext_ = RecoveryContext::Create(
                parentDescriptor_,
                leaf_.c_str(),
                descriptor_,
                expectedIdentity_
            );
        }
        std::string temporaryLeaf;
        const int temporaryDescriptor = recoveryContext_->createReplacement(&temporaryLeaf);

        // Carry ACLs, extended attributes and mode onto every derived temp before it can become
        // visible as the committed media file. The outer metadata snapshot restores timestamps
        // after CloseFile, but this copy also closes the protection gap inside AbsorbTemp and is
        // required for nested temps (the GIF handler derives a temp from another temp).
        if (fcopyfile(descriptor_, temporaryDescriptor, nullptr, COPYFILE_METADATA) != 0) {
            close(temporaryDescriptor);
            XMP_Throw("Unable to preserve metadata on anchored XMP temp", kXMPErr_WriteError);
        }

        struct stat temporaryStatus{};
        struct stat temporaryPathStatus{};
        if (fstat(temporaryDescriptor, &temporaryStatus) != 0
            || fstatat(
                recoveryContext_->directoryDescriptor(),
                temporaryLeaf.c_str(),
                &temporaryPathStatus,
                AT_SYMLINK_NOFOLLOW
            ) != 0
            || !S_ISREG(temporaryStatus.st_mode)
            || !S_ISREG(temporaryPathStatus.st_mode)
            || temporaryStatus.st_nlink != 1
            || temporaryPathStatus.st_nlink != 1
            || !identitiesEqual(identityFromStat(temporaryStatus), identityFromStat(temporaryPathStatus))) {
            close(temporaryDescriptor);
            XMP_Throw("New anchored XMP temp identity is invalid", kXMPErr_ExternalFailure);
        }
        const UMISXMPFileIdentity temporaryIdentity = identityFromStat(temporaryStatus);
        if (!recoveryContext_->bindArtifact(temporaryLeaf, temporaryDescriptor, false)) {
            close(temporaryDescriptor);
            XMP_Throw("Unable to bind anchored XMP replacement to recovery capability", kXMPErr_ExternalFailure);
        }

        const int temporaryParent = fcntl(
            recoveryContext_->directoryDescriptor(),
            F_DUPFD_CLOEXEC,
            0
        );
        if (temporaryParent < 0) {
            close(temporaryDescriptor);
            XMP_Throw("Unable to duplicate parent for anchored XMP temp", kXMPErr_ExternalFailure);
        }
        try {
            derivedTemporary_ = new AnchoredXMPIO(
                temporaryParent,
                temporaryDescriptor,
                temporaryLeaf,
                true,
                true,
                recoveryContext_,
                temporaryIdentity,
                temporaryStatus.st_ctimespec
            );
        } catch (...) {
            close(temporaryParent);
            close(temporaryDescriptor);
            throw;
        }
        return derivedTemporary_;
    }

    void AbsorbTemp() override {
        if (derivedTemporary_ == nullptr) XMP_Throw("No anchored XMP temp to absorb", kXMPErr_InternalFailure);
        if (!recoveryContext_ || derivedTemporary_->recoveryContext_ != recoveryContext_) {
            XMP_Throw("Anchored XMP recovery context changed", kXMPErr_ExternalFailure);
        }
        if (!descriptorMatches(expectedIdentity_, true) || !leafMatches(expectedIdentity_, true)) {
            XMP_Throw("Capability target changed before anchored XMP commit", kXMPErr_ExternalFailure);
        }
        if (!changeTimeMatchesExpected()) {
            XMP_Throw("Capability filesystem metadata changed before anchored XMP commit", kXMPErr_ExternalFailure);
        }
        // Refresh the derived file from the exact still-open original immediately before commit.
        // This preserves mode, ACLs, xattrs and timestamps without replaying an operation-start
        // snapshot that could overwrite a concurrent Finder tag change.
        if (fcopyfile(descriptor_, derivedTemporary_->descriptor_, nullptr, COPYFILE_METADATA) != 0) {
            XMP_Throw("Unable to preserve current metadata before anchored XMP commit", kXMPErr_WriteError);
        }
        if (!changeTimeMatchesExpected()) {
            XMP_Throw("Capability metadata changed while preparing anchored XMP commit", kXMPErr_ExternalFailure);
        }
        FileSystemWitness originalDescriptorWitness{};
        FileSystemWitness originalLeafWitness{};
        FileSystemWitness temporaryDescriptorWitness{};
        FileSystemWitness temporaryLeafWitness{};
        if (!descriptorWitness(descriptor_, &originalDescriptorWitness, true)
            || !leafWitness(parentDescriptor_, leaf_.c_str(), &originalLeafWitness, true)
            || !witnessesEqual(originalDescriptorWitness, originalLeafWitness)
            || !descriptorWitness(
                derivedTemporary_->descriptor_,
                &temporaryDescriptorWitness,
                true
            )
            || !leafWitness(
                derivedTemporary_->parentDescriptor_,
                derivedTemporary_->leaf_.c_str(),
                &temporaryLeafWitness,
                true
            )
            || !witnessesEqual(temporaryDescriptorWitness, temporaryLeafWitness)) {
            XMP_Throw("Anchored XMP temp fd and leaf no longer identify the same file", kXMPErr_ExternalFailure);
        }
        synchronizeDescriptorOrThrow(derivedTemporary_->descriptor_);

        // Rebind both names immediately before the only atomic namespace mutation. Any change
        // after this check is detected by the two post-swap comparisons; no rollback or unlink is
        // attempted on mismatch, so UMIS cannot delete an unrelated inode.
        FileSystemWitness originalImmediatelyBeforeSwap{};
        FileSystemWitness temporaryImmediatelyBeforeSwap{};
        if (!leafWitness(
                parentDescriptor_,
                leaf_.c_str(),
                &originalImmediatelyBeforeSwap,
                true
            )
            || !leafWitness(
                derivedTemporary_->parentDescriptor_,
                derivedTemporary_->leaf_.c_str(),
                &temporaryImmediatelyBeforeSwap,
                true
            )
            || !witnessesEqual(originalDescriptorWitness, originalImmediatelyBeforeSwap)
            || !witnessesEqual(temporaryDescriptorWitness, temporaryImmediatelyBeforeSwap)) {
            XMP_Throw("Anchored XMP identity changed immediately before swap", kXMPErr_ExternalFailure);
        }

        if (renameatx_np(
                derivedTemporary_->parentDescriptor_,
                derivedTemporary_->leaf_.c_str(),
                parentDescriptor_,
                leaf_.c_str(),
                RENAME_SWAP
            ) != 0) {
            XMP_Throw("Atomic anchored XMP swap failed", kXMPErr_WriteError);
        }

        FileSystemWitness swappedOriginal{};
        FileSystemWitness swappedTemporary{};
        const bool originalIsAtTemp = leafWitness(
            derivedTemporary_->parentDescriptor_,
            derivedTemporary_->leaf_.c_str(),
            &swappedOriginal,
            true
        ) && witnessesSameObjectAndContent(swappedOriginal, originalDescriptorWitness);
        const bool temporaryIsAtTarget = leafWitness(
            parentDescriptor_,
            leaf_.c_str(),
            &swappedTemporary,
            true
        ) && witnessesSameObjectAndContent(swappedTemporary, temporaryDescriptorWitness);
        if (!originalIsAtTemp || !temporaryIsAtTarget) {
            XMP_Throw("Anchored XMP compare-and-swap detected a replacement", kXMPErr_ExternalFailure);
        }
        if (inRecoveryDirectory_
            && !recoveryContext_->bindArtifact(leaf_, derivedTemporary_->descriptor_, false)) {
            XMP_Throw("Unable to bind nested committed XMP replacement", kXMPErr_ExternalFailure);
        }
        if (!recoveryContext_->bindArtifact(
                derivedTemporary_->leaf_,
                descriptor_,
                !inRecoveryDirectory_
            )) {
            XMP_Throw("Unable to bind old XMP data in private recovery storage", kXMPErr_ExternalFailure);
        }
        synchronizeDescriptorOrThrow(parentDescriptor_);
        if (derivedTemporary_->parentDescriptor_ != parentDescriptor_) {
            synchronizeDescriptorOrThrow(derivedTemporary_->parentDescriptor_);
        }

        close(descriptor_);
        descriptor_ = derivedTemporary_->descriptor_;
        derivedTemporary_->descriptor_ = -1;
        derivedTemporary_->isTemporary_ = false;
        derivedTemporary_->leaf_.clear();
        delete derivedTemporary_;
        derivedTemporary_ = nullptr;

        if (lseek(descriptor_, 0, SEEK_SET) < 0) {
            XMP_Throw("Unable to rewind committed anchored XMP file", kXMPErr_ExternalFailure);
        }
        if (!descriptorIdentity(&expectedIdentity_, true) || !leafMatches(expectedIdentity_, true)) {
            XMP_Throw("Anchored XMP commit identity verification failed", kXMPErr_ExternalFailure);
        }
        refreshExpectedChangeTimeOrThrow();
    }

    void DeleteTemp() override {
        if (derivedTemporary_ == nullptr) return;
        AnchoredXMPIO *temporary = derivedTemporary_;
        derivedTemporary_ = nullptr;
        delete temporary;
    }

    int descriptor() const { return descriptor_; }
    int parentDescriptor() const { return parentDescriptor_; }

    void synchronizeCommittedFile() const {
        synchronizeDescriptorOrThrow(descriptor_);
        synchronizeDescriptorOrThrow(parentDescriptor_);
    }

    bool publishRecoveryForUpperReadback(uint64_t *token, std::string *directoryLeaf) {
        if (token == nullptr || directoryLeaf == nullptr) return false;
        *token = 0;
        directoryLeaf->clear();
        // kXMPFiles_UpdateSafely is only considered complete in the capability API when the
        // pre-update inode is durably held for the independent Swift/Core readback phase.  A
        // handler that reports safe-update support but does not drive DeriveTemp/AbsorbTemp cannot
        // satisfy that contract, so fail closed instead of returning an unprotected success.
        if (!recoveryContext_) return false;
        if (!recoveryContext_->sealCommittedTarget(descriptor_, leaf_.c_str())) return false;
        const uint64_t registered = registerPendingRecovery(recoveryContext_);
        if (registered == 0) return false;
        *token = registered;
        *directoryLeaf = recoveryContext_->directoryLeaf();
        return true;
    }

    void reportRetainedRecovery(UMISXMPRatingResult *result) const {
        if (result == nullptr || !recoveryContext_) return;
        result->has_pending_recovery = 1;
        result->recovery_token = 0;
        const std::string &leaf = recoveryContext_->directoryLeaf();
        const size_t count = std::min(
            leaf.size(),
            static_cast<size_t>(UMIS_XMP_RECOVERY_LEAF_CAPACITY - 1)
        );
        memcpy(result->recovery_directory_leaf, leaf.data(), count);
        result->recovery_directory_leaf[count] = '\0';
    }

    bool currentIdentity(UMISXMPFileIdentity *identity, bool rejectHardLinks) const {
        return descriptorIdentity(identity, rejectHardLinks)
            && leafMatches(*identity, rejectHardLinks);
    }

    bool refreshIdentityAfterMetadataRestore(
        const UMISXMPFileIdentity &beforeRestore,
        UMISXMPFileIdentity *afterRestore
    ) {
        UMISXMPFileIdentity current{};
        if (!descriptorIdentity(&current, true) || !leafMatches(current, true)) return false;
        if (current.device != beforeRestore.device
            || current.inode != beforeRestore.inode
            || current.byte_size != beforeRestore.byte_size) {
            return false;
        }
        expectedIdentity_ = current;
        if (afterRestore != nullptr) *afterRestore = current;
        return true;
    }

private:
    AnchoredXMPIO(
        int ownedParentDescriptor,
        int ownedDescriptor,
        std::string leaf,
        bool isTemporary,
        bool inRecoveryDirectory,
        std::shared_ptr<RecoveryContext> recoveryContext,
        const UMISXMPFileIdentity &initialIdentity,
        const struct timespec &initialChangeTime
    )
        : parentDescriptor_(ownedParentDescriptor),
          descriptor_(ownedDescriptor),
          leaf_(std::move(leaf)),
          readOnly_(false),
          isTemporary_(isTemporary),
          inRecoveryDirectory_(inRecoveryDirectory),
          derivedTemporary_(nullptr),
          recoveryContext_(std::move(recoveryContext)),
          expectedIdentity_(initialIdentity),
          expectedChangeTime_(initialChangeTime) {}

    off_t currentLength() const {
        struct stat value{};
        if (fstat(descriptor_, &value) != 0) return -1;
        return value.st_size;
    }

    bool descriptorIdentity(UMISXMPFileIdentity *identity, bool rejectHardLinks) const {
        if (identity == nullptr) return false;
        struct stat value{};
        if (fstat(descriptor_, &value) != 0 || !S_ISREG(value.st_mode)) return false;
        if (rejectHardLinks && value.st_nlink != 1) return false;
        *identity = identityFromStat(value);
        return true;
    }

    bool descriptorMatches(const UMISXMPFileIdentity &expected, bool rejectHardLinks) const {
        UMISXMPFileIdentity current{};
        return descriptorIdentity(&current, rejectHardLinks) && identitiesEqual(current, expected);
    }

    bool identityAtLeaf(
        const char *leaf,
        UMISXMPFileIdentity *identity,
        bool rejectHardLinks
    ) const {
        struct stat value{};
        if (fstatat(parentDescriptor_, leaf, &value, AT_SYMLINK_NOFOLLOW) != 0) return false;
        if (!S_ISREG(value.st_mode)) return false;
        if (rejectHardLinks && value.st_nlink != 1) return false;
        *identity = identityFromStat(value);
        return true;
    }

    bool leafMatches(const UMISXMPFileIdentity &expected, bool rejectHardLinks) const {
        UMISXMPFileIdentity current{};
        return identityAtLeaf(leaf_.c_str(), &current, rejectHardLinks)
            && identitiesEqual(current, expected);
    }

    bool changeTimeMatchesExpected() const {
        struct stat value{};
        if (fstat(descriptor_, &value) != 0) return false;
        return value.st_ctimespec.tv_sec == expectedChangeTime_.tv_sec
            && value.st_ctimespec.tv_nsec == expectedChangeTime_.tv_nsec;
    }

    void refreshExpectedChangeTimeOrThrow() {
        struct stat value{};
        if (fstat(descriptor_, &value) != 0) {
            XMP_Throw("Unable to capture anchored XMP metadata witness", kXMPErr_ExternalFailure);
        }
        expectedChangeTime_ = value.st_ctimespec;
    }

    static void synchronizeDescriptorOrThrow(int descriptor) {
        if (!synchronizeDescriptor(descriptor)) {
            XMP_Throw("Unable to synchronize anchored XMP descriptor", kXMPErr_WriteError);
        }
    }

    int parentDescriptor_;
    int descriptor_;
    std::string leaf_;
    bool readOnly_;
    bool isTemporary_;
    bool inRecoveryDirectory_;
    AnchoredXMPIO *derivedTemporary_;
    std::shared_ptr<RecoveryContext> recoveryContext_;
    UMISXMPFileIdentity expectedIdentity_;
    struct timespec expectedChangeTime_;
};

class FailureRecoveryReporter {
public:
    FailureRecoveryReporter(AnchoredXMPIO *io, UMISXMPRatingResult *result)
        : io_(io), result_(result), completed_(false) {}
    FailureRecoveryReporter(const FailureRecoveryReporter &) = delete;
    FailureRecoveryReporter &operator=(const FailureRecoveryReporter &) = delete;
    ~FailureRecoveryReporter() {
        if (!completed_ && io_ != nullptr) io_->reportRetainedRecovery(result_);
    }
    void markCompleted() { completed_ = true; }

private:
    AnchoredXMPIO *io_;
    UMISXMPRatingResult *result_;
    bool completed_;
};

UMISXMPStatus captureIdentity(
    const char *path,
    UMISXMPFileIdentity *identity,
    char *errorMessage,
    size_t errorCapacity,
    bool rejectHardLinks
) {
    if (path == nullptr || path[0] == '\0' || identity == nullptr) {
        setError(errorMessage, errorCapacity, "A non-empty UTF-8 path and identity output are required");
        return UMIS_XMP_STATUS_INVALID_ARGUMENT;
    }
    struct stat value{};
    if (lstat(path, &value) != 0) {
        const int code = errno;
        setError(errorMessage, errorCapacity, errnoMessage("lstat", path, code));
        return statusForErrno(code);
    }
    if (S_ISLNK(value.st_mode)) {
        setError(errorMessage, errorCapacity, std::string("Symbolic links are not accepted: ") + path);
        return UMIS_XMP_STATUS_SYMLINK_REJECTED;
    }
    if (!S_ISREG(value.st_mode)) {
        setError(errorMessage, errorCapacity, std::string("Path is not a regular file: ") + path);
        return UMIS_XMP_STATUS_NOT_REGULAR_FILE;
    }
    if (rejectHardLinks && value.st_nlink != 1) {
        setError(errorMessage, errorCapacity, std::string("Hard-linked files are not modified: ") + path);
        return UMIS_XMP_STATUS_HARD_LINK_REJECTED;
    }
    *identity = identityFromStat(value);
    return UMIS_XMP_STATUS_OK;
}

UMISXMPStatus requireExpectedIdentity(
    const char *path,
    const UMISXMPFileIdentity *expected,
    UMISXMPFileIdentity *current,
    char *errorMessage,
    size_t errorCapacity,
    bool rejectHardLinks
) {
    if (expected == nullptr) {
        setError(errorMessage, errorCapacity, "An expected file identity is required");
        return UMIS_XMP_STATUS_INVALID_ARGUMENT;
    }
    const UMISXMPStatus captureStatus = captureIdentity(
        path,
        current,
        errorMessage,
        errorCapacity,
        rejectHardLinks
    );
    if (captureStatus != UMIS_XMP_STATUS_OK) return captureStatus;
    if (!identitiesEqual(*expected, *current)) {
        setError(errorMessage, errorCapacity, std::string("File identity changed before XMP access: ") + path);
        return UMIS_XMP_STATUS_CONCURRENT_MODIFICATION;
    }
    return UMIS_XMP_STATUS_OK;
}

void initializeToolkitOnce() {
    try {
        if (!SXMPMeta::Initialize()) {
            gInitializationError = "SXMPMeta::Initialize returned false";
            return;
        }
        if (!SXMPFiles::Initialize(kXMPFiles_ServerMode)) {
            gInitializationError = "SXMPFiles::Initialize returned false";
            SXMPMeta::Terminate();
            return;
        }
        gInitializationSucceeded = true;
    } catch (const XMP_Error &error) {
        gInitializationError = error.GetErrMsg();
    } catch (const std::exception &error) {
        gInitializationError = error.what();
    } catch (...) {
        gInitializationError = "Unknown exception while initializing Adobe XMP Toolkit";
    }
}

UMISXMPStatus ensureInitialized(char *errorMessage, size_t errorCapacity) {
    std::call_once(gInitializationOnce, initializeToolkitOnce);
    if (gInitializationSucceeded) return UMIS_XMP_STATUS_OK;
    setError(errorMessage, errorCapacity, gInitializationError);
    return UMIS_XMP_STATUS_INITIALIZATION_FAILED;
}

UMISXMPStatus xmpExceptionStatus(const XMP_Error &error) {
    switch (error.GetID()) {
        case kXMPErr_NoFileHandler: return UMIS_XMP_STATUS_NO_SMART_HANDLER;
        case kXMPErr_FilePermission: return UMIS_XMP_STATUS_READ_ONLY;
        case kXMPErr_BadXML:
        case kXMPErr_BadXMP:
        case kXMPErr_BadRDF: return UMIS_XMP_STATUS_MALFORMED_XMP;
        case kXMPErr_Unavailable: return UMIS_XMP_STATUS_SAFE_UPDATE_UNAVAILABLE;
        case kXMPErr_DiskSpace: return UMIS_XMP_STATUS_NO_SPACE;
        case kXMPErr_ReadError:
        case kXMPErr_WriteError: return UMIS_XMP_STATUS_IO_ERROR;
        case kXMPErr_ExternalFailure: return UMIS_XMP_STATUS_CONCURRENT_MODIFICATION;
        default: return UMIS_XMP_STATUS_XMP_ERROR;
    }
}

bool handlerSupportsSafeUpdate(XMP_OptionBits handlerFlags) {
    // This is Adobe's exact CloseFile(kXMPFiles_UpdateSafely) predicate in the pinned SDK
    // (XMPFiles/source/XMPFiles.cpp): non-owning handlers use XMPFiles' common DeriveTemp/
    // AbsorbTemp safe-update path, while owning handlers must advertise AllowsSafeUpdate.
    return (handlerFlags & kXMPFiles_AllowsSafeUpdate) != 0
        || (handlerFlags & kXMPFiles_HandlerOwnsFile) == 0;
}

bool handlerWritesEmbeddedXMP(XMP_OptionBits handlerFlags) {
    return (handlerFlags & kXMPFiles_UsesSidecarXMP) == 0
        && (handlerFlags & kXMPFiles_FolderBasedFormat) == 0;
}

bool parseRating(const std::string &raw, int32_t *rating) {
    if (rating == nullptr || raw.empty()) return false;
    char *end = nullptr;
    errno = 0;
    const double value = strtod(raw.c_str(), &end);
    if (errno != 0 || end == raw.c_str() || end == nullptr || *end != '\0' || !isfinite(value)) {
        return false;
    }
    if (value < -1.0 || value > 5.0 || trunc(value) != value) return false;
    *rating = static_cast<int32_t>(value);
    return true;
}

UMISXMPStatus extractRating(
    const SXMPMeta &metadata,
    int32_t *rating,
    uint8_t *hasExplicitRating,
    char *errorMessage,
    size_t errorCapacity
) {
    std::string raw;
    XMP_OptionBits options = 0;
    const bool exists = metadata.GetProperty(kXMP_NS_XMP, "Rating", &raw, &options);
    if (!exists) {
        *rating = 0;
        *hasExplicitRating = 0;
        return UMIS_XMP_STATUS_OK;
    }
    int32_t parsed = 0;
    if (!parseRating(raw, &parsed)) {
        setError(errorMessage, errorCapacity, "xmp:Rating is not one of the supported integral values -1...5");
        return UMIS_XMP_STATUS_MALFORMED_XMP;
    }
    *rating = parsed;
    *hasExplicitRating = 1;
    return UMIS_XMP_STATUS_OK;
}

class DescriptorMetadataSnapshot {
public:
    DescriptorMetadataSnapshot() : descriptor_(-1) {}
    DescriptorMetadataSnapshot(const DescriptorMetadataSnapshot &) = delete;
    DescriptorMetadataSnapshot &operator=(const DescriptorMetadataSnapshot &) = delete;
    ~DescriptorMetadataSnapshot() {
        if (descriptor_ >= 0) close(descriptor_);
    }

    UMISXMPStatus capture(
        int sourceDescriptor,
        const UMISXMPFileIdentity &expectedIdentity,
        char *errorMessage,
        size_t errorCapacity
    ) {
        struct stat sourceStatus{};
        if (fstat(sourceDescriptor, &sourceStatus) != 0) {
            const int code = errno;
            setError(errorMessage, errorCapacity, errnoMessage("fstat capability metadata source", nullptr, code));
            return statusForErrno(code);
        }
        if (!S_ISREG(sourceStatus.st_mode)) return UMIS_XMP_STATUS_NOT_REGULAR_FILE;
        if (sourceStatus.st_nlink != 1) return UMIS_XMP_STATUS_HARD_LINK_REJECTED;
        if (!identitiesEqual(identityFromStat(sourceStatus), expectedIdentity)) {
            setError(errorMessage, errorCapacity, "Capability file changed before metadata snapshot");
            return UMIS_XMP_STATUS_CONCURRENT_MODIFICATION;
        }

        char pattern[] = "/tmp/umis-xmp-metadata.XXXXXX";
        descriptor_ = mkstemp(pattern);
        if (descriptor_ < 0) {
            const int code = errno;
            setError(errorMessage, errorCapacity, errnoMessage("mkstemp capability metadata", nullptr, code));
            return statusForErrno(code);
        }
        if (unlink(pattern) != 0) {
            const int code = errno;
            close(descriptor_);
            descriptor_ = -1;
            setError(errorMessage, errorCapacity, errnoMessage("unlink anonymous metadata snapshot", nullptr, code));
            return statusForErrno(code);
        }
        if (fchmod(descriptor_, S_IRUSR | S_IWUSR) != 0) {
            const int code = errno;
            setError(errorMessage, errorCapacity, errnoMessage("fchmod metadata snapshot", nullptr, code));
            return statusForErrno(code);
        }
        if (fcopyfile(sourceDescriptor, descriptor_, nullptr, COPYFILE_METADATA) != 0) {
            const int code = errno;
            setError(errorMessage, errorCapacity, errnoMessage("fcopyfile metadata snapshot", nullptr, code));
            return statusForErrno(code);
        }
        return UMIS_XMP_STATUS_OK;
    }

    UMISXMPStatus restore(
        int destinationDescriptor,
        char *errorMessage,
        size_t errorCapacity
    ) const {
        if (descriptor_ < 0) {
            setError(errorMessage, errorCapacity, "Descriptor metadata snapshot was not created");
            return UMIS_XMP_STATUS_INTERNAL_ERROR;
        }
        if (fcopyfile(descriptor_, destinationDescriptor, nullptr, COPYFILE_METADATA) != 0) {
            const int code = errno;
            setError(errorMessage, errorCapacity, errnoMessage("fcopyfile capability metadata restore", nullptr, code));
            return statusForErrno(code);
        }
        return UMIS_XMP_STATUS_OK;
    }

private:
    int descriptor_;
};

class MetadataSnapshot {
public:
    MetadataSnapshot() = default;
    MetadataSnapshot(const MetadataSnapshot &) = delete;
    MetadataSnapshot &operator=(const MetadataSnapshot &) = delete;

    ~MetadataSnapshot() {
        if (!path_.empty()) unlink(path_.c_str());
    }

    UMISXMPStatus capture(
        const char *sourcePath,
        const UMISXMPFileIdentity &expectedIdentity,
        char *errorMessage,
        size_t errorCapacity
    ) {
        ScopedDescriptor source(open(sourcePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
        if (source.get() < 0) {
            const int code = errno;
            setError(errorMessage, errorCapacity, errnoMessage("open metadata source", sourcePath, code));
            return statusForErrno(code);
        }
        struct stat sourceStatus{};
        if (fstat(source.get(), &sourceStatus) != 0) {
            const int code = errno;
            setError(errorMessage, errorCapacity, errnoMessage("fstat metadata source", sourcePath, code));
            return statusForErrno(code);
        }
        if (!S_ISREG(sourceStatus.st_mode)) {
            setError(errorMessage, errorCapacity, std::string("Metadata source is not regular: ") + sourcePath);
            return UMIS_XMP_STATUS_NOT_REGULAR_FILE;
        }
        if (sourceStatus.st_nlink != 1) {
            setError(errorMessage, errorCapacity, std::string("Hard-linked files are not modified: ") + sourcePath);
            return UMIS_XMP_STATUS_HARD_LINK_REJECTED;
        }
        if (!identitiesEqual(identityFromStat(sourceStatus), expectedIdentity)) {
            setError(errorMessage, errorCapacity, std::string("File changed before metadata snapshot: ") + sourcePath);
            return UMIS_XMP_STATUS_CONCURRENT_MODIFICATION;
        }

        std::string pattern(sourcePath);
        pattern += ".umis-xmp-metadata.XXXXXX";
        std::vector<char> writable(pattern.begin(), pattern.end());
        writable.push_back('\0');
        ScopedDescriptor descriptor(mkstemp(writable.data()));
        if (descriptor.get() < 0) {
            const int code = errno;
            setError(errorMessage, errorCapacity, errnoMessage("mkstemp", sourcePath, code));
            return statusForErrno(code);
        }
        path_ = writable.data();
        if (fchmod(descriptor.get(), S_IRUSR | S_IWUSR) != 0) {
            const int code = errno;
            setError(errorMessage, errorCapacity, errnoMessage("fchmod", path_.c_str(), code));
            return statusForErrno(code);
        }
        if (fcopyfile(source.get(), descriptor.get(), nullptr, COPYFILE_METADATA) != 0) {
            const int code = errno;
            setError(errorMessage, errorCapacity, errnoMessage("fcopyfile metadata snapshot", sourcePath, code));
            return statusForErrno(code);
        }
        return UMIS_XMP_STATUS_OK;
    }

    UMISXMPStatus restoreToDescriptor(
        int destinationDescriptor,
        const char *destinationPath,
        char *errorMessage,
        size_t errorCapacity
    ) const {
        if (path_.empty()) {
            setError(errorMessage, errorCapacity, "Filesystem metadata snapshot was not created");
            return UMIS_XMP_STATUS_INTERNAL_ERROR;
        }
        ScopedDescriptor source(open(path_.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
        if (source.get() < 0) {
            const int code = errno;
            setError(errorMessage, errorCapacity, errnoMessage("open metadata snapshot", path_.c_str(), code));
            return statusForErrno(code);
        }
        if (fcopyfile(source.get(), destinationDescriptor, nullptr, COPYFILE_METADATA) != 0) {
            const int code = errno;
            setError(errorMessage, errorCapacity, errnoMessage("fcopyfile metadata restore", destinationPath, code));
            return statusForErrno(code);
        }
        return UMIS_XMP_STATUS_OK;
    }

private:
    std::string path_;
};

UMISXMPStatus synchronizeCommittedFileDescriptor(
    int descriptor,
    const char *path,
    UMISXMPFileIdentity *identity,
    char *errorMessage,
    size_t errorCapacity
) {
    struct stat value{};
    if (fstat(descriptor, &value) != 0) {
        const int code = errno;
        setError(errorMessage, errorCapacity, errnoMessage("fstat after XMP write", path, code));
        return statusForErrno(code);
    }
    if (!S_ISREG(value.st_mode)) {
        setError(errorMessage, errorCapacity, std::string("Committed XMP path is not a regular file: ") + path);
        return UMIS_XMP_STATUS_NOT_REGULAR_FILE;
    }
    if (value.st_nlink != 1) {
        setError(errorMessage, errorCapacity, std::string("Committed XMP file became hard-linked: ") + path);
        return UMIS_XMP_STATUS_HARD_LINK_REJECTED;
    }
    int syncResult = fcntl(descriptor, F_FULLFSYNC);
    if (syncResult != 0 && (errno == EINVAL || errno == ENOTSUP)) syncResult = fsync(descriptor);
    if (syncResult != 0) {
        const int code = errno;
        setError(errorMessage, errorCapacity, errnoMessage("fsync after XMP write", path, code));
        return statusForErrno(code);
    }

    std::string parentPath(path);
    const std::string::size_type separator = parentPath.find_last_of('/');
    if (separator == std::string::npos) {
        parentPath = ".";
    } else if (separator == 0) {
        parentPath = "/";
    } else {
        parentPath.resize(separator);
    }
    int directoryDescriptor = -1;
    const std::string descriptorPrefix = "/dev/fd/";
    if (parentPath.compare(0, descriptorPrefix.size(), descriptorPrefix) == 0) {
        const char *rawDescriptor = parentPath.c_str() + descriptorPrefix.size();
        char *end = nullptr;
        errno = 0;
        const long parsed = strtol(rawDescriptor, &end, 10);
        if (errno == 0 && end != rawDescriptor && end != nullptr && *end == '\0'
            && parsed >= 0 && parsed <= INT_MAX) {
            directoryDescriptor = fcntl(static_cast<int>(parsed), F_DUPFD_CLOEXEC, 0);
        } else {
            errno = EINVAL;
        }
    } else {
        directoryDescriptor = open(
            parentPath.c_str(),
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        );
    }
    if (directoryDescriptor < 0) {
        const int code = errno;
        setError(
            errorMessage,
            errorCapacity,
            errnoMessage("open parent directory for synchronization", parentPath.c_str(), code)
        );
        return statusForErrno(code);
    }
    struct stat directoryStatus{};
    if (fstat(directoryDescriptor, &directoryStatus) != 0) {
        const int code = errno;
        close(directoryDescriptor);
        setError(
            errorMessage,
            errorCapacity,
            errnoMessage("fstat parent directory for synchronization", parentPath.c_str(), code)
        );
        return statusForErrno(code);
    }
    if (!S_ISDIR(directoryStatus.st_mode)) {
        const int code = ENOTDIR;
        close(directoryDescriptor);
        setError(
            errorMessage,
            errorCapacity,
            errnoMessage("validate parent directory for synchronization", parentPath.c_str(), code)
        );
        return statusForErrno(code);
    }
    int directorySyncResult = fcntl(directoryDescriptor, F_FULLFSYNC);
    if (directorySyncResult != 0 && (errno == EINVAL || errno == ENOTSUP)) {
        directorySyncResult = fsync(directoryDescriptor);
    }
    if (directorySyncResult != 0) {
        const int code = errno;
        close(directoryDescriptor);
        setError(
            errorMessage,
            errorCapacity,
            errnoMessage("fsync parent directory after XMP write", parentPath.c_str(), code)
        );
        return statusForErrno(code);
    }
    if (close(directoryDescriptor) != 0) {
        const int code = errno;
        setError(
            errorMessage,
            errorCapacity,
            errnoMessage("close synchronized parent directory", parentPath.c_str(), code)
        );
        return statusForErrno(code);
    }
    *identity = identityFromStat(value);
    return UMIS_XMP_STATUS_OK;
}

template <typename Operation>
UMISXMPStatus guardExceptions(
    char *errorMessage,
    size_t errorCapacity,
    Operation &&operation
) {
    clearError(errorMessage, errorCapacity);
    try {
        return operation();
    } catch (const XMP_Error &error) {
        setError(errorMessage, errorCapacity, error.GetErrMsg());
        return xmpExceptionStatus(error);
    } catch (const std::bad_alloc &) {
        setError(errorMessage, errorCapacity, "Out of memory while processing XMP");
        return UMIS_XMP_STATUS_INTERNAL_ERROR;
    } catch (const std::exception &error) {
        setError(errorMessage, errorCapacity, error.what());
        return UMIS_XMP_STATUS_INTERNAL_ERROR;
    } catch (...) {
        setError(errorMessage, errorCapacity, "Unknown C++ exception while processing XMP");
        return UMIS_XMP_STATUS_INTERNAL_ERROR;
    }
}

UMISXMPStatus readEmbeddedRatingLocked(
    const char *path,
    const UMISXMPFileIdentity *expectedIdentity,
    UMISXMPRatingResult *result,
    char *errorMessage,
    size_t errorCapacity
) {
    if (result == nullptr) {
        setError(errorMessage, errorCapacity, "A rating result is required");
        return UMIS_XMP_STATUS_INVALID_ARGUMENT;
    }
    *result = {};
    UMISXMPFileIdentity before{};
    UMISXMPStatus status = requireExpectedIdentity(
        path,
        expectedIdentity,
        &before,
        errorMessage,
        errorCapacity,
        false
    );
    if (status != UMIS_XMP_STATUS_OK) return status;

    SXMPFiles file;
    const XMP_OptionBits openFlags = kXMPFiles_OpenForRead | kXMPFiles_OpenUseSmartHandler;
    if (!file.OpenFile(path, kXMP_UnknownFile, openFlags)) {
        setError(errorMessage, errorCapacity, std::string("No Adobe smart handler accepted: ") + path);
        return UMIS_XMP_STATUS_NO_SMART_HANDLER;
    }
    XMP_OptionBits handlerFlags = 0;
    file.GetFileInfo(nullptr, nullptr, nullptr, &handlerFlags);
    if (!handlerWritesEmbeddedXMP(handlerFlags)) {
        file.CloseFile();
        setError(errorMessage, errorCapacity, "The selected Adobe handler does not use embedded XMP");
        return UMIS_XMP_STATUS_EMBEDDED_UPDATE_UNAVAILABLE;
    }
    SXMPMeta metadata;
    file.GetXMP(&metadata);
    file.CloseFile();

    status = extractRating(
        metadata,
        &result->rating,
        &result->has_explicit_rating,
        errorMessage,
        errorCapacity
    );
    if (status != UMIS_XMP_STATUS_OK) return status;
    UMISXMPFileIdentity after{};
    status = captureIdentity(path, &after, errorMessage, errorCapacity, false);
    if (status != UMIS_XMP_STATUS_OK) return status;
    if (!identitiesEqual(before, after)) {
        setError(errorMessage, errorCapacity, std::string("File changed while reading embedded XMP: ") + path);
        return UMIS_XMP_STATUS_CONCURRENT_MODIFICATION;
    }
    result->identity = after;
    return UMIS_XMP_STATUS_OK;
}

UMISXMPStatus readEmbeddedRatingAtLocked(
    int parentDescriptor,
    const char *leaf,
    const UMISXMPFileIdentity *expectedIdentity,
    UMISXMPRatingResult *result,
    char *errorMessage,
    size_t errorCapacity
) {
    if (result == nullptr) {
        setError(errorMessage, errorCapacity, "A rating result is required");
        return UMIS_XMP_STATUS_INVALID_ARGUMENT;
    }
    *result = {};
    const XMP_FileFormat format = formatHintForLeaf(leaf);
    if (format == kXMP_UnknownFile) {
        setError(errorMessage, errorCapacity, "The capability leaf has no supported embedded-XMP format");
        return UMIS_XMP_STATUS_NO_SMART_HANDLER;
    }

    UMISXMPFileIdentity before{};
    UMISXMPStatus status = requireExpectedIdentityAt(
        parentDescriptor,
        leaf,
        expectedIdentity,
        &before,
        errorMessage,
        errorCapacity,
        true
    );
    if (status != UMIS_XMP_STATUS_OK) return status;

    AnchoredXMPIO io(parentDescriptor, leaf, true, before);
    SXMPFiles file;
    const XMP_OptionBits openFlags = kXMPFiles_OpenForRead
        | kXMPFiles_OpenUseSmartHandler
        | kXMPFiles_OpenStrictly;
    if (!file.OpenFile(&io, format, openFlags)) {
        setError(errorMessage, errorCapacity, std::string("No Adobe smart handler accepted capability leaf: ") + leaf);
        return UMIS_XMP_STATUS_NO_SMART_HANDLER;
    }
    XMP_OptionBits handlerFlags = 0;
    file.GetFileInfo(nullptr, nullptr, nullptr, &handlerFlags);
    if (!handlerWritesEmbeddedXMP(handlerFlags)) {
        file.CloseFile();
        setError(errorMessage, errorCapacity, "The selected Adobe handler does not use embedded XMP");
        return UMIS_XMP_STATUS_EMBEDDED_UPDATE_UNAVAILABLE;
    }
    SXMPMeta metadata;
    file.GetXMP(&metadata);
    file.CloseFile();

    status = extractRating(
        metadata,
        &result->rating,
        &result->has_explicit_rating,
        errorMessage,
        errorCapacity
    );
    if (status != UMIS_XMP_STATUS_OK) return status;
    UMISXMPFileIdentity after{};
    if (!io.currentIdentity(&after, true) || !identitiesEqual(before, after)) {
        setError(errorMessage, errorCapacity, "Capability target changed while reading embedded XMP");
        return UMIS_XMP_STATUS_CONCURRENT_MODIFICATION;
    }
    result->identity = after;
    return UMIS_XMP_STATUS_OK;
}

UMISXMPStatus probeAtLocked(
    int parentDescriptor,
    const char *leaf,
    const UMISXMPFileIdentity *expectedIdentity,
    UMISXMPProbeResult *result,
    char *errorMessage,
    size_t errorCapacity
) {
    if (result == nullptr) {
        setError(errorMessage, errorCapacity, "A probe result is required");
        return UMIS_XMP_STATUS_INVALID_ARGUMENT;
    }
    *result = {};
    result->abi_version = UMIS_XMP_BRIDGE_ABI_VERSION;
    const XMP_FileFormat formatHint = formatHintForLeaf(leaf);
    if (formatHint == kXMP_UnknownFile) {
        setError(errorMessage, errorCapacity, "The capability leaf has no supported embedded-XMP format");
        return UMIS_XMP_STATUS_NO_SMART_HANDLER;
    }

    UMISXMPFileIdentity before{};
    UMISXMPStatus status = requireExpectedIdentityAt(
        parentDescriptor,
        leaf,
        expectedIdentity,
        &before,
        errorMessage,
        errorCapacity,
        true
    );
    if (status != UMIS_XMP_STATUS_OK) return status;

    XMP_FileFormat actualFormat = kXMP_UnknownFile;
    XMP_OptionBits handlerFlags = 0;
    {
        AnchoredXMPIO readIO(parentDescriptor, leaf, true, before);
        SXMPFiles file;
        const XMP_OptionBits readFlags = kXMPFiles_OpenForRead
            | kXMPFiles_OpenUseSmartHandler
            | kXMPFiles_OpenStrictly;
        if (!file.OpenFile(&readIO, formatHint, readFlags)) {
            setError(errorMessage, errorCapacity, std::string("No Adobe smart handler accepted capability leaf: ") + leaf);
            return UMIS_XMP_STATUS_NO_SMART_HANDLER;
        }
        file.GetFileInfo(nullptr, nullptr, &actualFormat, &handlerFlags);
        SXMPMeta metadata;
        file.GetXMP(&metadata);
        file.CloseFile();
        UMISXMPFileIdentity afterRead{};
        if (!readIO.currentIdentity(&afterRead, true) || !identitiesEqual(before, afterRead)) {
            setError(errorMessage, errorCapacity, "Capability target changed while probing embedded XMP");
            return UMIS_XMP_STATUS_CONCURRENT_MODIFICATION;
        }
    }

    bool canPut = false;
    if (handlerWritesEmbeddedXMP(handlerFlags) && handlerSupportsSafeUpdate(handlerFlags)) {
        try {
            AnchoredXMPIO updateIO(parentDescriptor, leaf, false, before);
            SXMPFiles updateProbe;
            const XMP_OptionBits updateFlags = kXMPFiles_OpenForUpdate
                | kXMPFiles_OpenUseSmartHandler
                | kXMPFiles_OpenStrictly;
            if (updateProbe.OpenFile(&updateIO, formatHint, updateFlags)) {
                SXMPMeta updateMetadata;
                updateProbe.GetXMP(&updateMetadata);
                canPut = updateProbe.CanPutXMP(updateMetadata);
                updateProbe.CloseFile();
            }
        } catch (const XMP_Error &error) {
            if (error.GetID() != kXMPErr_FilePermission) throw;
        }
    }

    UMISXMPFileIdentity after{};
    status = captureIdentityAt(
        parentDescriptor,
        leaf,
        &after,
        errorMessage,
        errorCapacity,
        true
    );
    if (status != UMIS_XMP_STATUS_OK) return status;
    if (!identitiesEqual(before, after)) {
        setError(errorMessage, errorCapacity, "Capability target changed while probing XMP");
        return UMIS_XMP_STATUS_CONCURRENT_MODIFICATION;
    }

    result->xmp_file_format = static_cast<uint32_t>(actualFormat);
    result->handler_flags = static_cast<uint32_t>(handlerFlags);
    result->has_smart_handler = 1;
    result->can_read_embedded_xmp = handlerWritesEmbeddedXMP(handlerFlags) ? 1 : 0;
    result->can_put_embedded_xmp = canPut && handlerWritesEmbeddedXMP(handlerFlags) ? 1 : 0;
    result->supports_safe_update = handlerSupportsSafeUpdate(handlerFlags) ? 1 : 0;
    result->handler_uses_sidecar = (handlerFlags & kXMPFiles_UsesSidecarXMP) != 0 ? 1 : 0;
    result->handler_owns_file = (handlerFlags & kXMPFiles_HandlerOwnsFile) != 0 ? 1 : 0;
    result->identity = after;
    return UMIS_XMP_STATUS_OK;
}

UMISXMPStatus writeEmbeddedRatingAtLocked(
    int parentDescriptor,
    const char *leaf,
    const UMISXMPFileIdentity *expectedIdentity,
    int32_t rating,
    UMISXMPRatingResult *result,
    char *errorMessage,
    size_t errorCapacity
) {
    if (rating < -1 || rating > 5) {
        setError(errorMessage, errorCapacity, "Adobe xmp:Rating must be -1 or 0...5");
        return UMIS_XMP_STATUS_INVALID_RATING;
    }
    if (result == nullptr) {
        setError(errorMessage, errorCapacity, "A rating result is required");
        return UMIS_XMP_STATUS_INVALID_ARGUMENT;
    }
    *result = {};
    const XMP_FileFormat format = formatHintForLeaf(leaf);
    if (format == kXMP_UnknownFile) {
        setError(errorMessage, errorCapacity, "The capability leaf has no supported embedded-XMP format");
        return UMIS_XMP_STATUS_NO_SMART_HANDLER;
    }

    UMISXMPFileIdentity before{};
    UMISXMPStatus status = requireExpectedIdentityAt(
        parentDescriptor,
        leaf,
        expectedIdentity,
        &before,
        errorMessage,
        errorCapacity,
        true
    );
    if (status != UMIS_XMP_STATUS_OK) return status;

    AnchoredXMPIO io(parentDescriptor, leaf, false, before);
    FailureRecoveryReporter failureRecoveryReporter(&io, result);
    SXMPFiles file;
    const XMP_OptionBits openFlags = kXMPFiles_OpenForUpdate
        | kXMPFiles_OpenUseSmartHandler
        | kXMPFiles_OpenStrictly;
    if (!file.OpenFile(&io, format, openFlags)) {
        setError(errorMessage, errorCapacity, std::string("No Adobe smart handler accepted capability leaf: ") + leaf);
        return UMIS_XMP_STATUS_NO_SMART_HANDLER;
    }
    XMP_OptionBits handlerFlags = 0;
    file.GetFileInfo(nullptr, nullptr, nullptr, &handlerFlags);
    if (!handlerWritesEmbeddedXMP(handlerFlags)) {
        file.CloseFile();
        setError(errorMessage, errorCapacity, "The selected Adobe handler does not write embedded XMP");
        return UMIS_XMP_STATUS_EMBEDDED_UPDATE_UNAVAILABLE;
    }
    if (!handlerSupportsSafeUpdate(handlerFlags)) {
        file.CloseFile();
        setError(errorMessage, errorCapacity, "The selected Adobe handler does not advertise safe update support");
        return UMIS_XMP_STATUS_SAFE_UPDATE_UNAVAILABLE;
    }

    SXMPMeta metadata;
    file.GetXMP(&metadata);
    metadata.SetProperty_Int(kXMP_NS_XMP, "Rating", rating);
    if (!file.CanPutXMP(metadata)) {
        file.CloseFile();
        setError(errorMessage, errorCapacity, "Adobe XMPFiles cannot fit or safely rewrite this XMP packet");
        return UMIS_XMP_STATUS_EMBEDDED_UPDATE_UNAVAILABLE;
    }

    UMISXMPFileIdentity beforeCommit{};
    if (!io.currentIdentity(&beforeCommit, true) || !identitiesEqual(before, beforeCommit)) {
        setError(errorMessage, errorCapacity, "Capability target changed before queuing embedded XMP");
        return UMIS_XMP_STATUS_CONCURRENT_MODIFICATION;
    }
    file.PutXMP(metadata);
    if (!io.currentIdentity(&beforeCommit, true) || !identitiesEqual(before, beforeCommit)) {
        setError(errorMessage, errorCapacity, "Capability target changed before safe XMP close");
        return UMIS_XMP_STATUS_CONCURRENT_MODIFICATION;
    }
    file.CloseFile(kXMPFiles_UpdateSafely);

    UMISXMPFileIdentity afterWrite{};
    if (!io.currentIdentity(&afterWrite, true)) {
        setError(errorMessage, errorCapacity, "Committed capability target failed identity verification");
        return UMIS_XMP_STATUS_CONCURRENT_MODIFICATION;
    }
    if (afterWrite.device != before.device) {
        setError(errorMessage, errorCapacity, "Safe XMP capability update committed onto a different device");
        return UMIS_XMP_STATUS_CONCURRENT_MODIFICATION;
    }

    io.synchronizeCommittedFile();

    UMISXMPFileIdentity durableIdentity{};
    if (!io.currentIdentity(&durableIdentity, true)) {
        setError(errorMessage, errorCapacity, "Synchronized capability target failed identity verification");
        return UMIS_XMP_STATUS_CONCURRENT_MODIFICATION;
    }
    UMISXMPRatingResult verified{};
    status = readEmbeddedRatingAtLocked(
        parentDescriptor,
        leaf,
        &durableIdentity,
        &verified,
        errorMessage,
        errorCapacity
    );
    if (status != UMIS_XMP_STATUS_OK) return status;
    if (!verified.has_explicit_rating || verified.rating != rating) {
        setError(errorMessage, errorCapacity, "Embedded xmp:Rating did not verify after anchored safe update");
        return UMIS_XMP_STATUS_VERIFICATION_FAILED;
    }
    *result = verified;
    uint64_t recoveryToken = 0;
    std::string recoveryDirectoryLeaf;
    if (!io.publishRecoveryForUpperReadback(&recoveryToken, &recoveryDirectoryLeaf)) {
        setError(errorMessage, errorCapacity, "Unable to seal XMP recovery data for upper-layer readback");
        return UMIS_XMP_STATUS_VERIFICATION_FAILED;
    }
    if (recoveryToken != 0) {
        result->has_pending_recovery = 1;
        result->recovery_token = recoveryToken;
        const size_t count = std::min(
            recoveryDirectoryLeaf.size(),
            static_cast<size_t>(UMIS_XMP_RECOVERY_LEAF_CAPACITY - 1)
        );
        memcpy(result->recovery_directory_leaf, recoveryDirectoryLeaf.data(), count);
        result->recovery_directory_leaf[count] = '\0';
    }
    failureRecoveryReporter.markCompleted();
    return UMIS_XMP_STATUS_OK;
}

}  // namespace

UMISXMPStatus umis_xmp_initialize(char *errorMessage, size_t errorCapacity) {
    return guardExceptions(errorMessage, errorCapacity, [&]() -> UMISXMPStatus {
        return ensureInitialized(errorMessage, errorCapacity);
    });
}

UMISXMPStatus umis_xmp_probe_file(
    const char *path,
    const UMISXMPFileIdentity *expectedIdentity,
    UMISXMPProbeResult *result,
    char *errorMessage,
    size_t errorCapacity
) {
    return guardExceptions(errorMessage, errorCapacity, [&]() -> UMISXMPStatus {
        if (result == nullptr) {
            setError(errorMessage, errorCapacity, "A probe result is required");
            return UMIS_XMP_STATUS_INVALID_ARGUMENT;
        }
        *result = {};
        result->abi_version = UMIS_XMP_BRIDGE_ABI_VERSION;
        const UMISXMPStatus initialized = ensureInitialized(errorMessage, errorCapacity);
        if (initialized != UMIS_XMP_STATUS_OK) return initialized;
        std::lock_guard<std::mutex> lock(gToolkitMutex);

        UMISXMPFileIdentity before{};
        UMISXMPStatus status = requireExpectedIdentity(
            path,
            expectedIdentity,
            &before,
            errorMessage,
            errorCapacity,
            false
        );
        if (status != UMIS_XMP_STATUS_OK) return status;

        SXMPFiles file;
        const XMP_OptionBits openFlags = kXMPFiles_OpenForRead | kXMPFiles_OpenUseSmartHandler;
        if (!file.OpenFile(path, kXMP_UnknownFile, openFlags)) {
            setError(errorMessage, errorCapacity, std::string("No Adobe smart handler accepted: ") + path);
            return UMIS_XMP_STATUS_NO_SMART_HANDLER;
        }
        XMP_FileFormat format = kXMP_UnknownFile;
        XMP_OptionBits handlerFlags = 0;
        file.GetFileInfo(nullptr, nullptr, &format, &handlerFlags);
        SXMPMeta metadata;
        file.GetXMP(&metadata);
        file.CloseFile();

        // CanPutXMP is meaningful only for a file opened for update. Probe with a separate update
        // handle and close it without PutXMP; this performs no metadata mutation. A read-only file
        // still reports its readable smart handler while correctly returning can_put == false.
        bool canPut = false;
        if (handlerWritesEmbeddedXMP(handlerFlags) && handlerSupportsSafeUpdate(handlerFlags)) {
            SXMPFiles updateProbe;
            const XMP_OptionBits updateFlags = kXMPFiles_OpenForUpdate | kXMPFiles_OpenUseSmartHandler;
            if (updateProbe.OpenFile(path, kXMP_UnknownFile, updateFlags)) {
                SXMPMeta updateMetadata;
                updateProbe.GetXMP(&updateMetadata);
                canPut = updateProbe.CanPutXMP(updateMetadata);
                updateProbe.CloseFile();
            }
        }

        UMISXMPFileIdentity after{};
        status = captureIdentity(path, &after, errorMessage, errorCapacity, false);
        if (status != UMIS_XMP_STATUS_OK) return status;
        if (!identitiesEqual(before, after)) {
            setError(errorMessage, errorCapacity, std::string("File changed while probing XMP: ") + path);
            return UMIS_XMP_STATUS_CONCURRENT_MODIFICATION;
        }

        result->xmp_file_format = static_cast<uint32_t>(format);
        result->handler_flags = static_cast<uint32_t>(handlerFlags);
        result->has_smart_handler = 1;
        result->can_read_embedded_xmp = handlerWritesEmbeddedXMP(handlerFlags) ? 1 : 0;
        result->can_put_embedded_xmp = canPut && handlerWritesEmbeddedXMP(handlerFlags) ? 1 : 0;
        result->supports_safe_update = handlerSupportsSafeUpdate(handlerFlags) ? 1 : 0;
        result->handler_uses_sidecar = (handlerFlags & kXMPFiles_UsesSidecarXMP) != 0 ? 1 : 0;
        result->handler_owns_file = (handlerFlags & kXMPFiles_HandlerOwnsFile) != 0 ? 1 : 0;
        result->identity = after;
        return UMIS_XMP_STATUS_OK;
    });
}

UMISXMPStatus umis_xmp_read_embedded_rating(
    const char *path,
    const UMISXMPFileIdentity *expectedIdentity,
    UMISXMPRatingResult *result,
    char *errorMessage,
    size_t errorCapacity
) {
    return guardExceptions(errorMessage, errorCapacity, [&]() -> UMISXMPStatus {
        const UMISXMPStatus initialized = ensureInitialized(errorMessage, errorCapacity);
        if (initialized != UMIS_XMP_STATUS_OK) return initialized;
        std::lock_guard<std::mutex> lock(gToolkitMutex);
        return readEmbeddedRatingLocked(
            path,
            expectedIdentity,
            result,
            errorMessage,
            errorCapacity
        );
    });
}

UMISXMPStatus umis_xmp_probe_file_at(
    int32_t parentDescriptor,
    const char *leaf,
    const UMISXMPFileIdentity *expectedIdentity,
    UMISXMPProbeResult *result,
    char *errorMessage,
    size_t errorCapacity
) {
    return guardExceptions(errorMessage, errorCapacity, [&]() -> UMISXMPStatus {
        const UMISXMPStatus initialized = ensureInitialized(errorMessage, errorCapacity);
        if (initialized != UMIS_XMP_STATUS_OK) return initialized;
        std::lock_guard<std::mutex> lock(gToolkitMutex);
        return probeAtLocked(
            parentDescriptor,
            leaf,
            expectedIdentity,
            result,
            errorMessage,
            errorCapacity
        );
    });
}

UMISXMPStatus umis_xmp_read_embedded_rating_at(
    int32_t parentDescriptor,
    const char *leaf,
    const UMISXMPFileIdentity *expectedIdentity,
    UMISXMPRatingResult *result,
    char *errorMessage,
    size_t errorCapacity
) {
    return guardExceptions(errorMessage, errorCapacity, [&]() -> UMISXMPStatus {
        const UMISXMPStatus initialized = ensureInitialized(errorMessage, errorCapacity);
        if (initialized != UMIS_XMP_STATUS_OK) return initialized;
        std::lock_guard<std::mutex> lock(gToolkitMutex);
        return readEmbeddedRatingAtLocked(
            parentDescriptor,
            leaf,
            expectedIdentity,
            result,
            errorMessage,
            errorCapacity
        );
    });
}

UMISXMPStatus umis_xmp_write_embedded_rating_at(
    int32_t parentDescriptor,
    const char *leaf,
    const UMISXMPFileIdentity *expectedIdentity,
    int32_t rating,
    UMISXMPRatingResult *result,
    char *errorMessage,
    size_t errorCapacity
) {
    return guardExceptions(errorMessage, errorCapacity, [&]() -> UMISXMPStatus {
        const UMISXMPStatus initialized = ensureInitialized(errorMessage, errorCapacity);
        if (initialized != UMIS_XMP_STATUS_OK) return initialized;
        std::lock_guard<std::mutex> lock(gToolkitMutex);
        return writeEmbeddedRatingAtLocked(
            parentDescriptor,
            leaf,
            expectedIdentity,
            rating,
            result,
            errorMessage,
            errorCapacity
        );
    });
}

UMISXMPStatus umis_xmp_finalize_recovery_at(
    int32_t parentDescriptor,
    const char *leaf,
    const UMISXMPFileIdentity *expectedCommittedIdentity,
    uint64_t recoveryToken,
    uint8_t upperReadbackVerified,
    UMISXMPRecoveryFinalizeResult *result,
    char *errorMessage,
    size_t errorCapacity
) {
    return guardExceptions(errorMessage, errorCapacity, [&]() -> UMISXMPStatus {
        if (parentDescriptor < 0
            || !validLeafName(leaf)
            || expectedCommittedIdentity == nullptr
            || recoveryToken == 0
            || result == nullptr) {
            setError(errorMessage, errorCapacity, "A parent capability, target identity, recovery token and result are required");
            return UMIS_XMP_STATUS_INVALID_ARGUMENT;
        }
        *result = {};
        result->abi_version = UMIS_XMP_BRIDGE_ABI_VERSION;
        std::shared_ptr<RecoveryContext> recovery = takePendingRecovery(recoveryToken);
        if (!recovery) {
            setError(errorMessage, errorCapacity, "The recovery token is unknown or was already consumed");
            return UMIS_XMP_STATUS_INVALID_ARGUMENT;
        }
        const std::string recoveryLeaf = recovery->directoryLeaf();
        const size_t count = std::min(
            recoveryLeaf.size(),
            static_cast<size_t>(UMIS_XMP_RECOVERY_LEAF_CAPACITY - 1)
        );
        memcpy(result->recovery_directory_leaf, recoveryLeaf.data(), count);
        result->recovery_directory_leaf[count] = '\0';

        std::lock_guard<std::mutex> lock(gToolkitMutex);
        std::string warning;
        bool originalBackupRetained = false;
        bool cleanupIncomplete = false;
        const bool cleaned = recovery->finalizeAfterUpperReadback(
            parentDescriptor,
            leaf,
            *expectedCommittedIdentity,
            upperReadbackVerified != 0,
            &originalBackupRetained,
            &cleanupIncomplete,
            &warning
        );
        result->cleanup_completed = cleaned ? 1 : 0;
        result->original_backup_retained = originalBackupRetained ? 1 : 0;
        result->cleanup_incomplete = cleanupIncomplete ? 1 : 0;
        if (!cleaned) setError(errorMessage, errorCapacity, warning);
        return UMIS_XMP_STATUS_OK;
    });
}
