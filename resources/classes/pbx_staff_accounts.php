<?php
/** Explicit delegation and one-use staff invitations, using the instance mail queue. */
class pbx_staff_accounts {
    private PDO $db;
    private pbx_staff_access $access;
    public function __construct(?PDO $db=null){$this->db=$db??database::new()->db;$this->access=new pbx_staff_access($this->db);}
    private function q(string $sql,array $args=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($args);return $s;}
    public function grant(array $in): array {
        $a=$this->access;if(!$a->can('staff'))throw new pbx_staff_denied('Staff administration is not allowed.');
        $email=$in['email']??'';$number=$in['number']??'';$department=$in['department']??'';$role=$in['role']??'';
        if(!is_string($email)||strlen($email)>254||!filter_var($email,FILTER_VALIDATE_EMAIL)||!is_string($number)||!is_string($department)||!is_string($role)||!isset(pbx_staff_access::roles()[$role]))throw new InvalidArgumentException('Choose a user, department, role and valid email address.');
        $email=strtolower(trim($email));$token=null;$this->db->beginTransaction();try{
            $c=$a->config(true);$u=$c['users'][$number]??null;
            if(!$u||!in_array($department,pbx_departments::memberships($c,$number),true)||!in_array($department,$a->departments('staff',$c),true)||(!$a->owner()&&$role==='owner'))throw new pbx_staff_denied('You cannot assign that role in this department.');
            if(!$a->owner())$a->requireNumber('staff',$number,$c,true);
            if(!$this->q("select 1 from v_extensions where domain_uuid=? and extension_uuid=? and enabled='true'",[$a->domain,$u['extension_uuid']])->fetchColumn())throw new pbx_staff_denied('Choose an enabled phone in this PBX.');
            $rows=$this->q('select user_uuid,domain_uuid,user_enabled from v_users where lower(username)=? or lower(user_email)=? for update',[$email,$email])->fetchAll(PDO::FETCH_ASSOC);
            if(count($rows)>1)throw new InvalidArgumentException('This email identifies more than one web account. Ask the PBX owner to resolve it.');
            $existing=$rows[0]??null;$user=$existing['user_uuid']??uuid();$new=!$existing;
            if($existing&&$existing['domain_uuid']!==$a->domain)throw new pbx_staff_denied('This web account belongs to another PBX. Use a separate account for this PBX.');
            if(!$new&&$this->q('select 1 from v_pbx_staff_roles where domain_uuid=? and user_uuid=? and extension_uuid<>? limit 1',[$a->domain,$user,$u['extension_uuid']])->fetchColumn())throw new InvalidArgumentException('A web account can represent only one extension in a PBX.');
            if(!$a->owner()&&$existing&&$this->q("select 1 from v_pbx_staff_roles where domain_uuid=? and user_uuid=? and role='owner' and enabled",[$a->domain,$user])->fetchColumn())throw new pbx_staff_denied('Only the PBX owner can change an Owner account.');
            if($new){
                $group=$this->q("select group_uuid from v_groups where domain_uuid is null and group_name='openweb_staff'")->fetchColumn();if(!$group)throw new RuntimeException('Complete the server update before inviting staff.');
                $this->q("insert into v_users(user_uuid,domain_uuid,username,user_email,password,user_enabled,user_type) values(?,?,?,?,?,false,'default')",[$user,$a->domain,$email,$email,password_hash(bin2hex(random_bytes(32)),PASSWORD_DEFAULT)]);
                $this->q("insert into v_user_groups(user_group_uuid,domain_uuid,user_uuid,group_uuid,group_name) values(?,?,?,?,'openweb_staff')",[uuid(),$a->domain,$user,$group]);
                $token=bin2hex(random_bytes(32));$this->q("insert into v_pbx_staff_invites(invite_uuid,domain_uuid,user_uuid,token_hash,expires_at) values(?,?,?,?,now()+interval '48 hours')",[uuid(),$a->domain,$user,hash('sha256',$token)]);
            }elseif(!filter_var($existing['user_enabled'],FILTER_VALIDATE_BOOLEAN))throw new InvalidArgumentException('This account is disabled. The PBX owner must re-enable it explicitly.');
            $this->q('insert into v_pbx_staff_roles(staff_role_uuid,domain_uuid,user_uuid,extension_uuid,department_id,role) values(?,?,?,?,?,?) on conflict(domain_uuid,user_uuid,department_id) do update set extension_uuid=excluded.extension_uuid,role=excluded.role,enabled=true,updated_at=now()',[uuid(),$a->domain,$user,$u['extension_uuid'],$department,$role]);
            $a->audit('staff_grant',$number.'/'.$department.'/'.$role);
            $url=$token?'https://'.pbx_paths::host().'/app/pbx_staff/accept.php?invite='.$token:null;
            if($url&&!empty($in['email_invitation'])){
                // Queue only on an explicit administrator action; the normal global relay handles delivery.
                $body='You have been invited to OpenWeb PBX. Create your web password within 48 hours: '.$url;
                $this->q("insert into v_email_queue(email_queue_uuid,domain_uuid,hostname,email_date,email_to,email_subject,email_body,email_status) values(?,?,?,now(),?,?,?,'waiting')",[uuid(),$a->domain,gethostname(),$email,'Your OpenWeb PBX staff invitation',$body]);
            }
            $this->db->commit();return ['created'=>$new,'invitation_url'=>$url,'email_queued'=>$url&&!empty($in['email_invitation'])];
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    public function revoke(string $id): void {
        $a=$this->access;if(!is_uuid($id)||!$a->can('staff'))throw new pbx_staff_denied('Staff administration is not allowed.');
        $this->db->beginTransaction();try{$c=$a->config(true);$r=$this->q('select * from v_pbx_staff_roles where domain_uuid=? and staff_role_uuid=? for update',[$a->domain,$id])->fetch(PDO::FETCH_ASSOC);
            if(!$r||!in_array($r['department_id'],$a->departments('staff',$c),true)||(!$a->owner()&&$r['role']==='owner')||$r['user_uuid']===$a->actor)throw new pbx_staff_denied('You cannot revoke this role.');
            $this->q('update v_pbx_staff_roles set enabled=false,updated_at=now() where staff_role_uuid=?',[$id]);$a->audit('staff_revoke',$id);$this->db->commit();
        }catch(Throwable$e){if($this->db->inTransaction())$this->db->rollBack();throw$e;}
    }
    public function renew(string $id,bool $send=false): array {
        $a=$this->access;if(!is_uuid($id)||!$a->can('staff'))throw new pbx_staff_denied('Staff administration is not allowed.');
        $this->db->beginTransaction();try{
            $c=$a->config(true);$r=$this->q("select r.*,u.username,u.user_enabled from v_pbx_staff_roles r join v_users u using(user_uuid) where r.domain_uuid=? and r.staff_role_uuid=? and r.enabled for update of r,u",[$a->domain,$id])->fetch(PDO::FETCH_ASSOC);
            if(!$r||!in_array($r['department_id'],$a->departments('staff',$c),true)||(!$a->owner()&&$r['role']==='owner'))throw new pbx_staff_denied('You cannot renew this invitation.');
            if(filter_var($r['user_enabled'],FILTER_VALIDATE_BOOLEAN)||!$this->q('select 1 from v_pbx_staff_invites where domain_uuid=? and user_uuid=? and consumed_at is null',[$a->domain,$r['user_uuid']])->fetchColumn())throw new InvalidArgumentException('Only an account with a pending invitation can be invited again.');
            $token=bin2hex(random_bytes(32));$this->q('update v_pbx_staff_invites set consumed_at=now(),token_hash=? where domain_uuid=? and user_uuid=? and consumed_at is null',[hash('sha256',random_bytes(32)),$a->domain,$r['user_uuid']]);
            $this->q("insert into v_pbx_staff_invites(invite_uuid,domain_uuid,user_uuid,token_hash,expires_at) values(?,?,?,?,now()+interval '48 hours')",[uuid(),$a->domain,$r['user_uuid'],hash('sha256',$token)]);
            $url='https://'.pbx_paths::host().'/app/pbx_staff/accept.php?invite='.$token;
            if($send)$this->q("insert into v_email_queue(email_queue_uuid,domain_uuid,hostname,email_date,email_to,email_subject,email_body,email_status) values(?,?,?,now(),?,?,?,'waiting')",[uuid(),$a->domain,gethostname(),$r['username'],'Your OpenWeb PBX staff invitation','Create your web password within 48 hours: '.$url]);
            $a->audit('staff_invite_renew',$id);$this->db->commit();return ['invitation_url'=>$url,'email_queued'=>$send];
        }catch(Throwable$e){if($this->db->inTransaction())$this->db->rollBack();throw$e;}
    }
    public function invitation(string $token): ?array {
        if(!preg_match('/^[a-f0-9]{64}$/D',$token))return null;
        return $this->q("select i.invite_uuid,i.domain_uuid,i.user_uuid,u.username from v_pbx_staff_invites i join v_users u using(user_uuid) join v_domains d on d.domain_uuid=i.domain_uuid where i.token_hash=? and i.expires_at>now() and i.consumed_at is null and u.user_enabled='false' and d.domain_enabled='true' and exists(select 1 from v_pbx_staff_roles r where r.domain_uuid=i.domain_uuid and r.user_uuid=i.user_uuid and r.enabled) and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=i.domain_uuid and not t.enabled)",[hash('sha256',$token)])->fetch(PDO::FETCH_ASSOC)?:null;
    }
    public function accept(string $token,string $password): void {
        if(strlen($password)<12||strlen($password)>72||str_contains($password,"\0"))throw new InvalidArgumentException('Choose a password between 12 and 72 bytes.');
        $this->db->beginTransaction();try{$r=$this->invitation($token);if(!$r)throw new InvalidArgumentException('This invitation has expired or was already used.');
            $locked=$this->q('select invite_uuid from v_pbx_staff_invites where invite_uuid=? and consumed_at is null for update',[$r['invite_uuid']])->fetchColumn();if(!$locked||!$this->invitation($token))throw new InvalidArgumentException('This invitation is no longer available.');
            $this->q("update v_users set password=?,user_enabled=true where user_uuid=? and domain_uuid=? and user_enabled='false'",[password_hash($password,PASSWORD_DEFAULT),$r['user_uuid'],$r['domain_uuid']]);$this->q('update v_pbx_staff_invites set consumed_at=now(),token_hash=? where invite_uuid=?',[hash('sha256',random_bytes(32)),$r['invite_uuid']]);$this->db->commit();
        }catch(Throwable$e){if($this->db->inTransaction())$this->db->rollBack();throw$e;}
    }
}
