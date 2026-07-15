import type {ReactNode} from 'react';
import clsx from 'clsx';
import Heading from '@theme/Heading';
import styles from './styles.module.css';

type FeatureItem = {
  title: string;
  description: ReactNode;
};

const FeatureList: FeatureItem[] = [
  {
    title: 'AI proposes, GitOps disposes',
    description: (
      <>
        The agent reasons about what to build, but the only way anything gets
        created is a pull request a human merges — reconciled by Argo CD and
        Crossplane. Every order leaves an Argo Workflow run, a PR, and git
        history behind.
      </>
    ),
  },
  {
    title: 'The mesh is the boundary, not the model',
    description: (
      <>
        Which agents, MCP servers, and tools any identity can reach is decided
        by workload SPIFFE (Istio ambient) and Keycloak JWT claims
        (agentgateway) — never by the LLM. A prompt-injected agent still cannot
        touch a tool it isn&apos;t allow-listed for.
      </>
    ),
  },
  {
    title: 'Two identity rails',
    description: (
      <>
        Every privileged request carries a <em>human</em> identity (a Keycloak
        JWT brokered from Slack) alongside the <em>workload</em> identity
        (SPIFFE/mTLS) — so authorization and audit are per-person, not
        per-bot-token.
      </>
    ),
  },
];

function Feature({title, description}: FeatureItem) {
  return (
    <div className={clsx('col col--4')}>
      <div className="text--center padding-horiz--md">
        <Heading as="h3">{title}</Heading>
        <p>{description}</p>
      </div>
    </div>
  );
}

export default function HomepageFeatures(): ReactNode {
  return (
    <section className={styles.features}>
      <div className="container">
        <div className="row">
          {FeatureList.map((props, idx) => (
            <Feature key={idx} {...props} />
          ))}
        </div>
      </div>
    </section>
  );
}
