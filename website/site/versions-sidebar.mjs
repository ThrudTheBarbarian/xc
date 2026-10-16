// The "Previous versions" sidebar group: one collapsed group per released
// version, newest first, each mirroring the current sidebar's structure over
// the pages that version's tree has (src/content/docs/versions/<ver>/, made by
// tools/docversions.py). A page a version had that the current sidebar no
// longer lists goes under "Other pages", so nothing in a tree is unreachable.
import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.join(path.dirname(new URL(import.meta.url).pathname), 'src/content/docs/versions');

function verKey(v) {
	const p = v.split('.');
	const minor = p[1].length === 1 ? Number(p[1]) * 10 : Number(p[1]);
	return [Number(p[0]), minor, Number(p[2] || 0)];
}

function pagesOf(dir) {
	const out = new Map(); // slug -> file
	const walk = (d) => {
		for (const e of fs.readdirSync(d, { withFileTypes: true })) {
			const p = path.join(d, e.name);
			if (e.isDirectory()) walk(p);
			else if (/\.mdx?$/.test(e.name)) {
				let s = path.relative(dir, p).replace(/\.mdx?$/, '').replace(/(^|\/)index$/, '');
				out.set(s, p);
			}
		}
	};
	walk(dir);
	return out;
}

function titleOf(file) {
	const t = fs.readFileSync(file, 'utf8');
	const m = t.match(/^---\n[\s\S]*?^title:\s*["']?(.*?)["']?\s*$/m);
	return m ? m[1] : path.basename(file).replace(/\.mdx?$/, '');
}

function mirror(items, v, pages, used) {
	const out = [];
	for (const it of items) {
		if (it.slug !== undefined) {
			if (pages.has(it.slug)) {
				used.add(it.slug);
				out.push({ label: it.label, slug: `versions/${v}/${it.slug}`.replace(/\/$/, '') });
			}
		} else if (it.items) {
			const sub = mirror(it.items, v, pages, used);
			if (sub.length) out.push({ label: it.label, collapsed: true, items: sub });
		}
	}
	return out;
}

export default function previousVersions(sidebar) {
	if (!fs.existsSync(ROOT)) return null;
	const versions = fs
		.readdirSync(ROOT)
		.filter((v) => /^\d+\.\d+(\.\d+)?$/.test(v))
		.sort((a, b) => {
			const x = verKey(a), y = verKey(b);
			return y[0] - x[0] || y[1] - x[1] || y[2] - x[2];
		});
	if (!versions.length) return null;
	return {
		label: 'Previous versions',
		collapsed: true,
		items: versions.map((v) => {
			const pages = pagesOf(path.join(ROOT, v));
			const used = new Set();
			const items = mirror(sidebar, v, pages, used);
			const rest = [...pages.keys()].filter((s) => !used.has(s)).sort();
			if (rest.length)
				items.push({
					label: 'Other pages',
					collapsed: true,
					items: rest.map((s) => ({ label: titleOf(pages.get(s)), slug: `versions/${v}/${s}`.replace(/\/$/, '') })),
				});
			return { label: v, collapsed: true, items };
		}),
	};
}
