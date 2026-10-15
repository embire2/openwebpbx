<?php
/** Add new Windows release defaults without restoring an administrator's choices. */
class pbx_upgrade_defaults {
    private PDO $db;
    private string $current;
    private string $previous;

    public function __construct(PDO $db, string $current, string $previous) {
        if (PHP_SAPI !== 'cli') throw new RuntimeException('Instance upgrade initialization requires the command line.');
        $this->db = $db;
        $this->db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $this->current = $this->root($current);
        $this->previous = $this->root($previous);
        if ($this->current === $this->previous) throw new RuntimeException('A separate sealed previous source tree is required.');
    }

    private function root(string $path): string {
        $real = realpath($path);
        if ($real === false || !is_dir($real) || is_link($path) || !is_file($real.'/resources/require.php')) throw new RuntimeException('Upgrade source metadata is unavailable.');
        return str_replace('\\', '/', $real);
    }

    private function query(string $sql, array $values = []): PDOStatement {
        $statement = $this->db->prepare($sql);
        foreach (array_values($values) as $index => $value) $statement->bindValue($index + 1, $value, $value === null ? PDO::PARAM_NULL : (is_bool($value) ? PDO::PARAM_BOOL : (is_int($value) ? PDO::PARAM_INT : PDO::PARAM_STR)));
        $statement->execute();
        return $statement;
    }

    private function insert(string $table, array $row): void {
        $fields = array_keys($row);
        foreach ($fields as $field) if (!preg_match('/^[a-z_]+$/D', $field)) throw new RuntimeException('Upgrade metadata has an invalid field.');
        $this->query('insert into '.$table.' ('.implode(',', $fields).') values ('.implode(',', array_fill(0, count($fields), '?')).')', array_values($row));
    }

