export const TASKS = Object.freeze([
  {
    id: 'settings-persistence-v1',
    family: 'forms-persistence',
    title: 'Persist user settings',
    docs: [
      { title: 'React forms', url: 'https://react.dev/reference/react-dom/components/input' },
      { title: 'localStorage', url: 'https://developer.mozilla.org/en-US/docs/Web/API/Window/localStorage' },
    ],
    brief: `Inputs: your default export is rendered as <App {...props}> with props {initialName, initialEmail, themes:[{id,label}], wantsUpdates:boolean, storageKey:string}. Build a user-visible preferences card and form. Required accessible controls: textboxes named "Display name" and "Email", a combobox named "Theme", a checkbox named "Email updates", and a button named "Save preferences". Before anything is saved, prefill from props. On save, persist the chosen name/email/theme/updates under localStorage[storageKey], show a visible saved status that includes the display name, and update a preview. On browser reload, restore the saved values instead of the original props. Do not hardcode seed data; different props are used for practice and transfer.`,
  },
  {
    id: 'task-list-productivity-v1',
    family: 'stateful-lists',
    title: 'Manage a persistent task list',
    docs: [
      { title: 'React state', url: 'https://react.dev/learn/updating-arrays-in-state' },
      { title: 'ARIA button role', url: 'https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Roles/button_role' },
    ],
    brief: `Inputs: <App {...props}> receives {initialTasks:[{id,title,done}], newTaskTitle:string, storageKey:string}. Build a small task manager. Required accessible controls: textbox "New task", button "Add task", filter buttons named "All", "Active", and "Completed", one checkbox per task named with that task title, and one delete button per task whose accessible name includes "Delete" and the task title. Show initial tasks from props, add the typed task, toggle completion, delete tasks, filter active/completed/all, and persist the current task list to localStorage[storageKey] so reload keeps additions, toggles, and deletions. Do not pass by rendering static text only; the evaluator interacts with varied task data.`,
  },
  {
    id: 'catalog-search-sort-v1',
    family: 'data-browsing',
    title: 'Search, filter, and sort a product catalog',
    docs: [
      { title: 'Rendering lists', url: 'https://react.dev/learn/rendering-lists' },
      { title: 'Select element', url: 'https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/select' },
    ],
    brief: `Inputs: <App {...props}> receives {products:[{sku,name,category,price,rating}], categories:string[]}. Build a catalog browser. Required accessible controls: textbox "Search products", combobox "Category", and combobox "Sort". Category must include an "All" option plus the seeded categories. Sort options must include visible choices "Name A-Z", "Price: low to high", and "Rating: high to low". Render all matching products with their name, category, price, and rating, preferably in a list/table. Search must be case-insensitive across product names. Category filtering and sorting must compose with the current search. The evaluator uses different seeded products, searches for real item names, and verifies visible ordering, so hardcoded product text will fail transfer.`,
  },
  {
    id: 'registration-validation-v1',
    family: 'forms-validation',
    title: 'Validate registration before success',
    docs: [
      { title: 'Controlled inputs', url: 'https://react.dev/reference/react-dom/components/input' },
      { title: 'ARIA invalid', url: 'https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Attributes/aria-invalid' },
    ],
    brief: `Inputs: <App {...props}> receives {inviteCode:string, minAge:number, reservedNames:string[]}. Build a registration form. Required accessible controls: textboxes "Full name", "Email", "Password", "Age", "Invite code", checkbox "Accept terms", and button "Create account". Validate on submit: name is not blank and is not in reservedNames (case-insensitive), email looks valid, password is at least 8 characters, age is a number >= minAge, invite code exactly matches props.inviteCode, and terms are accepted. Show visible per-field error messages and set aria-invalid=true on invalid inputs. Do not show success while invalid. When all fields are valid, show a visible success summary containing the submitted name and email.`,
  },
  {
    id: 'keyboard-tabs-dialog-v1',
    family: 'keyboard-a11y',
    title: 'Keyboard tabs with a returning dialog',
    docs: [
      { title: 'React refs', url: 'https://react.dev/learn/manipulating-the-dom-with-refs' },
      { title: 'ARIA tabs role', url: 'https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Roles/tab_role' },
    ],
    brief: `Inputs: <App {...props}> receives {tabs:[{id,label,content}], dialogTitle:string, dialogBody:string, actionLabel:string}. Build an accessible information panel. Required: a tablist containing one role="tab" per tab, role="tabpanel" content for the selected tab, ArrowRight/ArrowLeft/Home/End keyboard navigation that moves focus and changes the selected tab, aria-selected on tabs, a button named exactly by props.actionLabel, and a modal-like element role="dialog" labelled by props.dialogTitle. Opening the dialog shows dialogTitle and dialogBody and moves focus inside it. A button "Close details" and the Escape key close it. After close, focus returns to the opener button. The evaluator uses seeded labels/content and real keyboard events.`,
  },
  {
    id: 'marketing-site-architecture-v1',
    family: 'marketing-sites',
    title: 'Structure a premium product marketing site',
    qualityProfile: 'marketing-site-v1',
    docs: [
    { title: 'Landmark regions', url: 'https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Roles/landmark_role' },
    { title: 'Responsive design', url: 'https://developer.mozilla.org/en-US/docs/Learn_web_development/Core/CSS_layout/Responsive_Design' },
    ],
    brief: `Inputs: <App {...props}> receives {brand,product,tagline,sections:[{id,label}],primaryCta,secondaryCta,proofPoints:string[]}. Build a polished B2B product-marketing page. Render a header with the brand and navigation links named from sections, exactly one meaningful h1 containing product or tagline language, a main region with a hero plus at least four substantial labelled sections, both CTA labels as real buttons or links, honest proof-point content from props, and a footer containing the brand. The supplied stylesheet hides button.menu on desktop; never put className="menu" on nav or display:none those links. The layout must have a deliberate visual system, readable typography, strong hierarchy, restrained density, and intentionally different desktop/mobile composition. Do not invent statistics, customers, certifications or guarantees.`,
  },
  {
    id: 'responsive-site-navigation-v1',
    family: 'marketing-sites',
    title: 'Build responsive marketing navigation',
    qualityProfile: 'marketing-site-v1',
    docs: [
    { title: 'ARIA expanded', url: 'https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Attributes/aria-expanded' },
    { title: 'Navigation landmark', url: 'https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Roles/navigation_role' },
    ],
    brief: `Inputs: <App {...props}> receives {brand:string,product:string,tagline:string,sections:Array<{id:string,label:string}>,primaryCta:string,secondaryCta:string,proofPoints:string[]}. Define this prop shape explicitly in TypeScript. Build a premium responsive product page whose header contains the seeded brand, a navigation landmark and links generated from every sections[].label using sections[].id as targets. The supplied stylesheet expects the brand link, button.menu and nav to be sibling children of header; set nav className to "open" only while expanded, and never inline-hide nav or set aria-hidden because desktop links must remain visible. At mobile width expose a button named "Menu" with aria-expanded=false while closed; it opens access to every seeded section link with aria-expanded=true, Escape closes it, and focus remains usable. Include exactly one meaningful h1, a strong hero, at least four substantial labelled main sections, both seeded CTA labels as real links or buttons, every seeded proofPoint, and a footer containing the brand. Main text must be substantial (at least 650 visible characters). Use small eyebrow/plan-label styles only for short labels, not repeated body paragraphs. Desktop and mobile must be composed intentionally without horizontal overflow or tiny text. Treat sections as objects, never call string methods on a section object, and do not hardcode fixture text or invent business claims.`,
  },
  {
    id: 'feature-lifecycle-explorer-v1',
    family: 'marketing-sites',
    title: 'Create an interactive product lifecycle explorer',
    qualityProfile: 'marketing-site-v1',
    docs: [
    { title: 'React state', url: 'https://react.dev/learn/state-a-components-memory' },
    { title: 'ARIA tabs pattern', url: 'https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Roles/tab_role' },
    ],
    brief: `Inputs: <App {...props}> receives {brand:string,product:string,tagline:string,sections:Array<{id:string,label:string}>,primaryCta:string,secondaryCta:string,proofPoints:string[],lifecycle:Array<{stage:string,summary:string,features:string[]}>}. Define this prop shape explicitly in TypeScript. Build a premium product page with an interactive lifecycle explorer. Provide one visible button or role=tab named from every lifecycle[].stage; selecting it must visibly show that same item's summary and every feature. Provide a textbox named "Search features" that searches case-insensitively across features from every lifecycle item and visibly lists all matches, independent of the selected stage; derive this list without synchronized duplicate state. The supplied stylesheet expects the brand link, button.menu and nav to be sibling children of header; set nav className to "open" only while expanded, never put className="menu" on nav, and never inline-hide desktop links. Place the hero, the single h1, and every content section inside the main landmark so the visual hierarchy is evaluated together. Render the seeded brand, product, section links, CTAs and proof points with at least four labelled main sections and at least 650 visible characters of meaningful main content. Seeded content must drive the UI; do not rename props, substitute old schemas, hardcode fixture examples or invent claims.`,
  },
  {
    id: 'pricing-demo-conversion-v1',
    family: 'marketing-sites',
    title: 'Design pricing and demo conversion',
    qualityProfile: 'marketing-site-v1',
    docs: [
    { title: 'React forms', url: 'https://react.dev/reference/react-dom/components/input' },
    { title: 'ARIA invalid', url: 'https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Attributes/aria-invalid' },
    ],
    brief: `Inputs: marketing-site props plus plans:[{name,description,features:string[]}],eventTypes:string[]. Build a premium product page with clearly comparable plan cards and an accessible demo form. Render every seeded plan name, description and feature. Provide textboxes "Name" and "Work email", combobox "Event type", and button "Book a demo". Invalid submission must show visible errors and aria-invalid without success; valid submission shows a success message containing the submitted name. Include coherent hero/navigation/CTA/footer structure and responsive professional styling. Never invent prices, customer metrics, certifications or guarantees.`,
  },
  {
    id: 'event-platform-showcase-v1',
    family: 'marketing-sites',
    title: 'Assemble a complete event-platform showcase',
    qualityProfile: 'marketing-site-v1',
    docs: [
      { title: 'Thinking in React', url: 'https://react.dev/learn/thinking-in-react' },
      { title: 'Web accessibility', url: 'https://developer.mozilla.org/en-US/docs/Web/Accessibility' },
    ],
    brief: `Inputs combine all marketing-site props: brand, product, tagline, sections, CTAs, proofPoints, lifecycle, plans and eventTypes. Build one cohesive premium event-platform marketing site that passes the complete architecture, responsive Menu navigation, lifecycle stage switching, feature search, comparable plan cards and validated demo-form requirements from the trusted marketing contracts. Use seeded content everywhere. Establish a distinctive but restrained visual system with deliberate hierarchy, spacing, responsive composition and conversion flow. Do not use placeholders or invent prices, customer statistics, certifications, guarantees or security claims.`,
  },
  {
    id: 'client-routing-v1',
    family: 'application-systems',
    title: 'Client-route a seeded workbench',
    docs: [
      { title: 'The Location interface', url: 'https://developer.mozilla.org/en-US/docs/Web/API/Location' },
      { title: 'hashchange', url: 'https://developer.mozilla.org/en-US/docs/Web/API/Window/hashchange_event' },
    ],
    brief: `Inputs: <App {...props}> receives {workspace:string, routes:[{id,label,title,body}]}. Build a client-routed workbench with no network router. Render the seeded workspace as a visible heading. Provide navigation links named exactly from every routes[].label whose href hash contains that item's id (for example #/inbox-12). Selecting a route must show that same item's title and body and update location.hash so it contains the id. An unknown hash such as #/missing-seed must show visible text "Not found" and must not show another route's body. Browser back must restore the previously visible route title. Do not hardcode fixture labels; practice and transfer use different route ids. Hash routing is enough; do not fetch remote URLs.`,
  },
  {
    id: 'async-data-states-v1',
    family: 'application-systems',
    title: 'Render loading, error, empty and ready data states',
    docs: [
      { title: 'ARIA status', url: 'https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Roles/status_role' },
      { title: 'ARIA alert', url: 'https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Roles/alert_role' },
    ],
    brief: `Inputs: <App {...props}> receives {records:[{id,title,detail}], errorMessage:string, emptyLabel:string}. Build a records panel whose Resource status combobox offers Loading, Error, Empty and Ready. Loading must expose a status named Loading and must not list seeded record titles. Error must expose role=alert containing errorMessage and a Retry button that returns to Ready. Empty must show emptyLabel and must not list seeded record titles. Ready must list every seeded record title and detail. The evaluator switches all four states and checks that titles disappear during Loading and Empty. Do not fetch the network; drive state from the combobox. Do not hardcode record titles.`,
  },
  {
    id: 'error-boundary-recovery-v1',
    family: 'application-systems',
    title: 'Recover from a render crash behind an error boundary',
    docs: [
      { title: 'React error boundaries', url: 'https://react.dev/reference/react/Component#catching-rendering-errors-with-an-error-boundary' },
      { title: 'getDerivedStateFromError', url: 'https://react.dev/reference/react/Component#static-getderivedstatefromerror' },
    ],
    brief: `Inputs: <App {...props}> receives {panelTitle:string, crashLabel:string, fallbackTitle:string, recoveryLabel:string}. Render panelTitle in a child that can crash during render (not in a click handler). A button named crashLabel arms the crash. After the throw, an error boundary must show fallbackTitle and must not keep showing panelTitle. A button named recoveryLabel resets the boundary so panelTitle is visible again. Use a class error boundary (getDerivedStateFromError or componentDidCatch). Event-handler throws do not count. Do not let the whole #root go blank. Do not hardcode the seeded titles.`,
  },
  {
    id: 'large-list-performance-v1',
    family: 'application-systems',
    title: 'Filter a large keyed list without stalling',
    docs: [
      { title: 'Rendering lists', url: 'https://react.dev/learn/rendering-lists' },
      { title: 'Keeping list items in order with key', url: 'https://react.dev/learn/rendering-lists#keeping-list-items-in-order-with-key' },
    ],
    brief: `Inputs: <App {...props}> receives {items:[{id,name,group}]} with dozens of unique seeded rows. Render a textbox named Search items and a list labelled Items. With an empty query every seeded name is visible. Filtering by a unique name must show that row and hide an unrelated seeded name. Map with a stable key on each row (key={item.id} or equivalent). The filter interaction must complete inside the examiner action timeout; a synchronous O(n) filter over the seeded array is enough, a hung render is not. Do not hardcode names. Do not fetch. Missing keys fail the source contract.`,
  },
  {
    id: 'react-god-workbench-v1',
    family: 'application-systems',
    title: 'Assemble a React God workbench',
    docs: [
      { title: 'Thinking in React', url: 'https://react.dev/learn/thinking-in-react' },
      { title: 'React error boundaries', url: 'https://react.dev/reference/react/Component#catching-rendering-errors-with-an-error-boundary' },
    ],
    brief: `Inputs combine the God-cycle contracts: workspace, routes[{id,label,title,body}] (Inbox, Catalog, Lab), records, errorMessage, emptyLabel, items[{id,name,group}], panelTitle, crashLabel, fallbackTitle, recoveryLabel. Build one client-routed workbench that still passes client routing (hash links, Not found, back), Resource status loading/error/empty/ready on Inbox, Search items over the large keyed catalog list, and the Lab error boundary crash/recovery. Default hash is the Inbox route. Do not call the network. Do not hardcode seeded labels. This is the God exam: all four systems in one app, not a marketing site reskin.`,
  },
]);

export function getTask(id) {
  const task = TASKS.find(item => item.id === id);
  if (!task) throw new Error(`Unknown frontend gym task: ${id}`);
  return task;
}
