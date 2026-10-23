<?php
/** QA path boundary only; inputs have already passed realpath and link checks. */
function windows_welcome_owned_paths(string $input,string $work,string $expected):bool {
    return strcasecmp(dirname($input),$expected)===0
        && basename($input)==='input.json'
        && strcasecmp(dirname($work),$expected.'/evidence')===0
        && preg_match('/^welcome-[a-f0-9]{24}$/D',basename($work))===1;
}
