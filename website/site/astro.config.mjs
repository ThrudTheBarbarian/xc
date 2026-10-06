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
				'xcc, the compiler and toolchain for xc — a modern, typed, class-based C-like language — compiled through a shared SSA intermediate representation to multiple backends: native arm64, x86-64, arm9 and win64, WebAssembly, and a banked-6502 target.',
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
								{ label: 'Parallel blocks (par)', slug: 'compiler/language/par' },
								{ label: 'Modules & shared libraries', slug: 'compiler/language/modules' },
								{ label: 'Inline assembly', slug: 'compiler/language/inline-asm' },
								{ label: 'Grammar', slug: 'compiler/language/grammar' },
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
										{ label: 'Array', slug: 'compiler/api/array' },
										{ label: 'AttributedString', slug: 'compiler/api/attributedstring' },
										{ label: 'Bag', slug: 'compiler/api/bag' },
										{ label: 'BinaryHeap', slug: 'compiler/api/binaryheap' },
										{ label: 'Cache', slug: 'compiler/api/cache' },
										{ label: 'CharacterSet', slug: 'compiler/api/characterset' },
										{ label: 'Coder', slug: 'compiler/api/coder' },
										{ label: 'CSV', slug: 'compiler/api/csv' },
										{ label: 'Data', slug: 'compiler/api/data' },
										{ label: 'Expression', slug: 'compiler/api/expression' },
										{ label: 'IndexSet', slug: 'compiler/api/indexset' },
										{ label: 'JSON', slug: 'compiler/api/json' },
										{ label: 'Map', slug: 'compiler/api/map' },
										{ label: 'NotificationCenter', slug: 'compiler/api/notificationcenter' },
										{ label: 'Null', slug: 'compiler/api/null' },
										{ label: 'Number', slug: 'compiler/api/number' },
										{ label: 'NumberFormatter', slug: 'compiler/api/numberformatter' },
										{ label: 'Object', slug: 'compiler/api/object' },
										{ label: 'OperationQueue', slug: 'compiler/api/operationqueue' },
										{ label: 'Predicate', slug: 'compiler/api/predicate' },
										{ label: 'Progress', slug: 'compiler/api/progress' },
										{ label: 'Range', slug: 'compiler/api/range' },
										{ label: 'Regex', slug: 'compiler/api/regex' },
										{ label: 'RunLoop', slug: 'compiler/api/runloop' },
										{ label: 'SearchIndex', slug: 'compiler/api/searchindex' },
										{ label: 'Set', slug: 'compiler/api/set' },
										{ label: 'Socket', slug: 'compiler/api/socket' },
										{ label: 'SortDescriptor', slug: 'compiler/api/sortdescriptor' },
										{ label: 'StateMachine', slug: 'compiler/api/statemachine' },
										{ label: 'String', slug: 'compiler/api/string' },
										{ label: 'String (xt6502)', slug: 'compiler/api/string-xt6502' },
										{ label: 'UndoManager', slug: 'compiler/api/undomanager' },
										{ label: 'Validator', slug: 'compiler/api/validator' },
									],
								},
								{
									label: 'Protocols',
									items: [
										{ label: 'Codable', slug: 'compiler/api/codable' },
										{ label: 'Comparable', slug: 'compiler/api/comparable' },
										{ label: 'Copying', slug: 'compiler/api/copying' },
										{ label: 'Enumerable', slug: 'compiler/api/enumerable' },
										{ label: 'Error', slug: 'compiler/api/error' },
										{ label: 'Hashable', slug: 'compiler/api/hashable' },
									],
								},
								{
									label: 'System utilities',
									items: [
										{ label: 'Assert', slug: 'compiler/api/assert' },
										{ label: 'AsyncFiles', slug: 'compiler/api/asyncfiles' },
										{ label: 'Bundle', slug: 'compiler/api/bundle' },
										{ label: 'FILE', slug: 'compiler/api/file' },
										{ label: 'Files', slug: 'compiler/api/files' },
										{ label: 'Http', slug: 'compiler/api/http' },
										{ label: 'Log', slug: 'compiler/api/log' },
										{ label: 'Math', slug: 'compiler/api/math' },
										{ label: 'Memory', slug: 'compiler/api/memory' },
										{ label: 'Settings', slug: 'compiler/api/settings' },
										{ label: 'Sort', slug: 'compiler/api/sort' },
										{ label: 'Stdio', slug: 'compiler/api/stdio' },
										{ label: 'Url', slug: 'compiler/api/url' },
									],
								},
								{
									label: '6502 (8-bit)',
									items: [
										{ label: 'Overview', slug: 'compiler/api/6502' },
										{ label: 'Bank switching', slug: 'compiler/api/mapdata' },
										{ label: 'Gfx', slug: 'compiler/api/gfx' },
										{ label: 'GfxFactory', slug: 'compiler/api/gfxfactory' },
										{ label: 'Heap', slug: 'compiler/api/heap' },
										{ label: 'Platform symbols', slug: 'compiler/api/symbols' },
										{ label: 'System', slug: 'compiler/api/system' },
										{ label: 'Time', slug: 'compiler/api/time' },
										{ label: 'Vbi', slug: 'compiler/api/vbi' },
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
								{ label: 'Allocator & ARC', slug: 'compiler/usage/allocator-arc' },
								{ label: 'CLI flag reference', slug: 'compiler/usage/cli' },
								{ label: 'Install', slug: 'compiler/usage/install' },
								{ label: 'Linker scripts (.lnk)', slug: 'compiler/usage/linker-scripts' },
								{ label: 'Memory models', slug: 'compiler/usage/memory-models' },
								{ label: 'Optimisation', slug: 'compiler/usage/optimization' },
							],
						},
						{ label: 'Performance', slug: 'compiler/performance' },
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
