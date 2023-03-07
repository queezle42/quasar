// Dev server entry point

import { hello } from './index';

document.querySelector<HTMLDivElement>('#app')!.innerHTML = `
  <h1>${hello}</h1>
`
