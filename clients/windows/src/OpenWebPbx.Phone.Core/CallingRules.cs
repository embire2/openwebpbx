// SPDX-License-Identifier: AGPL-3.0-or-later
namespace OpenWebPbx.Phone.Core;
public static class CallingRules
{
    public static void Stable(bool pending) { if (pending) throw new PhoneInputException("Wait for your call to finish connecting or going on hold."); }
    public static void Video(bool visible, bool camera, int calls, bool conference, bool dialing = false)
    {
        if (!visible) throw new PhoneInputException("Open the video window before turning on your camera.");
        if (!camera) throw new PhoneInputException("No available webcam was found. Your audio call can continue.");
        if (conference || calls > (dialing ? 0 : 1)) throw new PhoneInputException("Video is available in a call with one person. Finish your other call first.");
    }
}
