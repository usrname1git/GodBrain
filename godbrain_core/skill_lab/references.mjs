const baseCss = `
* { box-sizing: border-box; }
body { margin: 0; font-family: system-ui, Segoe UI, sans-serif; background: #f6f7fb; color: #172033; }
main { width: min(920px, calc(100vw - 24px)); margin: 16px auto; background: white; border-radius: 18px; padding: 20px; box-shadow: 0 8px 28px #17203322; }
label { display: grid; gap: 6px; margin: 10px 0; font-weight: 650; }
input, select, button { font: inherit; max-width: 100%; }
input, select { padding: 10px; border: 1px solid #aab2c5; border-radius: 10px; }
button { border: 0; border-radius: 10px; padding: 10px 14px; margin: 4px; background: #2447c6; color: white; cursor: pointer; }
button.secondary { background: #e8ecf8; color: #172033; }
button[aria-pressed="true"], [role="tab"][aria-selected="true"] { outline: 3px solid #ffbf47; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 12px; }
.card, li { overflow-wrap: anywhere; border: 1px solid #d8deed; border-radius: 14px; padding: 12px; margin: 8px 0; }
.error { color: #a00000; font-weight: 650; }
.ok { color: #086b2f; font-weight: 700; }
@media (max-width: 430px) { main { padding: 14px; } button { width: 100%; margin-inline: 0; } }
`;

const marketingApp = `import {useMemo,useState} from 'react';
import './styles.css';
export default function App(props) {
  const {brand,product,tagline,sections,primaryCta,secondaryCta,proofPoints,lifecycle,plans,eventTypes}=props;
  const theme=['ink','tide','ember','forest','sand'][(brand||'').length%5];
  const [menu,setMenu]=useState(false),[stage,setStage]=useState(0),[search,setSearch]=useState('');
  const [form,setForm]=useState({name:'',email:'',type:eventTypes[0]||''}),[errors,setErrors]=useState({}),[success,setSuccess]=useState('');
  const features=useMemo(()=>lifecycle.flatMap(item=>item.features.map(feature=>({feature,stage:item.stage})))
    .filter(item=>item.feature.toLowerCase().includes(search.toLowerCase())),[lifecycle,search]);
  function submit(event){event.preventDefault();const next={};if(!form.name.trim())next.name='Name is required';if(!/^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$/.test(form.email))next.email='Valid work email is required';setErrors(next);setSuccess(Object.keys(next).length?'':form.name);}
  return <div data-theme={theme} onKeyDown={event=>{if(event.key==='Escape')setMenu(false)}}>
    <header><a className="brand" href="#top">{brand}</a><button className="menu" aria-expanded={menu} onClick={()=>setMenu(value=>!value)}>Menu</button>
      <nav aria-label="Primary" className={menu?'open':''}>{sections.map(item=><a key={item.id} href={'#'+item.id} onClick={()=>setMenu(false)}>{item.label}</a>)}</nav>
    </header>
    <main id="top">
      <section className="hero"><p className="eyebrow">One platform · every event stage</p><h1>{product}</h1><p className="lede">{tagline}. Bring planning, participation and learning into one calm operating system.</p>
        <div className="actions"><a className="primary" href={'#'+sections.at(-1).id}>{primaryCta}</a><a className="secondary" href={'#'+sections[0].id}>{secondaryCta}</a></div>
        <div className="proof">{proofPoints.map(item=><p key={item}>{item}</p>)}</div>
      </section>
      <section id={sections[0].id}><p className="eyebrow">Platform</p><h2>{sections[0].label}</h2><p>Build event programs around clear workflows rather than disconnected tools. Teams can shape registration, communication, live operations and follow-up while keeping each audience journey understandable.</p><div className="grid">{proofPoints.map((item,index)=><article key={item}><span>0{index+1}</span><h3>{item}</h3><p>Configure the workflow for each program and keep the next action visible to the team.</p></article>)}</div></section>
      <section id={sections[1].id} className="tinted"><p className="eyebrow">Explore the journey</p><h2>{sections[1].label}</h2>
        <div className="stage-buttons">{lifecycle.map((item,index)=><button key={item.stage} aria-pressed={stage===index} onClick={()=>{setStage(index);setSearch('')}}>{item.stage}</button>)}</div>
        <div className="lifecycle"><div><h3>{lifecycle[stage].stage}</h3><p>{lifecycle[stage].summary}</p></div><ul>{lifecycle[stage].features.map(item=><li key={item}>{item}</li>)}</ul></div>
        <label className="search">Search features<input value={search} onChange={event=>setSearch(event.target.value)}/></label>
        {search&&<ul className="results">{features.map(item=><li key={item.stage+item.feature}><strong>{item.feature}</strong><span>{item.stage}</span></li>)}</ul>}
      </section>
      <section id={sections[2].id}><p className="eyebrow">Flexible by design</p><h2>{sections[2].label}</h2><p>Support conferences, internal programs, courses and hybrid formats without forcing every team into the same process. Start focused, then add capabilities as the event model develops.</p><div className="solution-row">{eventTypes.map(item=><article key={item}><h3>{item}</h3><p>Purposeful workflows, participant communication and follow-up shaped for {item.toLowerCase()} teams.</p></article>)}</div></section>
      <section id={sections[3].id} className="dark"><p className="eyebrow">Trust through clarity</p><h2>{sections[3].label}</h2><p>Security and operational expectations should be explained with verifiable documentation, clear ownership and direct answers. This demonstration intentionally avoids unsupported certifications and invented performance claims.</p><a className="text-link" href={'#'+sections.at(-1).id}>Discuss your requirements</a></section>
      <section id="plans"><p className="eyebrow">Choose a starting point</p><h2>Packages built around your operation</h2><div className="plans">{plans.map((plan,index)=><article key={plan.name} className={index===1?'featured':''}><p className="plan-label">{index===1?'Most flexible':'Package'}</p><h3>{plan.name}</h3><p>{plan.description}</p><ul>{plan.features.map(item=><li key={item}>{item}</li>)}</ul><a href={'#'+sections.at(-1).id}>Talk about {plan.name}</a></article>)}</div></section>
      <section id={sections.at(-1).id} className="demo"><div><p className="eyebrow">See the workflow</p><h2>{sections.at(-1).label}</h2><p>Tell us what kind of program you are planning. This demonstration validates the request locally and makes no network submission.</p></div>
        <form onSubmit={submit} noValidate><label>Name<input aria-invalid={Boolean(errors.name)} value={form.name} onChange={event=>setForm({...form,name:event.target.value})}/></label>{errors.name&&<p className="error">{errors.name}</p>}
          <label>Work email<input aria-invalid={Boolean(errors.email)} value={form.email} onChange={event=>setForm({...form,email:event.target.value})}/></label>{errors.email&&<p className="error">{errors.email}</p>}
          <label>Event type<select value={form.type} onChange={event=>setForm({...form,type:event.target.value})}>{eventTypes.map(item=><option key={item}>{item}</option>)}</select></label><button className="primary">Book a demo</button>{success&&<p className="success">Thanks {success}. Your demonstration request is ready.</p>}</form>
      </section>
    </main><footer><strong>{brand}</strong><p>{product} · A demonstrative frontend concept.</p></footer>
  </div>;
}`;

