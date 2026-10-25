<?php
// Shared by the desktop shell and classic pages. No changes to Debian or public pages.
if (PHP_OS_FAMILY !== 'Windows' || empty($_SESSION['authorized'])) return;
$windowsUpdateToken = permission_exists('pbx_update_instance') && permission_exists('pbx_update_manage')
    ? (new token)->create('/app/pbx_updates/index.php') : null;
$windowsUpdateEscape = static fn($s) => htmlspecialchars((string)$s, ENT_QUOTES, 'UTF-8');
?>
<link rel="stylesheet" href="/app/pbx_updates/notice.css?v=1">
<script src="/app/pbx_updates/notice.js?v=1" defer></script>
<aside id="windows-server-update" role="region" aria-label="Windows Server update required" hidden>
 <span data-server-update-message role="status"></span>
 <?php if ($windowsUpdateToken): ?>
 <form method="post" action="/app/pbx_updates/index.php" data-server-update-form>
  <input type="hidden" name="<?= $windowsUpdateEscape($windowsUpdateToken['name']) ?>" value="<?= $windowsUpdateEscape($windowsUpdateToken['hash']) ?>">
  <button type="submit" name="action" value="install" data-server-update-install>Update now</button>
 </form>
 <?php endif; ?>
 <span data-server-update-detail></span>
</aside>
<?php unset($windowsUpdateToken, $windowsUpdateEscape); ?>
