<!-- FSA-IDENTITY-LOGO-START -->

<!-- FSA-IDENTITY-LOGO-END -->

<div class="fsa-cover">

<!-- FSA-IDENTITY-TITLE-START -->
<p class="fsa-eyebrow">REPOSITORY AUTOMATION · CONTROL PLANE</p>

# fork-sync-all

<p class="fsa-hero-tagline">Sync with confidence. Mirror with clarity. Automate the busywork.</p>

<p class="fsa-hero-summary"><strong>fork-sync-all</strong> coordinates repository sync, cross-forge mirroring, README maintenance, upstream tracking, and operational workflows across the Interested-Deving-1896 ecosystem.</p>
<!-- FSA-IDENTITY-TITLE-END -->

<div class="fsa-badges">
<!-- FSA-COVER-BADGE-START -->
<a href="https://github.com/Interested-Deving-1896/fork-sync-all/actions"><img src="https://img.shields.io/badge/workflows-191-0033cc?style=flat-square" alt="191 Workflows"></a>
<!-- FSA-COVER-BADGE-END -->
<a href="https://interested-deving-1896.github.io/fork-sync-all/"><img src="https://img.shields.io/badge/docs-GitHub%20Pages-00aacc?style=flat-square" alt="GitHub Pages"></a>
<a href="https://ona.com"><img src="https://img.shields.io/badge/built%20with-Ona-cc0000?style=flat-square" alt="Built with Ona"></a>
<!-- FSA-IDENTITY-BADGE-EXTRA-START -->

<!-- FSA-IDENTITY-BADGE-EXTRA-END -->
</div>

<div class="fsa-hero-visual" role="img" aria-label="Repository changes flow from GitHub source through the Fork-Sync-All automation control plane to GitHub and GitLab mirrors">
  <svg viewBox="0 0 760 218" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
    <defs>
      <linearGradient id="fsa-flow" x1="0" y1="0" x2="1" y2="0">
        <stop offset="0%" stop-color="#39b8ff"/>
        <stop offset="100%" stop-color="#8b7bff"/>
      </linearGradient>
      <linearGradient id="fsa-panel" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0%" stop-color="#172a55"/>
        <stop offset="100%" stop-color="#101a35"/>
      </linearGradient>
    </defs>
    <path d="M145 99 H267 M493 99 H615" stroke="url(#fsa-flow)" stroke-width="3" stroke-linecap="round" stroke-dasharray="7 7"/>
    <path d="M255 90 L267 99 L255 108 M603 90 L615 99 L603 108" fill="none" stroke="#8b7bff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>
    <rect x="18" y="52" width="127" height="94" rx="17" fill="#132443" stroke="#3c5c8d"/>
    <rect x="267" y="24" width="226" height="150" rx="21" fill="url(#fsa-panel)" stroke="#5a8cff" stroke-width="1.5"/>
    <rect x="615" y="52" width="127" height="94" rx="17" fill="#132443" stroke="#3c5c8d"/>
    <circle cx="81" cy="81" r="17" fill="#233e6c"/>
    <path d="M75 76 L81 72 L87 76 L87 86 L81 90 L75 86 Z M75 76 L81 80 L87 76 M81 80 V90" fill="none" stroke="#8ed8ff" stroke-width="1.8" stroke-linejoin="round"/>
    <circle cx="678" cy="81" r="17" fill="#3d2941"/>
    <path d="M670 84 L675 75 L679 81 L683 75 L687 84 M670 87 H687" fill="none" stroke="#ffb19b" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>
    <circle cx="380" cy="67" r="21" fill="#243e78"/>
    <path d="M370 63 L380 57 L390 63 V74 L380 80 L370 74 Z M370 63 L380 69 L390 63 M380 69 V80" fill="none" stroke="#b8d9ff" stroke-width="2" stroke-linejoin="round"/>
    <path d="M344 106 H416 M344 116 H400 M344 126 H409" stroke="#5575ac" stroke-width="4" stroke-linecap="round"/>
    <circle cx="332" cy="106" r="3" fill="#54d7c5"/><circle cx="332" cy="116" r="3" fill="#5a9bff"/><circle cx="332" cy="126" r="3" fill="#b39bff"/>
    <g fill="#f3f7ff" font-family="system-ui, sans-serif" font-size="12" font-weight="650" text-anchor="middle">
      <text x="81" y="117">SOURCE</text><text x="81" y="132" fill="#8ca7d3" font-size="10" font-weight="500">Repositories</text>
      <text x="380" y="151">FORK-SYNC-ALL</text><text x="678" y="117">MIRRORS</text><text x="678" y="132" fill="#8ca7d3" font-size="10" font-weight="500">GitHub + GitLab</text>
    </g>
    <g fill="#8fb4ef" font-family="system-ui, sans-serif" font-size="10" text-anchor="middle"><text x="206" y="83">SYNC</text><text x="554" y="83">PUBLISH</text></g>
  </svg>
  <div class="fsa-hero-caption"><span class="fsa-live-dot"></span> One automation layer · Multiple forges · Observable workflows</div>
