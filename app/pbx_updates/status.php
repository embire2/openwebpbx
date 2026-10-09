<?php
require_once dirname(__DIR__,2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
header('Cache-Control: no-store'); header('Content-Type: application/json; charset=utf-8');
header('X-Content-Type-Options: nosniff');
if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'GET') { header('Allow: GET'); http_response_code(405); exit('{}'); }
try { echo json_encode((new pbx_updates)->status(), JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES); }
catch (DomainException) { http_response_code(403); echo '{"error":"Access denied."}'; }
catch (Throwable) { http_response_code(503); echo '{"error":"Update status is temporarily unavailable."}'; }