const marketingCss = `
:root,[data-theme=ink]{color-scheme:dark;--ink:#e8eef4;--muted:#9aa8b8;--paper:#101826;--navy:#d5e2ee;--on-navy:#10243a;--cyan:#5eead4;--coral:#fb7185;--line:#243044;--header:#101826f2;--tint:#182232;--footer:#070b12;--hero:#151c2b;--eyebrow:#7dd3d0;--stage:#243044}
[data-theme=tide]{color-scheme:light;--ink:#083344;--muted:#3d6b78;--paper:#e4f4f4;--navy:#0b3d4a;--on-navy:#fff;--cyan:#2bb3b7;--coral:#e07a5f;--line:#b7d4d6;--header:#e4f4f4f2;--tint:#cfe8ea;--footer:#06252c;--hero:#f2fbfb;--eyebrow:#0e6e75;--stage:#b9d9dc}
[data-theme=ember]{color-scheme:light;--ink:#2a1a12;--muted:#7a5a4a;--paper:#f4ebe3;--navy:#4a2418;--on-navy:#fff;--cyan:#d4a574;--coral:#c45c26;--line:#e0cfc4;--header:#f4ebe3f2;--tint:#ead9cc;--footer:#1a0e0a;--hero:#fff6ee;--eyebrow:#9a4a28;--stage:#e4cbb8}
[data-theme=forest]{color-scheme:light;--ink:#14261c;--muted:#4d6b5c;--paper:#eaf3ea;--navy:#1c3d2e;--on-navy:#fff;--cyan:#5eae66;--coral:#c9842a;--line:#c9d9cc;--header:#eaf3eaf2;--tint:#d5e6d6;--footer:#0c1a12;--hero:#f5faf5;--eyebrow:#2d6a3e;--stage:#c5dcc8}
[data-theme=sand]{color-scheme:light;--ink:#10243a;--muted:#546779;--paper:#f7f4ee;--navy:#092238;--on-navy:#fff;--cyan:#45c6c8;--coral:#ef765f;--line:#ced9dd;--header:#f7f4eef2;--tint:#e6f1ef;--footer:#061827;--hero:#fff;--eyebrow:#176f75;--stage:#c9dddb}
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:var(--paper);color:var(--ink);font:16px/1.65 system-ui,Segoe UI,sans-serif}a{color:inherit}header{position:sticky;top:0;z-index:5;display:flex;align-items:center;justify-content:space-between;padding:18px clamp(22px,5vw,80px);background:var(--header);border-bottom:1px solid var(--line);backdrop-filter:blur(16px)}.brand{font-size:22px;font-weight:850;text-decoration:none;letter-spacing:-.04em}nav{display:flex;gap:24px}nav a,.text-link{font-weight:700;text-underline-offset:5px}.menu{display:none}main section{padding:72px clamp(22px,7vw,112px)}.hero{min-height:82vh;display:grid;align-content:center;background:radial-gradient(circle at 80% 20%,color-mix(in srgb,var(--cyan) 28%,transparent),transparent 30%),linear-gradient(145deg,var(--hero),var(--paper))}.eyebrow,.plan-label{margin:0 0 12px;color:var(--eyebrow);font-size:12px;font-weight:850;letter-spacing:.14em;text-transform:uppercase}h1,h2,h3,p{margin-top:0}h1{max-width:820px;margin-bottom:22px;font-size:clamp(44px,7vw,82px);line-height:.98;letter-spacing:-.06em}h2{max-width:760px;font-size:clamp(31px,4vw,52px);line-height:1.05;letter-spacing:-.045em}.lede{max-width:720px;color:var(--muted);font-size:22px}.actions{display:flex;flex-wrap:wrap;gap:12px;margin:28px 0}.primary,.secondary,button{display:inline-flex;justify-content:center;border:0;border-radius:999px;padding:13px 20px;font:inherit;font-weight:800;text-decoration:none;cursor:pointer}.primary{background:var(--navy);color:var(--on-navy)}.secondary{background:var(--hero);border:1px solid var(--line);color:var(--ink)}.proof{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin-top:40px}.proof p,.grid article,.solution-row article,.plans article{padding:22px;border:1px solid var(--line);border-radius:20px;background:color-mix(in srgb,var(--hero) 72%,transparent)}.grid,.solution-row,.plans{display:grid;grid-template-columns:repeat(3,1fr);gap:18px;margin-top:30px}.grid span{color:var(--coral);font-weight:900}.tinted{background:var(--tint)}.stage-buttons{display:flex;gap:10px;flex-wrap:wrap}.stage-buttons button{background:var(--stage);color:var(--ink)}.stage-buttons button[aria-pressed=true]{background:var(--navy);color:var(--on-navy)}.lifecycle{display:grid;grid-template-columns:1fr 1fr;gap:28px;margin:24px 0;padding:28px;border-radius:24px;background:var(--hero)}.search{display:grid;gap:7px;max-width:520px;font-weight:800}.search input,input,select{width:100%;padding:13px;border:1px solid var(--line);border-radius:10px;background:var(--hero);color:var(--ink);font:inherit}.results{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;padding:0}.results li{display:flex;justify-content:space-between;padding:12px;border-radius:10px;background:var(--hero)}.dark{background:var(--footer);color:#fff}.dark .eyebrow{color:var(--cyan)}.featured{border:2px solid var(--coral)!important;transform:translateY(-8px)}.demo{display:grid;grid-template-columns:1fr 1fr;gap:48px;background:var(--hero)}.demo form{padding:24px;border-radius:20px;background:var(--paper)}.demo label{display:grid;gap:6px;margin-bottom:12px;font-weight:750}.error{color:#a12b24;font-weight:750}.success{color:#176b43;font-weight:800}footer{display:flex;justify-content:space-between;padding:32px clamp(22px,7vw,112px);background:var(--footer);color:#fff}
@media(max-width:700px){header{padding:14px 18px}.menu{display:inline-flex;background:var(--navy);color:var(--on-navy)}nav{display:none;position:absolute;inset:65px 12px auto;padding:16px;flex-direction:column;border-radius:16px;background:var(--hero);box-shadow:0 18px 50px #09223833}nav.open{display:flex}main section{padding:54px 20px}.hero{min-height:auto;padding-block:74px}h1{font-size:44px}.lede{font-size:19px}.proof,.grid,.solution-row,.plans,.demo,.lifecycle{grid-template-columns:1fr}.featured{transform:none}.results{grid-template-columns:1fr}.actions>a{width:100%}footer{display:block;padding:30px 20px}}
`;

