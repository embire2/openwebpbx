// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Runtime.CompilerServices;
[assembly: InternalsVisibleTo("OpenWebPbx.Phone.NativeChecks")]

#if PHONE_MEDIA_FIXTURE
[assembly: InternalsVisibleTo("OpenWebPbx.Phone.MediaChecks")]
#endif