    private function id($value): string {
        if (!is_string($value) || !preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/Di', $value)) throw new RuntimeException('Upgrade metadata has an invalid stable identifier.');
        return strtolower($value);
    }

    private function metadata(string $root): array {
        $files = array_merge(glob($root.'/*/*/app_config.php') ?: [], glob($root.'/*/*/app_menu.php') ?: []);
        if (!$files || count($files) > 4096) throw new RuntimeException('Upgrade application metadata is unavailable.');
        // Metadata is trusted code from the installed, sealed source backup or
        // reviewed candidate. Keep include variables separate from caller state.
        $apps = (static function(array $files): array {
            $apps = []; $x = 0;
            foreach ($files as $file) {
                if (is_link($file) || is_link(dirname($file))) throw new RuntimeException('Linked upgrade metadata is not supported.');
                $app_path = '/'.basename(dirname($file, 2)).'/'.basename(dirname($file));
                $y = 0; include $file; $x++;
            }
            return $apps;
        })($files);
        $result = ['settings'=>[], 'permission_names'=>[], 'permissions'=>[], 'menus'=>[], 'dialplans'=>[]];
        foreach ($apps as $app) {
            foreach ($app['default_settings'] ?? [] as $row) {
                $id = $this->id($row['default_setting_uuid'] ?? null);
                $row['app_uuid'] = $app['uuid'] ?? null;
                $result['settings'][$id][] = $row;
            }
            foreach ($app['permissions'] ?? [] as $row) {
                $name = $row['name'] ?? null;
                if (!is_string($name) || !preg_match('/^[a-z0-9_]{1,160}$/D', $name)) throw new RuntimeException('Invalid permission metadata.');
                $definition = ['application_uuid'=>$this->id($app['uuid'] ?? null), 'application_name'=>$app['name'] ?? null, 'permission_description'=>$row['description']['en-us'] ?? $row['description'] ?? null];
                if (!is_string($definition['application_name']) || ($definition['permission_description'] !== null && !is_string($definition['permission_description']))) throw new RuntimeException('Invalid permission application metadata.');
                if (!in_array($definition, $result['permission_names'][$name] ?? [], true)) $result['permission_names'][$name][] = $definition;
                foreach ($row['groups'] ?? [] as $group) {
                    if (!is_string($group) || !preg_match('/^[a-z0-9_]{1,80}$/D', $group)) throw new RuntimeException('Invalid group metadata.');
                    $result['permissions'][$group.'|'.$name] = ['group'=>$group, 'name'=>$name];
                }
            }
            foreach ($app['menu'] ?? [] as $row) {
                $id = $this->id($row['uuid'] ?? null);
                if (isset($result['menus'][$id])) throw new RuntimeException('Ambiguous menu metadata.');
                $result['menus'][$id] = $row;
            }
        }
        foreach (glob($root.'/*/*/resources/switch/conf/dialplan/*.xml') ?: [] as $file) {
            if (is_link($file) || filesize($file) > 1048576) throw new RuntimeException('Invalid stock dialplan metadata.');
            $text = file_get_contents($file);
            if ($text === false || preg_match('/<!\s*(DOCTYPE|ENTITY)\b/i', $text)) throw new RuntimeException('Invalid stock dialplan XML.');
            $xml = new DOMDocument();
            if (!$xml->loadXML($text, LIBXML_NONET) || $xml->documentElement->tagName !== 'extension') throw new RuntimeException('Invalid stock dialplan XML.');
            $id = $this->id($xml->documentElement->getAttribute('app_uuid'));
            if (isset($result['dialplans'][$id])) throw new RuntimeException('Ambiguous stock dialplan metadata.');
            $result['dialplans'][$id] = true;
        }
        if (!$result['menus'] || !$result['permissions'] || !$result['dialplans']) throw new RuntimeException('Incomplete previous or candidate metadata.');
        return $result;
    }

    public function apply(): array {
        $current = $this->metadata($this->current);
        $previous = $this->metadata($this->previous);
        foreach ($current['settings'] as $id => $rows) {
            // Some historical source defaults share an identifier. Preserve
            // their installed choices; never introduce a new ambiguous one.
            if (count($rows) > 1 && $rows !== ($previous['settings'][$id] ?? null)) throw new RuntimeException('Ambiguous new default-setting metadata.');
        }
        foreach ($current['permission_names'] as $name => $definitions) if (count($definitions) > 1 && $definitions !== ($previous['permission_names'][$name] ?? null)) throw new RuntimeException('Ambiguous new permission application metadata.');
        $database = database::new();
        if ($database->db !== $this->db || $this->current !== str_replace('\\', '/', realpath(PROJECT_ROOT))) throw new RuntimeException('The upgrade initializer requires the current application database and source.');
        $counts = ['settings'=>0, 'permission_catalog'=>0, 'permissions'=>0, 'menus'=>0, 'dialplan_applications'=>0];
        $own = !$this->db->inTransaction();
        if ($own) $this->db->beginTransaction();
        try {
            $this->query("select pg_advisory_xact_lock(1852798057)");
            $groups = [];
            foreach ($this->query('select * from v_groups where domain_uuid is null')->fetchAll(PDO::FETCH_ASSOC) as $group) {
                if (isset($groups[$group['group_name']])) throw new RuntimeException('Ambiguous global group metadata.');
                $groups[$group['group_name']] = $group;
            }
            foreach (array_diff_key($current['settings'], $previous['settings']) as $id => $rows) {
                $row = $rows[0];
                if ($this->query('select 1 from v_default_settings where default_setting_uuid=?', [$id])->fetchColumn()) continue;
                foreach (['default_setting_category','default_setting_subcategory','default_setting_name'] as $field) if (!isset($row[$field]) || !is_string($row[$field])) throw new RuntimeException('Incomplete default-setting metadata.');
                $values = [$row['default_setting_category'], $row['default_setting_subcategory'], $row['default_setting_name']];
                $sql = 'select 1 from v_default_settings where default_setting_category=? and default_setting_subcategory=? and default_setting_name=?';
                if ($row['default_setting_name'] === 'array') {
                    $sql .= ' and default_setting_value is not distinct from ? and default_setting_order is not distinct from ?';
                    $values[] = $row['default_setting_value'] ?? null; $values[] = $row['default_setting_order'] ?? null;
                }
                if ($this->query($sql, $values)->fetchColumn()) continue;
                $allowed = array_flip(['default_setting_uuid','default_setting_category','default_setting_subcategory','default_setting_name','default_setting_value','default_setting_order','default_setting_enabled','default_setting_description','app_uuid']);
                $this->insert('v_default_settings', array_intersect_key($row, $allowed)); $counts['settings']++;
            }
            foreach (array_diff_key($current['permission_names'], $previous['permission_names']) as $name => $definitions) {
                $definition = $definitions[0];
                if ($this->query('select 1 from v_permissions where permission_name=?', [$name])->fetchColumn()) continue;
                $this->insert('v_permissions', ['permission_uuid'=>uuid(), 'permission_name'=>$name] + $definition);
                $counts['permission_catalog']++;
            }
            foreach (array_diff_key($current['permissions'], $previous['permissions']) as $definition) {
                $group = $groups[$definition['group']] ?? null;
                if (!$group || $this->truth($group['group_protected'] ?? false)) continue;
                // A scoped deny must never be widened by a new global grant.
                // Existing rows, including false/NULL/protected choices, win.
                if ($this->query('select 1 from v_group_permissions where permission_name=? and ((domain_uuid is null and (group_uuid=? or group_name=?)) or (domain_uuid is not null and (group_uuid=? or group_name=?) and (permission_assigned is null or permission_assigned<>?)))', [$definition['name'], $group['group_uuid'], $definition['group'], $group['group_uuid'], $definition['group'], 'true'])->fetchColumn()) continue;
                $this->insert('v_group_permissions', ['group_permission_uuid'=>uuid(), 'group_uuid'=>$group['group_uuid'], 'group_name'=>$definition['group'], 'permission_name'=>$definition['name'], 'permission_protected'=>'false', 'permission_assigned'=>'true']);
                $counts['permissions']++;
            }
            $menus = $this->query("select * from v_menus where menu_name='default'")->fetchAll(PDO::FETCH_ASSOC);
            if (count($menus) !== 1) throw new RuntimeException('A unique default menu is required.');
            $menu = $menus[0]; $ids = [];
            foreach ($this->query('select * from v_menu_items where menu_uuid=?', [$menu['menu_uuid']])->fetchAll(PDO::FETCH_ASSOC) as $item) {
                if (empty($item['uuid'])) continue;
                $id = $this->id($item['uuid']);
                if (isset($ids[$id])) throw new RuntimeException('Ambiguous existing menu identifiers.');
                $ids[$id] = $item['menu_item_uuid'];
            }
            $new = [];
            foreach (array_diff_key($current['menus'], $previous['menus']) as $id => $definition) if (!isset($ids[$id])) {$ids[$id] = uuid(); $new[$id] = $definition;}
            foreach ($new as $id => $definition) {
                $parent = $definition['parent_uuid'] ?? '';
                $parentId = null;
                if ($parent !== '' && $parent !== null) {
                    $parent = $this->id($parent);
                    if (!isset($ids[$parent])) throw new RuntimeException('A new menu parent is unavailable.');
                    $parentId = $ids[$parent];
                }
                $language = $menu['menu_language'] ?: 'en-us';
                $title = $definition['title'][$language] ?? $definition['title']['en-us'] ?? null;
                if (!is_string($title) || !is_string($definition['path'] ?? null)) throw new RuntimeException('Incomplete new menu metadata.');
                $this->insert('v_menu_items', ['menu_item_uuid'=>$ids[$id], 'menu_uuid'=>$menu['menu_uuid'], 'uuid'=>$id, 'menu_item_title'=>$title, 'menu_item_parent_uuid'=>$parentId, 'menu_item_link'=>$definition['path'], 'menu_item_category'=>$definition['category'] ?? 'internal', 'menu_item_order'=>($definition['order'] ?? '') === '' ? null : $definition['order'], 'menu_item_icon'=>$definition['icon'] ?? null, 'menu_item_icon_color'=>$definition['icon_color'] ?? null, 'menu_item_description'=>$definition['desc'] ?? null]);
                foreach ($definition['title'] ?? [] as $code => $translation) {
                    if (!is_string($code) || !is_string($translation)) throw new RuntimeException('Invalid new menu language metadata.');
                    $this->insert('v_menu_languages', ['menu_language_uuid'=>uuid(), 'menu_uuid'=>$menu['menu_uuid'], 'menu_item_uuid'=>$ids[$id], 'menu_language'=>$code, 'menu_item_title'=>$translation]);
                }
                foreach ($definition['groups'] ?? [] as $name) {
                    $group = $groups[$name] ?? null;
                    if ($group) $this->insert('v_menu_item_groups', ['menu_item_group_uuid'=>uuid(), 'menu_uuid'=>$menu['menu_uuid'], 'menu_item_uuid'=>$ids[$id], 'group_uuid'=>$group['group_uuid'], 'group_name'=>$name]);
                }
                $counts['menus']++;
            }
            $applications = array_keys(array_diff_key($current['dialplans'], $previous['dialplans']));
            if ($applications) {
                // The ordinary importer retains existing/custom/disabled rows;
                // the filter prevents reintroducing deliberately deleted old defaults.
                $dialplan = new dialplan(['database'=>$database]);
                $dialplan->import($this->query('select * from v_domains')->fetchAll(PDO::FETCH_ASSOC), $applications);
                $counts['dialplan_applications'] = count($applications);
            }
            if ($own) $this->db->commit();
            return $counts;
        } catch (Throwable $error) {
            if ($own && $this->db->inTransaction()) $this->db->rollBack();
            throw $error;
        }
    }

    /** Retain the supported legacy Windows phrase layout without replaying voicemail defaults. */
    public function voicemailFiles(string $configuration): array {
        $conf = realpath($configuration);
        if ($conf === false || !is_dir($conf) || is_link($configuration)) throw new RuntimeException('The installed phrase configuration is unavailable.');
        $conf = str_replace('\\', '/', $conf);
        $legacy = $conf.'/lang'; $languages = $conf.'/languages';
        $selected = $this->query("select default_setting_uuid from v_default_settings where default_setting_category='switch' and default_setting_subcategory='languages' and default_setting_name='dir' and default_setting_enabled=true and default_setting_value=?", [$legacy])->fetchAll(PDO::FETCH_COLUMN);
        $counts = ['language_paths'=>0, 'includes'=>0, 'phrase_files'=>0];
        if ($selected) {
            // The exact selected old layout may move only when its destination
            // is absent. Two trees cannot be reconciled without operator input.
            if (!is_dir($legacy) || is_link($legacy) || file_exists($languages) || is_link($languages)) throw new RuntimeException('The legacy phrase layout is ambiguous.');
            if (!rename($legacy, $languages)) throw new RuntimeException('The legacy phrase layout could not be migrated.');
            foreach ($selected as $id) $counts['language_paths'] += $this->query('update v_default_settings set default_setting_value=? where default_setting_uuid=? and default_setting_value=? and default_setting_enabled=true', [$languages, $id, $legacy])->rowCount();
        }
        if (!is_dir($languages)) return $counts;
        if (is_link($languages)) throw new RuntimeException('Linked phrase directories are not supported.');
        $main = $conf.'/freeswitch.xml';
        if (is_file($main)) $counts['includes'] += $this->phraseInclude($main, 'lang/', 'languages/', true) ? 1 : 0;
        foreach (scandir($languages) as $language) {
            if ($language === '.' || $language === '..') continue;
            if (!preg_match('/^[a-z]{2}(?:-[a-z]{2})?$/Di', $language) || !is_dir($languages.'/'.$language)) continue;
            $directory = $languages.'/'.$language;
            if (is_link($directory)) throw new RuntimeException('Linked phrase directories are not supported.');
            $include = $directory.'/'.$language.'.xml';
            if (is_file($include)) $counts['includes'] += $this->phraseInclude($include, 'vm/sounds.xml', 'vm/*.xml') ? 1 : 0;
            $target = $directory.'/vm/voicemail.xml';
            if (is_link($directory.'/vm') || is_link($target)) throw new RuntimeException('Linked phrase files are not supported.');
            if (file_exists($target)) continue;
            $source = $this->current.'/app/voicemails/resources/switch/languages/'.$language.'/vm/voicemail.xml';
            if (!is_file($source)) $source = $this->current.'/app/switch/resources/conf/languages/'.$language.'/vm/voicemail.xml';
            if (!is_file($source)) continue; // No bundled phrase exists for this installed language.
            $bytes = $this->phraseXml($source)[0];
            if (!is_dir(dirname($target)) && !mkdir(dirname($target), 0755)) throw new RuntimeException('The phrase directory could not be created.');
            $this->publishPhrase($target, $bytes); $counts['phrase_files']++;
        }
        return $counts;
    }

    private function phraseXml(string $path): array {
        if (is_link($path) || !is_file($path) || filesize($path) > 1048576) throw new RuntimeException('The phrase XML is unavailable.');
        $bytes = file_get_contents($path);
        if ($bytes === false || preg_match('/<!\s*(DOCTYPE|ENTITY)\b/i', $bytes)) throw new RuntimeException('The phrase XML is invalid.');
        $document = new DOMDocument(); $previous = libxml_use_internal_errors(true);
        try { if (!$document->loadXML($bytes, LIBXML_NONET)) throw new RuntimeException('The phrase XML is invalid.'); }
        finally { libxml_clear_errors(); libxml_use_internal_errors($previous); }
        return [$bytes, $document];
    }

    private function phraseInclude(string $path, string $old, string $new, bool $prefix = false): bool {
        [$bytes, $document] = $this->phraseXml($path);
        $matches = (new DOMXPath($document))->query('//X-PRE-PROCESS[@cmd="include" and '.($prefix ? 'starts-with(@data,"'.$old.'")' : '@data="'.$old.'"').']');
        if ($matches->length === 0) return false;
        // Validate the selected nodes and replace their exact attribute bytes;
        // never serialize XML or touch unrelated/custom include targets.
        $pattern = '/(<X-PRE-PROCESS\b(?=[^>]*\bcmd=[\x22\x27]include[\x22\x27])[^>]*\bdata=)([\x22\x27])'.preg_quote($old, '/').'('.($prefix ? '[^\x22\x27]*' : '').')\2/';
        $next = preg_replace_callback($pattern, static fn($match) => $match[1].$match[2].$new.$match[3].$match[2], $bytes, -1, $count);
        if ($next === null || $count !== $matches->length) throw new RuntimeException('The legacy phrase include is ambiguous.');
        $this->publishPhrase($path, $next);
        return true;
    }

    private function publishPhrase(string $target, string $bytes): void {
        $temporary = $target.'.upgrade-'.bin2hex(random_bytes(8));
        try {
            $file = fopen($temporary, 'x'); if (!$file) throw new RuntimeException('The phrase file could not be saved.');
            try { if (fwrite($file, $bytes) !== strlen($bytes) || !fflush($file) || (function_exists('fsync') && !fsync($file))) throw new RuntimeException('The phrase file could not be saved.'); }
            finally { fclose($file); }
            if (!rename($temporary, $target)) throw new RuntimeException('The phrase file could not be published.');
        } finally { if (is_file($temporary)) unlink($temporary); }
    }

    private function truth($value): bool { return $value === true || $value === 'true' || $value === 't' || $value === '1' || $value === 1; }
}
