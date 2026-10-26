<?php

declare(strict_types=1);

/**
 * Universal static-site contact endpoint (Apache + PHP-FPM, InterWorx / crservers).
 *
 * Accepts:
 * - application/x-www-form-urlencoded or multipart/form-data (classic forms)
 * - application/json — flat object, or { "fields": { ... }, "subject": "..." } with extra keys merged
 *
 * Every submitted field (except reserved / honeypots) is emailed as key: value lines.
 * Reply-To is taken from the visitor’s email (see reply_to_field / auto-detect below).
 *
 * SMTP and mail routing:
 * - Prefer environment variables for secrets (SMTP_HOST, SMTP_USER, SMTP_PASSWORD, MAIL_TO, …).
 * - Optional private/smtp.config.php: the domain level (~/DOMAIN/private) wins over the account level (~/private); env overrides when set.
 *
 * Deploy: composer install --no-dev next to contact.php; configure secrets (env and/or private file).
 * AJAX / fetch: send X-Requested-With: XMLHttpRequest or Accept: application/json for JSON responses.
 */

use PHPMailer\PHPMailer\Exception as MailerException;
use PHPMailer\PHPMailer\PHPMailer;

header('X-Content-Type-Options: nosniff');

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    header('Allow: POST');
    exit('Method Not Allowed');
}

function wants_json(): bool
{
    if (isset($_SERVER['HTTP_X_REQUESTED_WITH']) &&
        strtolower((string) $_SERVER['HTTP_X_REQUESTED_WITH']) === 'xmlhttprequest') {
        return true;
    }
    $accept = $_SERVER['HTTP_ACCEPT'] ?? '';
    return stripos($accept, 'application/json') !== false;
}

function client_fail(string $message, int $status = 400): never
{
    if (wants_json()) {
        http_response_code($status);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode(['ok' => false, 'error' => $message], JSON_UNESCAPED_UNICODE);
        exit;
    }
    http_response_code($status);
    header('Content-Type: text/plain; charset=utf-8');
    exit($message);
}

function client_fake_ok(): never
{
    if (wants_json()) {
        http_response_code(200);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode(['ok' => true, 'error' => ''], JSON_UNESCAPED_UNICODE);
        exit;
    }
    http_response_code(204);
    exit;
}

function truncate_utf8(string $s, int $maxChars): string
{
    if ($maxChars <= 0) {
        return '';
    }
    if (function_exists('mb_substr')) {
        return mb_substr($s, 0, $maxChars);
    }
    if (strlen($s) <= $maxChars) {
        return $s;
    }
    $chunk = substr($s, 0, $maxChars);

    return (string) preg_replace('/(?:[\x80-\xBF])+$/', '', $chunk) ?: $chunk;
}

/**
 * @param list<mixed> $timestamps
 * @return list<int>
 */
function rate_prune_timestamps(array $timestamps, int $now, int $window): array
{
    $out = [];
    foreach ($timestamps as $t) {
        if (is_numeric($t) && (int) $t > $now - $window) {
            $out[] = (int) $t;
        }
    }

    return $out;
}

/**
 * @return array{attempts: list<int>, success: list<int>}
 */
function rate_decode_file(string $raw, int $now, int $window): array
{
    $attempts = [];
    $success = [];
    $decoded = json_decode($raw, true);
    if (!is_array($decoded)) {
        return ['attempts' => $attempts, 'success' => $success];
    }
    if (isset($decoded['attempts']) && is_array($decoded['attempts'])) {
        $attempts = rate_prune_timestamps($decoded['attempts'], $now, $window);
    }
    if (isset($decoded['success']) && is_array($decoded['success'])) {
        $success = rate_prune_timestamps($decoded['success'], $now, $window);
    } elseif ($attempts === [] && array_is_list($decoded)) {
        $success = rate_prune_timestamps($decoded, $now, $window);
    }

    return ['attempts' => $attempts, 'success' => $success];
}

/**
 * @param callable(array{attempts: list<int>, success: list<int>}): void $mutator
 */
