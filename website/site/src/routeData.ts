// Per-page sidebar for the versioned documentation (versions-sidebar.mjs).
//
// The config's sidebar holds every release's whole tree under "Previous
// versions", which Starlight needs to know them; sent as it is, every page
// would carry thousands of links. So each page gets only what it needs:
//
// - a page of the current docs: the current tree, with "Previous versions"
//   (at the bottom of Language) as one link per release;
// - a page of a release's tree: that tree alone, a link back to the current
//   docs, and the same list of releases at the bottom of its Language group.
//
// The previous/next links at a page's foot are recomputed from what is shown,
// so they stay inside one tree.
import { defineRouteMiddleware } from '@astrojs/starlight/route-data';

type Link = { type: 'link'; label: string; href: string; isCurrent: boolean; badge: any; attrs: any };
type Group = { type: 'group'; label: string; entries: Entry[]; collapsed: boolean; badge: any };
type Entry = Link | Group;

const link = (label: string, href: string, isCurrent = false): Link => ({
	type: 'link', label, href, isCurrent, badge: undefined, attrs: {},
});

function findGroup(entries: Entry[], label: string): Group | undefined {
	for (const e of entries) {
		if (e.type !== 'group') continue;
		if (e.label === label) return e;
		const f = findGroup(e.entries, label);
		if (f) return f;
	}
	return undefined;
}

function removeGroup(entries: Entry[], target: Group): boolean {
	const i = entries.indexOf(target);
	if (i >= 0) {
		entries.splice(i, 1);
		return true;
	}
	return entries.some((e) => e.type === 'group' && removeGroup(e.entries, target));
}

function firstLink(entries: Entry[]): Link | undefined {
	for (const e of entries) {
		if (e.type === 'link') return e;
		const f = firstLink(e.entries);
		if (f) return f;
	}
	return undefined;
}

function hasCurrent(entries: Entry[]): boolean {
	return entries.some((e) => (e.type === 'link' ? e.isCurrent : hasCurrent(e.entries)));
}

function flatten(entries: Entry[], out: Link[] = []): Link[] {
	for (const e of entries) {
		if (e.type === 'link') out.push(e);
		else flatten(e.entries, out);
	}
	return out;
}

export const onRequest = defineRouteMiddleware((context) => {
	const route = context.locals.starlightRoute;
	const sidebar = route.sidebar as Entry[];
	const prev = findGroup(sidebar, 'Previous versions');
	if (!prev) return;
	const releases = prev.entries.filter((e): e is Group => e.type === 'group');
	const shown = releases.find((g) => hasCurrent(g.entries));
	const list = (current?: Group): Group => ({
		type: 'group',
		label: 'Previous versions',
		collapsed: !current,
		badge: undefined,
		entries: releases.map((g) => {
			const home = g.entries.length ? (findLandingIn(g) ?? firstLink(g.entries)) : undefined;
			const l = link(g.label, home ? home.href : '#');
			// The release this page belongs to: a badge, not aria-current (that
			// would claim the link is this very page).
			if (g === current) l.badge = { text: 'this version', variant: 'note' };
			return l;
		}),
	});
	let entries: Entry[];
	if (shown) {
		entries = [link('Current documentation', '/compiler/'), ...shown.entries];
		const lang = findGroup(entries, 'Language');
		if (lang) lang.entries = [...lang.entries, list(shown)];
		else entries.push(list(shown));
	} else {
		removeGroup(sidebar, prev);
		const lang = findGroup(sidebar, 'Language');
		if (lang) lang.entries.push(list());
		entries = sidebar;
	}
	route.sidebar = entries as any;
	// Previous and next, within what is shown.
	const flat = flatten(entries).filter((l) => l.href !== '#');
	const at = flat.findIndex((l) => l.isCurrent);
	if (at >= 0) {
		route.pagination = { prev: flat[at - 1] as any, next: flat[at + 1] as any };
	}
});

// A release's landing page: its compiler overview, else its first page.
function findLandingIn(g: Group): Link | undefined {
	const all = flatten(g.entries);
	return all.find((l) => /\/versions\/[^/]+\/compiler\/?$/.test(l.href)) ?? all[0];
}
