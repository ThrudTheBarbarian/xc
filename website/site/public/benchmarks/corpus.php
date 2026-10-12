<?php
/*
 * The corpus of benchmark contributions.
 *
 *   GET /benchmarks/corpus.php            the whole corpus
 *   GET /benchmarks/corpus.php?id=<id>    one contribution
 *
 * Reply:
 *   {"schema":"xc-bench-corpus/1","count":N,"contributions":[ <xc-bench/1>, ... ],
 *    "published":[ <results.json>, ... ]}
 *
 * The visualiser's "Download contributions" reads this and merges every
 * contribution into its own data set.  "published" is the project's own
 * measurements (published/, written by benchmark/page.py with the performance
 * page), so a download shows them even before anyone has submitted a run.  Files are served newest first and the
 * read is bounded, so a large corpus still answers.
 */

header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');   // read-only, public data

const CORPUS    = __DIR__ . '/corpus';
const PUBLISHED = __DIR__ . '/published';
const MAX_FILES = 500;
const MAX_BYTES = 32 * 1024 * 1024;   // total served

$id = $_GET['id'] ?? '';

if ($id !== '') {
    $id = preg_replace('/[^A-Za-z0-9._-]/', '', (string)$id);
    if ($id === '' || $id === '.' || $id === '..') {
        http_response_code(400);
        echo json_encode(['error' => 'Bad id.']);
        exit;
    }
    $path = CORPUS . '/' . $id . '.json';
    if (!is_file($path)) {
        http_response_code(404);
        echo json_encode(['error' => 'No such contribution.']);
        exit;
    }
    header('Content-Type: application/json; charset=utf-8');
    readfile($path);
    exit;
}

$files = glob(CORPUS . '/*.json') ?: [];
usort($files, fn($a, $b) => filemtime($b) <=> filemtime($a));

// Embed each stored file's text as-is, so a round trip through this endpoint
// cannot change a contribution (an empty params object stays an object).
$out = [];
$bytes = 0;
foreach ($files as $f) {
    if (count($out) >= MAX_FILES || $bytes >= MAX_BYTES) {
        break;
    }
    $text = @file_get_contents($f);
    if ($text === false) {
        continue;
    }
    $c = json_decode($text);
    if (!is_object($c) || ($c->schema ?? '') !== 'xc-bench/1') {
        continue;
    }
    $bytes += strlen($text);
    $out[] = rtrim($text);
}

$published = [];
foreach (glob(PUBLISHED . '/*.json') ?: [] as $f) {
    $text = @file_get_contents($f);
    if ($text !== false && json_decode($text) !== null) {
        $published[] = rtrim($text);
    }
}

echo '{"schema":"xc-bench-corpus/1","count":' . count($out) . ',"contributions":['
     . implode(',', $out) . '],"published":[' . implode(',', $published) . ']}';
