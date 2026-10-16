# Starlight Starter Kit: Basics

[![Built with Starlight](https://astro.badg.es/v2/built-with-starlight/tiny.svg)](https://starlight.astro.build)

```
npm create astro@latest -- --template starlight
```

> 🧑‍🚀 **Seasoned astronaut?** Delete this file. Have fun!

## 🚀 Project Structure

Inside of your Astro + Starlight project, you'll see the following folders and files:

```
.
├── public/
├── src/
│   ├── assets/
│   ├── content/
│   │   └── docs/
│   └── content.config.ts
├── astro.config.mjs
├── package.json
└── tsconfig.json
```

Starlight looks for `.md` or `.mdx` files in the `src/content/docs/` directory. Each file is exposed as a route based on its file name.

Images can be added to `src/assets/` and embedded in Markdown with a relative link.

Static assets, like favicons, can be placed in the `public/` directory.

## 🧞 Commands

All commands are run from the root of the project, from a terminal:

| Command                   | Action                                           |
| :------------------------ | :----------------------------------------------- |
| `npm install`             | Installs dependencies                            |
| `npm run dev`             | Starts local dev server at `localhost:4321`      |
| `npm run build`           | Build your production site to `./dist/`          |
| `npm run preview`         | Preview your build locally, before deploying     |
| `npm run astro ...`       | Run CLI commands like `astro add`, `astro check` |
| `npm run astro -- --help` | Get help using the Astro CLI                     |

## 👀 Want to learn more?

Check out [Starlight’s docs](https://starlight.astro.build/), read [the Astro documentation](https://docs.astro.build), or jump into the [Astro Discord server](https://astro.build/chat).

## Versioned documentation

Each public release has its own documentation tree under
`src/content/docs/versions/<ver>/`, made from the docs as they stood at the
release's tag; the default tree is always the current documentation, and
"Previous versions" at the bottom of the Language sidebar group lists the
releases. No tree says "from 0.72" or "(new in 0.8)": each documents one
version, and a feature a version lacks is absent from its tree.

    python3 tools/docversions.py strip --check    # the current tree has no version marks (0 left)
    python3 tools/docversions.py snapshot v0.9    # a release's tree, after tagging it

`tools/docfixes.py` holds the history prose the automatic rewrite cannot
handle, as exact before/after pairs. `versions-sidebar.mjs` builds each
release's sidebar from the current one, and `src/routeData.ts` trims every
page's sidebar to its own tree. The site is deployed from a release tag
(`tools/release/deploy-website.sh` refuses otherwise), because the current
tree describes what is on main as if it were released.