function rate_update_locked(string $file, int $now, int $window, callable $mutator, bool $fatalOnLockError = true): void
{
    $fp = @fopen($file, 'c+');
    if ($fp === false) {
        if ($fatalOnLockError) {
            client_fail('Server busy. Please try again later.', 503);
        }
        error_log('contact.php: could not open rate-limit file');

        return;
    }
    if (!flock($fp, LOCK_EX)) {
        fclose($fp);
        if ($fatalOnLockError) {
            client_fail('Server busy. Please try again later.', 503);
        }
        error_log('contact.php: could not lock rate-limit file');

        return;
    }
    $raw = stream_get_contents($fp);
    $rate = rate_decode_file($raw === false ? '' : $raw, $now, $window);
    $mutator($rate);
    $encoded = json_encode([
        'attempts' => $rate['attempts'],
        'success' => $rate['success'],
    ]);
    ftruncate($fp, 0);
    rewind($fp);
    if ($encoded !== false) {
        fwrite($fp, $encoded);
    }
    fflush($fp);
    flock($fp, LOCK_UN);
    fclose($fp);
}

function ipv4_in_cidr(string $ip, string $cidr): bool
{
    if (strpos($ip, ':') !== false || strpos($cidr, ':') !== false) {
        return false;
    }
    $parts = explode('/', $cidr, 2);
    if (count($parts) !== 2) {
        return false;
    }
    $subnet = ip2long($parts[0]);
    $maskBits = (int) $parts[1];
    $addr = ip2long($ip);
    if ($subnet === false || $addr === false || $maskBits < 0 || $maskBits > 32) {
        return false;
    }
    $mask = $maskBits === 0 ? 0 : (-1 << (32 - $maskBits));

    return ($addr & $mask) === ($subnet & $mask);
}

/**
 * Cloudflare published IPv4 ranges (https://www.cloudflare.com/ips-v4).
 *
 * @return list<string>
 */
function cloudflare_ipv4_cidrs(): array
{
    return [
        '173.245.48.0/20',
        '103.21.244.0/22',
        '103.22.200.0/22',
        '103.31.4.0/22',
        '141.101.64.0/18',
        '108.162.192.0/18',
        '190.93.240.0/20',
        '188.114.96.0/20',
        '197.234.240.0/22',
        '198.41.128.0/17',
        '162.158.0.0/15',
        '104.16.0.0/13',
        '104.24.0.0/14',
        '172.64.0.0/13',
        '131.0.72.0/22',
    ];
}

/**
 * @return list<string>
 */
function cloudflare_ipv6_cidrs(): array
{
    return [
        '2400:cb00::/32',
        '2606:4700::/32',
        '2803:f800::/32',
        '2405:b500::/32',
        '2405:8100::/32',
        '2a06:98c0::/29',
        '2c0f:f248::/32',
    ];
}

function ipv6_in_cidr(string $ip, string $cidr): bool
{
    $parts = explode('/', $cidr, 2);
    if (count($parts) !== 2) {
        return false;
    }
    $bits = (int) $parts[1];
    $ipBin = inet_pton($ip);
    $subBin = inet_pton($parts[0]);
    if ($ipBin === false || $subBin === false || $bits < 0 || $bits > 128) {
        return false;
    }
    $fullBytes = (int) floor($bits / 8);
    $remainder = $bits % 8;
    if ($fullBytes > 0 && substr($ipBin, 0, $fullBytes) !== substr($subBin, 0, $fullBytes)) {
        return false;
    }
    if ($remainder === 0) {
        return true;
    }
    $mask = (0xFF << (8 - $remainder)) & 0xFF;

    return (ord($ipBin[$fullBytes]) & $mask) === (ord($subBin[$fullBytes]) & $mask);
}

