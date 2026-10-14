/* Local Windows C-ABI/pool-ownership check for the retained MPL1.1 wrapper.
 * No engine initialization, service control, SIP, configuration or credentials.
 * Compile with OPENWEB_BCG729_SOURCE selecting the exact reviewed wrapper.
 */
#include <windows.h>
#include <assert.h>
#include <stdio.h>
#ifndef OPENWEB_BCG729_SOURCE
#error Define OPENWEB_BCG729_SOURCE
#endif
#include OPENWEB_BCG729_SOURCE

typedef int (*apr_initialize_fn)(void);
typedef int (*apr_pool_create_fn)(switch_memory_pool_t **, switch_memory_pool_t *, void *, void *);
typedef void (*apr_pool_destroy_fn)(switch_memory_pool_t *);
typedef void (*apr_terminate_fn)(void);

int main(void) {
    HMODULE core = GetModuleHandleA("FreeSwitch.dll");
    HMODULE apr = GetModuleHandleA("libapr.dll");
    apr_initialize_fn initialize;
    apr_pool_create_fn create;
    apr_pool_destroy_fn destroy;
    apr_terminate_fn terminate;
    unsigned i;
    /* The pinned MSVC core uses a 32-bit process ID; MinGW CRT pid_t is 64-bit.
     * The private header adapter retains the core type without redefining CRT. */
    assert(sizeof(pid_t) == 4 && sizeof(switch_thread_id_t) == sizeof(DWORD));
    assert(sizeof(void *) == 8);
    assert(core && apr);
    /* A DATA import points at the actual core object, never a function thunk. */
    assert((void *)&SWITCH_GLOBAL_dirs == (void *)GetProcAddress(core, "SWITCH_GLOBAL_dirs"));
    assert((void *)&SWITCH_GLOBAL_filenames == (void *)GetProcAddress(core, "SWITCH_GLOBAL_filenames"));
    initialize = (apr_initialize_fn)GetProcAddress(apr, "fspr_initialize");
    create = (apr_pool_create_fn)GetProcAddress(apr, "fspr_pool_create_ex");
    destroy = (apr_pool_destroy_fn)GetProcAddress(apr, "fspr_pool_destroy");
    terminate = (apr_terminate_fn)GetProcAddress(apr, "fspr_terminate");
    assert(initialize && create && destroy && terminate && initialize() == 0);
    for (i = 0; i < 1000; i++) {
        switch_memory_pool_t *pool = NULL;
        switch_codec_t codec = {0};
        int16_t pcm[80] = {0};
        uint8_t bits[10];
        uint32_t length = sizeof(bits), rate = 0;
        unsigned flags = 0;
        assert(create(&pool, NULL, NULL, NULL) == 0 && pool);
        codec.memory_pool = pool;
        assert(switch_bcg729_init(&codec, SWITCH_CODEC_FLAG_ENCODE | SWITCH_CODEC_FLAG_DECODE, NULL) == SWITCH_STATUS_SUCCESS);
        assert(codec.private_info);
        assert(switch_bcg729_encode(&codec, NULL, pcm, sizeof(pcm), 8000, bits, &length, &rate, &flags) == SWITCH_STATUS_SUCCESS);
        assert(length == 10 && rate == 8000);
        /* Codec-library objects are closed by that DLL; the context belongs to
         * the real MSI APR pool and is freed only through its owning APR DLL. */
        assert(switch_bcg729_destroy(&codec) == SWITCH_STATUS_SUCCESS && !codec.private_info);
        destroy(pool);
    }
    terminate();
    puts("PASS: real MSI DATA imports and 1000 native codec/APR ownership cycles");
    return 0;
}
