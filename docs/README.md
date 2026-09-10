# Ardos Packer documentation

User-facing documentation for [ardos-packer2](../README.md), built with [Starlight](https://starlight.astro.build/) and Astro. Pages live in `src/content/docs/`, organized by the [Diátaxis](https://diataxis.fr/) framework: tutorials, how-to guides, reference, and explanation.

## Commands

```sh
bun install            # install dependencies
bun dev                # start the dev server at localhost:4321
bun build              # build the site into ./dist
bun preview            # preview a production build
bun astro check        # type-check the content
```

The dev server runs through the Astro CLI; `astro dev --background` starts it without blocking.

## Writing pages

Each page is a Markdown or MDX file with Starlight frontmatter (`title` and `description`). Internal links are relative, for example `/reference/instance/`. After editing, rebuild with `bun build` to catch broken links or frontmatter errors. Format any Markdown or MDX with `just fmt md`, which runs remark through the docs bun project and preserves frontmatter.
