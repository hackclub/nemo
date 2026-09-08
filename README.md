<p align="center">
  <img src="./web/public/nemo-pod.png" width="620" alt="a very large fish carrying some tiny friends">
</p>
<h1 align="center">mnemosyne</h1>

<p align="center">a big fish with a suspiciously good memory.</p>

mnemosyne is an internal hack club tool for understanding the community and helping the fire department handle conduct.

it turns slack metadata into useful community charts, follows the journey from joining to sticking around, and gives the cool folks a careful place to manage reports and cases.

there are two sides to the fish:

- **community (nemo):** aggregate analytics for onboarding, replies, retention, activity, and channels
- **fire engine:** cases, mirrored threads, notes, reports, and actions

mnemosyne is the umbrella for both ^

underneath both is the less fish-shaped part: an ingestion and warehouse engine that keeps track of sources, backfills, runs, coverage, and whether the numbers can actually be trusted.

built with rails, postgres, python, dbt, and d3. fueled by slack and an unreasonable number of shenanigans.

## inspirations and thanks

- [palantir foundry's](https://www.palantir.com/platforms/foundry/) and [data protection and governance guidance](https://www.palantir.com/docs/foundry/security/data-protection-and-governance/). mnemosyne is independent and hackclub isn't affilated with palantir.
- [d3](https://d3js.org/) my beloved tool for making charts that do exactly what I need them to do.
- the hack club community and fire department are the reason this exists, and the people teaching the fish what is useful deserve the biggest thanks.