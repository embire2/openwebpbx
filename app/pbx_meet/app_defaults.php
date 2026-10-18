<?php
if(PHP_SAPI==='cli'){
    $meet_db=database::new()->db;
    // Fresh defaults visit Meet before sip_profiles. Stock phone-profile import
    // runs only while its table is empty; the explicit bootstrap installs Meet
    // once those ordinary phone profiles have been initialized and guarded.
    if($meet_db->query("select 1 from v_sip_profiles where sip_profile_name in ('internal','internal-ipv6') and sip_profile_enabled=true limit 1")->fetchColumn()){
        pbx_meet_install::apply($meet_db);pbx_meet_install::tls();
    }
    unset($meet_db);
}
