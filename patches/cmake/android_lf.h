/* Large-file shim for CMake's bundled libarchive on Android.
 *
 * archive.h does `#if defined(__LIBARCHIVE_BUILD) && defined(__ANDROID__)
 * #include "android_lf.h"`, but the header is expected to be supplied by the
 * build environment (it isn't shipped with CMake). On the API levels we target
 * (24+) bionic already provides 64-bit off_t / lseek / lseek64 / pread64 / ...
 * with _FILE_OFFSET_BITS=64, so nothing needs remapping, this just satisfies
 * the include. scripts/build.sh drops it next to archive.h for android targets.
 */
#ifndef CMAKE_CUSTOM_ANDROID_LF_H
#define CMAKE_CUSTOM_ANDROID_LF_H
#endif
