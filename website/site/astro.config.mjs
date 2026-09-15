// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import uxkitSidebar from './uxkit-sidebar.mjs';

// https://astro.build/config
export default defineConfig({
	site: 'https://compile-xc.org',
	integrations: [
		starlight({
			title: 'xc',
			description:
				'The xc compiler and toolchain — a modern, typed, class-based C-like language (the "xtc language") compiled through a shared SSA intermediate representation to multiple backends: native arm64, x86-64, arm9 and win64, WebAssembly, and a banked-6502 target. Ships as xcc.',
			customCss: ['./src/styles/xtc.css'],
			// Browser-tab icon, cropped to the golden jigsaw piece (see public/).
			favicon: '/favicon.png',
			head: [
				{
					tag: 'link',
					attrs: { rel: 'apple-touch-icon', sizes: '180x180', href: '/apple-touch-icon.png' },
				},
			],
			// Starlight 0.38's preprocess-wrapped schema treats `social` as
			// required even though the underlying type is optional; pass an
			// empty array to satisfy validation.
			social: [],
			sidebar: [
				{ label: 'Introduction', slug: 'index' },
				{
					label: 'Compiler (xcc)',
					items: [
						{ label: 'Overview', slug: 'compiler' },
						{
							label: 'Language',
							collapsed: true,
							items: [
								{ label: 'Overview', slug: 'compiler/language' },
								{ label: 'Lexical structure', slug: 'compiler/language/lexical' },
								{ label: 'Preprocessor', slug: 'compiler/language/preprocessor' },
								{ label: 'Types', slug: 'compiler/language/types' },
								{ label: 'Operators', slug: 'compiler/language/operators' },
								{ label: 'Statements & control flow', slug: 'compiler/language/statements' },
								{ label: 'Functions', slug: 'compiler/language/functions' },
								{ label: 'Classes', slug: 'compiler/language/classes' },
								{ label: 'Inheritance & protocols', slug: 'compiler/language/inheritance' },
								{ label: 'Bound methods & callbacks', slug: 'compiler/language/bound-methods' },
								{ label: 'Blocks', slug: 'compiler/language/blocks' },
								{ label: 'Errors (throws / try / catch)', slug: 'compiler/language/errors' },
								{ label: 'Heap, ARC & weak refs', slug: 'compiler/language/memory' },
								{ label: 'Collections & strings', slug: 'compiler/language/collections' },
								{ label: 'Threading', slug: 'compiler/language/threading' },
								{ label: 'Modules & shared libraries', slug: 'compiler/language/modules' },
								{ label: 'Inline assembly', slug: 'compiler/language/inline-asm' },
							],
						},
						{
							label: 'Standard library',
							collapsed: true,
							items: [
								{ label: 'Overview', slug: 'compiler/api' },
								{
									label: 'Foundation',
									items: [
										{ label: 'Overview', slug: 'compiler/api/foundation' },
										{ label: 'Object', slug: 'compiler/api/object' },
										{ label: 'Number', slug: 'compiler/api/number' },
										{ label: 'String', slug: 'compiler/api/string' },
										{ label: 'String (xt6502)', slug: 'compiler/api/string-xt6502' },
										{ label: 'Data', slug: 'compiler/api/data' },
										{ label: 'Array', slug: 'compiler/api/array' },
										{ label: 'Map', slug: 'compiler/api/map' },
										{ label: 'Set', slug: 'compiler/api/set' },
										{ label: 'CharacterSet', slug: 'compiler/api/characterset' },
									],
								},
								{
									label: 'Protocols',
									items: [
										{ label: 'Comparable', slug: 'compiler/api/comparable' },
										{ label: 'Hashable', slug: 'compiler/api/hashable' },
										{ label: 'Enumerable', slug: 'compiler/api/enumerable' },
										{ label: 'Copying', slug: 'compiler/api/copying' },
										{ label: 'Error', slug: 'compiler/api/error' },
									],
								},
								{
									label: 'System utilities',
									items: [
										{ label: 'Stdio', slug: 'compiler/api/stdio' },
										{ label: 'Math', slug: 'compiler/api/math' },
										{ label: 'Sort', slug: 'compiler/api/sort' },
										{ label: 'Memory', slug: 'compiler/api/memory' },
										{ label: 'Assert', slug: 'compiler/api/assert' },
										{ label: 'FILE', slug: 'compiler/api/file' },
									],
								},
								{
									label: 'Graphics',
									items: [
										{ label: 'Gfx', slug: 'compiler/api/gfx' },
										{ label: 'GfxFactory', slug: 'compiler/api/gfxfactory' },
									],
								},
								{
									label: '6502 (8-bit)',
									items: [
										{ label: 'Overview', slug: 'compiler/api/6502' },
										{ label: 'Time', slug: 'compiler/api/time' },
										{ label: 'Heap', slug: 'compiler/api/heap' },
										{ label: 'Vbi', slug: 'compiler/api/vbi' },
										{ label: 'System', slug: 'compiler/api/system' },
										{ label: 'Bank switching', slug: 'compiler/api/mapdata' },
										{ label: 'Platform symbols', slug: 'compiler/api/symbols' },
									],
								},
							],
						},
						uxkitSidebar,
						{
							label: 'Compiler usage',
							collapsed: true,
							items: [
								{ label: 'Overview', slug: 'compiler/usage' },
								{ label: 'Install', slug: 'compiler/usage/install' },
								{ label: 'CLI flag reference', slug: 'compiler/usage/cli' },
								{ label: 'Optimisation', slug: 'compiler/usage/optimization' },
								{ label: 'Memory models', slug: 'compiler/usage/memory-models' },
								{ label: 'Allocator & ARC', slug: 'compiler/usage/allocator-arc' },
								{ label: 'Linker scripts (.lnk)', slug: 'compiler/usage/linker-scripts' },
							],
						},
						{ label: 'Future work', slug: 'compiler/future-work' },
						{
							label: 'Downloads',
							collapsed: true,
							items: [
								{ label: 'Most Recent Release', slug: 'compiler/downloads' },
								{ label: 'Historical Releases', slug: 'compiler/downloads/historical' },
								{ label: 'ChangeLog', slug: 'compiler/downloads/changelog' },
							],
						},
					],
				},
				{ label: 'Report a bug', slug: 'feedback' },
			],
		}),
	],
});
