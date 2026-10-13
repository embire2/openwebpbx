<?php
/** Exact source-to-native ringing semantics; never silently replace an unknown order. */
final class pbx_ringing {
    public static function group(string $strategy): string {
        $strategy=preg_replace('/^RingStrategy/', '', $strategy);
        return match($strategy) {
            'RingAll','simultaneous'=>'simultaneous',
            'Hunt','PrioritizedHunt','sequence'=>'sequence',
            default=>throw new InvalidArgumentException('This ring-group ringing order needs a matching restore check.')
        };
    }
    public static function queue(string $strategy): array {
        $strategy=preg_replace('/^PollingStrategy/', '', $strategy);
        $native=match($strategy) {
            'RingAll','ring-all'=>'ring-all',
            'Hunt','PrioritizedHunt','HuntRandomStart','top-down'=>'top-down',
            'RoundRobin','round-robin'=>'round-robin',
            'LongestWaiting','longest-idle-agent'=>'longest-idle-agent',
            'LeastTalkTime','agent-with-least-talk-time'=>'agent-with-least-talk-time',
            'FewestAnswered','agent-with-fewest-calls'=>'agent-with-fewest-calls',
            'random'=>'random',
            'sequentially-by-agent-order'=>'sequentially-by-agent-order',
            default=>throw new InvalidArgumentException('This queue ringing order needs a matching restore check.')
        };
        return ['native_strategy'=>$native,'polling_mode'=>$strategy==='HuntRandomStart'?'random_start':'native'];
    }
}
