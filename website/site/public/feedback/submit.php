<?php
/*
 * Bug-report intake. Receives the multipart POST from /feedback/, validates
 * size + required fields, and emails everything (with attachments inline as
 * MIME parts) to RECIPIENT in a single message.
 *
 * Constraints baked in to match the form copy:
 *   - max 2 MB per file (server-enforced via php.ini upload_max_filesize)
 *   - max 5 MB total across all attachments (enforced here)
 *   - summary + description required; everything else optional
 *
 * Returns plain text + a 2xx/4xx status. The form's fetch() reads both.
 */

// RECIPIENT is defined in config.php, which the deploy script writes from
// build.env. It is not part of the repository.
if (is_readable(__DIR__ . '/config.php')) {
    require __DIR__ . '/config.php';
}
if (!defined('RECIPIENT')) {
    http_response_code(503);
    header('Content-Type: text/plain; charset=utf-8');
    exit('The feedback form is not configured.');
}

const FROM_ADDRESS  = 'noreply@compile-xc.org';
const MAX_TOTAL     = 5 * 1024 * 1024;
const MAX_PER_FILE  = 2 * 1024 * 1024;

header('Content-Type: text/plain; charset=utf-8');

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    exit('POST required.');
}

// Honeypot — bots fill hidden fields, humans don't.
if (!empty($_POST['company'] ?? '')) {
    http_response_code(200);
    exit('Thanks.');
}

// Detect post_max_size overflow: when the body exceeds the server limit,
// $_POST and $_FILES come back empty regardless of what was sent.
if (empty($_POST) && empty($_FILES) &&
    (int)($_SERVER['CONTENT_LENGTH'] ?? 0) > 0) {
    http_response_code(413);
    exit('Submission exceeded the server post-size limit. Please reduce attachments.');
}

$summary     = trim((string)($_POST['summary']     ?? ''));
$description = trim((string)($_POST['description'] ?? ''));
$snippet     = (string)($_POST['snippet']          ?? '');
$email       = trim((string)($_POST['email']       ?? ''));

if ($summary === '' || $description === '') {
    http_response_code(400);
    exit('Summary and description are required.');
}
if (strlen($summary) > 200) {
    http_response_code(400);
    exit('Summary too long (max 200 chars).');
}
if ($email !== '' && !filter_var($email, FILTER_VALIDATE_EMAIL)) {
    http_response_code(400);
    exit('Email address is not valid.');
}

// Collect attachments. PHP flattens `name="attachments[]"` into parallel arrays.
$attachments = [];
$totalSize   = 0;
if (!empty($_FILES['attachments']) && is_array($_FILES['attachments']['name'])) {
    $files = $_FILES['attachments'];
    $count = count($files['name']);
    for ($i = 0; $i < $count; $i++) {
        $err = $files['error'][$i];
        if ($err === UPLOAD_ERR_NO_FILE) continue;
        if ($err === UPLOAD_ERR_INI_SIZE || $err === UPLOAD_ERR_FORM_SIZE) {
            http_response_code(413);
            exit('File "' . basename($files['name'][$i]) . '" exceeds the 2 MB per-file limit.');
        }
        if ($err !== UPLOAD_ERR_OK) {
            http_response_code(400);
            exit('Upload failed for "' . basename($files['name'][$i]) . '" (code ' . $err . ').');
        }
        $size = (int)$files['size'][$i];
        if ($size > MAX_PER_FILE) {
            http_response_code(413);
            exit('File "' . basename($files['name'][$i]) . '" exceeds the 2 MB per-file limit.');
        }
        $totalSize += $size;
        if ($totalSize > MAX_TOTAL) {
            http_response_code(413);
            exit('Attachments exceed the 5 MB total limit.');
        }
        $tmp = $files['tmp_name'][$i];
        if (!is_uploaded_file($tmp)) {
            http_response_code(400);
            exit('Bad upload.');
        }
        $attachments[] = [
            'name' => preg_replace('/[^A-Za-z0-9._-]/', '_', basename($files['name'][$i])),
            'type' => $files['type'][$i] ?: 'application/octet-stream',
            'data' => file_get_contents($tmp),
        ];
    }
}

// Compose the multipart MIME body.
$boundary = '=_xtc_' . bin2hex(random_bytes(16));
$eol      = "\r\n";
$ip       = $_SERVER['REMOTE_ADDR'] ?? '?';
$ua       = substr((string)($_SERVER['HTTP_USER_AGENT'] ?? '?'), 0, 200);
$now      = gmdate('Y-m-d H:i:s') . ' UTC';

$plain  = "xcc bug report" . $eol . str_repeat('-', 60) . $eol;
$plain .= "Submitted: $now" . $eol;
$plain .= "From IP:   $ip" . $eol;
$plain .= "User-Agent: $ua" . $eol;
$plain .= "Reply-to:  " . ($email !== '' ? $email : '(not provided)') . $eol;
$plain .= str_repeat('-', 60) . $eol . $eol;
$plain .= "SUMMARY" . $eol . $eol . $summary . $eol . $eol;
$plain .= "DESCRIPTION" . $eol . $eol . $description . $eol . $eol;
if (trim($snippet) !== '') {
    $plain .= "SOURCE SNIPPET" . $eol . $eol . $snippet . $eol . $eol;
}
if (count($attachments) > 0) {
    $plain .= "ATTACHMENTS (" . count($attachments) . ", " . number_format($totalSize) . " bytes total)" . $eol;
    foreach ($attachments as $a) {
        $plain .= "  - " . $a['name'] . " (" . strlen($a['data']) . " bytes)" . $eol;
    }
}

$body  = "--$boundary$eol";
$body .= "Content-Type: text/plain; charset=UTF-8$eol";
$body .= "Content-Transfer-Encoding: 8bit$eol$eol";
$body .= $plain . $eol;

foreach ($attachments as $a) {
    $body .= "--$boundary$eol";
    $body .= "Content-Type: " . $a['type'] . "; name=\"" . $a['name'] . "\"$eol";
    $body .= "Content-Transfer-Encoding: base64$eol";
    $body .= "Content-Disposition: attachment; filename=\"" . $a['name'] . "\"$eol$eol";
    $body .= chunk_split(base64_encode($a['data'])) . $eol;
}
$body .= "--$boundary--$eol";

$subject = '[xcc bug] ' . preg_replace('/[\r\n]+/', ' ', $summary);
// RFC 2047 encoding for non-ASCII in the subject.
if (preg_match('/[^\x20-\x7e]/', $subject)) {
    $subject = '=?UTF-8?B?' . base64_encode($subject) . '?=';
}

$headers  = "From: xcc bug form <" . FROM_ADDRESS . ">$eol";
$headers .= "MIME-Version: 1.0$eol";
$headers .= "Content-Type: multipart/mixed; boundary=\"$boundary\"$eol";
if ($email !== '') {
    $headers .= "Reply-To: $email$eol";
}
$headers .= "X-Mailer: xcc-bug-form/1$eol";

$ok = mail(RECIPIENT, $subject, $body, $headers, '-f' . FROM_ADDRESS);
if (!$ok) {
    http_response_code(500);
    exit('Mail delivery failed. Please try again later or email directly.');
}

http_response_code(200);
echo 'Sent ' . count($attachments) . ' attachment(s).';
