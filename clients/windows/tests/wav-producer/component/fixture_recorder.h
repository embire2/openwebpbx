/* SPDX-License-Identifier: AGPL-3.0-or-later */
#ifndef OPENWEB_FIXTURE_RECORDER_H
#define OPENWEB_FIXTURE_RECORDER_H
#include <mediastreamer2/msfactory.h>
#ifdef OPENWEB_FIXTURE_PLUGIN_BUILD
#define OW_FIXTURE_API __declspec(dllexport)
#else
#define OW_FIXTURE_API __declspec(dllimport)
#endif
#ifdef __cplusplus
extern "C" {
#endif
/* Version-bound fixture only; succeeds only after public ID lookup proves selection. */
OW_FIXTURE_API int openweb_fixture_wav_register(MSFactory *factory);
OW_FIXTURE_API int openweb_fixture_wav_selected(MSFactory *factory);
#ifdef __cplusplus
}
#endif
#endif
