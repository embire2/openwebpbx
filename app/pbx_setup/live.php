<?php
require_once dirname(__DIR__,2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
header('Content-Type: application/json');header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');header('X-Content-Type-Options: nosniff');
try{
    $core=new pbx_core;$now=time();$rate=$_SESSION['pbx_core_rate']??['start'=>$now,'count'=>0];if($now-$rate['start']>=60)$rate=['start'=>$now,'count'=>0];$rate['count']++;$_SESSION['pbx_core_rate']=$rate;if($rate['count']>90){http_response_code(429);throw new RuntimeException('Wait a moment before refreshing.');}
    if($_SERVER['REQUEST_METHOD']==='POST'){
        if(!(new token)->validate('/app/pbx_setup/live.php')){http_response_code(403);throw new RuntimeException('Refresh the call list and try again.');}
        $message=($_POST['operation']??'')==='agent'?$core->agent($_POST):$core->control($_POST);$result=['message'=>$message];
    }elseif($_SERVER['REQUEST_METHOD']==='GET'){$result=$core->live();}
    else{http_response_code(405);throw new RuntimeException('Use the call controls on this page.');}
    $result['token']=(new token)->create('/app/pbx_setup/live.php');echo json_encode($result,JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES);
}catch(pbx_core_access $e){http_response_code(403);echo json_encode(['error'=>$e->getMessage()]);}
catch(OutOfBoundsException|InvalidArgumentException $e){http_response_code(422);echo json_encode(['error'=>$e->getMessage(),'token'=>(new token)->create('/app/pbx_setup/live.php')]);}
catch(Throwable $e){if(http_response_code()===200)http_response_code(503);echo json_encode(['error'=>$e instanceof PDOException?'The call list is not ready. Ask your administrator to complete the server update.':$e->getMessage(),'token'=>(new token)->create('/app/pbx_setup/live.php')]);}
