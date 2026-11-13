'use strict';
const node=(tag,text,className)=>{const value=document.createElement(tag);if(text!==undefined)value.textContent=text;if(className)value.className=className;return value};
const container=document.getElementById('projects'),status=document.getElementById('status'),viewer=document.getElementById('viewer');
let projects=[];
const projectOrder=new Map([['workspace',0],['command-center',1],['ios-shortcuts',2],['remote-dashboard',3],['reclaim11',Number.MAX_SAFE_INTEGER]]);
function link(text,value){const url=new URL(value);if(url.protocol!=='https:'||url.username||url.password)throw new Error('Invalid project link');const a=node('a',text);a.href=url.href;a.rel='noopener noreferrer';return a}
function imageUrl(project,image){
  if(!/^[a-z][a-z0-9-]{0,47}$/.test(project.id)||!/^[A-Z][A-Z0-9_]{0,47}$/.test(image.id)||!/^[a-f0-9]{64}$/.test(image.sha256)||
    !['webp','png'].some(ext=>image.path===`assets/${project.id}/${image.id}.${ext}`))throw new Error('Invalid image reference');
  return `./${image.path}?v=${image.sha256}`;
}
function render(){
  const query=document.getElementById('search').value.toLowerCase().trim(),visible=projects.filter(p=>`${p.title} ${p.description} ${p.images.map(image=>image.description).join(' ')}`.toLowerCase().includes(query));
  container.replaceChildren();
  for(const project of visible){
    const article=node('article');article.append(node('h2',project.title),node('p',project.description));
    const shots=node('div',undefined,'shots');
    for(const image of project.images){
      const figure=node('figure'),button=node('button'),img=node('img'),url=imageUrl(project,image);
      button.type='button';button.setAttribute('aria-label',`Enlarge ${image.description}`);
      img.src=url;img.alt=image.description;img.width=image.width;img.height=image.height;img.loading='lazy';button.append(img);
      button.addEventListener('click',()=>{document.getElementById('viewer-title').textContent=project.title;const full=document.getElementById('full-image');full.src=url;full.alt=image.description;document.getElementById('caption').textContent=`${image.description} Capture: ${image.capture_kind}.`;viewer.showModal()});
      figure.append(button,node('figcaption',image.description),node('p',`Capture: ${image.capture_kind}`, 'capture'));shots.append(figure);
    }
    const nav=node('nav');nav.setAttribute('aria-label',`${project.title} links`);nav.append(link('Project',project.url),link('Source',project.source_url));
    article.append(shots,nav);container.append(article);
  }
  status.textContent=`${visible.length} project${visible.length===1?'':'s'} / ${visible.reduce((sum,p)=>sum+p.images.length,0)} images`;
}
document.getElementById('search').addEventListener('input',render);
document.getElementById('close').addEventListener('click',()=>viewer.close());
fetch('./catalog.json',{cache:'no-store'}).then(response=>{if(!response.ok)throw new Error(`Catalog HTTP ${response.status}`);return response.json()}).then(data=>{
  if(data.schema_version!==1||!Array.isArray(data.projects))throw new Error('Invalid project catalog');
  projects=[...data.projects].sort((a,b)=>(projectOrder.get(a.id)??4)-(projectOrder.get(b.id)??4));render();
}).catch(error=>{status.textContent=`Showcase unavailable: ${error.message}`;status.setAttribute('role','alert')});
