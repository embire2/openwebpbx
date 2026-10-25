<?php
/** Office-hour decisions shared by Admin previews and phone status. */
class pbx_schedule {
    public static function periods(mixed $rows): array {
        if(!is_array($rows)||count($rows)>56)throw new InvalidArgumentException('Use up to 56 opening or break periods.');
        $out=[];
        foreach($rows as $row){
            if(!is_array($row))throw new InvalidArgumentException('Choose a day and opening and closing times.');
            if(empty($row['enabled'])&&empty($row['open']))continue;
            $day=$row['day']??null;$start=$row['start']??'';$end=$row['end']??'';
            if(filter_var($day,FILTER_VALIDATE_INT,['options'=>['min_range'=>0,'max_range'=>6]])===false||!is_string($start)||!is_string($end)||!preg_match('/^(?:[01][0-9]|2[0-3]):[0-5][0-9]$/D',$start)||(!preg_match('/^(?:[01][0-9]|2[0-3]):[0-5][0-9]$/D',$end)&&$end!=='24:00')||$start===$end)throw new InvalidArgumentException('Choose a day and different valid opening and closing times.');
            if($start<$end)$out[]=['day'=>(int)$day,'start'=>$start,'end'=>$end];
            else{$out[]=['day'=>(int)$day,'start'=>$start,'end'=>'24:00'];if($end!=='00:00')$out[]=['day'=>((int)$day+1)%7,'start'=>'00:00','end'=>$end];}
        }
        usort($out,fn($a,$b)=>[$a['day'],$a['start']]<=>[$b['day'],$b['start']]);
        // Coalesce overlapping periods without changing their effective routing.
        $merged=[];foreach($out as $p){$i=count($merged)-1;if($i>=0&&$merged[$i]['day']===$p['day']&&$p['start']<=$merged[$i]['end'])$merged[$i]['end']=max($p['end'],$merged[$i]['end']);else $merged[]=$p;}
        return $merged;
    }
    public static function holidays(mixed $value): array {
        if(!is_string($value)||strlen($value)>12000)throw new InvalidArgumentException('Enter one holiday date per line.');
        $out=[];foreach(preg_split('/\R/',$value) as $line){$line=trim($line);if($line==='')continue;[$date,$name]=array_pad(preg_split('/\s+/', $line,2),2,'Holiday');$d=DateTimeImmutable::createFromFormat('!Y-m-d',$date);if(!$d||$d->format('Y-m-d')!==$date||mb_strlen($name)>80||preg_match('/[\x00-\x1f\x7f]/',$name))throw new InvalidArgumentException('Use a valid holiday date, followed by an optional name.');$out[$date]=['date'=>$date,'name'=>$name];}
        if(count($out)>200)throw new InvalidArgumentException('Use up to 200 holiday dates.');ksort($out);return array_values($out);
    }
    public static function inside(array $hours,int $day,string $time): bool {
        if(($hours['type']??'AllHours')==='AllHours')return true;
        foreach($hours['periods']??[] as $p){
            if($p['start']<$p['end']&&(int)$p['day']===$day&&$time>=$p['start']&&$time<$p['end'])return true;
            if($p['start']>$p['end']&&(((int)$p['day']===$day&&$time>=$p['start'])||((int)$p['day']===($day+6)%7&&$time<$p['end'])))return true;
        }
        return false;
    }
    public static function office(array $department,string $fallbackZone='UTC',?int $now=null,bool $ignoreHolidays=false): array {
        $now??=time();$override=$department['office_override']??[];
        if((int)($override['expires']??0)>$now&&in_array($override['state']??'',['open','closed'],true))return ['open'=>$override['state']==='open','break'=>false,'holiday'=>false,'override'=>$override['state'],'expires'=>(int)$override['expires']];
        $clock=(new DateTimeImmutable('@'.$now))->setTimezone(new DateTimeZone($department['timezone']??$fallbackZone));$day=(int)$clock->format('w');$time=$clock->format('H:i');$date=$clock->format('Y-m-d');
        $break=!empty($department['breaks']['periods'])&&self::inside($department['breaks'],$day,$time);$holiday=false;
        foreach($department['holidays']??[] as $h)if(($h['date']??'')===$date)$holiday=true;
        return ['open'=>self::inside($department['hours']??[],$day,$time)&&!$break&&($ignoreHolidays||!$holiday),'break'=>$break,'holiday'=>$holiday,'override'=>null,'expires'=>null];
    }
    public static function department(array $config,string $number): ?array {
        $fallback=null;foreach($config['departments']??[] as $d){if((string)($d['number']??'')===$number)return $d;foreach($d['members']??[] as $m)if((string)$m['number']===$number){if(!empty($m['primary']))return $d;$fallback??=$d;}}return $fallback;
    }
    public static function route(mixed $value): ?array {
        if(is_array($value))return ($value['type']??'')==='ProceedWithNoExceptions'?null:$value;
        if(!is_string($value)||!preg_match('/^([A-Za-z]+)\.([^.]*)\.(.*)$/D',$value,$m)||$m[1]==='ProceedWithNoExceptions')return null;
        return ['type'=>$m[1],'number'=>$m[2],'external'=>$m[3]];
    }
    public static function userDestination(array $config,array $user,?int $now=null,bool $internal=false): ?array {
        $routing=$user['office_routing']??[];
        if(($routing['enabled']??false)!==true)return self::objectDestination($config,$user,$now);
        $department=self::department($config,(string)$user['number']);
        if(!$department)return null;
        $open=self::office($department,$config['timezone']??'UTC',$now)['open'];
        // The existing direct-internal exception remains separate from outside/company calls.
        if(!$open&&$internal&&($user['internal_after_hours']??false)===true)return null;
        return self::route($routing[$open?'office':'outside']??null);
    }
    public static function objectDestination(array $config,array $object,?int $now=null): ?array {
        if(!isset($object['hours']))return null;
        $now??=time();$schedule=$object['hours'];$override=$object['office_override']??$schedule['office_override']??[];
        if((int)($override['expires']??0)>$now&&in_array($override['state']??'',['open','closed'],true))return self::route($schedule[$override['state']==='open'?'office':'outside']??null);
        $hours=$schedule['hours']??['type'=>'AllHours'];$department=self::department($config,(string)$object['number']);
        $clock=(new DateTimeImmutable('@'.$now))->setTimezone(new DateTimeZone($department['timezone']??$config['timezone']??'UTC'));
        $day=(int)$clock->format('w');$time=$clock->format('H:i');
        $office=$department?self::office($department,$config['timezone']??'UTC',$now,!empty($hours['ignore_holidays'])):['open'=>self::inside($config['default_hours']??[],$day,$time),'break'=>false,'holiday'=>false];
        $open=$office['open'];$break=$office['break'];$holiday=$office['holiday'];$type=$hours['type']??'AllHours';
        if(($schedule['follow_department']??null)===false){$office=['open'=>true,'break'=>false,'holiday'=>false];$open=true;$break=false;$holiday=false;}
        if(!in_array($type,['OfficeHours','OutOfOfficeHours'],true))$open=self::inside($hours,$day,$time);
        elseif($type==='OutOfOfficeHours')$open=!$open;
        if(!empty($hours['ignore_holidays']))$holiday=false;
        if(!empty($schedule['breaks']['periods'])&&self::inside($schedule['breaks'],$day,$time))$break=true;
        return self::route($schedule[$holiday?'holiday':($break?'break':(!$open?'outside':'office'))]??null);
    }
}
