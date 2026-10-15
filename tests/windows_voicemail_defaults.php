<?php
/**
 * CLI-only checks of the real voicemail defaults filesystem migration.
 * Uses owned temporary XML files, a genuine private config singleton and SQLite.
 * No application bootstrap, installed configuration or engine is loaded.
 * Usage: php tests/windows_voicemail_defaults.php [source-root]
 */
if (PHP_SAPI !== 'cli') {
    exit(2);
}
if (!in_array('sqlite', PDO::getAvailableDrivers(), true)) {
    throw new RuntimeException('The isolated test requires PDO SQLite.');
}
$sourceRoot = realpath($argv[1] ?? dirname(__DIR__));
if ($sourceRoot === false || !is_file($sourceRoot.'/app/voicemails/app_defaults.php')) {
    throw new RuntimeException('Supply the source tree containing voicemail app_defaults.php.');
}
require $sourceRoot.'/resources/classes/config.php';

final class VoicemailDefaultsFixtureSettings {
    public function __construct(public array $values) {}
    public function get(string $category, string $subcategory): mixed {
        return $this->values[$category.'.'.$subcategory] ?? null;
    }
}

final class VoicemailDefaultsFixtureDatabase {
    public PDO $pdo;
    public int $operations = 0;
    public function __construct() {
        $this->pdo = new PDO('sqlite::memory:', null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
        $this->pdo->exec('CREATE TABLE v_domains(domain_uuid TEXT, domain_name TEXT);
            CREATE TABLE v_voicemails(domain_uuid TEXT, voicemail_id TEXT, voicemail_enabled TEXT,
                voicemail_recording_instructions INTEGER, voicemail_recording_options INTEGER, voicemail_file TEXT);
            CREATE TABLE v_default_settings(default_setting_category TEXT, default_setting_subcategory TEXT,
                default_setting_name TEXT, default_setting_value TEXT, default_setting_enabled INTEGER);
            INSERT INTO v_domains VALUES (\'owned-domain\', \'voicemail-fixture.invalid\');
            INSERT INTO v_voicemails VALUES (\'owned-domain\', \'1001\', \'true\', NULL, NULL, NULL);
            INSERT INTO v_voicemails VALUES (\'owned-domain\', \'1002\', \'false\', 0, 0, \'custom\');
            INSERT INTO v_default_settings VALUES (\'switch\', \'phrases\', \'dir\', \'owned-old-path\', 1);');
    }
    public function select(string $sql, mixed $parameters = null, string $type = 'all'): array {
        $this->operations++;
        return $this->pdo->query($sql)->fetchAll(PDO::FETCH_ASSOC);
    }
    public function execute(string $sql): int {
        $this->operations++;
        return $this->pdo->exec($sql);
    }
    public function snapshot(): array {
        $result = [];
        foreach (['v_domains', 'v_voicemails', 'v_default_settings'] as $table) {
            $result[$table] = $this->pdo->query('SELECT * FROM '.$table.' ORDER BY rowid')->fetchAll(PDO::FETCH_ASSOC);
        }
        return $result;
    }
}

$root = str_replace('\\', '/', sys_get_temp_dir()).'/openweb voicemail defaults '.bin2hex(random_bytes(8));
if (!mkdir($root, 0700)) {
    throw new RuntimeException('Unable to create owned temporary test directory.');
}
$project = $root.'/private project';
$originalIncludePath = get_include_path();
$originalServer = $_SERVER;
$checks = 0;
$check = static function (bool $ok, string $label) use (&$checks): void {
    if (!$ok) {
        throw new RuntimeException($label);
    }
    $checks++;
};
$mkdir = static function (string $path): void {
    if (!is_dir($path) && !mkdir($path, 0700, true)) {
        throw new RuntimeException('Unable to create owned fixture directory.');
    }
};
$mainXml = '<include><!-- preserve main marker --><X-PRE-PROCESS cmd="include" data="lang/en/en.xml"/></include>';
$languageXml = '<include><!-- preserve language marker --><X-PRE-PROCESS cmd="include" data="vm/sounds.xml"/></include>';
$makeConf = static function (string $path, string $folder = 'languages') use ($mkdir, $mainXml, $languageXml): void {
    $mkdir($path.'/'.$folder.'/en/vm');
    file_put_contents($path.'/freeswitch.xml', $mainXml);
    file_put_contents($path.'/'.$folder.'/en/en.xml', $languageXml);
};
$loadConfig = static function (string $name, ?string $conf) use ($root, $project): void {
    $ini = 'document.root = "'.str_replace('\\', '/', $project).'"'.PHP_EOL;
    if ($conf !== null) {
        $ini .= 'switch.conf.dir = "'.str_replace('\\', '/', $conf).'"'.PHP_EOL;
    }
    $file = $root.'/'.$name.'.conf';
    file_put_contents($file, $ini);
    config::$config = null;
    config::load($file);
};
$fixture = static function (string $name, ?string $conf, ?string $languages) use ($root): array {
    $db = new VoicemailDefaultsFixtureDatabase();
    $insert = $db->pdo->prepare('INSERT INTO v_default_settings VALUES (\'switch\', \'languages\', \'dir\', ?, 1)');
    $insert->execute([$languages]);
    $settings = new VoicemailDefaultsFixtureSettings([
        'switch.conf' => $conf, 'switch.languages' => $languages, 'switch.voicemail' => $root.'/'.$name.'/owned voicemail',
    ]);
    return [$db, $settings];
};
$run = static function (VoicemailDefaultsFixtureDatabase $database, VoicemailDefaultsFixtureSettings $settings) use ($sourceRoot): void {
    $domains_processed = 1;
    include $sourceRoot.'/app/voicemails/app_defaults.php';
};
$verifyXml = static function (string $conf, string $expectedVoicemail) use ($check, $mainXml, $languageXml): void {
    $check(file_get_contents($conf.'/freeswitch.xml') === str_replace('data="lang/', 'data="languages/', $mainXml), 'Actual main XML migration preserves unrelated bytes');
    $check(file_get_contents($conf.'/languages/en/en.xml') === str_replace('data="vm/sounds.xml"', 'data="vm/*.xml"', $languageXml), 'Actual language XML migration preserves unrelated bytes');
    $check(file_get_contents($conf.'/languages/en/vm/voicemail.xml') === $expectedVoicemail, 'Actual voicemail XML copied from expected source byte for byte');
};

try {
    $bundleDir = $project.'/app/switch/resources/conf/languages/en/vm';
    $mkdir($bundleDir);
    $bundle = file_get_contents($sourceRoot.'/app/switch/resources/conf/languages/en/vm/voicemail.xml');
    if ($bundle === false || $bundle === '') {
        throw new RuntimeException('The actual bundled English voicemail XML is required.');
    }
    file_put_contents($bundleDir.'/voicemail.xml', $bundle);

    // A DB override wins over a distinct installed config path, including spaces.
    $explicit = $root.'/explicit override/conf with spaces';
    $unused = $root.'/unused configured/conf with spaces';
    $makeConf($explicit);
    $makeConf($unused);
    $loadConfig('explicit', $unused);
    $dbConf = PHP_OS_FAMILY === 'Windows' ? str_replace('/', '\\', $explicit).'\\' : $explicit.'/';
    [$db, $settings] = $fixture('explicit override', $dbConf, '/languages');
    $run($db, $settings);
    $verifyXml($explicit, $bundle);
    $check(file_get_contents($unused.'/freeswitch.xml') === $mainXml && !file_exists($unused.'/languages/en/vm/voicemail.xml'), 'Explicit database override does not mutate configured alternative');
    $check($settings->get('switch', 'conf') === $dbConf, 'Explicit configuration value retained exactly');
    $check(is_dir($settings->get('switch', 'voicemail').'/default/voicemail-fixture.invalid/1001'), 'Enabled owned mailbox directory created');
    $check(!file_exists($settings->get('switch', 'voicemail').'/default/voicemail-fixture.invalid/1002'), 'Disabled owned mailbox directory not created');
    $rows = $db->pdo->query('SELECT * FROM v_voicemails ORDER BY voicemail_id')->fetchAll(PDO::FETCH_ASSOC);
    $check($rows[0]['voicemail_recording_instructions'] === 1 && $rows[0]['voicemail_recording_options'] === 1 && $rows[0]['voicemail_file'] === 'attach', 'Actual nullable voicemail defaults migrated through SQL');
    $check($rows[1]['voicemail_recording_instructions'] === 0 && $rows[1]['voicemail_recording_options'] === 0 && $rows[1]['voicemail_file'] === 'custom', 'Explicit voicemail values preserved');
    $check((int)$db->pdo->query("SELECT count(*) FROM v_default_settings WHERE default_setting_subcategory='phrases'")->fetchColumn() === 0, 'Actual obsolete phrases setting removed');
    $check($db->pdo->query("SELECT default_setting_value FROM v_default_settings WHERE default_setting_subcategory='languages'")->fetchColumn() === '/languages', 'Nonlegacy source languages value preserved');

    // Existing local target phrases must survive repeat migrations.
    $custom = '<include><!-- owned custom voicemail phrases --></include>';
    file_put_contents($explicit.'/languages/en/vm/voicemail.xml', $custom);
    $dbBeforeRepeat = $db->snapshot();
    $run($db, $settings);
    $verifyXml($explicit, $custom);
    $check($db->snapshot() === $dbBeforeRepeat, 'Repeat defaults migration is database-idempotent');

    // Retain the original app-local override contract when such a file exists.
    $overrideDir = $project.'/app/voicemails/resources/switch/languages/en/vm';
    $mkdir($overrideDir);
    $override = '<include><!-- owned app-local override --></include>';
    file_put_contents($overrideDir.'/voicemail.xml', $override);
    $overrideConf = $root.'/app override/conf';
    $makeConf($overrideConf);
    $loadConfig('app-override', null);
    [$db, $settings] = $fixture('app override', $overrideConf, '/languages');
    $run($db, $settings);
    $verifyXml($overrideConf, $override);
    unlink($overrideDir.'/voicemail.xml');

    // Exercise the real legacy folder rename plus the SQL languages update.
    $legacy = $root.'/legacy rename/conf';
    $makeConf($legacy, 'lang');
    $loadConfig('legacy', null);
    [$db, $settings] = $fixture('legacy rename', $legacy, $legacy.'/lang');
    $run($db, $settings);
    $verifyXml($legacy, $bundle);
    $check(!file_exists($legacy.'/lang') && is_dir($legacy.'/languages'), 'Actual legacy language directory renamed');
    $check($db->pdo->query("SELECT default_setting_value FROM v_default_settings WHERE default_setting_subcategory='languages'")->fetchColumn() === $legacy.'/languages', 'Actual language directory SQL value relocated');

    if (PHP_OS_FAMILY === 'Windows') {
        // Original Windows DB conf is NULL and languages may be /languages.
        $installedConf = $root.'/Windows installed/conf with spaces';
        $makeConf($installedConf);
        $loadConfig('windows-config', $installedConf);
        $check(config::load()->get('switch.conf.dir') === $installedConf, 'Genuine private configuration singleton supplies Windows engine path');
        [$db, $settings] = $fixture('Windows installed', null, '/languages');
        $run($db, $settings);
        $verifyXml($installedConf, $bundle);
        $check($settings->get('switch', 'conf') === null, 'Windows fallback does not invent a database conf override');
        $check($db->pdo->query("SELECT default_setting_value FROM v_default_settings WHERE default_setting_subcategory='languages'")->fetchColumn() === '/languages', 'Windows fallback retains unrelated explicit source languages setting');

        foreach ([null, '', '   ', $root.'/absent configuration', $root.'/not a directory'] as $index => $badConf) {
            if ($index === 4) {
                file_put_contents($badConf, 'owned non-directory fixture');
            }
            $loadConfig('windows-invalid-'.$index, $badConf);
            [$db, $settings] = $fixture('Windows invalid '.$index, null, '/languages');
            $before = $db->snapshot();
            $rejected = false;
            try {
                $run($db, $settings);
            } catch (RuntimeException $error) {
                $rejected = $error->getMessage() === 'The Windows call-engine configuration directory is unavailable.';
            }
            $check($rejected, 'Missing or unusable Windows configured directory refuses migration');
            $check($db->operations === 0 && $db->snapshot() === $before && !file_exists($settings->get('switch', 'voicemail')), 'Invalid Windows config refuses before filesystem or database mutations');
        }
    } else {
        // Never run the empty-conf Linux branch: it targets installed /etc/freeswitch.
        echo "SKIP: Windows configured-path fallback/refusal needs native Windows PHP; Linux empty-conf branch intentionally not executed.\n";
    }
    echo 'PASS: '.$checks.' actual voicemail defaults XML, SQL and filesystem checks ('.PHP_OS_FAMILY.").\n";
} finally {
    config::$config = null;
    set_include_path($originalIncludePath);
    $_SERVER = $originalServer;
    $files = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
    foreach ($files as $file) {
        if ($file->isDir() && !$file->isLink()) {
            rmdir($file->getPathname());
        } else {
            unlink($file->getPathname());
        }
    }
    rmdir($root);
}
