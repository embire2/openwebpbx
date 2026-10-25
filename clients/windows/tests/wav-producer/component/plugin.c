/* SPDX-License-Identifier: AGPL-3.0-or-later
 * OpenWebPBX isolated software-media fixture. Not a production SDK replacement.
 */
#include <string.h>
#include <mediastreamer2/msfactory.h>
#include "fixture_recorder.h"
extern MSFilterDesc ms_file_rec_desc;
int openweb_fixture_wav_selected(MSFactory *factory) {
    return factory && ms_factory_lookup_filter_by_id(factory, MS_FILE_REC_ID) == &ms_file_rec_desc &&
        strcmp(ms_file_rec_desc.name, "OpenWebPBXFixtureWavRecorder") == 0;
}
int openweb_fixture_wav_register(MSFactory *factory) {
    MSFilterDesc *before;
    if (!factory) return 0;
    if (openweb_fixture_wav_selected(factory)) return 1;
    before = ms_factory_lookup_filter_by_id(factory, MS_FILE_REC_ID);
    if (!before || strcmp(before->name, "MSFileRec") != 0) return 0;
    /* Public version-pinned registry operation; no descriptor/vtable patching. */
    ms_factory_register_filter(factory, &ms_file_rec_desc);
    return openweb_fixture_wav_selected(factory);
}
/* Standard Windows mediastreamer plugin entry-name convention. */
__declspec(dllexport) void libmsopenwebwav_init(MSFactory *factory) {
    if (!openweb_fixture_wav_register(factory))
        ms_error("OpenWebPBX fixture WAV producer selection refused");
}
