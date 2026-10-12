<?php
/*
 * Benchmark contribution intake.  Receives one contribution as a JSON POST
 * (Content-Type: application/json), checks it is the shape the visualiser
 * writes, and files it in corpus/.  The reply is JSON: the id it was stored
 * under and the corpus size.
 *
 * The submission is a machine's benchmark numbers plus the parameters of each
 * run.  Nothing personal is required or wanted; the body is stored as-is, with
 * the id and a receive time added.
 *
 *   POST /benchmarks/submit.php        body: one xc-bench/1 JSON object
 *   200 {"ok":true,"id":"...","count":N}
 *
 * Limits are generous for real runs and tight enough to refuse nonsense: 1 MB of JSON, at most 4096 runs and 256 repeats a run.
 */

header('Content-Type: application/json; charset=utf-8');

const MAX_BODY  = 1024 * 1024;   // 1 MB
const MAX_RUNS  = 4096;
const MAX_SAMPS = 256;
const CORPUS    = __DIR__ . '/corpus';

function fail($code, $msg) {
    http_response_code($code);
    echo json_encode(['ok' => false, 'error' => $msg]);
    exit;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    fail(405, 'POST required.');
}

$len = (int)($_SERVER['CONTENT_LENGTH'] ?? 0);
if ($len <= 0 || $len > MAX_BODY) {
    fail(413, 'A body of 1 to ' . MAX_BODY . ' bytes is required.');
}

$raw = file_get_contents('php://input');
if ($raw === false || strlen($raw) > MAX_BODY) {
    fail(413, 'Body too large.');
}

// Decode as objects, not arrays, so an empty run `params` object is stored
// back as `{}` and not flattened to `[]`.
$c = json_decode($raw);
if (!is_object($c)) {
    fail(400, 'The body is not valid JSON.');
}
if (($c->schema ?? '') !== 'xc-bench/1') {
    fail(400, 'Unsupported schema; expected "xc-bench/1".');
}
if (!isset($c->machine->cpu) || !is_string($c->machine->cpu)) {
    fail(400, 'machine.cpu is required.');
}
if (!isset($c->runs) || !is_array($c->runs) || count($c->runs) === 0) {
    fail(400, 'At least one run is required.');
}
if (count($c->runs) > MAX_RUNS) {
    fail(413, 'Too many runs (max ' . MAX_RUNS . ').');
}
foreach ($c->runs as $r) {
    if (!is_object($r) || !isset($r->benchmark, $r->best_us)) {
        fail(400, 'Every run needs a benchmark and a best_us.');
    }
    if (isset($r->samples_us) && is_array($r->samples_us) && count($r->samples_us) > MAX_SAMPS) {
        fail(413, 'Too many samples in one run (max ' . MAX_SAMPS . ').');
    }
}

// The id is the contributor's if it is well-formed, else a random one.  Only
// [A-Za-z0-9._-] survives, so the name can never leave the corpus directory.
$id = (string)($c->id ?? '');
$id = preg_replace('/[^A-Za-z0-9._-]/', '', $id);
$id = substr($id, 0, 80);
if ($id === '' || $id === '.' || $id === '..') {
    $id = bin2hex(random_bytes(12));
}
$c->id = $id;
$c->received = gmdate('Y-m-d\TH:i:s\Z');

// A simple per-IP rate limit: at most one submission a minute.
$limit = sys_get_temp_dir() . '/bench-submit-' . sha1($_SERVER['REMOTE_ADDR'] ?? '?');
if (is_file($limit) && (time() - filemtime($limit)) < 60) {
    fail(429, 'Please wait a minute between submissions.');
}

if (!is_dir(CORPUS) && !@mkdir(CORPUS, 0775, true)) {
    fail(500, 'The corpus is not writable.');
}

// A stored contribution is never replaced: a second submission under the
// same id (the same file sent twice, or someone else's id) gets a new one.
if (is_file(CORPUS . '/' . $id . '.json')) {
    $id = substr($id, 0, 60) . '-' . bin2hex(random_bytes(6));
}
$c->id = $id;

$target = CORPUS . '/' . $id . '.json';
$tmp    = $target . '.tmp.' . bin2hex(random_bytes(4));
if (file_put_contents($tmp, json_encode($c, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)) === false) {
    fail(500, 'Could not store the contribution.');
}
rename($tmp, $target);
@touch($limit);

$count = count(glob(CORPUS . '/*.json') ?: []);
echo json_encode(['ok' => true, 'id' => $id, 'count' => $count]);
