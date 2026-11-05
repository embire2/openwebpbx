<?php
/** Callback narration uses the existing, bounded Keoma Greetings queue. */
class pbx_cmb_scripts {
    public const DEFAULTS = [
        'incoming-new'=>'Gooday, thank you for calling. You may now disconnect this call and we will call you back. Goodbye',
        'incoming-known'=>'Hello, you are already authenticated to use this service. We will now call you back.',
        'callback-authenticate'=>'Hello, this is {companyname} calling you back. You may now authenticate by entering your South African ID Number and press hash.',
        'authenticated'=>'You have successfully authenticated, in the future, you will not need to authenticate again.',
        'enter-number'=>'Kindly enter the telephone number of the person you wish to call and press #',
        'invalid-id'=>'We could not authenticate you. Please contact your service administrator. Goodbye.',
        'unavailable'=>'This service is not available at present. Please try again later. Goodbye.',
        'invalid-number'=>'This number is not available through this service. Goodbye.',
        'quota-exhausted'=>'You have used your available calling minutes. Please contact your service administrator. Goodbye.'
    ];
    public const LABELS = ['incoming-new'=>'First incoming call','incoming-known'=>'Recognised incoming caller','callback-authenticate'=>'Callback: ask for ID','authenticated'=>'Authentication successful','enter-number'=>'Ask for the number / speed dial','invalid-id'=>'Authentication failed','unavailable'=>'Service unavailable','invalid-number'=>'Number unavailable','quota-exhausted'=>'No minutes remaining'];
    public static function text(mixed $value): string {
        if(!is_string($value)||!mb_check_encoding($value,'UTF-8')||mb_strlen($value)>1500||preg_match('/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f<>]/u',$value))throw new InvalidArgumentException('Use plain text up to 1,500 characters for each script.');
        $value=trim($value);
        if($value===''||preg_match('/[{}]/',str_replace('{companyname}','',$value)))throw new InvalidArgumentException('Enter the script. The only supported placeholder is {companyname}.');
        return $value;
    }
    public static function render(string $text,string $company): string {return str_replace('{companyname}',$company,self::text($text));}
    private static function q(PDO $db,string $sql,array $args=[]): PDOStatement {$s=$db->prepare($sql);$s->execute($args);return $s;}
    public static function rows(PDO $db,string $domain): array {
        return self::q($db,"select s.service_uuid,s.step,s.script_text,g.state,g.script prepared_script,g.last_result,old.state active_state,old.script active_script from v_pbx_cmb_scripts s left join v_pbx_greetings g on g.domain_uuid=s.domain_uuid and g.greeting_uuid=s.greeting_uuid left join v_pbx_greetings old on old.domain_uuid=s.domain_uuid and old.greeting_uuid=s.active_greeting_uuid where s.domain_uuid=? order by s.service_uuid,s.step",[$domain])->fetchAll(PDO::FETCH_ASSOC);
    }
    /** Caller holds the owner/routing transaction and checks service ownership. */
    public static function save(PDO $db,string $domain,string $actor,array $service,array $in,bool $reset): void {
        if(!$db->inTransaction())throw new LogicException('Lock the callback settings before editing scripts.');
        $id=$service['service_uuid'];
        $old=array_column(self::q($db,'select s.*,g.state candidate_state,g.script candidate_script from v_pbx_cmb_scripts s left join v_pbx_greetings g on g.domain_uuid=s.domain_uuid and g.greeting_uuid=s.greeting_uuid where s.domain_uuid=? and s.service_uuid=? for update of s',[$domain,$id])->fetchAll(PDO::FETCH_ASSOC),null,'step');
        if($reset){
            if(($in['confirm_reset']??'')!=='1')throw new InvalidArgumentException('Confirm Reset Default Scripts first.');
            self::q($db,'delete from v_pbx_cmb_scripts where domain_uuid=? and service_uuid=?',[$domain,$id]);return;
        }
        $changes=[];
        foreach(self::DEFAULTS as $step=>$default){
            $text=self::text($in['script_'.$step]??($old[$step]['script_text']??$default));
            if($text===($old[$step]['script_text']??$default)&&(!isset($old[$step])||$text===$default||(!in_array($old[$step]['candidate_state']??'', ['failed','cancelled','archived'],true)&&($old[$step]['candidate_script']??'')===self::render($text,$service['name']))))continue;
            $changes[$step]=$text;
        }
        if(!$changes)throw new InvalidArgumentException('The scripts are unchanged.');
        $ready=(new pbx_greetings($db))->readiness();
        $generated=array_filter($changes,fn($text,$step)=>$text!==self::DEFAULTS[$step],ARRAY_FILTER_USE_BOTH);
        if($generated&&!$ready['ready'])throw new InvalidArgumentException($ready['message']);
        self::q($db,'select pg_advisory_xact_lock(hashtextextended(?,741103501))',[$domain]);
        $daily=(int)self::q($db,"select count(*) from v_pbx_greetings where domain_uuid=? and created_at>now()-interval '1 day'",[$domain])->fetchColumn();
        $pending=(int)self::q($db,"select count(*) from v_pbx_greetings where domain_uuid=? and state in ('pending','preparing','ready_to_call','calling')",[$domain])->fetchColumn();
        if($daily+count($generated)>40||$pending+count($generated)>12)throw new InvalidArgumentException('Wait for the current recordings to finish, or try again tomorrow after the daily greeting allowance resets.');
        foreach($changes as $step=>$text){
            if($text===self::DEFAULTS[$step]){self::q($db,'delete from v_pbx_cmb_scripts where domain_uuid=? and service_uuid=? and step=?',[$domain,$id,$step]);continue;}
            $greeting=uuid();$spoken=self::render($text,$service['name']);
            self::q($db,"insert into v_pbx_greetings(greeting_uuid,domain_uuid,created_by,name,category,source,company_name,script) values(?,?,?,?,'announcement','text',?,?)",[$greeting,$domain,$actor,mb_substr($service['name'].' · '.self::LABELS[$step].' · '.substr($greeting,0,8),0,120),$service['name'],$spoken]);
            $previous=$old[$step]??null;
            $active=$previous&&$previous['candidate_state']==='ready'?$previous['greeting_uuid']:($previous['active_greeting_uuid']??null);
            self::q($db,'insert into v_pbx_cmb_scripts(domain_uuid,service_uuid,step,script_text,greeting_uuid,active_greeting_uuid) values(?,?,?,?,?,?) on conflict(domain_uuid,service_uuid,step) do update set script_text=excluded.script_text,greeting_uuid=excluded.greeting_uuid,active_greeting_uuid=excluded.active_greeting_uuid,updated_at=now()',[$domain,$id,$step,$text,$greeting,$active]);
        }
    }
}