</div>

<div class="fsa-quick-actions">
  <a href="architecture.html"><span class="fsa-action-symbol">↗</span><span><strong>Explore the architecture</strong><small>Understand the mirror chain</small></span></a>
  <a href="workflow-triggers.html"><span class="fsa-action-symbol">⌘</span><span><strong>Browse workflows</strong><small>See triggers and dependencies</small></span></a>
  <a href="runbooks.html"><span class="fsa-action-symbol">◷</span><span><strong>Open runbooks</strong><small>Find operational guidance</small></span></a>
</div>

</div>

---

## Find your way around

<p class="fsa-section-intro">Start with the overview, jump into daily operations, or dig into the generated reference material.</p>

<div class="fsa-index-grid">
<a class="fsa-index-card" href="architecture.html"><span class="fsa-card-icon fsa-icon-blue">⌘</span><h3>Architecture</h3><p>Mirror-chain design, data flow, GitLab subgroups, token model, and quota layers.</p><span class="fsa-card-arrow">Explore guide →</span></a>
<a class="fsa-index-card" href="workflow-triggers.html"><span class="fsa-card-icon fsa-icon-cyan">⇄</span><h3>Workflow triggers</h3><p>Schedules, dispatch events, cross-workflow dependencies, and all <!-- FSA-COVER-COUNT-START -->191 workflows<!-- FSA-COVER-COUNT-END -->.</p><span class="fsa-card-arrow">Browse workflows →</span></a>
<a class="fsa-index-card" href="OPERATIONS.html"><span class="fsa-card-icon fsa-icon-red">⌁</span><h3>Operations</h3><p>Actions limits, quota management, concurrency groups, and schedule planning.</p><span class="fsa-card-arrow">View operations →</span></a>
<a class="fsa-index-card" href="quota-costs.html"><span class="fsa-card-icon fsa-icon-violet">◫</span><h3>Quota &amp; costs</h3><p>REST call costs, daily budgets, rate-limit strategy, and GraphQL savings.</p><span class="fsa-card-arrow">Review budgets →</span></a>
<a class="fsa-index-card" href="runbooks.html"><span class="fsa-card-icon fsa-icon-amber">⚑</span><h3>Runbooks</h3><p>Response steps for quota exhaustion, queue pile-ups, token expiry, and mirror incidents.</p><span class="fsa-card-arrow">Get help →</span></a>
<a class="fsa-index-card" href="contributing.html"><span class="fsa-card-icon fsa-icon-green">＋</span><h3>Contributing</h3><p>How to add workflows, scripts, config, tests, and white-label support.</p><span class="fsa-card-arrow">Start contributing →</span></a>
<a class="fsa-index-card" href="generated/source-tree.html"><span class="fsa-card-icon fsa-icon-slate">▤</span><h3>Source tree</h3><p>Navigate the project’s directories and files from one searchable index.</p><span class="fsa-card-arrow">Browse source →</span></a>
<a class="fsa-index-card" href="generated/glossary.html"><span class="fsa-card-icon fsa-icon-violet">Aa</span><h3>Glossary</h3><p>Definitions for the terminology, acronyms, and concepts used throughout the project.</p><span class="fsa-card-arrow">Look up a term →</span></a>
</div>

<div class="fsa-bottom-cta">
  <div><span class="fsa-bottom-kicker">OPEN SOURCE · AUTOMATION FIRST</span><h2>Need to go deeper?</h2><p>Read the source, inspect the latest workflow runs, or help improve the project.</p></div>
  <div class="fsa-bottom-links"><a href="https://github.com/Interested-Deving-1896/fork-sync-all">View repository ↗</a><a href="https://github.com/Interested-Deving-1896/fork-sync-all/actions">Inspect Actions ↗</a></div>
</div>
