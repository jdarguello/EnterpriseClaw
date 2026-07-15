import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

// This runs in Node.js - Don't use client-side code here (browser APIs, JSX...)

const config: Config = {
  title: 'EnterpriseClaw',
  tagline: 'AI proposes; a governed, auditable GitOps pipeline disposes.',
  favicon: 'img/favicon.ico',

  future: {
    v4: true,
  },

  url: 'https://jdarguello.github.io',
  baseUrl: '/EnterpriseClaw/',

  organizationName: 'jdarguello',
  projectName: 'EnterpriseClaw',

  onBrokenLinks: 'throw',

  markdown: {
    mermaid: true,
  },
  themes: ['@docusaurus/theme-mermaid'],

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: './sidebars.ts',
          editUrl: 'https://github.com/jdarguello/EnterpriseClaw/tree/main/docs/',
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    colorMode: {
      respectPrefersColorScheme: true,
    },
    navbar: {
      title: 'EnterpriseClaw',
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'docsSidebar',
          position: 'left',
          label: 'Docs',
        },
        {
          href: 'https://github.com/jdarguello/EnterpriseClaw',
          label: 'GitHub',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Docs',
          items: [
            {label: 'What is EnterpriseClaw?', to: '/docs/intro'},
            {label: 'Architecture', to: '/docs/architecture'},
            {label: 'Demo walkthrough', to: '/docs/demo-walkthrough'},
            {label: 'Install & configuration', to: '/docs/install'},
          ],
        },
        {
          title: 'Project',
          items: [
            {
              label: 'GitHub',
              href: 'https://github.com/jdarguello/EnterpriseClaw',
            },
            {
              label: 'Session-Broker (identity layer)',
              href: 'https://github.com/jdarguello/Session-Broker',
            },
            {
              label: 'Issues & roadmap',
              href: 'https://github.com/jdarguello/EnterpriseClaw/issues',
            },
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} EnterpriseClaw. Built with Docusaurus.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