export const REFERENCES = Object.freeze({
  'settings-persistence-v1': {
    'App.jsx': `import {useMemo,useState} from 'react';
import './styles.css';
export default function App({initialName, initialEmail, themes, wantsUpdates, storageKey}) {
  const initial = useMemo(() => {
    try { return JSON.parse(localStorage.getItem(storageKey)) || null; } catch { return null; }
  }, [storageKey]);
  const [form, setForm] = useState(initial || {name: initialName, email: initialEmail, theme: themes[0]?.id || '', updates: wantsUpdates});
  const [saved, setSaved] = useState(Boolean(initial));
  const theme = themes.find(item => item.id === form.theme) || themes[0] || {label: 'Default', id: ''};
  function update(key, value) { setSaved(false); setForm(current => ({...current, [key]: value})); }
  function save(event) {
    event.preventDefault();
    localStorage.setItem(storageKey, JSON.stringify(form));
    setSaved(true);
  }
  return <main>
    <h1>Preferences</h1>
    <form onSubmit={save}>
      <label>Display name<input value={form.name} onChange={e => update('name', e.target.value)} /></label>
      <label>Email<input value={form.email} onChange={e => update('email', e.target.value)} /></label>
      <label>Theme<select value={form.theme} onChange={e => update('theme', e.target.value)}>{themes.map(theme => <option key={theme.id} value={theme.id}>{theme.label}</option>)}</select></label>
      <label><span>Email updates</span><input type="checkbox" checked={form.updates} onChange={e => update('updates', e.target.checked)} /></label>
      <button>Save preferences</button>
    </form>
    {saved && <p className="ok">Saved {form.name}</p>}
    <section className="card" aria-label="Profile preview">
      <h2>Preview</h2><p>{form.name}</p><p>{form.email}</p><p>{theme.label}</p><p>{form.updates ? 'Email updates on' : 'Email updates off'}</p>
    </section>
  </main>;
}`,
    'styles.css': baseCss,
  },
  'task-list-productivity-v1': {
    'App.jsx': `import {useEffect,useMemo,useState} from 'react';
import './styles.css';
export default function App({initialTasks, newTaskTitle, storageKey}) {
  const restored = useMemo(() => { try { return JSON.parse(localStorage.getItem(storageKey)) || null; } catch { return null; } }, [storageKey]);
  const [tasks, setTasks] = useState(restored || initialTasks);
  const [draft, setDraft] = useState('');
  const [filter, setFilter] = useState('All');
  useEffect(() => { localStorage.setItem(storageKey, JSON.stringify(tasks)); }, [tasks, storageKey]);
  const shown = tasks.filter(task => filter === 'All' || (filter === 'Active' ? !task.done : task.done));
  function add(event) { event.preventDefault(); const title = draft.trim() || newTaskTitle; if (title) setTasks(items => [...items, {id: crypto.randomUUID(), title, done: false}]); setDraft(''); }
  return <main>
    <h1>Tasks</h1>
    <form onSubmit={add}><label>New task<input value={draft} placeholder={newTaskTitle} onChange={e => setDraft(e.target.value)} /></label><button>Add task</button></form>
    <p>{tasks.filter(task => !task.done).length} active</p>
    {['All','Active','Completed'].map(name => <button className="secondary" aria-pressed={filter === name} key={name} onClick={() => setFilter(name)}>{name}</button>)}
    <ul>{shown.map(task => <li key={task.id}>
      <label><input aria-label={task.title} type="checkbox" checked={task.done} onChange={() => setTasks(items => items.map(item => item.id === task.id ? {...item, done: !item.done} : item))} /> {task.title}</label>
      <button onClick={() => setTasks(items => items.filter(item => item.id !== task.id))}>Delete {task.title}</button>
    </li>)}</ul>
  </main>;
}`,
    'styles.css': baseCss,
  },
  'catalog-search-sort-v1': {
    'App.jsx': `import {useMemo,useState} from 'react';
import './styles.css';
export default function App({products, categories}) {
  const [search, setSearch] = useState('');
  const [category, setCategory] = useState('All');
  const [sort, setSort] = useState('Name A-Z');
  const shown = useMemo(() => products
    .filter(product => product.name.toLowerCase().includes(search.toLowerCase()))
    .filter(product => category === 'All' || product.category === category)
    .sort((a,b) => sort === 'Price: low to high' ? a.price - b.price : sort === 'Rating: high to low' ? b.rating - a.rating : a.name.localeCompare(b.name)),
    [products, search, category, sort]);
  return <main>
    <h1>Catalog</h1>
    <div className="grid">
      <label>Search products<input value={search} onChange={e => setSearch(e.target.value)} /></label>
      <label>Category<select value={category} onChange={e => setCategory(e.target.value)}><option>All</option>{categories.map(item => <option key={item}>{item}</option>)}</select></label>
      <label>Sort<select value={sort} onChange={e => setSort(e.target.value)}><option>Name A-Z</option><option>Price: low to high</option><option>Rating: high to low</option></select></label>
    </div>
    <ul aria-label="Products">{shown.map(product => <li key={product.sku}><strong>{product.name}</strong><br />{product.category}<br />$ {product.price}<br />Rating {product.rating}</li>)}</ul>
  </main>;
}`,
    'styles.css': baseCss,
  },
  'registration-validation-v1': {
    'App.jsx': `import {useState} from 'react';
import './styles.css';
export default function App({inviteCode, minAge, reservedNames}) {
  const [values, setValues] = useState({name:'', email:'', password:'', age:'', invite:'', terms:false});
  const [errors, setErrors] = useState({});
  const [success, setSuccess] = useState(null);
  function set(key, value) { setValues(current => ({...current, [key]: value})); }
  function submit(event) {
    event.preventDefault();
    const next = {};
    if (!values.name.trim()) next.name = 'Name is required';
    else if (reservedNames.some(name => name.toLowerCase() === values.name.trim().toLowerCase())) next.name = 'That name is reserved';
    if (!/^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$/.test(values.email)) next.email = 'Enter a valid email';
    if (values.password.length < 8) next.password = 'Password must be at least 8 characters';
    if (!Number.isFinite(Number(values.age)) || Number(values.age) < minAge) next.age = 'Age must be at least ' + minAge;
    if (values.invite !== inviteCode) next.invite = 'Invite code does not match';
    if (!values.terms) next.terms = 'Accept terms to continue';
    setErrors(next); setSuccess(Object.keys(next).length ? null : {name: values.name, email: values.email});
  }
  const invalid = key => errors[key] ? 'true' : 'false';
  return <main><h1>Create account</h1><form onSubmit={submit} noValidate>
    <label>Full name<input aria-invalid={invalid('name')} value={values.name} onChange={e => set('name', e.target.value)} /></label>{errors.name && <p className="error">{errors.name}</p>}
    <label>Email<input aria-invalid={invalid('email')} value={values.email} onChange={e => set('email', e.target.value)} /></label>{errors.email && <p className="error">{errors.email}</p>}
    <label>Password<input aria-invalid={invalid('password')} type="password" value={values.password} onChange={e => set('password', e.target.value)} /></label>{errors.password && <p className="error">{errors.password}</p>}
    <label>Age<input aria-invalid={invalid('age')} value={values.age} onChange={e => set('age', e.target.value)} /></label>{errors.age && <p className="error">{errors.age}</p>}
    <label>Invite code<input aria-invalid={invalid('invite')} value={values.invite} onChange={e => set('invite', e.target.value)} /></label>{errors.invite && <p className="error">{errors.invite}</p>}
    <label><span>Accept terms</span><input aria-invalid={invalid('terms')} type="checkbox" checked={values.terms} onChange={e => set('terms', e.target.checked)} /></label>{errors.terms && <p className="error">{errors.terms}</p>}
    <button>Create account</button>
  </form>{success && <section className="ok"><h2>Success</h2><p>{success.name}</p><p>{success.email}</p></section>}</main>;
}`,
    'styles.css': baseCss,
  },
  'keyboard-tabs-dialog-v1': {
    'App.jsx': `import {useEffect,useRef,useState} from 'react';
import './styles.css';
export default function App({tabs, dialogTitle, dialogBody, actionLabel}) {
  const [selected, setSelected] = useState(0);
  const [open, setOpen] = useState(false);
  const opener = useRef(null);
  const closeButton = useRef(null);
  useEffect(() => { if (open) closeButton.current?.focus(); }, [open]);
  function choose(index) {
    const next = (index + tabs.length) % tabs.length;
    setSelected(next);
    requestAnimationFrame(() => document.getElementById('tab-' + tabs[next].id)?.focus());
  }
  function keys(event, index) {
    if (event.key === 'ArrowRight') choose(index + 1);
    if (event.key === 'ArrowLeft') choose(index - 1);
    if (event.key === 'Home') choose(0);
    if (event.key === 'End') choose(tabs.length - 1);
  }
  function close() { setOpen(false); requestAnimationFrame(() => opener.current?.focus()); }
  return <main><h1>Information</h1>
    <div role="tablist" aria-label="Seeded sections">{tabs.map((tab, index) => <button key={tab.id} id={'tab-' + tab.id} role="tab" aria-selected={selected === index} aria-controls={'panel-' + tab.id} tabIndex={selected === index ? 0 : -1} onKeyDown={event => keys(event, index)} onClick={() => choose(index)}>{tab.label}</button>)}</div>
    {tabs.map((tab, index) => selected === index && <section key={tab.id} id={'panel-' + tab.id} role="tabpanel" aria-labelledby={'tab-' + tab.id}><h2>{tab.label}</h2><p>{tab.content}</p></section>)}
    <button ref={opener} onClick={() => setOpen(true)}>{actionLabel}</button>
    {open && <div role="dialog" aria-modal="true" aria-labelledby="dialog-title" onKeyDown={event => { if (event.key === 'Escape') close(); }} className="card">
      <h2 id="dialog-title">{dialogTitle}</h2><p>{dialogBody}</p><button ref={closeButton} onClick={close}>Close details</button>
    </div>}
  </main>;
}`,
    'styles.css': baseCss,
  },
  'marketing-site-architecture-v1': { 'App.jsx': marketingApp, 'styles.css': marketingCss },
  'responsive-site-navigation-v1': { 'App.jsx': marketingApp, 'styles.css': marketingCss },
  'feature-lifecycle-explorer-v1': { 'App.jsx': marketingApp, 'styles.css': marketingCss },
  'pricing-demo-conversion-v1': { 'App.jsx': marketingApp, 'styles.css': marketingCss },
  'event-platform-showcase-v1': { 'App.jsx': marketingApp, 'styles.css': marketingCss },
  'client-routing-v1': {
    'App.jsx': `import {useEffect,useState} from 'react';
import './styles.css';
export default function App({workspace, routes}) {
  const read = () => (location.hash.replace(/^#\\/?/, '') || routes[0].id);
  const [id, setId] = useState(read);
  useEffect(() => {
    const onHash = () => setId(read());
    if (!location.hash) location.hash = '#/' + routes[0].id;
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, [routes]);
  const route = routes.find(item => item.id === id);
  return <main>
    <h1>{workspace}</h1>
    <nav aria-label="Workbench">{routes.map(item => <a key={item.id} href={'#/' + item.id}>{item.label}</a>)}</nav>
    {route ? <section><h2>{route.title}</h2><p>{route.body}</p></section> : <p role="status">Not found</p>}
  </main>;
}`,
    'styles.css': baseCss,
  },
  'async-data-states-v1': {
    'App.jsx': `import {useState} from 'react';
import './styles.css';
export default function App({records, errorMessage, emptyLabel}) {
  const [status, setStatus] = useState('ready');
  return <main>
    <h1>Records</h1>
    <label>Resource status<select value={status} onChange={event => setStatus(event.target.value)}>
      <option value="loading">Loading</option>
      <option value="error">Error</option>
      <option value="empty">Empty</option>
      <option value="ready">Ready</option>
    </select></label>
    {status === 'loading' && <p role="status">Loading</p>}
    {status === 'error' && <><p role="alert">{errorMessage}</p><button onClick={() => setStatus('ready')}>Retry</button></>}
    {status === 'empty' && <p>{emptyLabel}</p>}
    {status === 'ready' && <ul>{records.map(item => <li key={item.id}><strong>{item.title}</strong><p>{item.detail}</p></li>)}</ul>}
  </main>;
}`,
    'styles.css': baseCss,
  },
  'error-boundary-recovery-v1': {
    'App.jsx': `import {Component,useState} from 'react';
import './styles.css';
class Boundary extends Component {
  constructor(props) { super(props); this.state = {failed: false}; }
  static getDerivedStateFromError() { return {failed: true}; }
  render() {
    if (this.state.failed) {
      return <>
        <h2>{this.props.fallbackTitle}</h2>
        <button onClick={() => { this.setState({failed: false}); this.props.onReset(); }}>{this.props.recoveryLabel}</button>
      </>;
    }
    return this.props.children;
  }
}
function Panel({armed, panelTitle}) {
  if (armed) throw new Error('god-crash');
  return <p>{panelTitle}</p>;
}
export default function App({panelTitle, crashLabel, fallbackTitle, recoveryLabel}) {
  const [armed, setArmed] = useState(false);
  const [nonce, setNonce] = useState(0);
  return <main>
    <h1>Lab</h1>
    <Boundary key={nonce} fallbackTitle={fallbackTitle} recoveryLabel={recoveryLabel} onReset={() => { setArmed(false); setNonce(value => value + 1); }}>
      <Panel armed={armed} panelTitle={panelTitle} />
    </Boundary>
    <button onClick={() => setArmed(true)}>{crashLabel}</button>
  </main>;
}`,
    'styles.css': baseCss,
  },
  'large-list-performance-v1': {
    'App.jsx': `import {useMemo,useState} from 'react';
import './styles.css';
export default function App({items}) {
  const [query, setQuery] = useState('');
  const shown = useMemo(() => items.filter(item => item.name.toLowerCase().includes(query.toLowerCase())), [items, query]);
  return <main>
    <h1>Index</h1>
    <label>Search items<input value={query} onChange={event => setQuery(event.target.value)} /></label>
    <p>{shown.length} matches</p>
    <ul aria-label="Items">{shown.map(item => <li key={item.id}>{item.name}<span>{item.group}</span></li>)}</ul>
  </main>;
}`,
    'styles.css': baseCss,
  },
  'react-god-workbench-v1': {
    'App.jsx': `import {Component,useEffect,useMemo,useState} from 'react';
import './styles.css';
class Boundary extends Component {
  constructor(props) { super(props); this.state = {failed: false}; }
  static getDerivedStateFromError() { return {failed: true}; }
  render() {
    if (this.state.failed) {
      return <>
        <h2>{this.props.fallbackTitle}</h2>
        <button onClick={() => { this.setState({failed: false}); this.props.onReset(); }}>{this.props.recoveryLabel}</button>
      </>;
    }
    return this.props.children;
  }
}
function Panel({armed, panelTitle}) {
  if (armed) throw new Error('god-crash');
  return <p>{panelTitle}</p>;
}
export default function App({workspace, routes, records, errorMessage, emptyLabel, items, panelTitle, crashLabel, fallbackTitle, recoveryLabel}) {
  const read = () => (location.hash.replace(/^#\\/?/, '') || routes[0].id);
  const [id, setId] = useState(read);
  const [status, setStatus] = useState('ready');
  const [query, setQuery] = useState('');
  const [armed, setArmed] = useState(false);
  const [nonce, setNonce] = useState(0);
  useEffect(() => {
    const onHash = () => setId(read());
    if (!location.hash) location.hash = '#/' + routes[0].id;
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, [routes]);
  const shown = useMemo(() => items.filter(item => item.name.toLowerCase().includes(query.toLowerCase())), [items, query]);
  const route = routes.find(item => item.id === id);
  const inbox = routes[0];
  const catalog = routes[1];
  const lab = routes[2];
  return <main>
    <h1>{workspace}</h1>
    <nav aria-label="Workbench">{routes.map(item => <a key={item.id} href={'#/' + item.id}>{item.label}</a>)}</nav>
    {!route && <p role="status">Not found</p>}
    {route && id === inbox.id && <>
      <h2>{inbox.title}</h2><p>{inbox.body}</p>
      <label>Resource status<select value={status} onChange={event => setStatus(event.target.value)}>
        <option value="loading">Loading</option>
        <option value="error">Error</option>
        <option value="empty">Empty</option>
        <option value="ready">Ready</option>
      </select></label>
      {status === 'loading' && <p role="status">Loading</p>}
      {status === 'error' && <><p role="alert">{errorMessage}</p><button onClick={() => setStatus('ready')}>Retry</button></>}
      {status === 'empty' && <p>{emptyLabel}</p>}
      {status === 'ready' && <ul>{records.map(item => <li key={item.id}><strong>{item.title}</strong><p>{item.detail}</p></li>)}</ul>}
    </>}
    {route && id === catalog.id && <>
      <h2>{catalog.title}</h2><p>{catalog.body}</p>
      <label>Search items<input value={query} onChange={event => setQuery(event.target.value)} /></label>
      <p>{shown.length} matches</p>
      <ul aria-label="Items">{shown.map(item => <li key={item.id}>{item.name}<span>{item.group}</span></li>)}</ul>
    </>}
    {route && id === lab.id && <>
      <h2>{lab.title}</h2><p>{lab.body}</p>
      <Boundary key={nonce} fallbackTitle={fallbackTitle} recoveryLabel={recoveryLabel} onReset={() => { setArmed(false); setNonce(value => value + 1); }}>
        <Panel armed={armed} panelTitle={panelTitle} />
      </Boundary>
      <button onClick={() => setArmed(true)}>{crashLabel}</button>
    </>}
  </main>;
}`,
    'styles.css': baseCss,
  },
  'visual-god-v1': {
    'App.jsx': `import './styles.css';
export default function App({brand, product, tagline, proof, primaryCta, visualSystem}) {
  const theme = {
    '--ink': visualSystem.ink,
    '--paper': visualSystem.paper,
    '--accent': visualSystem.accent,
    '--muted': visualSystem.muted,
    '--display': visualSystem.displayFont,
    '--body': visualSystem.bodyFont,
    '--radius': visualSystem.radius,
  };
  return <div data-visual="stage" style={theme}>
    <header><a href="#top">{brand}</a></header>
    <main id="top">
      <section className="hero">
        <p className="eyebrow">{visualSystem.name}</p>
        <h1>{product}</h1>
        <p className="lede">{tagline}</p>
        <a className="cta" href="#note">{primaryCta}</a>
      </section>
      <section className="split" id="note">
        <article>
          <h2>Field notes</h2>
          <p>{proof}</p>
        </article>
        <aside>
          <h2>Canvas</h2>
          <p>{visualSystem.name}</p>
        </aside>
      </section>
    </main>
    <footer>{brand}</footer>
  </div>;
}`,
    'styles.css': `
:root { --ink: #111111; --paper: #ffffff; --accent: #888888; --muted: #666666; --display: Georgia, serif; --body: Georgia, serif; --radius: 0px; }
* { box-sizing: border-box; }
html, body { margin: 0; }
[data-visual] { min-height: 100vh; background: var(--paper); color: var(--ink); font-family: var(--body); }
header, footer { padding: 20px 7vw; }
header a { color: inherit; font-weight: 800; text-decoration: none; }
main { padding: 0; }
.hero { padding: 72px 7vw 56px; text-align: start; max-width: 52rem; }
.eyebrow { margin: 0 0 12px; color: var(--muted); letter-spacing: .14em; text-transform: uppercase; font-size: 12px; font-weight: 800; }
h1 { margin: 0 0 16px; font-family: var(--display); font-size: 56px; line-height: 1.05; text-align: start; letter-spacing: -.03em; }
.lede { margin: 0 0 28px; font-size: 20px; color: var(--muted); max-width: 40rem; }
.cta { display: inline-block; background: var(--accent); color: var(--paper); text-decoration: none; font-weight: 800; padding: 12px 18px; border-radius: var(--radius); }
.split { display: grid; grid-template-columns: 1.6fr .8fr; gap: 28px; padding: 48px 7vw 80px; }
article, aside { padding: 24px; border: 1px solid color-mix(in srgb, var(--ink) 16%, transparent); border-radius: var(--radius); }
h2 { margin: 0 0 12px; font-family: var(--display); font-size: 22px; }
@media (max-width: 700px) { h1 { font-size: 40px; } .split { grid-template-columns: 1fr; padding: 32px 20px 56px; } .hero { padding: 48px 20px; } }
`,
  },
});

export function getReference(taskId) {
  const files = REFERENCES[taskId];
  if (!files) throw new Error(`No reference fixture for ${taskId}`);
  return { 'App.jsx': files['App.jsx'], 'styles.css': files['styles.css'] };
}
