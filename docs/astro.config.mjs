// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightThemeSix from '@six-tech/starlight-theme-six';

const site = process.env.GITHUB_PAGES_SITE_URL;
const base = process.env.GITHUB_PAGES_BASE || '/';
const docsLink = `${base.replace(/\/$/, '')}/tutorials/first-build/`;

export default defineConfig({
  ...(site ? { site } : {}),
  base,
  trailingSlash: "always",
  vite: {
    build: {
      // Six 1.0.16 ships an invalid `:after :before` reset selector that
      // Lightning CSS refuses to minify. Browsers already ignore it, so
      // keep the stylesheet untouched and skip minification instead.
      cssMinify: false,
    },
  },
  redirects: {
    '/getting-started': docsLink,
  },
  integrations: [
    starlight({
      title: 'Ardos Packer 2',
      logo: { src: './src/assets/ardos-packer2.svg', alt: 'Ardos Packer 2' },
      plugins: [
        starlightThemeSix({
          navLinks: [{ label: 'Docs', link: '/tutorials/first-build/' }],
          footerText: 'Built for & part of [Ardos OS](https://github.com/ardos-os)',
        }),
      ],
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/ardos-os/ardos-packer2' },
      ],
      sidebar: [
        {
          label: 'Tutorials',
          items: [
            { label: 'Build your first image', link: '/tutorials/first-build/' },
          ],
        },
        {
          label: 'How-to guides',
          items: [
            { label: 'Add a package to an Ardos image', link: '/how-to/add-package/' },
            { label: 'Use the Cachix binary cache', link: '/how-to/use-cachix/' },
            { label: 'Assemble the system image', link: '/how-to/assemble-image/' },
            { label: 'Run the image in a virtual machine', link: '/how-to/run-vm/' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Instance', link: '/reference/instance/' },
            { label: 'Builders', link: '/reference/builders/' },
          ],
        },
        {
          label: 'Explanation',
          items: [
            { label: 'About the build pipeline', link: '/explanation/build-pipeline/' },
          ],
        },
        {
          label: 'Contributing',
          items: [
            { label: 'Repository commands', link: '/contributing/commands/' },
          ],
        },
      ],
    }),
  ],
});
