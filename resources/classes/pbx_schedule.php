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
        foreach($hours['periods']??[] as $p)if((int)$p['day']===$day&&$time>=$p['start']&&$time<$p['end'])return true;
        return false;
    }
    public static function office(array $department,string $fallbackZone='UTC',?int $now=null): array {
        $now??=time();$override=$department['office_override']??[];
        if((int)($override['expires']??0)>$now&&in_array($override['state']??'',['open','closed'],true))return ['open'=>$override['state']==='open','break'=>false,'holiday'=>false,'override'=>$override['state'],'expires'=>(int)$override['expires']];
        $clock=(new DateTimeImmutable('@'.$now))->setTimezone(new DateTimeZone($department['timezone']??$fallbackZone));$day=(int)$clock->format('w');$time=$clock->format('H:i');$date=$clock->format('Y-m-d');
        $break=!empty($department['breaks']['periods'])&&self::inside($department['breaks'],$day,$time);$holiday=false;
        foreach($department['holidays']??[] as $h)if(($h['date']??'')===$date)$holiday=true;
        return ['open'=>self::inside($department['hours']??[],$day,$time)&&!$break&&!$holiday,'break'=>$break,'holiday'=>$holiday,'override'=>null,'expires'=>null];
    }
    public static function department(array $config,string $number): ?array {
        $fallback=null;foreach($config['departments']??[] as $d){if((string)($d['number']??'')===$number)return $d;foreach($d['members']??[] as $m)if((string)$m['number']===$number){if(!empty($m['primary']))return $d;$fallback??=$d;}}return $fallback;
    }
}
