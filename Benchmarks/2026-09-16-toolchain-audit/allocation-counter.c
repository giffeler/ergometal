#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

// Diagnostic-only Swift runtime interposition, never linked into a miner.
extern void *swift_allocObject(const void *, size_t, size_t) __attribute__((swiftcall));
static _Atomic uint64_t objects, bytes;
static void *audit_alloc(const void *metadata, size_t size, size_t align) __attribute__((swiftcall));
static void *audit_alloc(const void *metadata, size_t size, size_t align) {
    atomic_fetch_add_explicit(&objects, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&bytes, size, memory_order_relaxed);
    return swift_allocObject(metadata, size, align);
}
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement, *original; } binding = {
    (const void *)audit_alloc, (const void *)swift_allocObject
};
void audit_reset(void) { atomic_store(&objects, 0); atomic_store(&bytes, 0); }
uint64_t audit_objects(void) { return atomic_load(&objects); }
uint64_t audit_bytes(void) { return atomic_load(&bytes); }
