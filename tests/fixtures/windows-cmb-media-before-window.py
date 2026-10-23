# Exact decoded observer body from Windows suite source8a377ff7e; no PBX code.
def decoded(left, right, left_frequency, right_frequency, seconds=3):
    left['decoded_pcm'].clear()
    right['decoded_pcm'].clear()
    time.sleep(seconds)
    for peer in (caller, extension, *providers):
        peer.check_receiver()
        assert peer.thread.is_alive(), 'An owned SIP/RTP receiver stopped during the native media window'
    sip.rtp_rate_check(left)
    sip.rtp_rate_check(right)
    return (original.decoded_tone_check(left, left_frequency), original.decoded_tone_check(right, right_frequency))
