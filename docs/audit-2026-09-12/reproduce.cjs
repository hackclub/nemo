const fs=require('fs'),vm=require('vm');
const path=require('path');
const repo=path.resolve(__dirname, '../..');
const root=repo+'/web/app/javascript/';
function load(name,extra={}){const src=fs.readFileSync(root+name+'_controller.js','utf8').replace('import { Controller } from "@hotwired/stimulus"','class Controller {}').replace('export default class extends Controller','globalThis.TestClass = class extends Controller');const ctx=vm.createContext({console,...extra});vm.runInContext(src,ctx);return ctx.TestClass}
(async()=>{
const Mention=load('controllers/mention'),Chat=load('controllers/chat');
const field={value:'Hi @al',selectionStart:6,setSelectionRange(x){this.selectionStart=x},focus(){}};
const pop={hidden:false,innerHTML:''};const m=new Mention();Object.assign(m,{fieldTarget:field,resultsTarget:pop,rows:()=>[{dataset:{id:'UALICE'}}],at:0});
let sends=0;const c=new Chat();Object.assign(c,{fieldTarget:field,sendTarget:{disabled:false},element:{querySelector:()=>pop,requestSubmit(){sends++}}});
const ev={key:'Enter',shiftKey:false,defaultPrevented:false,preventDefault(){this.defaultPrevented=true}};
m.keys(ev);c.keys(ev);console.log('Mention Enter submissions:',sends,'(expected 0)');
sends=0;c.keys({...ev,defaultPrevented:false,isComposing:true});console.log('IME Enter submissions:',sends,'(expected 0)');
const Cond=load('controllers/conditions'),cond=new Cond(),value={};
const op={dataset:{arity:'1'},closest:()=>({dataset:{for:'created'}})};
const row={querySelector:(s)=>s==='.cond-field'?{value:'created',selectedOptions:[{dataset:{kind:'date'}}]}:s==='.cond-op'?{selectedOptions:[op],querySelectorAll:()=>[]}:null,querySelectorAll:()=>[value]};
cond.fit(row);console.log('Absolute date filter input:',value.type,'(expected date)');
const stickSrc=fs.readFileSync(root+'controllers/stick_controller.js','utf8');const chatLogTpl=fs.readFileSync(repo+'/web/app/views/fd/cases/_chat_log.html.erb','utf8');console.log('Stick controller finds actual markup:',/targets\s*=\s*\[[^\]]*"log"/.test(stickSrc)&&chatLogTpl.includes('data-stick-target="log"'),'(expected true)');
const pending=[];const Picker=load('controllers/member_picker',{fetch:()=>new Promise(resolve=>pending.push(resolve))});const p=new Picker();Object.assign(p,{urlValue:'/mock',inputTarget:{value:'alice'},chosen:new Map(),show(members){this.shown=members}});
const a=p.look();p.inputTarget.value='bob';const b=p.look();pending[1]({ok:true,json:async()=>({members:[{id:'BOB'}]})});await b;pending[0]({ok:true,json:async()=>({members:[{id:'ALICE'}]})});await a;console.log('Latest bob search displays:',p.shown[0].id,'(expected BOB)');
const Tree=load('charts/treemap');const t=new Tree();Object.assign(t,{tilesValue:[{name:'existing',messages:300,prior:250,pct:null,thin:true}],heightValue:100,hasHeightValue:true});let html='';const box={querySelector(){return null},insertAdjacentHTML(_,s){html=s}};t.draw(box,360);console.log('Existing low-volume treemap says new:',/class="t-v"[^>]*>new</.test(html),'(expected false)');
// Run the original Turbo response handler with a reset response.
let reloads=0,streams=0;const context=vm.createContext({URL,window:{location:{href:'https://example.invalid/'}},document:{addEventListener(){}},fetch:async()=>({status:205,ok:true,text:async()=>''}),Turbo:{StreamActions:{},renderStreamMessage(){streams++}}});let source=fs.readFileSync(root+'turbo_actions.js','utf8').replace('import { Turbo } from "@hotwired/turbo-rails"','').replaceAll('export function','function');vm.runInContext(source,context);await context.fetchChanges({dataset:{},getAttribute(){return '/chat'},reload(){reloads++}},'/chat','old');console.log('205 reset: reloads / empty streams:',reloads,streams,'(expected 1 / 0)');
})();