function remote_addr_is_cloudflare(string $remoteAddr): bool
{
    if (filter_var($remoteAddr, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
        foreach (cloudflare_ipv4_cidrs() as $cidr) {
            if (ipv4_in_cidr($remoteAddr, $cidr)) {
                return true;
            }
        }

        return false;
    }
    if (filter_var($remoteAddr, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) {
        foreach (cloudflare_ipv6_cidrs() as $cidr) {
            if (ipv6_in_cidr($remoteAddr, $cidr)) {
                return true;
            }
        }
    }

    return false;
}

/**
 * Visitor IP for rate limits, logging, and Turnstile verify.
 * CF-Connecting-IP is used only when REMOTE_ADDR is a Cloudflare edge (not forgeable via headers alone).
 *
 * @param array<string, mixed> $cfg
 */
function resolve_client_ip(array $cfg): string
{
    $remote = trim((string) ($_SERVER['REMOTE_ADDR'] ?? '0.0.0.0'));
    $useCf = !isset($cfg['trust_cloudflare_ip']) || $cfg['trust_cloudflare_ip'] !== false;
    if ($useCf && remote_addr_is_cloudflare($remote)) {
        foreach (['HTTP_CF_CONNECTING_IP', 'HTTP_CF_CONNECTING_IPV6'] as $hdr) {
            if (empty($_SERVER[$hdr])) {
                continue;
            }
            $cf = trim((string) $_SERVER[$hdr]);
            if (filter_var($cf, FILTER_VALIDATE_IP)) {
                return $cf;
            }
        }
    }
    if (!empty($cfg['trust_forwarded_for']) && $cfg['trust_forwarded_for'] === true
        && !empty($_SERVER['HTTP_X_FORWARDED_FOR'])) {
        $parts = array_map('trim', explode(',', (string) $_SERVER['HTTP_X_FORWARDED_FOR']));
        foreach ($parts as $candidate) {
            if (filter_var($candidate, FILTER_VALIDATE_IP)) {
                return $candidate;
            }
        }
    }

    return $remote !== '' ? $remote : '0.0.0.0';
}

/**
 * Per-install, per-site rate-limit state (not shared across vhosts on the same host).
 *
 * @param array<string, mixed> $cfg
 */
function rate_limit_file_path(string $clientIp, array $cfg): string
{
    $siteKey = isset($cfg['rate_limit_site_id']) ? trim((string) $cfg['rate_limit_site_id']) : '';
    if ($siteKey === '') {
        $siteKey = substr(hash('sha256', __DIR__), 0, 16);
    }
    $dir = __DIR__ . '/.rate-limit';
    if (!is_dir($dir)) {
        @mkdir($dir, 0700, true);
        @file_put_contents($dir . '/.htaccess', "Require all denied\n");
    }

    return $dir . '/rl-' . $siteKey . '-' . hash('sha256', $clientIp) . '.json';
}

/**
 * Non-empty getenv overrides $cfg keys (SMTP secrets from hosting / injectors).
 *
 * @param array<string, mixed> $cfg
 * @return array<string, mixed>
 */
function merge_env_smtp(array $cfg): array
{
    $map = [
        'SMTP_HOST' => 'smtp_host',
        'SMTP_PORT' => 'smtp_port',
        'SMTP_SECURE' => 'smtp_secure',
        'SMTP_USER' => 'smtp_user',
        'SMTP_PASS' => 'smtp_pass',
        'SMTP_PASSWORD' => 'smtp_pass',
        'MAIL_FROM_EMAIL' => 'mail_from_email',
        'MAIL_FROM_NAME' => 'mail_from_name',
        'MAIL_TO' => 'mail_to',
        'MAIL_TO_NAME' => 'mail_to_name',
        'TURNSTILE_SECRET' => 'turnstile_secret',
        'REDIRECT_SUCCESS_URL' => 'redirect_success_url',
        'DEFAULT_MAIL_SUBJECT' => 'default_mail_subject',
        'REPLY_TO_FIELD' => 'reply_to_field',
    ];
    foreach ($map as $envName => $cfgKey) {
        $v = getenv($envName);
        if ($v !== false && $v !== '') {
            if ($cfgKey === 'smtp_port') {
                $cfg[$cfgKey] = (int) $v;
            } else {
                $cfg[$cfgKey] = $v;
            }
        }
    }
    return $cfg;
}

/**
 * @return array<string, string>
 */
function parse_post_payload(): array
{
    $ct = $_SERVER['CONTENT_TYPE'] ?? '';
    if (stripos($ct, 'application/json') !== false) {
        $raw = file_get_contents('php://input');
        $j = json_decode($raw ?: 'null', true);
        if (!is_array($j)) {
            client_fail('Invalid JSON body.', 400);
        }
        if (isset($j['fields']) && is_array($j['fields'])) {
            $out = [];
            foreach ($j['fields'] as $k => $v) {
                $out[(string) $k] = $v;
            }
            $occupied = [];
            foreach (array_keys($out) as $fk) {
                $occupied[strtolower((string) $fk)] = true;
            }
            foreach ($j as $k => $v) {
                if ($k === 'fields' || !is_scalar($v)) {
                    continue;
                }
                $lk = strtolower((string) $k);
                if (isset($occupied[$lk])) {
                    continue;
                }
                $out[(string) $k] = $v;
                $occupied[$lk] = true;
            }
            return $out;
        }
        $flat = [];
        foreach ($j as $k => $v) {
            $flat[(string) $k] = $v;
        }
        return $flat;
    }
    return $_POST;
}

/**
 * @param mixed $v
 */
function scalar_to_string($v): string
{
    if (is_string($v) || is_numeric($v)) {
        return trim((string) $v);
    }
    if (is_bool($v)) {
        return $v ? 'true' : 'false';
    }
    if ($v === null) {
        return '';
    }
    if (is_array($v)) {
        $enc = json_encode($v, JSON_UNESCAPED_UNICODE);
        return $enc !== false ? $enc : '';
    }
    return '';
}

/**
 * @param array<string, mixed> $raw
 */
function extract_turnstile_token(array $raw): string
{
    foreach ($raw as $key => $val) {
        if (strtolower((string) $key) === 'cf-turnstile-response') {
            return scalar_to_string($val);
        }
    }

    return '';
}

/**
 * @param array<string, mixed> $raw
 * @param list<string> $honeypots lowercased names
 * @return array{fields: array<string, string>, turnstile: string}
 */
function normalize_fields(array $raw, array $honeypots): array
{
    $reserved = array_flip(array_map('strtolower', array_merge(
        ['cf-turnstile-response', 'g-recaptcha-response'],
        $honeypots
    )));

    $turnstile = extract_turnstile_token($raw);

    $fields = [];
    $count = 0;
    foreach ($raw as $key => $val) {
        $k = (string) $key;
        $lk = strtolower($k);
        if ($lk === 'cf-turnstile-response' || $lk === 'g-recaptcha-response') {
            continue;
        }
        if (isset($reserved[$lk])) {
            continue;
        }
        if (str_starts_with($k, '__')) {
            continue;
        }
        if (strlen($k) > 100) {
            client_fail('Field name too long.', 400);
        }
        $s = scalar_to_string($val);
        if (strlen($s) > 8000) {
            client_fail('Field value too long.', 400);
        }
        $fields[$k] = $s;
        $count++;
        if ($count > 50) {
            client_fail('Too many fields.', 400);
        }
    }

    return ['fields' => $fields, 'turnstile' => $turnstile];
}

/**
 * @param array<string, string> $fields
 */
function find_reply_email(array $fields, string $replyToField): ?string
{
    if ($replyToField !== '') {
        foreach ($fields as $k => $v) {
            if (strcasecmp($k, $replyToField) === 0 && $v !== '' && filter_var($v, FILTER_VALIDATE_EMAIL)) {
                return $v;
            }
        }
    }
    $priority = ['email', 'e-mail', 'mail', 'reply_email', 'contact_email', 'your_email'];
    foreach ($priority as $p) {
        foreach ($fields as $k => $v) {
            if (strcasecmp($k, $p) === 0 && $v !== '' && filter_var($v, FILTER_VALIDATE_EMAIL)) {
                return $v;
            }
        }
    }
    foreach ($fields as $v) {
        if ($v !== '' && filter_var($v, FILTER_VALIDATE_EMAIL)) {
            return $v;
        }
    }
    return null;
}

/**
 * @param array<string, string> $fields
 */
function reply_display_name(array $fields): string
{
    $pairs = [
        ['firstName', 'lastName'],
        ['firstname', 'lastname'],
        ['given', 'family'],
        ['name', ''],
    ];
    foreach ($pairs as [$a, $b]) {
        $x = '';
        $y = '';
        foreach ($fields as $k => $v) {
            if (strcasecmp($k, $a) === 0) {
                $x = $v;
            }
            if ($b !== '' && strcasecmp($k, $b) === 0) {
                $y = $v;
            }
        }
        $c = trim($x . ' ' . $y);
        if ($c !== '') {
            return truncate_utf8($c, 100);
        }
    }
    foreach ($fields as $k => $v) {
        if (stripos($k, 'name') !== false && $v !== '' && !filter_var($v, FILTER_VALIDATE_EMAIL)) {
            return truncate_utf8($v, 100);
        }
    }
    return '';
}

$vendor = __DIR__ . '/vendor/autoload.php';
if (!is_file($vendor)) {
    client_fail('Mail is not configured on this server (missing vendor/).', 500);
}
require $vendor;

// The site's own config (~/DOMAIN/private, next to html/) wins over the account-wide one (~/private):
// managed installs write the domain level, and an older account-level file must not override it.
$cfg = [];
foreach ([
    dirname(__DIR__) . '/private/smtp.config.php',
    dirname(__DIR__, 2) . '/private/smtp.config.php',
] as $configPath) {
    if (!is_file($configPath)) {
        continue;
    }
    /** @var array<string, mixed> $loaded */
    $loaded = require $configPath;
    if (is_array($loaded)) {
        $cfg = $loaded;
        break;
    }
}
$cfg = merge_env_smtp($cfg);

if (empty($cfg['smtp_port']) || (int) $cfg['smtp_port'] < 1) {
    $cfg['smtp_port'] = 587;
}
if (!isset($cfg['smtp_secure']) || (string) $cfg['smtp_secure'] === '') {
    $cfg['smtp_secure'] = 'tls';
}

$required = ['smtp_host', 'smtp_user', 'smtp_pass', 'mail_from_email', 'mail_to'];
foreach ($required as $key) {
    if (empty($cfg[$key])) {
        client_fail('Mail is not configured (set SMTP_* / MAIL_* env vars or private/smtp.config.php).', 500);
    }
}

$honeypots = ['company', 'website', 'url', 'fax', 'phone_ext'];
if (!empty($cfg['honeypot_fields']) && is_array($cfg['honeypot_fields'])) {
    $honeypots = array_map('strtolower', array_map('strval', $cfg['honeypot_fields']));
}

$raw = parse_post_payload();
foreach ($honeypots as $hp) {
    foreach ($raw as $k => $v) {
        if (strtolower((string) $k) === $hp && scalar_to_string($v) !== '') {
            client_fake_ok();
        }
    }
}

$ip = resolve_client_ip($cfg);
$rateFile = rate_limit_file_path($ip, $cfg);
$now = time();
$window = 3600;
$maxAttemptsPerWindow = 40;
$maxSuccessPerWindow = 8;
rate_update_locked($rateFile, $now, $window, static function (array &$rate) use (
    $now,
    $maxAttemptsPerWindow,
    $maxSuccessPerWindow
): void {
    if (count($rate['attempts']) >= $maxAttemptsPerWindow) {
        client_fail('Too many submissions. Please try again later.', 429);
    }
    if (count($rate['success']) >= $maxSuccessPerWindow) {
        client_fail('Too many messages sent from this address. Please try again later.', 429);
    }
    $rate['attempts'][] = $now;
});

$turnstileSecret = isset($cfg['turnstile_secret']) ? trim((string) $cfg['turnstile_secret']) : '';
$parsed = normalize_fields($raw, $honeypots);
$fields = $parsed['fields'];
$turnstileToken = $parsed['turnstile'] !== '' ? $parsed['turnstile'] : extract_turnstile_token($raw);

if ($turnstileSecret !== '') {
    if ($turnstileToken === '') {
        client_fail('Captcha verification missing.', 400);
    }
    $verify = @file_get_contents('https://challenges.cloudflare.com/turnstile/v0/siteverify', false, stream_context_create([
        'http' => [
            'method' => 'POST',
            'header' => "Content-Type: application/x-www-form-urlencoded\r\n",
            'content' => http_build_query([
                'secret' => $turnstileSecret,
                'response' => $turnstileToken,
                'remoteip' => $ip,
            ]),
            'timeout' => 10,
        ],
    ]));
    $vr = $verify ? json_decode($verify, true) : null;
    if (!is_array($vr) || empty($vr['success'])) {
        client_fail('Captcha verification failed.', 400);
    }
}

$nonEmpty = 0;
$totalLen = 0;
foreach ($fields as $v) {
    if ($v !== '') {
        $nonEmpty++;
    }
    $totalLen += strlen($v);
}
if ($nonEmpty === 0) {
    client_fail('Please enter a message or fill at least one field.', 400);
}
if ($totalLen < 3) {
    client_fail('Submission too short.', 400);
}

$requireReply = !isset($cfg['require_reply_email']) || $cfg['require_reply_email'] !== false;
$replyField = isset($cfg['reply_to_field']) ? trim((string) $cfg['reply_to_field']) : '';
$replyEmail = find_reply_email($fields, $replyField);
if ($requireReply && $replyEmail === null) {
    client_fail('A valid email address is required (use a field named email or set reply_to_field in config).', 400);
}

$subjectField = '';
foreach (['subject', '_subject', 'mail_subject'] as $sk) {
    foreach ($fields as $k => $v) {
        if (strcasecmp($k, $sk) === 0 && $v !== '') {
            $subjectField = $v;
            unset($fields[$k]);
            break 2;
        }
    }
}
$defaultSub = isset($cfg['default_mail_subject']) ? trim((string) $cfg['default_mail_subject']) : 'Website form submission';
$subject = $subjectField !== '' ? truncate_utf8($subjectField, 200) : $defaultSub;

$bodyLines = [
    '--- Form submission ---',
    'IP: ' . $ip,
    'UA: ' . (string) ($_SERVER['HTTP_USER_AGENT'] ?? ''),
    '',
    '--- Fields ---',
];
foreach ($fields as $k => $v) {
    $bodyLines[] = $k . ': ' . ($v !== '' ? $v : '—');
}
$body = implode("\n", $bodyLines);
if (strlen($body) > 200000) {
    client_fail('Submission too large.', 400);
}

$mail = new PHPMailer(true);
try {
    $mail->CharSet = PHPMailer::CHARSET_UTF8;
    $mail->isSMTP();
    $mail->Host = (string) $cfg['smtp_host'];
    $mail->SMTPAuth = true;
    $mail->Username = (string) $cfg['smtp_user'];
    $mail->Password = (string) $cfg['smtp_pass'];
    $mail->Port = (int) $cfg['smtp_port'];

    $secure = isset($cfg['smtp_secure']) ? strtolower((string) $cfg['smtp_secure']) : 'tls';
    if ($secure === 'ssl') {
        $mail->SMTPSecure = PHPMailer::ENCRYPTION_SMTPS;
    } elseif ($secure === 'tls') {
        $mail->SMTPSecure = PHPMailer::ENCRYPTION_STARTTLS;
    } else {
        $mail->SMTPSecure = '';
    }

    $fromName = isset($cfg['mail_from_name']) ? (string) $cfg['mail_from_name'] : '';
    $mail->setFrom((string) $cfg['mail_from_email'], $fromName);

    $toName = isset($cfg['mail_to_name']) ? (string) $cfg['mail_to_name'] : '';
    $mail->addAddress((string) $cfg['mail_to'], $toName);

    if ($replyEmail !== null) {
        $rn = reply_display_name($fields);
        $mail->addReplyTo($replyEmail, $rn);
    }

    $mail->Subject = $subject;
    $mail->Body = $body;

    $mail->send();
} catch (MailerException $e) {
    error_log('contact.php mail error: ' . $mail->ErrorInfo);
    client_fail('Could not send message. Please try again later.', 500);
}

rate_update_locked($rateFile, $now, $window, static function (array &$rate) use ($now): void {
    $rate['success'][] = $now;
}, false);

if (wants_json()) {
    http_response_code(200);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['ok' => true, 'error' => ''], JSON_UNESCAPED_UNICODE);
    exit;
}

$redirect = isset($cfg['redirect_success_url']) ? (string) $cfg['redirect_success_url'] : '/contact/?sent=1';
header('Location: ' . $redirect, true, 303);
exit;
